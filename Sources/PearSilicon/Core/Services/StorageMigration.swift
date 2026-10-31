import AppKit
import Foundation

struct StorageMigrationResult: Sendable {
    let rootURL: URL
    let previousRootURL: URL?
}

/// Moves the complete PearSilicon root — installed apps, game data, keymaps,
/// ODR packs, keychain store, logs and work files — to a new folder.
///
/// The flow is copy → rebase → verify → commit. The old copy is kept as a
/// rollback until the user explicitly removes it; nothing is deleted during a
/// move, and any failure leaves both the old root and the stored location
/// untouched.
struct StorageMigration: Sendable {

    /// Flat iOS bundles can live in the legacy Applications folder or the new
    /// ios-apps folder; both are rebased when storage moves.
    static let flatApplicationFolders = ["Applications", "ios-apps"]

    /// Rewrites an installed app's absolute load paths for the new root and
    /// re-signs the copy. Injectable so tests can exercise the copy/commit
    /// transaction without signing synthetic bundles.
    var relocateBundle: @Sendable (_ staged: URL, _ original: URL, _ target: URL) throws -> Void
    private let locations: StorageLocationStore

    init(
        locations: StorageLocationStore = .shared,
        relocateBundle: @escaping @Sendable (_ staged: URL, _ original: URL, _ target: URL) throws -> Void
            = StorageMigration.defaultRelocate
    ) {
        self.locations = locations
        self.relocateBundle = relocateBundle
    }

    static func defaultRelocate(staged: URL, original: URL, target: URL) throws {
        try PackageInstaller(libraryURL: staged.deletingLastPathComponent())
            .relocateInstalledBundle(at: staged, from: original, to: target)
    }

    private var fileManager: FileManager { FileManager.default }

