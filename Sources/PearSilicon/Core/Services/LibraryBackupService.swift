import AppKit
import CryptoKit
import Darwin
import Foundation

/// A portable, uncompressed, single-entry archive. No installed files are modified.
/// Callers must hold their launch/mutation exclusion for the *whole* operation;
/// a running-process check alone cannot prevent an app from launching afterwards.
/// Native-container adoption and iOS load-command rebasing belong to the caller.
struct LibraryBackupService: Sendable {
    typealias RunningGuard = @Sendable (LibraryEntry) async throws -> Void
    typealias CapacityReader = @Sendable (URL) throws -> UInt64

    static let privacyWarning = "Backups include app data, saves, keychain secrets and other private files. They are not encrypted; store and share them securely."

    struct Limits: Sendable {
        var maximumInventoryBytes = 32 * 1_024 * 1_024
        var maximumEntries = 200_000
        var maximumFileBytes: UInt64 = 1 << 40
        var maximumPayloadBytes: UInt64 = 8 << 40
        var diskSpaceReserve: UInt64 = 16 * 1_024 * 1_024
    }

    private let limits: Limits
    private let requireStopped: RunningGuard
    private let availableCapacity: CapacityReader

    init(
        limits: Limits = Limits(),
        requireStopped: @escaping RunningGuard = LibraryBackupService.defaultRunningGuard,
        availableCapacity: @escaping CapacityReader = LibraryBackupService.diskCapacity
    ) {
        self.limits = limits
        self.requireStopped = requireStopped
        self.availableCapacity = availableCapacity
    }

