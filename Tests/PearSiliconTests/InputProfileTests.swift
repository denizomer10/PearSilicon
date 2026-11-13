import Foundation
import XCTest
@testable import PearSilicon

final class InputProfileTests: XCTestCase {
    /// Mirrors the profile the runtime detects for an iOS 10 era, scene-less app.
    private var legacyProfile: AppCompatibility {
        AppCompatibility.make(from: ["DTSDKName": "iphoneos10.3"])
    }

    func testLegacyProfileAppliesTheAutomaticBridgesAndDoesNotLeakToAnotherApp() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }

        let modernEnvironment = AppSettings.compatibilityEnvironment(
            for: id, compatibility: .modern, virtualGamepad: false
        )
        XCTAssertEqual(modernEnvironment, ["PEAR_MOUSE_TOUCH": "1", "PEAR_GAME_MODE": "1"])
        XCTAssertNil(modernEnvironment["PEAR_LEGACY_WINDOW_LAYER_ONLY"])

        let environment = AppSettings.compatibilityEnvironment(
            for: id, compatibility: legacyProfile, virtualGamepad: false
        )
        XCTAssertEqual(environment["PEAR_LEGACY_WINDOW_LAYER_ONLY"], "1")
        XCTAssertEqual(environment["PEAR_DIRECT_LEGACY_TOUCH"], "1")
        XCTAssertEqual(environment["PEAR_MOUSE_TOUCH"], "1")
        XCTAssertNil(environment["PEAR_LEGACY_LOGICAL_SIZE"])
        XCTAssertFalse(AppSettings.hasCompatibilityOverride(for: id, compatibility: legacyProfile))
    }

    func testVirtualGamepadKeepsRenderingProfileButExcludesTouchTranslation() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }
        AppSettings.defaults.set("1024x768", forKey: "legacyBridge.resolution." + id)

        let environment = AppSettings.compatibilityEnvironment(
            for: id, compatibility: legacyProfile, virtualGamepad: true
        )
        XCTAssertEqual(environment["PEAR_LEGACY_ATTACH_LAYER"], "1")
        XCTAssertEqual(environment["PEAR_LEGACY_LOGICAL_SIZE"], "1024x768")
        XCTAssertNil(environment["PEAR_DIRECT_LEGACY_TOUCH"])
        XCTAssertNil(environment["PEAR_MOUSE_TOUCH"])
    }

    func testMalformedStoredResolutionFallsBackToGameGeometry() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }
        for resolution in ["0x0", "nanxinf", "999999x999999", "unrecognized"] {
            AppSettings.defaults.set(resolution, forKey: "legacyBridge.resolution." + id)
            XCTAssertEqual(AppSettings.legacyResolution(for: id), "auto")
            XCTAssertNil(
                AppSettings.compatibilityEnvironment(
                    for: id, compatibility: legacyProfile, virtualGamepad: false
                )["PEAR_LEGACY_LOGICAL_SIZE"]
            )
        }
    }

    func testManualOverridesWinAndCanBeCleared() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }

        AppSettings.defaults.set(false, forKey: "legacyBridge.enabled." + id)
        AppSettings.defaults.set(false, forKey: "mouseTouch.enabled." + id)
        XCTAssertFalse(AppSettings.isLegacyBridgeEnabled(for: id, compatibility: legacyProfile))
        XCTAssertFalse(AppSettings.isMouseTouchFallbackEnabled(for: id, compatibility: legacyProfile))
        XCTAssertTrue(AppSettings.hasCompatibilityOverride(for: id, compatibility: legacyProfile))
        XCTAssertTrue(AppSettings.hasCompatibilityOverride(for: id, compatibility: .modern))
        XCTAssertEqual(AppSettings.compatibilityEnvironment(
            for: id, compatibility: legacyProfile, virtualGamepad: false
        ), ["PEAR_GAME_MODE": "1"])

        AppSettings.clearCompatibilityOverrides(for: id)
        XCTAssertFalse(AppSettings.hasCompatibilityOverride(for: id, compatibility: legacyProfile))
        XCTAssertFalse(AppSettings.hasCompatibilityOverride(for: id, compatibility: .modern))
        XCTAssertTrue(AppSettings.isLegacyBridgeEnabled(for: id, compatibility: legacyProfile))
        XCTAssertTrue(AppSettings.isMouseTouchFallbackEnabled(for: id, compatibility: .modern))
    }

    func testGameModeIsOnByDefaultAndRenderScaleIsNative() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }

        XCTAssertTrue(AppSettings.gameModeEnabled(for: id))
        XCTAssertEqual(AppSettings.renderScale(for: id), "native")
        XCTAssertEqual(AppSettings.performanceEnvironment(for: id), ["PEAR_GAME_MODE": "1"])

        AppSettings.setGameModeEnabled(false, for: id)
        AppSettings.setRenderScale("0.5", for: id)
        XCTAssertEqual(AppSettings.performanceEnvironment(for: id),
                       ["PEAR_GAME_MODE": "0", "PEAR_RENDER_SCALE": "0.5"])

        AppSettings.setRenderScale("3", for: id) // not a choice: ignored
        XCTAssertEqual(AppSettings.renderScale(for: id), "0.5")
        AppSettings.defaults.set("garbage", forKey: "renderScale." + id)
        XCTAssertEqual(AppSettings.renderScale(for: id), "native")
    }

    func testGameModeInfoDeclaresGamesCategoryWithoutOverridingTheApp() {
        var info: [String: Any] = [:]
        GameModeInfo.apply(to: &info)
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.games")
        XCTAssertEqual(info["LSSupportsGameMode"] as? Bool, true)
        XCTAssertEqual(info["GCSupportsGameMode"] as? Bool, true)
        XCTAssertEqual(info["CADisableMinimumFrameDurationOnPhone"] as? Bool, true)
        XCTAssertEqual(info["LSAppNapIsDisabled"] as? Bool, true)

        var optedOut: [String: Any] = [
            "LSApplicationCategoryType": "public.app-category.music",
            "LSSupportsGameMode": false,
        ]
        GameModeInfo.apply(to: &optedOut)
        XCTAssertEqual(optedOut["LSApplicationCategoryType"] as? String, "public.app-category.music")
        XCTAssertEqual(optedOut["LSSupportsGameMode"] as? Bool, false)
    }

    private func clear(_ id: String) {
        AppSettings.clearCompatibilityOverrides(for: id)
        AppSettings.defaults.removeObject(forKey: "legacyBridge.resolution." + id)
        AppSettings.defaults.removeObject(forKey: "gameMode.enabled." + id)
        AppSettings.defaults.removeObject(forKey: "renderScale." + id)
    }
}
