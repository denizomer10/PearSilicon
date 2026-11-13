import Foundation

/// Records where PearSilicon keeps its root data folder.
///
/// Everything lives under one root: installed apps, per-game data, keymaps,
/// ODR packs, the local keychain store, logs and work files. The root is either
/// the default `~/Library/Application Support/PearSilicon` or a user-chosen
/// folder (for example one on an external disk, so games and their data can
/// live beside each other).
///
/// A marker file identifies a folder as a PearSilicon root. A migration never
/// adopts, merges into, or overwrites a folder it did not create.
final class StorageLocationStore: @unchecked Sendable {

    static let shared = StorageLocationStore()

    static let markerName = ".pear-storage-root"
    static let markerContents = "1\n"
    static let rootPathKey = "storage.rootPath"
    static let previousRootPathKey = "storage.previousRootPath"
    static let rootBookmarkKey = "storage.rootBookmark"

    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    /// Kept outside the relocatable root so it survives an unavailable disk.
    let leaseFileURL: URL

    /// The Mac's own storage ("Internal Storage" in the location picker).
    /// Injectable so tests never touch the real Application Support folder.
    let internalRootURL: URL

    init(
        defaults: UserDefaults = AppSettings.defaults,
        leaseFileURL: URL? = nil,
        internalRootURL: URL? = nil
    ) {
        self.defaults = defaults
        self.internalRootURL = (internalRootURL ?? Self.defaultSupportRoot).standardizedFileURL
        self.leaseFileURL = leaseFileURL ?? Self.defaultSupportRoot
            .deletingLastPathComponent()
            .appendingPathComponent("PearSilicon.storage.lock")
    }

