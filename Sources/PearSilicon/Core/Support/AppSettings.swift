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

    // MARK: - PearLegacyEngine (32-bit iOS runtime) options

    /// Whether to open the 32-bit iOS app with an enlarged, resizable window
    /// (`--large-window`). Defaults to true when unset.
    static func legacyLargeWindow(for bundleID: String) -> Bool {
        let key = "legacy32.largeWindow." + bundleID
        return defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setLegacyLargeWindow(_ enabled: Bool, for bundleID: String) {
        defaults.set(enabled, forKey: "legacy32.largeWindow." + bundleID)
    }

    /// Whether to start the 32-bit iOS app in fullscreen mode (`--fullscreen`).
    static func legacyFullscreen(for bundleID: String) -> Bool {
        defaults.bool(forKey: "legacy32.fullscreen." + bundleID)
    }

    static func setLegacyFullscreen(_ fullscreen: Bool, for bundleID: String) {
        defaults.set(fullscreen, forKey: "legacy32.fullscreen." + bundleID)
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

    // MARK: - Automatic compatibility
    //
    // Compatibility is automatic: detection decides the defaults, and the
    // stored keys are only kept as manual overrides for edge cases (the GUI
    // no longer exposes them; use the `pearsilicon compat` CLI command).

    static func legacyBridgeOverride(for bundleID: String) -> Bool? {
        defaults.object(forKey: "legacyBridge.enabled." + bundleID) as? Bool
    }

    static func mouseTouchFallbackOverride(for bundleID: String) -> Bool? {
        defaults.object(forKey: "mouseTouch.enabled." + bundleID) as? Bool
    }

    /// Effective window-bridge state: manual override when present, otherwise
    /// the detected legacy profile.
    static func isLegacyBridgeEnabled(
        for bundleID: String,
        compatibility: AppCompatibility
    ) -> Bool {
        legacyBridgeOverride(for: bundleID) ?? compatibility.isLegacyRuntime
    }

    /// Effective mouse-to-touch state. Enabled by default for every app: a
    /// native UIKit touch normally arrives first, and the runtime cancels the
    /// synthetic fallback when it sees that. Modern games that only understand
    /// touches (for example Minecraft PE) otherwise receive no mouse input.
    static func isMouseTouchFallbackEnabled(
        for bundleID: String,
        compatibility: AppCompatibility
    ) -> Bool {
        mouseTouchFallbackOverride(for: bundleID) ?? true
    }

    /// True when a stored override disagrees with detection (shown in the UI
    /// with a "Use automatic" reset).
    static func hasCompatibilityOverride(
        for bundleID: String,
        compatibility: AppCompatibility
    ) -> Bool {
        if let legacy = legacyBridgeOverride(for: bundleID),
           legacy != compatibility.isLegacyRuntime { return true }
        if let touch = mouseTouchFallbackOverride(for: bundleID), touch != true { return true }
        return false
    }

    static func clearCompatibilityOverrides(for bundleID: String) {
        defaults.removeObject(forKey: "legacyBridge.enabled." + bundleID)
        defaults.removeObject(forKey: "mouseTouch.enabled." + bundleID)
    }

    static func legacyResolution(for bundleID: String) -> String {
        let stored = defaults.string(forKey: "legacyBridge.resolution." + bundleID) ?? "auto"
        return legacyResolutionChoices.contains(stored) ? stored : "auto"
    }

    /// Environment shared by the GUI and CLI launch paths. Direct legacy touch
    /// is only paired with the mouse shim, and never while the virtual pad owns
    /// the input path.
    static func compatibilityEnvironment(
        for bundleID: String,
        compatibility: AppCompatibility,
        virtualGamepad: Bool
    ) -> [String: String] {
        var result: [String: String] = [:]
        let mouseTouch = !virtualGamepad
            && isMouseTouchFallbackEnabled(for: bundleID, compatibility: compatibility)

        if isLegacyBridgeEnabled(for: bundleID, compatibility: compatibility) {
            result["PEAR_LEGACY_ATTACH_LAYER"] = "1"
            result["PEAR_LEGACY_WINDOW_LAYER_ONLY"] = "1"
            let resolution = legacyResolution(for: bundleID)
            if resolution != "auto" { result["PEAR_LEGACY_LOGICAL_SIZE"] = resolution }
            if mouseTouch { result["PEAR_DIRECT_LEGACY_TOUCH"] = "1" }
        }
        if mouseTouch { result["PEAR_MOUSE_TOUCH"] = "1" }
        return result
    }
}
