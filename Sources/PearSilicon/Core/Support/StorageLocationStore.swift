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

    init(defaults: UserDefaults = AppSettings.defaults, leaseFileURL: URL? = nil) {
        self.defaults = defaults
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
            return Self.defaultSupportRoot.standardizedFileURL
        }
        let storedURL = URL(fileURLWithPath: stored, isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: storedURL.path) { return storedURL }
        if let bookmark = defaults.data(forKey: Self.rootBookmarkKey),
           let resolved = URL.resourceValuesFromBookmark(bookmark) {
            return resolved.standardizedFileURL
        }
        return storedURL
    }

    var previousRootURL: URL? {
        guard let stored = defaults.string(forKey: Self.previousRootPathKey), !stored.isEmpty else { return nil }
        return URL(fileURLWithPath: stored, isDirectory: true).standardizedFileURL
    }

    /// True when the user moved the root somewhere other than the default.
    var usesCustomRoot: Bool {
        rootURL.standardizedFileURL != Self.defaultSupportRoot.standardizedFileURL
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

    /// Explicitly deletes the retained copy a migration left behind. Never runs
    /// automatically: the old data is the user's rollback until they confirm.
    func removePreviousCopy() throws {
        guard let previous = previousRootURL?.standardizedFileURL else {
            throw PearError.invalidPackage("There is no previous copy to remove")
        }
        let current = rootURL.standardizedFileURL
        guard previous != current,
              previous.lastPathComponent == "PearSilicon" || previous == Self.defaultSupportRoot.standardizedFileURL,
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

    static func writeMarker(at root: URL) throws {
        try markerContents.write(
            to: root.appendingPathComponent(markerName), atomically: true, encoding: .utf8
        )
    }

    /// Reads a marker written by `writeMarker` without following symlinks.
    static func hasMarker(at root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(markerName)) else { return false }
        return data == Data(markerContents.utf8)
    }
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