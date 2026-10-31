import Darwin
import Foundation

/// How an app is prepared to run on macOS.
///
/// `.compatibility` loads the in-process compatibility runtime through an
/// `LC_LOAD_DYLIB` entry. Runtime hooks adapt selected API behavior.
///
/// `.nativeContainer` removes PearSilicon's runtime artifacts. Despite the name,
/// this preparation mode does not itself add App Sandbox entitlements or
/// establish secure per-app isolation.
 enum PreparationMode: String, Sendable {
    case compatibility
    /// Same in-process runtime, but loaded by the launcher through
    /// `DYLD_INSERT_LIBRARIES` instead of an `LC_LOAD_DYLIB` in the app binary.
    /// Experimental launcher loading with a local KV/static-device-profile host.
    case compatibilityEnvironment
    case nativeContainer
}

/// Installs app package files into the library, prepares them to run on macOS,
/// scans the library and removes apps.
///
/// Installation pipeline:
///   1. unzip the package (it is a zip) into a temporary directory
///   2. locate `Payload/*.app` and read its `Info.plist`
///   3. validate the bundle and clone it into a sibling transaction directory
///   4. prepare the copy for macOS using its final installation paths
///   5. adhoc re-sign, verify, and atomically commit the prepared copy
///
/// Steps 4–5 are what allows an arm64 iOS binary to be loaded by macOS via the
/// `/System/iOSSupport` runtime. This is interoperability work only: it adapts
/// the binary's declared platform and leaves all application logic untouched.
final class PackageInstaller: @unchecked Sendable {

    /// Injectable operations keep installation and mode-switch failure tests on synthetic bundles.
    struct PreparationTools {
        var runtimeLibraryURL: () -> URL? = { AppLauncher.runtimeLibraryURL() }
        var removeLoadDylib: (URL, String) throws -> Bool = {
            try BinaryPatcher.removeLoadDylib(at: $0, containing: $1)
        }
        var run: (String, [String]) throws -> String = { try Shell.run($0, $1) }
        var requireStopped: @MainActor (InstalledApp) throws -> Void = { app in
            try AppLauncher.requireStopped(app)
        }
    }

    private let fileManager = FileManager.default
    private let libraryURL: URL
    private let workRoot: URL
    private let preparationTools: PreparationTools


    init(libraryURL: URL, preparationTools: PreparationTools = PreparationTools()) {
        self.libraryURL = libraryURL
        self.preparationTools = preparationTools
        self.workRoot = libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent("Work", isDirectory: true)
    }

    // MARK: - Scanning

    func scanLibrary() throws -> [InstalledApp] {
        guard fileManager.fileExists(atPath: libraryURL.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { $0.pathExtension == "app" }
            .compactMap { try? makeInstalledApp(fromBundleAt: $0) }
    }

    // MARK: - Install

    func install(packageAt url: URL, mode: PreparationMode = .compatibility) async throws -> InstalledApp {
        guard fileManager.fileExists(atPath: url.path) else {
            throw PearError.packageNotFound(url.lastPathComponent)
        }

        // Validate the archive's own entry names before asking an external tool
        // to extract it. unzip currently confines `..` entries to the destination,
        // but that is a tool policy, not an admission check: reject traversal,
        // absolute paths and ambiguous separators as malformed input.
        try validateArchivePaths(at: url)

        let tempDir = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // Even a CRC failure confined to an asset invalidates the extraction.
        // Shell.run rejects every nonzero status, including unzip's warning status.
        do {
            _ = try preparationTools.run("/usr/bin/unzip", ["-o", "-q", url.path, "-d", tempDir.path])
        } catch PearError.commandFailed(let tool, let status, let output) {
            let diagnostic = output.range(of: "CRC", options: .caseInsensitive) == nil
                ? output
                : "Archive CRC check failed; re-download the package. No app was installed.\n" + output
            throw PearError.commandFailed(tool: tool, status: status, output: diagnostic)
        }

        // 2) find Payload/*.app
        let payload = tempDir.appendingPathComponent("Payload", isDirectory: true)
        guard let app = try fileManager.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" }) else {
            throw PearError.invalidPackage("no .app inside Payload")
        }

        return try await installBundle(at: app, mode: mode)
    }

    /// Reads the ZIP central directory without extracting anything. Only entry
    /// names are inspected; file contents, CRC and signatures are handled by the
    /// existing extraction and preparation steps.
    private func validateArchivePaths(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else {
            throw PearError.invalidPackage("\(url.lastPathComponent): not a valid ZIP archive")
        }

        let tailSize = min(fileSize, 65_557) // EOCD + maximum comment
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        guard let eocd = tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards) else {
            throw PearError.invalidPackage("\(url.lastPathComponent): ZIP end record is missing")
        }
        let eocdOffset = eocd.lowerBound
        guard eocdOffset + 22 <= tail.count else {
            throw PearError.invalidPackage("\(url.lastPathComponent): truncated ZIP end record")
        }

        var entries = UInt64(tail.u16(at: eocdOffset + 10))
        var directorySize = UInt64(tail.u32(at: eocdOffset + 12))
        var directoryOffset = UInt64(tail.u32(at: eocdOffset + 16))