    /// `to` is a filename in an existing directory; .pearbackup is appended if needed.
    /// The destination must not exist, including dangling symlinks. Hardlinks are
    /// flattened, internal relative symlinks retained, and external/dangling links refused.
    func backup(entry: LibraryEntry, to destination: URL) async throws -> URL {
        let work = Task.detached(priority: .userInitiated) {
            try await backupEntry(entry, to: destination)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// `libraryRoot` must already exist. Only a new platform/id is committed;
    /// existing entries are never merged, overwritten, rebased or re-signed.
    /// `preparedDirectoryPath` is retained so the caller can rebase before launch.
    func restore(from archive: URL, to libraryRoot: URL) async throws -> LibraryEntry {
        let work = Task.detached(priority: .userInitiated) {
            try await restoreEntry(from: archive, to: libraryRoot)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - Version 1 wire format

    // magic[8], big-endian version[4], JSON byte count[8], SHA256(JSON)[32],
    // bounded JSON, root xattr bytes, then (file bytes, xattr bytes) per node.
    // Hashes provide corruption detection, NOT authenticity or encryption.
    private static let magic = Data([0x50, 0x45, 0x41, 0x52, 0x42, 0x41, 0x4b, 0])
    private static let headerSize = 52
    private static let chunkSize = 1_024 * 1_024
    private static let resourceFork = "com.apple.ResourceFork"

    private struct Inventory: Codable {
        var schemaVersion: Int = 1
        var entry: LibraryManifest
        var root: Metadata
        var nodes: [Node]
    }

    private struct Metadata: Codable {
        var mode: UInt32
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var attributes: [Attribute]
    }

    private struct Attribute: Codable {
        var name: String
        var size: UInt64
        var sha256: String
    }

    private struct Node: Codable {
        enum Kind: String, Codable { case directory, file, symlink }
        var path: String
        var kind: Kind
        var size: UInt64
        var sha256: String?
        var target: String?
        var metadata: Metadata
    }

    private struct Fingerprint {
        let status: stat

        func matches(_ other: stat) -> Bool {
            status.st_dev == other.st_dev && status.st_ino == other.st_ino
                && status.st_mode == other.st_mode && status.st_size == other.st_size
                && status.st_mtimespec.tv_sec == other.st_mtimespec.tv_sec
                && status.st_mtimespec.tv_nsec == other.st_mtimespec.tv_nsec
                && status.st_ctimespec.tv_sec == other.st_ctimespec.tv_sec
                && status.st_ctimespec.tv_nsec == other.st_ctimespec.tv_nsec
        }
    }

    private final class Descriptor {
        let raw: Int32
        init(_ raw: Int32, _ operation: String) throws {
            guard raw >= 0 else { throw LibraryBackupService.ioError(operation) }
            self.raw = raw
        }
        deinit { Darwin.close(raw) }
    }

    private func backupEntry(_ entry: LibraryEntry, to destination: URL) async throws -> URL {
        try validateLimits()
        try Task.checkCancellation()
        try await requireStopped(entry)
        try LibraryPath.validate(entry.manifest, directory: entry.directoryURL)
        let sourceURL = try Self.location(entry.directoryURL)
        let source = try Self.openDirectory(sourceURL)
        let rootSnapshot = Fingerprint(status: try Self.status(source.raw))
        guard try Self.readManifest(source.raw) == entry.manifest else {
            throw Self.invalid("Entry metadata disagrees with pear-app.json")
        }

        var snapshots: [String: Fingerprint] = [:]
        var nodes: [Node] = []
        let rootMetadata = try metadata(source.raw)
        var inventoryBudget = try JSONEncoder().encode(rootMetadata).count + JSONEncoder().encode(entry.manifest).count + 1_024
        try scan(source.raw, relative: "", platform: entry.platform, nodes: &nodes, snapshots: &snapshots, inventoryBudget: &inventoryBudget)
        let inventory = Inventory(entry: entry.manifest, root: rootMetadata, nodes: nodes)
        let payloadSize = try validateInventory(inventory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(inventory)
        guard json.count <= limits.maximumInventoryBytes else {
            throw Self.invalid("Backup inventory exceeds the format limit")
        }

        var output = try Self.location(destination)
        if output.pathExtension.lowercased() != "pearbackup" {
            output.appendPathExtension("pearbackup")
        }
        try Self.validateFilename(output.lastPathComponent)
        let parentURL = output.deletingLastPathComponent().resolvingSymlinksInPath()
        output = parentURL.appendingPathComponent(output.lastPathComponent)
        let canonicalSource = sourceURL.resolvingSymlinksInPath()
        guard !Self.contains(parentURL, in: canonicalSource) else {
            throw Self.invalid("A backup cannot be written inside its source entry")
        }
        let parent = try Self.openDirectory(parentURL)
        try Self.requireAbsent(parent.raw, output.lastPathComponent)
        let archiveSize = try Self.add(UInt64(Self.headerSize + json.count), payloadSize)
        try checkCapacity(at: parentURL, bytes: archiveSize)

        let temporaryName = ".pear-backup-\(UUID().uuidString).tmp"
        let file = try Descriptor(openat(parent.raw, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600), "create backup staging file")
        var committed = false
        defer { if !committed { _ = unlinkat(parent.raw, temporaryName, 0) } }
        var header = Self.magic
        header.append(contentsOf: Self.bigEndian(1, bytes: 4))
        header.append(contentsOf: Self.bigEndian(UInt64(json.count), bytes: 8))
        header.append(contentsOf: SHA256.hash(data: json))
        try Self.write(file.raw, header)
        try Self.write(file.raw, json)
        try archiveAttributes(rootMetadata, from: source.raw, into: file.raw)
        for node in nodes {
            try Task.checkCancellation()
            let item = try Self.openNode(source.raw, node)
            try Self.verify(item.raw, snapshot: snapshots[node.path], path: node.path)
            if node.kind == .file {
                let digest = try Self.stream(size: node.size, read: { count, _ in
                    try Self.readExactly(item.raw, count)
                }, write: { data, _ in try Self.write(file.raw, data) })
                guard digest == node.sha256 else { throw Self.changed(node.path) }
            }
            try archiveAttributes(node.metadata, from: item.raw, into: file.raw)
            try Self.verify(item.raw, snapshot: snapshots[node.path], path: node.path)
        }
        try await requireStopped(entry)
        try Self.verify(source.raw, snapshot: rootSnapshot, path: "entry root")
        for node in nodes {
            let item = try Self.openNode(source.raw, node)
            try Self.verify(item.raw, snapshot: snapshots[node.path], path: node.path)
        }
        try Task.checkCancellation()
        guard fsync(file.raw) == 0 else { throw Self.ioError("sync backup") }
        try Self.commit(parent.raw, from: temporaryName, to: output.lastPathComponent)
        committed = true
        _ = fsync(parent.raw)
        return output
    }

    private func restoreEntry(from archive: URL, to libraryRoot: URL) async throws -> LibraryEntry {
        try validateLimits()
        try Task.checkCancellation()
        let archiveURL = try Self.location(archive)
        let file = try Descriptor(open(archiveURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), "open backup")
        let snapshot = Fingerprint(status: try Self.status(file.raw))
        guard snapshot.status.st_mode & S_IFMT == S_IFREG else {
            throw Self.invalid("Backup must be a regular file")
        }
        let header = try Self.readExactly(file.raw, Self.headerSize)
        guard header.prefix(8) == Self.magic, Self.integer(header, at: 8, count: 4) == 1 else {
            throw Self.invalid("Unsupported backup magic or version")
        }
        let length = Self.integer(header, at: 12, count: 8)
        guard length > 0, length <= UInt64(limits.maximumInventoryBytes) else {
            throw Self.invalid("Backup inventory exceeds the format limit")
        }
        let json = try Self.readExactly(file.raw, Int(length))
        guard Data(SHA256.hash(data: json)) == header.subdata(in: 20..<52) else {
            throw Self.invalid("Backup inventory checksum mismatch")
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: json)
        let payloadSize = try validateInventory(inventory)
        let expectedSize = try Self.add(UInt64(Self.headerSize) + length, payloadSize)
        guard snapshot.status.st_size >= 0, UInt64(snapshot.status.st_size) == expectedSize else {
            throw Self.invalid("Backup is truncated or contains extra bytes")
        }

        let rootURL = try Self.location(libraryRoot)
        let root = try Self.openDirectory(rootURL)
        try checkCapacity(at: rootURL, bytes: try Self.add(payloadSize, UInt64(inventory.nodes.count + 1) * 4_096))
        let platform = inventory.entry.platform.rawValue
        let destination = rootURL.appendingPathComponent(platform, isDirectory: true)
            .appendingPathComponent(inventory.entry.id, isDirectory: true)
        let result = LibraryEntry(manifest: inventory.entry, directoryURL: destination)
        try await requireStopped(result)

        if mkdirat(root.raw, platform, 0o700) != 0 && errno != EEXIST {
            throw Self.ioError("create platform directory")
        }
        // In particular, a pre-existing platform symlink must never redirect extraction.
        let platformDirectory = try Descriptor(openat(root.raw, platform, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "open platform directory")
        try Self.requireAbsent(platformDirectory.raw, inventory.entry.id)
        let stagingName = ".pear-restore-\(UUID().uuidString)"
        guard mkdirat(platformDirectory.raw, stagingName, 0o700) == 0 else {
            throw Self.ioError("create restore staging directory")
        }
        var committed = false
        defer { if !committed { Self.removeTree(platformDirectory.raw, name: stagingName) } }
        let staging = try Descriptor(openat(platformDirectory.raw, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "open restore staging directory")

        // The entire graph has been validated before creating any archive-controlled path.
        let directories = inventory.nodes.filter { $0.kind == .directory }
            .sorted { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
        for node in directories {
            try Task.checkCancellation()
            let (parent, name) = try Self.openParent(staging.raw, path: node.path)
            guard mkdirat(parent.raw, name, 0o700) == 0 else { throw Self.ioError("create archived directory") }
        }
        try restoreAttributes(inventory.root, from: file.raw, into: staging.raw)
        for node in inventory.nodes {
            try Task.checkCancellation()
            let (parent, name) = try Self.openParent(staging.raw, path: node.path)
            switch node.kind {
            case .file:
                let item = try Descriptor(openat(parent.raw, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600), "create archived file")
                let digest = try Self.stream(size: node.size, read: { count, _ in
                    try Self.readExactly(file.raw, count)
                }, write: { data, _ in try Self.write(item.raw, data) })
                guard digest == node.sha256 else { throw Self.invalid("File checksum mismatch: \(node.path)") }
                try restoreAttributes(node.metadata, from: file.raw, into: item.raw)
                try Self.applyMetadata(node.metadata, to: item.raw)
                guard fsync(item.raw) == 0 else { throw Self.ioError("sync restored file") }
            case .symlink:
                guard let target = node.target, symlinkat(target, parent.raw, name) == 0 else {
                    throw Self.ioError("create internal symbolic link")
                }
                let item = try Self.openNode(staging.raw, node)
                try restoreAttributes(node.metadata, from: file.raw, into: item.raw)
                try Self.applyMetadata(node.metadata, to: item.raw)
            case .directory:
                let item = try Self.openNode(staging.raw, node)
                try restoreAttributes(node.metadata, from: file.raw, into: item.raw)
            }
        }
        guard try Self.readSome(file.raw, 1).isEmpty else { throw Self.invalid("Backup contains extra bytes") }
        try Self.verify(file.raw, snapshot: snapshot, path: "backup file")
        guard try Self.readManifest(staging.raw) == inventory.entry else {
            throw Self.invalid("Archived pear-app.json disagrees with the inventory")
        }
        let stagedURL = destination.deletingLastPathComponent().appendingPathComponent(stagingName)
        try LibraryPath.validate(inventory.entry, directory: stagedURL)
        try await requireStopped(result)
        for node in directories.reversed() {
            let item = try Self.openNode(staging.raw, node)
            try Self.applyMetadata(node.metadata, to: item.raw)
        }
        try Self.applyMetadata(inventory.root, to: staging.raw)
        try Task.checkCancellation()
        guard fsync(staging.raw) == 0 else { throw Self.ioError("sync restored entry") }
        try Self.commit(platformDirectory.raw, from: stagingName, to: inventory.entry.id)
        committed = true
        _ = fsync(platformDirectory.raw)
        return result
    }

    // MARK: - Inventory admission boundary

    private func validateLimits() throws {
        guard (1...32 * 1_024 * 1_024).contains(limits.maximumInventoryBytes),
              (1...200_000).contains(limits.maximumEntries),
              limits.maximumFileBytes <= 1 << 40,
              limits.maximumPayloadBytes <= 8 << 40 else {
            throw Self.invalid("Invalid backup safety limits")
        }
    }

    private func validateInventory(_ inventory: Inventory) throws -> UInt64 {
        guard inventory.schemaVersion == 1, inventory.entry.formatVersion == 1 else {
            throw Self.invalid("Unsupported backup schema version")
        }
        try LibraryPath.validateComponent(inventory.entry.id)
        try LibraryPath.validateRelative(inventory.entry.payloadPath)
        guard inventory.entry.payloadPath.utf8.count <= 4_096,
              inventory.nodes.count <= limits.maximumEntries else {
            throw Self.invalid("Backup inventory exceeds the format limit")
        }
        var nodes: [String: Node] = [:]
        var portableNames = Set<String>()
        var size = try validateMetadata(inventory.root)
        for node in inventory.nodes {
            try Self.validateArchivePath(node.path, platform: inventory.entry.platform, kind: node.kind)
            let portableName = node.path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard nodes.updateValue(node, forKey: node.path) == nil,
                  portableNames.insert(portableName).inserted else {
                throw Self.invalid("Duplicate or case-colliding archive path")
            }
            switch node.kind {
            case .file:
                guard node.size <= limits.maximumFileBytes, Self.validHash(node.sha256), node.target == nil else {
                    throw Self.invalid("Invalid file inventory record")
                }
            case .directory:
                guard node.size == 0, node.sha256 == nil, node.target == nil else {
                    throw Self.invalid("Invalid directory inventory record")
                }
            case .symlink:
                guard node.size == 0, node.sha256 == nil, let target = node.target,
                      !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"), !target.contains(":"),
                      target.utf8.count <= 4_096, !Self.hasControl(target) else {
                    throw Self.invalid("Unsafe symbolic link target")
                }
            }
            size = try Self.add(size, node.size)
            size = try Self.add(size, validateMetadata(node.metadata))
            guard size <= limits.maximumPayloadBytes else { throw Self.invalid("Backup payload exceeds the format limit") }
        }
        guard let manifestNode = nodes[LibraryManifest.filename], manifestNode.kind == .file,
              manifestNode.size <= UInt64(Self.chunkSize), nodes[inventory.entry.payloadPath] != nil else {
            throw Self.invalid("Backup is missing its manifest or application payload")
        }
        for node in inventory.nodes {
            var parents = node.path.split(separator: "/").map(String.init)
            parents.removeLast()
            while !parents.isEmpty {
                guard nodes[parents.joined(separator: "/")]?.kind == .directory else {
                    throw Self.invalid("Archive parent is absent or is not a real directory")
                }
                parents.removeLast()
            }
            if node.kind == .symlink { try Self.validateLink(node.path, nodes: nodes) }
        }
        guard size <= limits.maximumPayloadBytes else { throw Self.invalid("Backup payload exceeds the format limit") }
        return size
    }

    private static func validateArchivePath(_ path: String, platform: LibraryPlatform, kind: Node.Kind) throws {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"),
              !path.contains("\\"), !hasControl(path) else { throw invalid("Unsafe archive path") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 128, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw invalid("Unsafe archive path component")
        }
        if path.contains(":") {
            // Wine drive mappings are POSIX symlink names, not Windows absolute paths.
            let drive = Array(parts.last!.utf8)
            guard platform == .wine, kind == .symlink, parts.count == 3,
                  parts[0] == "Prefix", parts[1] == "dosdevices", drive.count == 2,
                  drive[1] == 58, (65...90).contains(drive[0]) || (97...122).contains(drive[0]) else {
                throw invalid("Unsafe colon in archive path")
            }
        }
    }

    private static func validateLink(_ path: String, nodes: [String: Node]) throws {
        var pending = path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var hops = 0
        var cursor = 0
        while cursor < pending.count {
            let component = pending[cursor]
            cursor += 1
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else { throw invalid("Symbolic link escapes the entry") }
                resolved.removeLast()
                continue
            }
            guard !component.isEmpty else { throw invalid("Unsafe symbolic link target") }
            resolved.append(component)
            guard let node = nodes[resolved.joined(separator: "/")] else {
                throw invalid("Dangling symbolic links are not portable")
            }
            if node.kind == .symlink {
                hops += 1
                guard hops <= 40, let target = node.target else { throw invalid("Symbolic link cycle") }
                resolved.removeLast()
                pending = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending[cursor...]
                cursor = 0
            } else if cursor < pending.count && node.kind != .directory {
                throw invalid("Symbolic link traverses a non-directory")
            }
        }
    }

    private func validateMetadata(_ metadata: Metadata) throws -> UInt64 {
        guard metadata.mode <= 0o777, (0..<1_000_000_000).contains(metadata.modifiedNanoseconds),
              (-62_135_596_800...253_402_300_799).contains(metadata.modifiedSeconds),
              metadata.attributes.count <= 128 else { throw Self.invalid("Invalid file metadata") }
        var names = Set<String>()
        var size: UInt64 = 0
        for attribute in metadata.attributes {
            guard !attribute.name.isEmpty, attribute.name.utf8.count <= 127,
                  !Self.hasControl(attribute.name), !attribute.name.contains("/"),
                  attribute.name != "com.apple.decmpfs", names.insert(attribute.name).inserted,
                  Self.validHash(attribute.sha256),
                  attribute.size <= (attribute.name == Self.resourceFork ? UInt64(UInt32.max) : UInt64(Self.chunkSize)) else {
                throw Self.invalid("Invalid or oversized extended attribute")
            }
            size = try Self.add(size, attribute.size)
        }
        return size
    }

    // MARK: - Descriptor-relative source traversal

    private func scan(
        _ directory: Int32, relative: String, platform: LibraryPlatform,
        nodes: inout [Node], snapshots: inout [String: Fingerprint], inventoryBudget: inout Int
    ) throws {
        for name in try Self.children(directory, maximum: limits.maximumEntries - nodes.count).sorted() {
            try Task.checkCancellation()
            guard nodes.count < limits.maximumEntries else { throw Self.invalid("Too many backup entries") }
            let path = relative.isEmpty ? name : relative + "/" + name
            var status = stat()
            guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.ioError("inspect source file") }
            let kind: Node.Kind
            switch status.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            default: throw Self.invalid("Devices, sockets and FIFOs cannot be backed up: \(path)")
            }
            try Self.validateArchivePath(path, platform: platform, kind: kind)
            // Darwin rejects O_SYMLINK | O_NOFOLLOW. O_SYMLINK itself opens
            // the link, never its target; the fingerprint also verifies its type.
            let flags = kind == .symlink ? O_SYMLINK : O_NOFOLLOW | (kind == .directory ? O_DIRECTORY : 0)
            let item = try Descriptor(openat(directory, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | flags), "open source node")
            let snapshot = Fingerprint(status: status)
            try Self.verify(item.raw, snapshot: snapshot, path: path)
            var node = Node(path: path, kind: kind, size: 0, metadata: try metadata(item.raw))
            if kind == .file {
                guard status.st_size >= 0, UInt64(status.st_size) <= limits.maximumFileBytes else {
                    throw Self.invalid("Source file exceeds the format limit")
                }
                node.size = UInt64(status.st_size)
                node.sha256 = try Self.stream(size: node.size, read: { count, _ in
                    try Self.readExactly(item.raw, count)
                })
            } else if kind == .symlink {
                var buffer = [UInt8](repeating: 0, count: 4_097)
                let count = buffer.withUnsafeMutableBytes { readlinkat(directory, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
                guard count > 0, count <= 4_096, let target = String(bytes: buffer.prefix(count), encoding: .utf8) else {
                    throw Self.invalid("Invalid or oversized symbolic link")
                }
                node.target = target
            }
            inventoryBudget += try JSONEncoder().encode(node).count + 1
            guard inventoryBudget <= limits.maximumInventoryBytes else { throw Self.invalid("Backup inventory exceeds the format limit") }
            nodes.append(node)
            snapshots[path] = snapshot
            if kind == .directory {
                try scan(item.raw, relative: path, platform: platform, nodes: &nodes, snapshots: &snapshots, inventoryBudget: &inventoryBudget)
            }
            try Self.verify(item.raw, snapshot: snapshot, path: path)
        }
    }

    private func metadata(_ fd: Int32) throws -> Metadata {
        let status = try Self.status(fd)
        // Owners, ACLs, BSD flags and set-id/sticky bits are deliberately not portable.
        guard status.st_mode & 0o7000 == 0 else { throw Self.invalid("Privileged file permission bits are not portable") }
        let count = flistxattr(fd, nil, 0, 0)
        guard count >= 0, count <= 64 * 1_024 else { throw Self.invalid("Cannot read bounded extended-attribute list") }
        var names: [String] = []
        if count > 0 {
            var bytes = [UInt8](repeating: 0, count: count)
            let actual = bytes.withUnsafeMutableBytes { flistxattr(fd, $0.baseAddress!.assumingMemoryBound(to: CChar.self), count, 0) }
            guard actual == count, bytes.last == 0 else { throw Self.changed("extended attributes") }
            for part in bytes.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
                guard let name = String(bytes: part, encoding: .utf8) else { throw Self.invalid("Invalid extended attribute name") }
                // Logical file reads already decompress the data; this is storage encoding,
                // not a portable attribute, and restoring it would corrupt that logical copy.
                if name != "com.apple.decmpfs" { names.append(name) }
            }
        }
        guard names.count <= 128 else { throw Self.invalid("Too many extended attributes") }
        var attributes: [Attribute] = []
        for name in names.sorted() {
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0, UInt64(size) <= (name == Self.resourceFork ? UInt64(UInt32.max) : UInt64(Self.chunkSize)) else {
                throw Self.invalid("Cannot preserve oversized extended attribute: \(name)")
            }
            let digest = try Self.stream(size: UInt64(size), read: { count, offset in
                try Self.readAttribute(fd, name: name, count: count, offset: offset)
            })
            attributes.append(Attribute(name: name, size: UInt64(size), sha256: digest))
        }
        return Metadata(mode: UInt32(status.st_mode & 0o777), modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                        modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec), attributes: attributes)
    }

    private func archiveAttributes(_ metadata: Metadata, from source: Int32, into archive: Int32) throws {
        for attribute in metadata.attributes {
            guard fgetxattr(source, attribute.name, nil, 0, 0, 0) == attribute.size else { throw Self.changed(attribute.name) }
            let digest = try Self.stream(size: attribute.size, read: { count, offset in
                try Self.readAttribute(source, name: attribute.name, count: count, offset: offset)
            }, write: { data, _ in try Self.write(archive, data) })
            guard digest == attribute.sha256 else { throw Self.changed(attribute.name) }
        }
    }

    private func restoreAttributes(_ metadata: Metadata, from archive: Int32, into target: Int32) throws {
        for attribute in metadata.attributes {
            if attribute.size == 0 {
                guard fsetxattr(target, attribute.name, nil, 0, 0, 0) == 0 else { throw Self.ioError("restore empty extended attribute") }
            }
            let digest = try Self.stream(size: attribute.size, read: { count, _ in
                try Self.readExactly(archive, count)
            }, write: { data, offset in
                let result = data.withUnsafeBytes { fsetxattr(target, attribute.name, $0.baseAddress, $0.count, UInt32(offset), 0) }
                guard result == 0 else { throw Self.ioError("restore extended attribute: \(attribute.name)") }
            })
            guard digest == attribute.sha256 else { throw Self.invalid("Extended-attribute checksum mismatch") }
        }
    }

    private static func readAttribute(_ fd: Int32, name: String, count: Int, offset: UInt64) throws -> Data {
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, count, UInt32(offset), 0) }
        guard actual == count else { throw changed("extended attribute: \(name)") }
        return data
    }

    // MARK: - Bounded I/O and filesystem operations

    private static func stream(
        size: UInt64,
        read: (Int, UInt64) throws -> Data,
        write: (Data, UInt64) throws -> Void = { _, _ in }
    ) throws -> String {
        var hash = SHA256()
        var offset: UInt64 = 0
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(UInt64(chunkSize), size - offset))
            let data = try read(count, offset)
            guard data.count == count else { throw invalid("Truncated backup payload") }
            hash.update(data: data)
            try write(data, offset)
            offset += UInt64(count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readSome(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var actual: Int
        repeat { actual = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) } } while actual < 0 && errno == EINTR
        guard actual >= 0 else { throw ioError("read backup data") }
        data.count = actual
        return data
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            try Task.checkCancellation()
            let part = try readSome(fd, count - data.count)
            guard !part.isEmpty else { throw invalid("Truncated backup payload") }
            data.append(part)
        }
        return data
    }

    private static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ioError("write backup data") }
                offset += count
            }
        }
    }

    private static func children(_ fd: Int32, maximum: Int = 200_000) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw ioError("duplicate directory descriptor") }
        guard let directory = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ioError("enumerate directory")
        }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                guard errno == 0 else { throw ioError("read directory") }
                break
            }
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw invalid("Non-UTF8 filenames are not portable") }
            if name != "." && name != ".." {
                guard result.count < maximum else { throw invalid("Too many backup entries") }
                result.append(name)
            }
        }
        return result
    }

    private static func openDirectory(_ url: URL) throws -> Descriptor {
        try Descriptor(open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "open directory: \(url.path)")
    }

    private static func openParent(_ root: Int32, path: String) throws -> (Descriptor, String) {
        var parts = path.split(separator: "/").map(String.init)
        let name = parts.removeLast()
        var current = try Descriptor(dup(root), "duplicate entry descriptor")
        for part in parts {
            current = try Descriptor(openat(current.raw, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "open real parent directory")
        }
        return (current, name)
    }

    private static func openNode(_ root: Int32, _ node: Node) throws -> Descriptor {
        let (parent, name) = try openParent(root, path: node.path)
        let flags = node.kind == .symlink ? O_SYMLINK : O_NOFOLLOW | (node.kind == .directory ? O_DIRECTORY : 0)
        let fd = try Descriptor(openat(parent.raw, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | flags), "open archive node")
        let type = try status(fd.raw).st_mode & S_IFMT
        let expected = node.kind == .file ? S_IFREG : (node.kind == .directory ? S_IFDIR : S_IFLNK)
        guard type == expected else { throw changed(node.path) }
        return fd
    }

    private static func status(_ fd: Int32) throws -> stat {
        var result = stat()
        guard fstat(fd, &result) == 0 else { throw ioError("inspect open file") }
        return result
    }

    private static func verify(_ fd: Int32, snapshot: Fingerprint?, path: String) throws {
        guard let snapshot, snapshot.matches(try status(fd)) else { throw changed(path) }
    }

    private static func applyMetadata(_ metadata: Metadata, to fd: Int32) throws {
        guard fchmod(fd, mode_t(metadata.mode)) == 0 else { throw ioError("restore file permissions") }
        let time = timespec(tv_sec: Int(metadata.modifiedSeconds), tv_nsec: Int(metadata.modifiedNanoseconds))
        guard [time, time].withUnsafeBufferPointer({ futimens(fd, $0.baseAddress) }) == 0 else {
            throw ioError("restore modification time")
        }
    }

    private static func readManifest(_ root: Int32) throws -> LibraryManifest {
        let file = try Descriptor(openat(root, LibraryManifest.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), "read entry manifest")
        let info = try status(file.raw)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= chunkSize else {
            throw invalid("Invalid or oversized pear-app.json")
        }
        let data = try readExactly(file.raw, Int(info.st_size))
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(LibraryManifest.self, from: data) { return manifest }
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryManifest.self, from: data)
    }

    private static func requireAbsent(_ parent: Int32, _ name: String) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw invalid("Destination already exists; the existing item was kept")
        }
        guard errno == ENOENT else { throw ioError("check destination") }
    }

    private static func commit(_ parent: Int32, from source: String, to destination: String) throws {
        guard renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw invalid("Destination already exists; the existing item was kept") }
            throw ioError("exclusive same-volume commit")
        }
    }

    private static func removeTree(_ parent: Int32, name: String) {
        // A late failure can occur after applying archived mode 000. Repair
        // access descriptor-relatively without ever following a symlink.
        _ = fchmodat(parent, name, 0o700, AT_SYMLINK_NOFOLLOW)
        guard let directory = try? Descriptor(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "clean staging directory") else { return }
        _ = fchmod(directory.raw, 0o700)
        for child in (try? children(directory.raw)) ?? [] {
            var info = stat()
            if fstatat(directory.raw, child, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR {
                removeTree(directory.raw, name: child)
            } else {
                _ = unlinkat(directory.raw, child, 0)
            }
        }
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    private func checkCapacity(at url: URL, bytes: UInt64) throws {
        let needed = try Self.add(bytes, limits.diskSpaceReserve)
        let available = try availableCapacity(url)
        guard available >= needed else { throw Self.invalid("Insufficient disk space (need \(needed) bytes, have \(available))") }
    }

    static func diskCapacity(at url: URL) throws -> UInt64 {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw ioError("query available disk space") }
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow else { throw invalid("Invalid filesystem capacity") }
        return bytes
    }

    private static func location(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.isEmpty, !hasControl(url.path) else { throw invalid("Expected a local file URL") }
        return url.standardizedFileURL
    }

    private static func validateFilename(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !hasControl(name) else { throw invalid("Unsafe backup filename") }
    }

    private static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validHash(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw invalid("Backup size overflow") }
        return sum
    }

    private static func bigEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func integer(_ bytes: Data, at offset: Int, count: Int) -> UInt64 {
        bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func invalid(_ reason: String) -> PearError { .invalidPackage(reason) }
    private static func changed(_ path: String) -> PearError { invalid("Source changed during backup: \(path)") }
    private static func ioError(_ operation: String) -> PearError {
        let code = errno
        return .commandFailed(tool: "backup: \(operation)", status: code, output: String(cString: strerror(code)))
    }

    // MARK: - Default running-process guard

    /// Replacements must cover both native apps and Wine prefix users, not bundle IDs
    /// alone. This guard is checked at admission and immediately before commit.
    static func defaultRunningGuard(_ entry: LibraryEntry) async throws {
        let nativeRunning = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains {
                !$0.isTerminated && processBelongsToEntry(bundle: $0.bundleURL, executable: $0.executableURL, entry: entry)
            }
        }
        guard !nativeRunning else { throw invalid("Stop the app before backing up or restoring it") }
        try checkProcesses(entry)
    }

    static func processBelongsToEntry(bundle: URL?, executable: URL?, entry: LibraryEntry) -> Bool {
        [bundle, executable].compactMap { $0 }.contains {
            contains($0.resolvingSymlinksInPath(), in: entry.directoryURL.resolvingSymlinksInPath())
        }
    }

    private static func contains(_ child: URL, in root: URL) -> Bool {
        let path = child.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    private static func checkProcesses(_ entry: LibraryEntry) throws {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 131_072 else { throw invalid("Cannot verify running processes") }
        var pids = [pid_t](repeating: 0, count: Int(count) + 1_024)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0, actual < pids.count else { throw invalid("Cannot obtain a complete running-process list") }
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            try Task.checkCancellation()
            var pathBytes = [UInt8](repeating: 0, count: 4_096)
            let length = pathBytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            // Exited and inaccessible system processes cannot use our private entry.
            guard length > 0, let path = String(bytes: pathBytes.prefix(while: { $0 != 0 }), encoding: .utf8) else { continue }
            let executable = URL(fileURLWithPath: path)
            if processBelongsToEntry(bundle: nil, executable: executable, entry: entry) {
                throw invalid("Stop the app process before backing up or restoring it")
            }
            guard entry.platform == .wine, executable.lastPathComponent.lowercased().hasPrefix("wine") else { continue }
            guard let prefix = try winePrefix(pid: pid) else {
                // Some launchers remove WINEPREFIX. Fail closed rather than guess by
                // process name; a caller with tracked Wine sessions can inject a guard.
                throw invalid("Stop Wine processes or provide a prefix-aware running guard")
            }
            if contains(prefix.resolvingSymlinksInPath(), in: entry.directoryURL.resolvingSymlinksInPath()) {
                throw invalid("Stop Wine processes using this entry's Prefix before backing it up")
            }
        }
    }

    private static func winePrefix(pid: pid_t) throws -> URL? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: Self.chunkSize)
        var count = bytes.count
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &count, nil, 0)
        }
        if result != 0 {
            if errno == ESRCH { return nil }
            throw invalid("Cannot inspect Wine process; stop Wine before backing up")
        }
        guard count >= 4, count <= bytes.count else { return nil }
        bytes.removeSubrange(count...)
        return winePrefix(inProcessArguments: bytes)
    }

    /// KERN_PROCARGS2 uses argc, executable path, NUL padding, argv, then envp.
    /// Keep parsing independent of process enumeration so ambiguous/malformed
    /// environments can be tested without launching or depending on Wine.
    static func winePrefix(inProcessArguments bytes: [UInt8]) -> URL? {
        let count = bytes.count
        guard count >= 4, count <= chunkSize else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 65_536 else { return nil }
        var cursor = 4
        func skipString() -> Bool {
            while cursor < count && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < count else { return false }
            cursor += 1
            return true
        }
        guard skipString() else { return nil } // executable path, then NUL padding
        while cursor < count && bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc { guard skipString() else { return nil } }
        while cursor < count && bytes[cursor] != 0 {
            let start = cursor
            guard skipString() else { return nil }
            if let value = String(bytes: bytes[start..<(cursor - 1)], encoding: .utf8), value.hasPrefix("WINEPREFIX=") {
                let path = String(value.dropFirst(11))
                guard path.hasPrefix("/"), !hasControl(path) else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }
}
