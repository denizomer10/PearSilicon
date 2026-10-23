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
