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
        pointerLockAllowed: Bool
    ) async throws -> NSRunningApplication? {
        var extra: [String: String] = ["PEAR_IOS_SANDBOX": "1"]
        if metalHUDEnabled {
            extra["MTL_HUD_ENABLED"] = "1"
        }
        if pointerLockAllowed {
            extra["PEAR_ALLOW_POINTER_LOCK"] = "1"
        }

        let launchLease = try AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
        defer { launchLease.release() }
        try AppLauncher.requireStopped(app)

        let mode: PreparationMode = installer.currentPreparationMode(for: app) == .compatibilityEnvironment
            ? .compatibilityEnvironment : .compatibility
        try installer.setPreparationMode(mode, for: app, launchLease: launchLease)

        return try await launcher.launch(
            app,
            keymapURL: keymapURL,
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