        if entries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            guard eocdOffset >= 20 else {
                throw PearError.invalidPackage("\(url.lastPathComponent): ZIP64 locator is missing")
            }
            let locator = eocdOffset - 20
            guard tail.u32(at: locator) == 0x0706_4B50 else {
                throw PearError.invalidPackage("\(url.lastPathComponent): ZIP64 locator is invalid")
            }
            let zip64Offset = tail.u64(at: locator + 8)
            guard zip64Offset + 56 <= fileSize else {
                throw PearError.invalidPackage("\(url.lastPathComponent): ZIP64 end record is missing")
            }
            try handle.seek(toOffset: zip64Offset)
            let zip64 = try handle.read(upToCount: 56) ?? Data()
            guard zip64.count == 56, zip64.u32(at: 0) == 0x0606_4B50 else {
                throw PearError.invalidPackage("\(url.lastPathComponent): ZIP64 end record is invalid")
            }
            entries = zip64.u64(at: 32)
            directorySize = zip64.u64(at: 40)
            directoryOffset = zip64.u64(at: 48)
        }

        guard directoryOffset <= fileSize,
              directorySize <= fileSize - directoryOffset else {
            throw PearError.invalidPackage("\(url.lastPathComponent): ZIP directory lies outside the file")
        }

        var offset = directoryOffset
        let end = directoryOffset + directorySize
        var seen: UInt64 = 0
        while offset < end {
            guard end - offset >= 46 else {
                throw PearError.invalidPackage("\(url.lastPathComponent): truncated ZIP directory entry")
            }
            try handle.seek(toOffset: offset)
            let header = try handle.read(upToCount: 46) ?? Data()
            guard header.count == 46, header.u32(at: 0) == 0x0201_4B50 else {
                throw PearError.invalidPackage("\(url.lastPathComponent): invalid ZIP directory entry")
            }
            let nameLength = UInt64(header.u16(at: 28))
            let extraLength = UInt64(header.u16(at: 30))
            let commentLength = UInt64(header.u16(at: 32))
            let variableLength = nameLength + extraLength + commentLength
            guard end - offset - 46 >= variableLength else {
                throw PearError.invalidPackage("\(url.lastPathComponent): truncated ZIP entry name")
            }
            let nameData = try handle.read(upToCount: Int(nameLength)) ?? Data()
            guard nameData.count == Int(nameLength),
                  let name = String(data: nameData, encoding: .utf8) else {
                throw PearError.invalidPackage("\(url.lastPathComponent): entry name is not UTF-8")
            }
            try validateArchiveEntryName(name, archive: url.lastPathComponent)
            offset += 46 + variableLength
            seen += 1
        }
        guard offset == end, seen == entries else {
            throw PearError.invalidPackage("\(url.lastPathComponent): ZIP directory is inconsistent")
        }
    }

    private func validateArchiveEntryName(_ name: String, archive: String) throws {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        let driveLetter = name.count >= 2 && name[name.index(after: name.startIndex)] == ":"
            && name.first?.isLetter == true
        guard !name.isEmpty,
              !name.contains("\0"),
              !name.contains("\\"),
              !name.hasPrefix("/"),
              !driveLetter,
              !components.contains("..") else {
            throw PearError.invalidPackage(
                "\(archive): archive contains an unsafe path. No app was installed."
            )
        }
    }

    /// Installs an already-built `.app` bundle (for example the product of a
    /// toolchain build) instead of a package. The bundle is copied as-is (ditto, so
    /// symlinks and extended attributes survive), then prepared and signed the
    /// same way an app package is.
    ///
    /// Simulator builds are rejected: their binaries target the simulator
    /// runtime and cannot be turned into Mac Catalyst binaries.
    func installBundle(at sourceURL: URL, mode: PreparationMode = .compatibility) async throws -> InstalledApp {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PearError.packageNotFound(sourceURL.lastPathComponent)
        }
        try validateBundleForPreparation(at: sourceURL)
        if isSimulatorBuild(at: sourceURL) {
            throw PearError.invalidPackage(
                "\(sourceURL.lastPathComponent) is a simulator build. "
                + "Build for a device (destination generic/platform=iOS) or run \"pearsilicon build\" instead."
            )
        }

        let probe = try makeInstalledApp(fromBundleAt: sourceURL)
        guard !probe.id.isEmpty, probe.id != ".", probe.id != "..",
              !probe.id.contains("/"), !probe.id.contains("\\"), !probe.id.utf8.contains(0) else {
            throw PearError.invalidPackage("Info.plist: bundle identifier is not a safe library filename")
        }
        let lease = try AppLaunchLease.acquire(appID: probe.id, libraryURL: libraryURL)
        defer { lease.release() }
        try await preparationTools.requireStopped(probe)

        let destination = libraryURL.appendingPathComponent("\(probe.id).app", isDirectory: true)
        let sourcePath = sourceURL.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path
        guard !destinationPath.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(destinationPath + "/") else {
            throw PearError.invalidPackage("Source and installation bundles must not contain one another")
        }
        let replacing = try itemExists(at: destination)
        if replacing {
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw PearError.invalidPackage("Installation target is not a regular bundle directory: \(destination.path)")
            }
        }
        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let transaction = libraryURL.appendingPathComponent(".pear-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: transaction) }
        let staged = transaction.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        _ = try preparationTools.run("/usr/bin/ditto", ["--clone", sourceURL.path, staged.path])
        try finalizeInstall(at: staged, mode: mode, targetBundleURL: destination)
        let installed = try makeInstalledApp(fromBundleAt: staged, targetBundleURL: destination)
        guard installed.id == probe.id else { throw PearError.invalidPackage("Bundle identifier changed during preparation") }
        try await preparationTools.requireStopped(probe)
        try commitBundle(at: staged, to: destination, replacing: replacing)

        // Nothing after commit may turn a completed replacement into a reported failure.
        let odrRoot = libraryURL.deletingLastPathComponent().appendingPathComponent("ODR", isDirectory: true)
        try? fileManager.createDirectory(
            at: odrRoot.appendingPathComponent(probe.id, isDirectory: true), withIntermediateDirectories: true
        )
        return installed
    }

    private func finalizeInstall(at staged: URL, mode: PreparationMode, targetBundleURL: URL) throws {
        try prepareForMacOS(at: staged, mode: mode, targetBundleURL: targetBundleURL)
        try signBundle(at: staged, mode: mode)
        _ = try preparationTools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        try validateBundleForPreparation(at: staged)
        try validatePreparationMode(at: staged, mode: mode, targetBundleURL: targetBundleURL)
    }

    private func commitBundle(at staged: URL, to destination: URL, replacing: Bool) throws {
        // Both paths are on the library filesystem. A failed rename leaves the
        // installed bundle in place; a swap leaves the old copy in staging.
        let flags = replacing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renamex_np(staged.path, destination.path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: destination.path
            ])
        }
    }

    /// True when the bundle declares itself as an iOS Simulator build.
    private func isSimulatorBuild(at bundleURL: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
            as? [String: Any] else { return false }
        if let platform = info["DTPlatformName"] as? String,
           platform.lowercased().contains("simulator") {
            return true
        }
        if let platforms = info["CFBundleSupportedPlatforms"] as? [String],
           platforms.contains(where: { $0.lowercased().contains("simulator") }) {
            return true
        }
        return false
    }

    // MARK: - Removal

    @MainActor
    func uninstall(_ app: InstalledApp) throws {
        let lease = try AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
        defer { lease.release() }
        try preparationTools.requireStopped(app)
        try fileManager.removeItem(at: app.bundleURL)
    }

    // MARK: - Relocation

    /// Rewrites absolute load-command paths that point inside the original
    /// bundle so they point inside the copied bundle. Matching the bundle prefix
    /// instead of a two-level library root keeps flat (`Applications/*.app`)
    /// and wrapped (`ios-apps/<id>/Payload/*.app`) layouts working.
    func relocateInstalledBundle(
        at stagedBundleURL: URL, from originalBundleURL: URL, to targetBundleURL: URL
    ) throws {
        let oldRoot = originalBundleURL.standardizedFileURL.path
        let newRoot = targetBundleURL.standardizedFileURL.path
        guard oldRoot != newRoot else { return }
        try validateStagingIsolation(at: stagedBundleURL)

        let app = try makeInstalledApp(fromBundleAt: stagedBundleURL)
        var targets = Set<URL>([app.executableURL])
        targets.formUnion(try machOTargets(in: stagedBundleURL))
        for file in targets {
            try relocateLoadPaths(at: file, oldRoot: oldRoot, newRoot: newRoot)
        }

        // Preserve the mode the copy already has; relocation must not update or
        // replace its runtime, only point its absolute paths at the new root.
        let mode: PreparationMode
        if fileManager.fileExists(atPath: Self.injectionMarkerURL(in: stagedBundleURL).path) {
            mode = .compatibilityEnvironment
        } else if BinaryPatcher.hasLoadDylib(at: app.executableURL, containing: "libPearRuntime") {
            mode = .compatibility
        } else {
            mode = .nativeContainer
        }
        try signBundle(at: stagedBundleURL, mode: mode)
        _ = try preparationTools.run(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedBundleURL.path]
        )
        // A rebase must leave every compatibility load path pointing at the
        // staged bundle's own Frameworks directory. Without this check a stale
        // absolute path could still resolve on the old disk and hide the fault.
        try validatePreparationMode(
            at: stagedBundleURL, mode: mode, targetBundleURL: targetBundleURL
        )
        guard !loadPaths(at: stagedBundleURL).contains(where: { $0.hasPrefix(oldRoot + "/") }) else {
            throw PearError.invalidPackage(
                "Relocation left a path pointing at the previous location in \(stagedBundleURL.lastPathComponent)"
            )
        }
    }

    private func loadPaths(at bundleURL: URL) -> [String] {
        let app = try? makeInstalledApp(fromBundleAt: bundleURL)
        var urls = Set<URL>()
        if let app { urls.insert(app.executableURL) }
        urls.formUnion((try? machOTargets(in: bundleURL)) ?? [])
        return urls.flatMap { (try? preparationLoadPaths(at: $0))?.flatMap {
            $0.dependencies.map(\.path) + $0.rpaths
        } ?? [] }
    }

    /// Rewrites load commands whose path starts at `oldRoot`. Strings that fit
    /// are rewritten in place; longer replacements fall back to
    /// `install_name_tool`, which can grow a load command when header space
    /// allows. Any failure propagates so the migration can roll back.
    private func relocateLoadPaths(at url: URL, oldRoot: String, newRoot: String) throws {
        let data = try Data(contentsOf: url)
        guard !BinaryPatcher.machO64Offsets(data).isEmpty else { return }
        var rewritten = data
        var changed = false
        var fallback: [(command: UInt32, old: String, new: String)] = []

        for base in BinaryPatcher.machO64Offsets(data) {
            let count = Int(readU32(data, base + 16))
            let end = base + 32 + Int(readU32(data, base + 20))
            guard end <= data.count, count <= (end - base - 32) / 8 else {
                throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
            }
            var offset = base + 32
            for _ in 0..<count {
                guard offset + 8 <= end else {
                    throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
                }
                let command = readU32(data, offset)
                let size = Int(readU32(data, offset + 4))
                guard size >= 8, offset + size <= end else {
                    throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
                }
                if isPathCommand(command) {
                    let nameOffset = Int(readU32(data, offset + 8))
                    let minimum = command == Self.rpathCommand ? 12 : 24
                    guard nameOffset >= minimum, nameOffset < size,
                          let terminator = data[(offset + nameOffset)..<(offset + size)].firstIndex(of: 0) else {
                        throw PearError.invalidPackage("Invalid Mach-O path command: \(url.lastPathComponent)")
                    }
                    let path = String(decoding: data[(offset + nameOffset)..<terminator], as: UTF8.self)
                    if path == oldRoot || path.hasPrefix(oldRoot + "/") {
                        let replacement = newRoot + path.dropFirst(oldRoot.count)
                        let bytes = Array(replacement.utf8) + [0]
                        if bytes.count <= terminator + 1 - (offset + nameOffset) {
                            rewritten.replaceSubrange(
                                (offset + nameOffset)..<(offset + nameOffset + bytes.count), with: bytes
                            )
                            changed = true
                        } else {
                            fallback.append((command, path, replacement))
                        }
                    }
                }
                offset += size
            }
            guard offset == end else {
                throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
            }
        }

        if changed {
            let permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
            try rewritten.write(to: url, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes(
                    [.posixPermissions: permissions], ofItemAtPath: url.path
                )
            }
        }
        for entry in fallback {
            if entry.command == Self.rpathCommand {
                _ = try preparationTools.run(
                    "/usr/bin/install_name_tool", ["-rpath", entry.old, entry.new, url.path]
                )
            } else if entry.command == Self.idDylibCommand {
                _ = try preparationTools.run(
                    "/usr/bin/install_name_tool", ["-id", entry.new, url.path]
                )
            } else {
                _ = try preparationTools.run(
                    "/usr/bin/install_name_tool", ["-change", entry.old, entry.new, url.path]
                )
            }
        }
    }

    private static let idDylibCommand: UInt32 = 0x0D
    private static let rpathCommand: UInt32 = 0x8000_001C
    private static let dependencyCommands: Set<UInt32> = [0x0C, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]

    private func isPathCommand(_ command: UInt32) -> Bool {
        command == Self.idDylibCommand || command == Self.rpathCommand
            || Self.dependencyCommands.contains(command)
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    // MARK: - Prepare for macOS

    /// Rewrites the bundle so macOS will load it as a Mac Catalyst app.
    /// Staged preparation uses `targetBundleURL` for all absolute load paths;
    /// ordinary installs default to the bundle being prepared.
    func prepareForMacOS(
        at bundleURL: URL,
        mode: PreparationMode = .compatibility,
        targetBundleURL: URL? = nil
    ) throws {
        try validateBundleForPreparation(at: bundleURL)
        let target = targetBundleURL ?? bundleURL
        try patchInfoPlist(at: bundleURL)
        removeLegacySignatureArtifacts(at: bundleURL)
        try installMarketplaceKitStubIfNeeded(at: bundleURL, targetBundleURL: target)
        _ = try patchMachOBinaries(at: bundleURL)
        switch mode {
        case .compatibility:
            try loadRuntime(at: bundleURL, targetBundleURL: target, addLoadCommand: true)
        case .compatibilityEnvironment:
            try loadRuntime(at: bundleURL, targetBundleURL: target, addLoadCommand: false)
        case .nativeContainer:
            try removeRuntimeArtifacts(at: bundleURL)
        }
        try validateBundleForPreparation(at: bundleURL)
        try validatePreparationMode(at: bundleURL, mode: mode, targetBundleURL: target)
        ensureExecutableBits(at: bundleURL)
        _ = try? preparationTools.run("/usr/bin/xattr", ["-cr", bundleURL.path])
    }

    /// The selected mode, inferred from the marker/load command. This is only
    /// a hint for UI/callers; `setPreparationMode` validates the complete state.
    func currentPreparationMode(for app: InstalledApp) -> PreparationMode {
        if (try? itemExists(at: Self.injectionMarkerURL(in: app.bundleURL))) == true {
            return .compatibilityEnvironment
        }
        return BinaryPatcher.hasLoadDylib(at: app.executableURL, containing: "libPearRuntime")
            ? .compatibility : .nativeContainer
    }

    /// Sidecar that records a launcher-injected runtime. It lives next to the
    /// runtime so both the launcher and `currentPreparationMode` can see it
    /// without reading the executable.
    static func injectionMarkerURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Frameworks/.pear-injection")
    }

    private func itemExists(at url: URL) throws -> Bool {
        // fileExists follows symlinks, which would hide a dangling marker or
        // compatibility artifact from both validation and removal.
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    /// Prepares and signs a separate copy before atomically exchanging it with
    /// the installed bundle. Until that exchange, rollback is just discarding
    /// the copy; no failed preparation or signature can alter the original.
    @MainActor
    func setPreparationMode(_ mode: PreparationMode, for app: InstalledApp, launchLease: AppLaunchLease? = nil, force: Bool = false) throws {
        let lease = try launchLease ?? AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
        defer { if launchLease == nil { lease.release() } }
        try lease.validate(appID: app.id, libraryURL: libraryURL)
        try validateBundleForPreparation(at: app.bundleURL)
        if !force, try preparationModeIsValid(at: app.bundleURL, mode: mode, targetBundleURL: app.bundleURL) {
            return
        }
        try preparationTools.requireStopped(app)

        // A sibling keeps the exchange on the same filesystem. Copy the current
        // bundle, not the IPA, so user-added resources and third-party changes survive.
        let transaction = app.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".pear-preparation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: transaction) }
        let staged = transaction.appendingPathComponent(app.bundleURL.lastPathComponent, isDirectory: true)
        _ = try preparationTools.run("/usr/bin/ditto", ["--clone", app.bundleURL.path, staged.path])
        try validateStagingIsolation(at: staged)
        let stagedApp = try makeInstalledApp(fromBundleAt: staged)
        _ = try preparationLoadPaths(at: stagedApp.executableURL)

        try finalizeInstall(at: staged, mode: mode, targetBundleURL: app.bundleURL)
        try preparationTools.requireStopped(app)
        try commitBundle(at: staged, to: app.bundleURL, replacing: true)
    }

    /// Installs a new PearSilicon build's runtime into an already-installed iOS
    /// app. Only runs when the runtime fingerprint differs; the app's own files
    /// and data are preserved and the staged copy is re-signed before exchange.
    @MainActor
    func refreshRuntimeIfNeeded(
        for app: InstalledApp, sourceRuntimeDirectory: URL, launchLease: AppLaunchLease? = nil
    ) throws -> Bool {
        let mode = currentPreparationMode(for: app)
        guard mode != .nativeContainer else { return false }
        let installed = app.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let installedRevision = try RuntimeRevision.fingerprint(in: installed)
        let sourceRevision = try RuntimeRevision.fingerprint(in: sourceRuntimeDirectory)
        guard let sourceRevision else {
            throw PearError.missingRuntimeComponent("libPearRuntime.dylib")
        }
        guard installedRevision != sourceRevision else { return false }
        try setPreparationMode(mode, for: app, launchLease: launchLease, force: true)
        return true
    }

    /// Read-only admission check, not a decryption or runtime-compatibility test.
    /// Every regular file is inspected, including hidden and extensionless files.
    /// This deliberately creates no work, library, or transaction directories.
    func validateBundleForPreparation(at bundleURL: URL) throws {
        for file in try machOTargets(in: bundleURL) {
            try validateBinaryForPreparation(at: file, in: bundleURL)
        }
    }

    private func validateBinaryForPreparation(at file: URL, in bundleURL: URL) throws {
        do {
            try BinaryPatcher.validateForPreparation(at: file)
        } catch {
            throw preparationError(error, at: file, in: bundleURL)
        }
    }

    private func preparationError(_ error: Error, at file: URL, in bundleURL: URL) -> PearError {
        let path = file.standardizedFileURL.path
        let roots = [bundleURL.standardizedFileURL.path, bundleURL.resolvingSymlinksInPath().path]
        let relative: String
        if let root = roots.first(where: { path.hasPrefix($0 + "/") }) {
            relative = String(path.dropFirst(root.count + 1))
        } else {
            relative = roots.contains(path) ? bundleURL.lastPathComponent : path
        }
        let detail: String
        if case PearError.invalidPackage(let reason) = error { detail = reason }
        else { detail = error.localizedDescription }
        return .invalidPackage("\(relative): \(detail)")
    }

    private struct BundleEntry {
        let url: URL
        let kind: FileAttributeType
    }

    private func bundleEntries(at bundleURL: URL) throws -> [BundleEntry] {
        let root = bundleURL.resolvingSymlinksInPath().path
        do {
            let attributes = try fileManager.attributesOfItem(atPath: bundleURL.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw PearError.invalidPackage("Bundle root must be a directory, not a symlink")
            }
        } catch { throw preparationError(error, at: bundleURL, in: bundleURL) }

        var inspectionError: Error?
        guard let enumerator = fileManager.enumerator(
            at: bundleURL, includingPropertiesForKeys: nil, options: [],
            errorHandler: { item, error in
                inspectionError = self.preparationError(error, at: item, in: bundleURL)
                return false
            }
        ) else {
            throw PearError.invalidPackage("\(bundleURL.lastPathComponent): could not enumerate bundle")
        }
        var entries: [BundleEntry] = []
        for case let item as URL in enumerator {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: item.path)
                guard let kind = attributes[.type] as? FileAttributeType else {
                    throw PearError.invalidPackage("Could not determine file type")
                }
                if kind == .typeSymbolicLink {
                    // Directory enumeration does not descend through symlinks.
                    // Their real internal targets are inspected at their own paths.
                    enumerator.skipDescendants()
                    let parent = URL(
                        fileURLWithPath: item.deletingLastPathComponent().resolvingSymlinksInPath().path,
                        isDirectory: true
                    )
                    let destination = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                    let resolved = URL(fileURLWithPath: destination, relativeTo: parent)
                        .standardizedFileURL.resolvingSymlinksInPath().path
                    guard resolved == root || resolved.hasPrefix(root + "/") else {
                        throw PearError.invalidPackage("Cannot prepare a bundle containing an external symlink")
                    }
                } else if kind != .typeDirectory && kind != .typeRegular {
                    throw PearError.invalidPackage("Unsupported non-regular bundle entry")
                }
                entries.append(BundleEntry(url: item, kind: kind))
            } catch { throw preparationError(error, at: item, in: bundleURL) }
        }
        if let inspectionError { throw inspectionError }
        return entries
    }

    private func validateStagingIsolation(at bundleURL: URL) throws {
        _ = try bundleEntries(at: bundleURL)
    }

    private struct PreparationLoadPaths {
        var dependencies: [(command: UInt32, path: String)] = []
        var rpaths: [String] = []
    }

    /// Unlike the patcher's best-effort predicates, this reader fails closed on
    /// unreadable/invalid executables and checks every 64-bit slice and exact path.
    private func preparationLoadPaths(at executableURL: URL) throws -> [PreparationLoadPaths] {
        let data = try Data(contentsOf: executableURL)
        let bases = BinaryPatcher.machO64Offsets(data)
        func invalid() -> PearError {
            .invalidPackage("Invalid Mach-O load commands: \(executableURL.lastPathComponent)")
        }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard !bases.isEmpty else { throw invalid() }
        return try bases.map { base in
            guard base + 32 <= data.count else { throw invalid() }
            let count = Int(u32(base + 16))
            let end = base + 32 + Int(u32(base + 20))
            guard end <= data.count, count <= (end - base - 32) / 8 else { throw invalid() }
            var paths = PreparationLoadPaths()
            var offset = base + 32
            for _ in 0..<count {
                guard offset + 8 <= end else { throw invalid() }
                let command = u32(offset)
                let size = Int(u32(offset + 4))
                guard size >= 8, offset + size <= end else { throw invalid() }
                let isDependency = [UInt32(0x0C), 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023].contains(command)
                if isDependency || command == BinaryPatcher.LoadCommand.rpath {
                    let minimum = isDependency ? 24 : 12
                    guard size >= minimum else { throw invalid() }
                    let nameOffset = Int(u32(offset + 8))
                    guard nameOffset >= minimum, nameOffset < size,
                          let terminator = data[(offset + nameOffset)..<(offset + size)].firstIndex(of: 0),
                          let path = String(data: data[(offset + nameOffset)..<terminator], encoding: .utf8)
                    else { throw invalid() }
                    if isDependency { paths.dependencies.append((command, path)) }
                    else { paths.rpaths.append(path) }
                }
                offset += size
            }
            guard offset == end else { throw invalid() }
            return paths
        }
    }

    private func preparationModeIsValid(
        at bundleURL: URL, mode: PreparationMode, targetBundleURL: URL
    ) throws -> Bool {
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        let slices = try preparationLoadPaths(at: app.executableURL)
        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        let targetFrameworks = targetBundleURL.appendingPathComponent("Frameworks")
        let marker = Self.injectionMarkerURL(in: bundleURL)
        let markerExists = try itemExists(at: marker)
        let artifacts = ["libPearRuntime.dylib", "libswiftUIKit.dylib", "libcxxcompat.dylib"]
        func regularFile(_ url: URL) -> Bool {
            (try? fileManager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular
        }

        switch mode {
        case .compatibility:
            guard !markerExists, regularFile(frameworks.appendingPathComponent(artifacts[0])) else { return false }
        case .compatibilityEnvironment:
            guard regularFile(marker), regularFile(frameworks.appendingPathComponent(artifacts[0])) else { return false }
            guard try Data(contentsOf: marker) == Data("environment\n".utf8) else { return false }
        case .nativeContainer:
            guard !markerExists,
                  try artifacts.allSatisfy({ try !itemExists(at: frameworks.appendingPathComponent($0)) })
            else { return false }
        }

        return slices.allSatisfy { paths in
            let runtimeLoads = paths.dependencies.filter { $0.path.contains("libPearRuntime") }
            let cxxLoads = paths.dependencies.filter { $0.path.contains("libcxxcompat") }
            if mode == .compatibility {
                guard runtimeLoads.count == 1,
                      runtimeLoads[0].command == BinaryPatcher.LoadCommand.loadDylib,
                      runtimeLoads[0].path == targetFrameworks.appendingPathComponent(artifacts[0]).path
                else { return false }
            } else if !runtimeLoads.isEmpty { return false }
            if mode == .nativeContainer { return cxxLoads.isEmpty }
            guard paths.rpaths.contains(targetFrameworks.path) else { return false }
            if !cxxLoads.isEmpty {
                guard regularFile(frameworks.appendingPathComponent("libcxxcompat.dylib")),
                      cxxLoads.allSatisfy({ $0.path == targetFrameworks.appendingPathComponent("libcxxcompat.dylib").path })
                else { return false }
            }
            // This also catches any accidentally staged MarketplaceKit paths.
            let allPaths = paths.dependencies.map(\.path) + paths.rpaths
            return bundleURL == targetBundleURL || !allPaths.contains { $0.hasPrefix(bundleURL.path + "/") }
        }
    }

    private func validatePreparationMode(
        at bundleURL: URL, mode: PreparationMode, targetBundleURL: URL
    ) throws {
        guard try preparationModeIsValid(at: bundleURL, mode: mode, targetBundleURL: targetBundleURL) else {
            throw PearError.invalidPackage("Preparation invariants failed for \(mode.rawValue)")
        }
    }

    /// Ensures no compatibility library is referenced or shipped. The native
    /// container adds no load commands to the app's executable.
    private func removeRuntimeArtifacts(at bundleURL: URL) throws {
        let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let marker = Self.injectionMarkerURL(in: bundleURL)
        if try itemExists(at: marker) {
            try fileManager.removeItem(at: marker)
        }
        for name in ["libPearRuntime.dylib", "libswiftUIKit.dylib", "libcxxcompat.dylib"] {
            let url = frameworks.appendingPathComponent(name)
            if try itemExists(at: url) {
                try fileManager.removeItem(at: url)
            }
        }
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        _ = try preparationTools.removeLoadDylib(app.executableURL, "libPearRuntime")
        _ = try preparationTools.removeLoadDylib(app.executableURL, "libcxxcompat")
    }

    /// `unzip` does not reliably restore the executable bit from an app package, and a
    /// patched copy can lose it too. Without it `Process` refuses to launch the
    /// app ("The file '…' doesn't exist.").
    private func ensureExecutableBits(at bundleURL: URL) {
        if let app = try? makeInstalledApp(fromBundleAt: bundleURL) {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.executableURL.path)
        }

        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        guard let items = try? fileManager.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items where item.pathExtension == "framework" {
            let binary = item.appendingPathComponent(item.deletingPathExtension().lastPathComponent)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }

    /// Copies the runtime into the bundle. With `addLoadCommand` the binary gets
    /// an `LC_LOAD_DYLIB`; without it the launcher injects the same library via
    /// `DYLD_INSERT_LIBRARIES` and a marker records the choice.
    private func loadRuntime(at bundleURL: URL, targetBundleURL: URL, addLoadCommand: Bool) throws {
        guard let runtime = preparationTools.runtimeLibraryURL() else {
            throw PearError.missingRuntimeComponent("libPearRuntime.dylib")
        }
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        let targetFrameworks = targetBundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let destination = frameworks.appendingPathComponent("libPearRuntime.dylib")
        if try itemExists(at: destination) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: runtime.resolvingSymlinksInPath(), to: destination)
        try validateBinaryForPreparation(at: destination, in: bundleURL)

        // Normalize old/duplicate paths in load-command mode too. Environment
        // mode only removes these commands; it must never create a runtime load.
        _ = try preparationTools.removeLoadDylib(app.executableURL, "libPearRuntime")
        let marker = Self.injectionMarkerURL(in: bundleURL)
        if addLoadCommand {
            if try itemExists(at: marker) {
                try fileManager.removeItem(at: marker)
            }
        } else {
            try Data("environment\n".utf8).write(to: marker, options: .atomic)
        }

        // The host does not provide the Swift UIKit overlay. Ship our small
        // source-built bridge next to the runtime, for frameworks that link it.
        let swiftOverlay = runtime.deletingLastPathComponent()
            .appendingPathComponent("libswiftUIKit.dylib")
        if fileManager.fileExists(atPath: swiftOverlay.path) {
            let overlayDestination = frameworks.appendingPathComponent("libswiftUIKit.dylib")
            if try itemExists(at: overlayDestination) {
                try fileManager.removeItem(at: overlayDestination)
            }
            try fileManager.copyItem(at: swiftOverlay.resolvingSymlinksInPath(), to: overlayDestination)
            try validateBinaryForPreparation(at: overlayDestination, in: bundleURL)
        }

        // A few builds carry a weak placeholder for a C++ runtime data symbol
        // that macOS does not export. Put the re-exporting compatibility
        // library in the bundle and point the binary's C++ dependency at it.
        let cxxCompat = runtime.deletingLastPathComponent()
            .appendingPathComponent("libcxxcompat.dylib")
        if fileManager.fileExists(atPath: cxxCompat.path),
           BinaryPatcher.containsSymbol(at: app.executableURL,
                                        named: "__ZNSt3__119piecewise_constructE") {
            let compatDestination = frameworks.appendingPathComponent("libcxxcompat.dylib")
            if try itemExists(at: compatDestination) {
                try fileManager.removeItem(at: compatDestination)
            }
            try fileManager.copyItem(at: cxxCompat.resolvingSymlinksInPath(), to: compatDestination)
            try validateBinaryForPreparation(at: compatDestination, in: bundleURL)
            let dependencies = try preparationLoadPaths(at: app.executableURL)
                .flatMap { $0.dependencies.map(\.path) }
            let replacement = targetFrameworks.appendingPathComponent("libcxxcompat.dylib").path
            for path in Set(dependencies) where path == "/usr/lib/libc++.1.dylib"
                || path.contains("libcxxcompat") {
                if path != replacement {
                    _ = try preparationTools.run("/usr/bin/install_name_tool", [
                        "-change", path, replacement, app.executableURL.path
                    ])
                }
            }
        }

        // Absolute paths must describe the final installation, never staging.
        if addLoadCommand {
            try BinaryPatcher.addLoadDylib(
                at: app.executableURL,
                path: targetFrameworks.appendingPathComponent("libPearRuntime.dylib").path
            )
        }
        try BinaryPatcher.addRPath(at: app.executableURL, path: targetFrameworks.path)
    }

    private func patchInfoPlist(at bundleURL: URL) throws {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSMutableDictionary(contentsOf: infoURL),
              let mutable = info as? [String: Any] else {
            throw PearError.invalidPackage("Info.plist could not be read")
        }
        var updated = mutable
        updated["CFBundleSupportedPlatforms"] = ["MacOSX"]
        updated["DTPlatformName"] = "macosx"
        updated["LSMinimumSystemVersion"] = "15.0"

        let data = try PropertyListSerialization.data(
            fromPropertyList: updated, format: .binary, options: 0
        )
        try data.write(to: infoURL, options: .atomic)
    }

    /// Signature sidecars stop matching once the platform has been rewritten;
    /// remove them and let the final signing step create fresh ones.
    private func removeLegacySignatureArtifacts(at bundleURL: URL) {
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        for case let item as URL in enumerator {
            let name = item.lastPathComponent
            let ext = item.pathExtension.lowercased()

            if name == "SC_Info" || name == "_CodeSignature" {
                try? fileManager.removeItem(at: item)
                enumerator.skipDescendants()
            } else if ["supf", "supp", "supx"].contains(ext) {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    @discardableResult
    private func patchMachOBinaries(at bundleURL: URL) throws -> Int {
        var count = 0
        for file in try machOTargets(in: bundleURL) {
            do {
                if try BinaryPatcher.patchFile(at: file) { count += 1 }
            } catch { throw preparationError(error, at: file, in: bundleURL) }
        }
        return count
    }

    /// Discover by header, not extension or executable permissions. The main
    /// executable is mandatory even if its bytes have no recognized magic.
    private func machOTargets(in bundleURL: URL) throws -> [URL] {
        let entries = try bundleEntries(at: bundleURL)
        let app: InstalledApp
        do { app = try makeInstalledApp(fromBundleAt: bundleURL) }
        catch { throw preparationError(error, at: bundleURL.appendingPathComponent("Info.plist"), in: bundleURL) }
        let root = bundleURL.resolvingSymlinksInPath().path
        let main = app.executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard main.path.hasPrefix(root + "/") else {
            throw PearError.invalidPackage("\(app.executableName): main executable is outside the bundle")
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: main.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw PearError.invalidPackage("Main executable must be a regular file")
            }
        } catch { throw preparationError(error, at: app.executableURL, in: bundleURL) }
        var targets: Set<URL> = [main]
        let magics: Set<UInt32> = [0xFEEDFACE, 0xCEFAEDFE, 0xFEEDFACF, 0xCFFAEDFE,
                                    0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA]
        for entry in entries where entry.kind == .typeRegular {
            do {
                let handle = try FileHandle(forReadingFrom: entry.url)
                defer { try? handle.close() }
                let head = try handle.read(upToCount: 4) ?? Data()
                if head.count == 4 {
                    let magic = head.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    if magics.contains(magic) { targets.insert(entry.url.resolvingSymlinksInPath().standardizedFileURL) }
                }
            } catch { throw preparationError(error, at: entry.url, in: bundleURL) }
        }
        return targets.sorted { $0.path < $1.path }
    }

    /// Store builds may link `MarketplaceKit`, which macOS provides as
    /// resources only. When an image references the framework, copy the stub
    /// shipped with the runtime into the bundle and point the reference at
    /// that copy. A weak reference to a missing Swift framework otherwise
    /// aborts the process while it registers metadata, before `main` runs.
    private func installMarketplaceKitStubIfNeeded(at bundleURL: URL, targetBundleURL: URL) throws {
        let stubDirectory = bundleURL.appendingPathComponent(
            "Frameworks/MarketplaceKit.framework", isDirectory: true
        )
        let stubBinary = targetBundleURL.appendingPathComponent("Frameworks/MarketplaceKit.framework/MarketplaceKit")

        let referencing = try machOTargets(in: bundleURL).filter { file in
            let path = file.standardizedFileURL.path
            let stubRoot = stubDirectory.standardizedFileURL.path
            guard path != stubRoot, !path.hasPrefix(stubRoot + "/") else { return false }
            return BinaryPatcher.hasLoadDylib(at: file, containing: "MarketplaceKit.framework")
                || BinaryPatcher.containsSymbol(at: file, withPrefix: "_$s14MarketplaceKit")
        }
        guard !referencing.isEmpty else { return }

        if !fileManager.fileExists(atPath: stubDirectory.path) {
            guard let source = AppLauncher.marketplaceKitStubURL() else {
                throw PearError.missingRuntimeComponent("MarketplaceKit.framework")
            }
            try fileManager.createDirectory(
                at: bundleURL.appendingPathComponent("Frameworks", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: stubDirectory)
        }
        try validateBundleForPreparation(at: bundleURL)

        // Absolute paths avoid any dependency on the app's run-path setup and
        // match how the compatibility runtime itself is loaded.
        let replacement = stubBinary.path
        for file in referencing {
            if BinaryPatcher.hasLoadDylib(at: file, containing: "MarketplaceKit.framework") {
                let listing = try preparationTools.run("/usr/bin/otool", ["-L", file.path])
                var stale = Set<String>()
                for line in listing.split(separator: "\n").dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let end = trimmed.range(of: " (compatibility version") else { continue }
                    let path = String(trimmed[..<end.lowerBound])
                    if path.contains("MarketplaceKit.framework") { stale.insert(path) }
                }
                for path in stale where path != replacement {
                    _ = try preparationTools.run("/usr/bin/install_name_tool", [
                        "-change", path, replacement, file.path
                    ])
                }
            } else {
                try BinaryPatcher.addLoadDylib(at: file, path: replacement)
            }
        }
    }

    // MARK: - Helpers

    /// Builds an `InstalledApp` from a bundle's `Info.plist`.
    func makeInstalledApp(fromBundleAt bundleURL: URL, targetBundleURL: URL? = nil) throws -> InstalledApp {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw PearError.invalidPackage("Info.plist could not be read: \(bundleURL.lastPathComponent)")
        }
        guard let bundleID = info["CFBundleIdentifier"] as? String else {
            throw PearError.missingBundleIdentifier
        }
        let executable = (info["CFBundleExecutable"] as? String) ?? ""
        guard !executable.isEmpty else {
            throw PearError.missingExecutable(bundleID)
        }

        let display = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? (bundleURL.deletingPathExtension().lastPathComponent)

        let iconName = (info["CFBundleIcons"] as? [String: Any])
            .flatMap { ($0["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String] }
            .flatMap { $0.last }
            ?? (info["CFBundleIconFile"] as? String)

        let iconURL = iconName.flatMap { name -> URL? in
            let candidates = [name, "\(name).png", "\(name)@2x.png", "\(name)@3x.png"]
            return candidates
                .map { bundleURL.appendingPathComponent($0) }
                .first { fileManager.fileExists(atPath: $0.path) }
        }

        let attrs = try? fileManager.attributesOfItem(atPath: bundleURL.path)
        let installedAt = (attrs?[.creationDate] as? Date) ?? Date()

        return InstalledApp(
            id: bundleID,
            displayName: display,
            bundleName: (info["CFBundleName"] as? String) ?? display,
            shortVersion: (info["CFBundleShortVersionString"] as? String) ?? "—",
            bundleVersion: (info["CFBundleVersion"] as? String) ?? "—",
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            bundleURL: targetBundleURL ?? bundleURL,
            executableName: executable,
            iconURL: iconURL.map { icon in
                (targetBundleURL ?? bundleURL).appendingPathComponent(String(icon.path.dropFirst(bundleURL.path.count + 1)))
            },
            installedAt: installedAt
        )
    }

    /// Adhoc signing for a prepared app.
    ///
    /// A shipping app carries no extra entitlements. Real App Store builds have
    /// neither debug (`get-task-allow`) nor JIT keys, and an app can read them
    /// back with `csops`, so granting them here would make every install look
    /// like a debug repack. The debug set is written next to this file for
    /// explicit, short-lived debugging sessions only.
    ///
    /// Code is signed **inside-out**: every nested code object first, then the
    /// main executable, then the bundle. `codesign --deep` is deliberately NOT
    /// used: on an already-prepared app it can leave the original (now stale) platform
    /// signature on nested frameworks, which makes `dlopen` fail with
    /// "code signature invalid" and the app exit silently at launch.
    private func signBundle(at bundleURL: URL, mode: PreparationMode) throws {
        let entitlements = try ensureEntitlementsPath(for: bundleURL, mode: mode)

        // 1) nested code objects (frameworks, plugins, dylibs)
        for object in try codeObjects(in: bundleURL) {
            try sign(object, entitlements: entitlements)
        }

        // 2) main executable
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        try sign(app.executableURL, entitlements: entitlements)

        // 3) the bundle itself
        try sign(bundleURL, entitlements: entitlements)
    }

    private func sign(_ url: URL, entitlements: String) throws {
        _ = try preparationTools.run("/usr/bin/codesign", [
            "--force", "--sign", "-",
            "--entitlements", entitlements,
            url.path
        ])
    }

    /// Sign discovered binaries and their code containers inside-out, including
    /// extensionless code outside the usual Frameworks/PlugIns directories.
    private func codeObjects(in bundleURL: URL) throws -> [URL] {
        var result = Set(try machOTargets(in: bundleURL))
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        result.remove(app.executableURL.resolvingSymlinksInPath().standardizedFileURL)
        for entry in try bundleEntries(at: bundleURL) where entry.kind == .typeDirectory {
            if ["framework", "appex", "app", "xpc"].contains(entry.url.pathExtension.lowercased()) {
                result.insert(entry.url)
            }
        }
        return result.sorted {
            if $0.pathComponents.count != $1.pathComponents.count {
                return $0.pathComponents.count > $1.pathComponents.count
            }
            return $0.path < $1.path
        }
    }

    /// Writes empty shipping/native-mode entitlements and a separate debug set.
    /// Neither shipping set enables App Sandbox isolation; debug entitlements
    /// are not selected automatically.
    private func ensureEntitlementsPath(for bundleURL: URL, mode: PreparationMode) throws -> String {
        try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)

        let entitlements = workRoot.appendingPathComponent("entitlements.plist")
        let nativeEntitlements = workRoot.appendingPathComponent("native-entitlements.plist")
        let debugEntitlements = workRoot.appendingPathComponent("debug-entitlements.plist")

        let shipping = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict/>
        </plist>
        """
        try shipping.write(to: entitlements, atomically: true, encoding: .utf8)

        let native = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict/>
        </plist>
        """
        try native.write(to: nativeEntitlements, atomically: true, encoding: .utf8)

        let debug = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.get-task-allow</key>
            <true/>
            <key>com.apple.security.cs.allow-jit</key>
            <true/>
            <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
            <true/>
            <key>com.apple.security.cs.disable-library-validation</key>
            <true/>
        </dict>
        </plist>
        """
        try debug.write(to: debugEntitlements, atomically: true, encoding: .utf8)
        return (mode == .nativeContainer ? nativeEntitlements : entitlements).path
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) | UInt32(self[start + 1]) << 8
            | UInt32(self[start + 2]) << 16 | UInt32(self[start + 3]) << 24
    }

    func u64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return UInt64(self[start]) | UInt64(self[start + 1]) << 8
            | UInt64(self[start + 2]) << 16 | UInt64(self[start + 3]) << 24
            | UInt64(self[start + 4]) << 32 | UInt64(self[start + 5]) << 40
            | UInt64(self[start + 6]) << 48 | UInt64(self[start + 7]) << 56
    }
}
