import Foundation

/// Applies small, per-app launch tweaks to the app's own options files.
///
/// Some titles store a setting that makes them unusable under the iOS-on-Mac
/// runtime, and the value is read at boot, before a shim could influence it.
/// Rather than hardcoding any title, the rules live in a user-provided file
/// outside the repository:
///
///   ~/Library/Application Support/PearSilicon/tweaks.json
///
/// The file maps a bundle identifier to relative file paths inside that app's
/// data directory and the keys to set in each JSON file:
///
///   {
///     "com.example.app": {
///       "Documents/save/options.json": { "captureMouse": false }
///     }
///   }
///
/// Opt out with `PEAR_NO_GAME_TWEAKS=1`.
enum GameTweaks {

    static func applyBeforeLaunch(bundleID: String, supportRoot: URL) {
        if ProcessInfo.processInfo.environment["PEAR_NO_GAME_TWEAKS"] != nil { return }

        let configURL = supportRoot.appendingPathComponent("tweaks.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = config[bundleID] as? [String: Any] else { return }

        let appRoot = supportRoot
            .appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)

        for (relativePath, value) in files {
            guard let changes = value as? [String: Any] else { continue }
            let fileURL = appRoot.appendingPathComponent(relativePath)
            guard let fileData = try? Data(contentsOf: fileURL),
                  var json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] else {
                continue
            }
            for (key, newValue) in changes { json[key] = newValue }
            if let updated = try? JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
            ) {
                try? updated.write(to: fileURL, options: .atomic)
            }
        }
    }
}
