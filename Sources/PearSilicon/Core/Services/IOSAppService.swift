import AppKit
import Foundation

/// Platform-facing service boundary for the iOS compatibility runtime.
///
/// AppState keeps SwiftUI-facing state (overlays, keymapper toggles, status
/// text), while this type owns the launch policy: lease acquisition, preparation
/// mode selection and the environment flags the runtime reads. Mac and Wine
/// entries never call into this type.
struct IOSAppService {
    let launcher: AppLauncher
    let installer: PackageInstaller

    @MainActor
    func launch(
        _ app: InstalledApp,
        libraryURL: URL,
        keymapURL: URL?,
        metalHUDEnabled: Bool,
        pointerLockAllowed: Bool,
        virtualGamepad: Bool = false,
        virtualGamepadMapping: VirtualGamepadMapping = .standard
    ) async throws -> NSRunningApplication? {
        let compatibility = AppCompatibility.detect(bundleURL: app.bundleURL)
        var extra: [String: String] = ["PEAR_IOS_SANDBOX": "1"]
        if metalHUDEnabled {
            // Metal HUD is the only FPS meter. For OpenGL ES titles the
            // runtime presents a transparent carrier layer with every game
            // frame, so the HUD stays visible and measures the game.
            extra["MTL_HUD_ENABLED"] = "1"
        }
        // The virtual pad captures the cursor itself, so native pointer lock is
        // not requested in that mode. Leaving it off also prevents the game
        // from hiding the cursor before the first click arms the pad.
        if pointerLockAllowed && !virtualGamepad { extra["PEAR_ALLOW_POINTER_LOCK"] = "1" }

        if virtualGamepad {
            extra["PEAR_VIRTUAL_GAMEPAD"] = "1"
            extra["PEAR_VIRTUAL_GAMEPAD_MAP"] = virtualGamepadMapping.environmentValue
        }
        extra.merge(
            AppSettings.compatibilityEnvironment(
                for: app.id,
                compatibility: compatibility,
                virtualGamepad: virtualGamepad
            )
        ) { _, selected in selected }

        let launchLease = try AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
        defer { launchLease.release() }
        try AppLauncher.requireStopped(app)

        let mode: PreparationMode = installer.currentPreparationMode(for: app) == .compatibilityEnvironment
            ? .compatibilityEnvironment : .compatibility
        try installer.setPreparationMode(mode, for: app, launchLease: launchLease)

        return try await launcher.launch(
            app,
            keymapURL: virtualGamepad ? nil : keymapURL,
            extraEnvironment: extra,
            nativeContainer: false,
            launchLease: launchLease
        )
    }

    @MainActor
    func uninstall(_ app: InstalledApp) throws {
        try installer.uninstall(app)
    }
}
