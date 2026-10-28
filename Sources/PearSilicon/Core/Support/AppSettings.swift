import Foundation

/// Shared, explicit settings domain.
///
/// The app and the CLI are the same binary, but when the CLI runs from a bare
/// SwiftPM build product `Bundle.main.bundleIdentifier` is nil, so
/// `UserDefaults.standard` would point at a different domain than the app's.
/// Using a named suite keeps both sides on the same values (verified: the app's
/// standard domain and this suite return the same objects).
enum AppSettings {

    static var defaults: UserDefaults {
        UserDefaults(suiteName: "com.pearsilicon.app") ?? .standard
    }

    /// Whether the game is allowed to lock the pointer. Games that need relative
    /// mouse motion for the camera depend on this; a per-app setting can turn it
    /// off for titles whose pointer lock traps the cursor.
    static func pointerLockAllowed(for bundleID: String) -> Bool {
        if let stored = defaults.object(forKey: "pointerLock.enabled." + bundleID) as? Bool {
            return stored
        }
        return true
    }

    static func setPointerLockAllowed(_ allowed: Bool, for bundleID: String) {
        defaults.set(allowed, forKey: "pointerLock.enabled." + bundleID)
    }
}
