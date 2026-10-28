import Foundation

/// Shared locations for the app's own data, plus a one-time migration from the
/// previous product name so installed apps, keymaps and per-app data survive
/// the rename.
enum AppPaths {

    /// Root of the app's support data (library, logs, keymaps, work files).
    static var supportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PearSilicon", isDirectory: true)
    }

    /// Per-app data containers used by the compatibility runtime.
    static var gamesRoot: URL {
        supportRoot.appendingPathComponent("Games", isDirectory: true)
    }

    /// Optional per-app directory for On-Demand Resources that are not part of
    /// the app package. The runtime merges bundles found here into its local
    /// Addressables view, so content can be supplied without repackaging the
    /// app.
    static func odrDirectory(for bundleID: String) -> URL {
        supportRoot
            .appendingPathComponent("ODR", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// The macOS App Sandbox data directory for an app. When the app is signed
    /// with `com.apple.security.app-sandbox`, the system makes this its home
    /// before any app code runs.
    static func nativeContainerData(for bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    /// Moves an existing compatibility container into the native sandbox
    /// container. The large assets live under `Documents`, which is a rename on
    /// the same volume; only the small `Library` entries are merged item by
    /// item.
    static func migrateToNativeContainerIfNeeded(for bundleID: String) {
        let fileManager = FileManager.default
        let source = gamesRoot.appendingPathComponent(bundleID, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return }

        let destination = nativeContainerData(for: bundleID)
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for name in ["Documents", "tmp"] {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: from.path),
                  !fileManager.fileExists(atPath: to.path) else { continue }
            try? fileManager.moveItem(at: from, to: to)
        }

        let librarySource = source.appendingPathComponent("Library", isDirectory: true)
        let libraryDestination = destination.appendingPathComponent("Library", isDirectory: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: librarySource, includingPropertiesForKeys: nil
        ) else { return }
        try? fileManager.createDirectory(at: libraryDestination, withIntermediateDirectories: true)
        for item in items {
            let target = libraryDestination.appendingPathComponent(item.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: item, to: target)
            }
        }
    }

    /// Moves the previous support directory to the new name once. No-op when
    /// the new directory already exists or there is nothing to migrate.
    static func migrateLegacySupportDirectoryIfNeeded() {
        let fileManager = FileManager.default
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacy = support.appendingPathComponent("PearSilicone", isDirectory: true)
        let current = support.appendingPathComponent("PearSilicon", isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path) else { return }
        try? fileManager.moveItem(at: legacy, to: current)
    }
}
