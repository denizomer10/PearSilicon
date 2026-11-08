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
        // Inside the app bundle, the standard domain already is
        // com.pearsilicon.app. Asking for that same name as an explicit suite
        // makes CoreFoundation log a nonsensical-suite warning on every command.
        // A bare SwiftPM CLI has no bundle identifier, so it still needs the
        // named suite to read the app's domain.
        if Bundle.main.bundleIdentifier == "com.pearsilicon.app" { return .standard }
        return UserDefaults(suiteName: "com.pearsilicon.app") ?? .standard
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

    // MARK: - PearLegacyEngine (32-bit iOS runtime) options

    /// Resolution scale factor (`--scale-hack`) for a 32-bit iOS app (1...4).
    static func legacyScaleHack(for bundleID: String) -> Int {
        let value = defaults.integer(forKey: "legacy32.scaleHack." + bundleID)
        return (1...4).contains(value) ? value : 2
    }

    static func setLegacyScaleHack(_ scale: Int, for bundleID: String) {
        defaults.set(max(1, min(4, scale)), forKey: "legacy32.scaleHack." + bundleID)
    }

    /// Whether to start the 32-bit iOS app in fullscreen mode (`--fullscreen`).
    static func legacyFullscreen(for bundleID: String) -> Bool {
        defaults.bool(forKey: "legacy32.fullscreen." + bundleID)
    }

    static func setLegacyFullscreen(_ fullscreen: Bool, for bundleID: String) {
        defaults.set(fullscreen, forKey: "legacy32.fullscreen." + bundleID)
    }
}
