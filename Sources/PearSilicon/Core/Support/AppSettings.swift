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
        return false
    }

    static func setPointerLockAllowed(_ allowed: Bool, for bundleID: String) {
        defaults.set(allowed, forKey: "pointerLock.enabled." + bundleID)
    }

    // MARK: - Virtual gamepad mapping

    private static let virtualGamepadMappingKey = "virtualGamepad.map."

    static func virtualGamepadMapping(for bundleID: String) -> VirtualGamepadMapping {
        guard let data = defaults.data(forKey: virtualGamepadMappingKey + bundleID),
              let mapping = try? JSONDecoder().decode(VirtualGamepadMapping.self, from: data)
        else { return .standard }
        return mapping
    }

    static func setVirtualGamepadMapping(_ mapping: VirtualGamepadMapping, for bundleID: String) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: virtualGamepadMappingKey + bundleID)
    }

    static let legacyResolutionChoices = ["auto", "1024x768", "768x1024", "1920x1080", "1280x720"]

    static func legacyBridgeEnabled(for bundleID: String) -> Bool {
        defaults.bool(forKey: "legacyBridge.enabled." + bundleID)
    }

    static func legacyResolution(for bundleID: String) -> String {
        let stored = defaults.string(forKey: "legacyBridge.resolution." + bundleID) ?? "auto"
        return legacyResolutionChoices.contains(stored) ? stored : "auto"
    }

    static func legacyEnvironment(for bundleID: String, virtualGamepad: Bool) -> [String: String] {
        guard legacyBridgeEnabled(for: bundleID) else { return [:] }
        var result = ["PEAR_LEGACY_ATTACH_LAYER": "1", "PEAR_LEGACY_WINDOW_LAYER_ONLY": "1"]
        let resolution = legacyResolution(for: bundleID)
        if resolution != "auto" { result["PEAR_LEGACY_LOGICAL_SIZE"] = resolution }
        if !virtualGamepad {
            result["PEAR_DIRECT_LEGACY_TOUCH"] = "1"
            result["PEAR_MOUSE_TOUCH"] = "1"
        }
        return result
    }

}