    static var defaultSupportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PearSilicon", isDirectory: true)
    }

    /// The configured root, whether or not it is currently available. Use
    /// `requireAvailableRoot()` before doing filesystem work; a missing external
    /// disk must produce an error, never a silent fallback to the internal disk.
    ///
    /// The stored path is authoritative while it exists; the bookmark only helps
    /// when the volume was remounted at a different location.
    var rootURL: URL {
        guard let stored = defaults.string(forKey: Self.rootPathKey), !stored.isEmpty else {
            return internalRootURL
        }
        let storedURL = URL(fileURLWithPath: stored, isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: storedURL.path) { return storedURL }
        if let bookmark = defaults.data(forKey: Self.rootBookmarkKey),
           let resolved = URL.resourceValuesFromBookmark(bookmark) {
            return resolved.standardizedFileURL
        }
        return storedURL
    }

    /// The stored custom path, if any (nil means Internal Storage).
    var storedRootPath: String? {
        defaults.string(forKey: Self.rootPathKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    var previousRootURL: URL? {
        guard let stored = defaults.string(forKey: Self.previousRootPathKey), !stored.isEmpty else { return nil }
        return URL(fileURLWithPath: stored, isDirectory: true).standardizedFileURL
    }

    /// True when the user moved the root somewhere other than the default.
    var usesCustomRoot: Bool {
        rootURL.standardizedFileURL != internalRootURL
    }

    /// The root the migration must write into when the user picks `folder`.
    /// A folder already named `PearSilicon` is used as-is; any other folder gets
    /// one PearSilicon root inside it so a whole disk is not repurposed.
    static func destinationRoot(in folder: URL) -> URL {
        let folder = folder.standardizedFileURL
        return folder.lastPathComponent == "PearSilicon"
            ? folder
            : folder.appendingPathComponent("PearSilicon", isDirectory: true)
    }

    /// Validates (and for the default root creates) the current root.
    ///
    /// Custom roots must already carry the marker: a missing external volume has
    /// no parent to create into and must not cause writes to an unrelated path.
    @discardableResult
    func requireAvailableRoot() throws -> URL {
        let root = rootURL.standardizedFileURL
        let marker = root.appendingPathComponent(Self.markerName)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)

        if exists, isDirectory.boolValue {
            if fileManager.fileExists(atPath: marker.path) { return root }
            // Adopt a legacy/default root created before the marker existed, but
            // never a custom folder holding somebody else's files.
            guard !usesCustomRoot else {
                throw PearError.invalidPackage(
                    "\(root.path) is not a PearSilicon folder. Choose an empty folder or one that contains a \(Self.markerName) marker."
                )
            }
            try Self.writeMarker(at: root)
            return root
        }
        guard !exists else {
            throw PearError.invalidPackage("\(root.path) is not a directory")
        }
        guard usesCustomRoot == false || fileManager.fileExists(atPath: root.deletingLastPathComponent().path) else {
            throw PearError.invalidPackage(
                "\(root.deletingLastPathComponent().path) is not available. Reconnect the disk or choose another location."
            )
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.writeMarker(at: root)
        return root
    }

    /// Finishes a migration. Only call after the complete new root is in place.
    func commit(rootURL: URL, previousRootURL: URL?) throws {
        let root = rootURL.standardizedFileURL
        guard fileManager.fileExists(atPath: root.appendingPathComponent(Self.markerName).path) else {
            throw PearError.invalidPackage("Refusing to select a folder that is not a PearSilicon root")
        }
        var record = defaults
        let bookmark = root.bookmarkDataForStorage()
        record.set(root.path, forKey: Self.rootPathKey)
        if let bookmark { record.set(bookmark, forKey: Self.rootBookmarkKey) }
        else { record.removeObject(forKey: Self.rootBookmarkKey) }
        if let previousRootURL, previousRootURL.standardizedFileURL != root {
            record.set(previousRootURL.standardizedFileURL.path, forKey: Self.previousRootPathKey)
        } else {
            record.removeObject(forKey: Self.previousRootPathKey)
        }
    }

    /// Switches between libraries that already exist (the location picker).
    /// Unlike `commit`, the rollback copy recorded by a migration is kept.
    /// Selecting the internal root clears the custom path, so the internal
    /// library is created (with its marker) on first use.
    func select(rootURL: URL) throws {
        let root = rootURL.standardizedFileURL
        if root == internalRootURL {
            defaults.removeObject(forKey: Self.rootPathKey)
            defaults.removeObject(forKey: Self.rootBookmarkKey)
            try requireAvailableRoot()
            return
        }
        guard Self.hasMarker(at: root) else {
            throw PearError.invalidPackage("\(root.path) is not a PearSilicon library or its disk is not connected")
        }
        defaults.set(root.path, forKey: Self.rootPathKey)
        if let bookmark = root.bookmarkDataForStorage() { defaults.set(bookmark, forKey: Self.rootBookmarkKey) }
        else { defaults.removeObject(forKey: Self.rootBookmarkKey) }
    }

    /// Explicitly deletes the retained copy a migration left behind. Never runs
    /// automatically: the old data is the user's rollback until they confirm.
    func removePreviousCopy() throws {
        guard let previous = previousRootURL?.standardizedFileURL else {
            throw PearError.invalidPackage("There is no previous copy to remove")
        }
        let current = rootURL.standardizedFileURL
        guard previous != current,
              previous.lastPathComponent == "PearSilicon" || previous == internalRootURL,
              fileManager.fileExists(atPath: previous.appendingPathComponent(Self.markerName).path) else {
            throw PearError.invalidPackage("The previous location is no longer a PearSilicon folder; it was left untouched")
        }
        guard !previous.path.hasPrefix(current.path + "/"),
              !current.path.hasPrefix(previous.path + "/") else {
            throw PearError.invalidPackage("The previous copy overlaps the current storage and cannot be removed safely")
        }
        try fileManager.removeItem(at: previous)
        defaults.removeObject(forKey: Self.previousRootPathKey)
    }

    /// Bounded discovery: volume root and its immediate children only. Never
    /// creates folders on a disconnected or unrelated disk.
    static func discoverRoots(on volumes: [URL]) -> [URL] {
        var roots = Set<URL>()
        for volume in volumes {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: volume, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for candidate in [volume] + children {
                guard let attributes = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      attributes.isDirectory == true, attributes.isSymbolicLink != true,
                      hasMarker(at: candidate) else { continue }
                roots.insert(candidate.standardizedFileURL)
            }
        }
        return roots.sorted { $0.path < $1.path }
    }

    /// Marked libraries on connected disks, one picker option each. The boot
    /// volume and the internal root are excluded: they are "Internal Storage".
    static func externalLocations(
        on volumes: [URL],
        internalRoot: URL = defaultSupportRoot,
        isSystemVolume: (URL) -> Bool = StorageLocationStore.isSystemVolume
    ) -> [StorageLocationOption] {
        var options: [StorageLocationOption] = []
        for volume in volumes where !isSystemVolume(volume) {
            let roots = discoverRoots(on: [volume]).filter { $0 != internalRoot.standardizedFileURL }
            let diskName = volumeDisplayName(volume)
            for root in roots {
                let name = roots.count > 1 && root != volume.standardizedFileURL
                    ? "\(diskName) — \(root.lastPathComponent)"
                    : diskName
                options.append(StorageLocationOption(rootURL: root, name: name, kind: .external))
            }
        }
        return options
    }

    static func isSystemVolume(_ volume: URL) -> Bool {
        (try? volume.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem == true
    }

    /// The disk's Finder name when `volume` is a mount point, else the folder name.
    static func volumeDisplayName(_ volume: URL) -> String {
        let values = try? volume.resourceValues(forKeys: [.volumeURLKey, .volumeLocalizedNameKey])
        if let mount = values?.volume, mount.standardizedFileURL == volume.standardizedFileURL,
           let name = values?.volumeLocalizedName, !name.isEmpty {
            return name
        }
        return volume.lastPathComponent
    }

    /// The picker shows Internal Storage first, then every connected marked
    /// library. A selected custom root that discovery does not reach (for
    /// example a folder on the Mac disk) is kept visible while it exists.
    static func locationOptions(
        internalRoot: URL,
        selectedRoot: URL,
        external: [StorageLocationOption]
    ) -> [StorageLocationOption] {
        let internalRoot = internalRoot.standardizedFileURL
        let selected = selectedRoot.standardizedFileURL
        var options = [StorageLocationOption(rootURL: internalRoot, name: "Internal Storage", kind: .internal)]
        options += external.filter { $0.rootURL != internalRoot }
        if !options.contains(where: { $0.rootURL == selected }), hasMarker(at: selected) {
            options.append(StorageLocationOption(rootURL: selected, name: selected.deletingLastPathComponent().lastPathComponent, kind: .external))
        }
        return options
    }

    static func writeMarker(at root: URL) throws {
        try markerContents.write(
            to: root.appendingPathComponent(markerName), atomically: true, encoding: .utf8
        )
    }

    /// Reads a marker written by `writeMarker` without following symlinks.
    static func hasMarker(at root: URL) -> Bool {
        let marker = root.appendingPathComponent(markerName)
        guard let attributes = try? marker.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              attributes.isSymbolicLink != true, attributes.isRegularFile == true,
              let data = try? Data(contentsOf: marker) else { return false }
        return data == Data(markerContents.utf8)
    }
}

/// One entry of the storage location picker.
struct StorageLocationOption: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case `internal`, external }
    let rootURL: URL
    let name: String
    let kind: Kind
    var id: String { rootURL.standardizedFileURL.path }
}

extension URL {
    /// Best-effort bookmark so a remounted external volume is found again.
    func bookmarkDataForStorage() -> Data? {
        try? bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resourceValuesFromBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return url
    }
}