    /// Moves everything to a root inside `folderURL`. `progress` is called with
    /// short stage descriptions on a background thread; it must not touch UI.
    func move(
        to folderURL: URL,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> StorageMigrationResult {
        try await Task.detached(priority: .userInitiated) {
            try moveBlocking(to: folderURL, progress: progress)
        }.value
    }

    /// Deletes the retained previous copy after a successful move.
    func removePreviousCopy() async throws {
        try await Task.detached(priority: .utility) { [locations] in
            let store = locations
            let previous = store.previousRootURL
            let current = store.rootURL.standardizedFileURL
            if let previous {
                let running = NSWorkspace.shared.runningApplications.contains {
                    !$0.isTerminated && $0.bundleURL?.path.hasPrefix(previous.path + "/") == true
                }
                guard !running else {
                    throw PearError.invalidPackage(
                        "An app is still running from the previous location. Stop it before removing the copy."
                    )
                }
            }
            try store.removePreviousCopy()
            _ = current
        }.value
    }

    private func moveBlocking(
        to folderURL: URL, progress: @escaping @Sendable (String) -> Void
    ) throws -> StorageMigrationResult {
        let store = locations
        let source = try store.requireAvailableRoot().standardizedFileURL
        let target = StorageLocationStore.destinationRoot(in: folderURL).standardizedFileURL
        try validate(source: source, target: target)
        progress("Checking running apps")

        guard !hasRunningApps(from: source) else {
            throw PearError.invalidPackage("Close the running games before moving storage")
        }

        let container = target.deletingLastPathComponent()
            .appendingPathComponent(".pear-storage-move-\(UUID().uuidString)", isDirectory: true)
        let staging = container.appendingPathComponent("PearSilicon", isDirectory: true)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: container) } }

        progress("Copying apps and data")
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: staging)
        try copyNativeContainerDataIfNeeded(from: source, into: staging, progress: progress)

        progress("Rebasing installed apps")
        for folder in Self.flatApplicationFolders {
            let stagedApps = try appBundles(in: staging.appendingPathComponent(folder))
            for staged in stagedApps {
                let original = source.appendingPathComponent(folder)
                    .appendingPathComponent(staged.lastPathComponent, isDirectory: true)
                let final = target.appendingPathComponent(folder)
                    .appendingPathComponent(staged.lastPathComponent, isDirectory: true)
                progress("Preparing \(staged.deletingPathExtension().lastPathComponent)")
                try relocateBundle(staged, original, final)
            }
        }

        progress("Verifying copy")
        try verifyCopy(from: source, to: staging, relocatedApps: Self.flatApplicationFolders.reduce(0) { total, folder in
            total + ((try? appBundles(in: staging.appendingPathComponent(folder)))?.count ?? 0)
        })

        // Same-volume rename: staging is deliberately a sibling of the target.
        progress("Activating new location")
        guard !fileManager.fileExists(atPath: target.path) else {
            throw PearError.invalidPackage("\(target.path) already exists")
        }
        guard rename(staging.path, target.path) == 0 else {
            throw PearError.commandFailed(
                tool: "rename", status: errno, output: String(cString: strerror(errno))
            )
        }
        try StorageLocationStore.writeMarker(at: target)
        try store.commit(rootURL: target, previousRootURL: source)
        committed = true
        try? fileManager.removeItem(at: container)
        progress("Done")
        return StorageMigrationResult(rootURL: target, previousRootURL: source)
    }

    // MARK: - Validation

    private func validate(source: URL, target: URL) throws {
        guard source != target else {
            throw PearError.invalidPackage("That is already the current storage location")
        }
        guard !target.path.hasPrefix(source.path + "/") else {
            throw PearError.invalidPackage("The new location cannot be inside the current storage")
        }
        guard !source.path.hasPrefix(target.path + "/") else {
            throw PearError.invalidPackage("The current storage cannot be inside the new location")
        }
        var isDirectory: ObjCBool = false
        let parent = target.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PearError.invalidPackage("\(parent.path) is not available. Reconnect the disk and try again.")
        }
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw PearError.invalidPackage("\(parent.path) is not writable")
        }
        if fileManager.fileExists(atPath: target.path) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: target.path)) ?? []
            guard contents.isEmpty else {
                throw PearError.invalidPackage("\(target.path) already contains data; choose an empty folder")
            }
            try fileManager.removeItem(at: target)
        }
        // Refuse paths macOS cannot execute from (e.g. some mounted shares).
        let probe = parent.appendingPathComponent(".pear-write-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data("1".utf8)) else {
            throw PearError.invalidPackage("\(parent.path) is not writable")
        }
        try? fileManager.removeItem(at: probe)
    }

    private func hasRunningApps(from root: URL) -> Bool {
        var ids: Set<String> = []
        for folder in Self.flatApplicationFolders {
            let applications = root.appendingPathComponent(folder, isDirectory: true)
            let bundles = (try? appBundles(in: applications)) ?? []
            ids.formUnion(bundles.map { $0.deletingPathExtension().lastPathComponent })
        }
        let canonicalRoot = LibraryPath.canonicalPath(root)
        return NSWorkspace.shared.runningApplications.contains { running in
            guard !running.isTerminated else { return false }
            if let bundleID = running.bundleIdentifier, ids.contains(bundleID) { return true }
            let path = running.executableURL?.path ?? running.bundleURL?.path
            return path.map { LibraryPath.canonicalPath(URL(fileURLWithPath: $0)).hasPrefix(canonicalRoot + "/") } ?? false
        }
    }

    private func appBundles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "app" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Copy verification

    /// Compares the copied tree against the source before anything is switched
    /// over. App bundles were rebased and re-signed, so their bytes legitimately
    /// differ; everything else must match file-for-file in size.
    private func verifyCopy(from source: URL, to copy: URL, relocatedApps: Int) throws {
        func inventory(_ root: URL, excludingApps: Bool) throws -> [String: Int64] {
            let root = LibraryPath.canonicalURL(root)
            var result: [String: Int64] = [:]
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) else { return result }
            for case let item as URL in enumerator {
                let relative = item.path.dropFirst(root.path.count + 1)
                if excludingApps {
                    let relativeString = String(relative)
                    if let folder = Self.flatApplicationFolders.first(where: {
                        relativeString.hasPrefix($0 + "/")
                    }) {
                        let inside = relativeString.dropFirst(folder.count + 1)
                        if inside.contains("/") || inside.hasSuffix(".app") { continue }
                    }
                }
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                result[String(relative)] = Int64(values?.fileSize ?? 0)
            }
            return result
        }
        let original = try inventory(source, excludingApps: false)
        let copied = try inventory(copy, excludingApps: true)
        for (path, size) in original where !Self.flatApplicationFolders.contains(where: { path.hasPrefix($0 + "/") }) {
            guard copied[path] == size else {
                throw PearError.invalidPackage("Verification failed for \(path); the copy was discarded")
            }
        }
        let stagedApps = Self.flatApplicationFolders.reduce(0) { total, folder in
            total + ((try? appBundles(in: copy.appendingPathComponent(folder)))?.count ?? 0)
        }
        let sourceApps = Self.flatApplicationFolders.reduce(0) { total, folder in
            total + ((try? appBundles(in: source.appendingPathComponent(folder)))?.count ?? 0)
        }
        guard stagedApps == sourceApps, stagedApps == relocatedApps else {
            throw PearError.invalidPackage("Not every installed app was prepared in the copy")
        }
    }

    // MARK: - Native containers

    /// A game may hold its data in the macOS container instead of the storage
    /// root (when it last ran in native-container mode). Copy that data into the
    /// new root's per-game folder so the move does not strand real saves.
    private func copyNativeContainerDataIfNeeded(
        from source: URL, into staging: URL, progress: @escaping @Sendable (String) -> Void
    ) throws {
        let bundles = Self.flatApplicationFolders.flatMap {
            (try? appBundles(in: source.appendingPathComponent($0))) ?? []
        }
        for app in bundles {
            let id = app.deletingPathExtension().lastPathComponent
            let container = AppPaths.nativeContainerData(for: id)
            let containerDocuments = container.appendingPathComponent("Documents", isDirectory: true)
            let sourceGame = source.appendingPathComponent("Games", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            guard fileManager.fileExists(atPath: containerDocuments.path),
                  !fileManager.fileExists(atPath: sourceGame.appendingPathComponent("Documents").path)
            else { continue }
            progress("Copying saved data for \(id)")
            let destination = staging.appendingPathComponent("Games", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in ["Documents", "Library", "tmp"] {
                let from = container.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: from.path) else { continue }
                try fileManager.copyItem(at: from, to: destination.appendingPathComponent(name))
            }
        }
    }
}