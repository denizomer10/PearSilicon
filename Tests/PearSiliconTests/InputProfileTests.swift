import Foundation
import XCTest
@testable import PearSilicon

final class InputProfileTests: XCTestCase {
    func testLegacyProfileIsExplicitAndDoesNotLeakToAnotherApp() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }
        XCTAssertTrue(AppSettings.legacyEnvironment(for: id, virtualGamepad: false).isEmpty)
        AppSettings.defaults.set(true, forKey: "legacyBridge.enabled." + id)
        let environment = AppSettings.legacyEnvironment(for: id, virtualGamepad: false)
        XCTAssertEqual(environment["PEAR_LEGACY_WINDOW_LAYER_ONLY"], "1")
        XCTAssertEqual(environment["PEAR_DIRECT_LEGACY_TOUCH"], "1")
        XCTAssertEqual(environment["PEAR_MOUSE_TOUCH"], "1")
        XCTAssertNil(environment["PEAR_LEGACY_LOGICAL_SIZE"])
        XCTAssertTrue(AppSettings.legacyEnvironment(for: id + ".other", virtualGamepad: false).isEmpty)
    }

    func testVirtualGamepadKeepsRenderingProfileButExcludesTouchTranslation() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }
        AppSettings.defaults.set(true, forKey: "legacyBridge.enabled." + id)
        AppSettings.defaults.set("1024x768", forKey: "legacyBridge.resolution." + id)
        let environment = AppSettings.legacyEnvironment(for: id, virtualGamepad: true)
        XCTAssertEqual(environment["PEAR_LEGACY_ATTACH_LAYER"], "1")
        XCTAssertEqual(environment["PEAR_LEGACY_LOGICAL_SIZE"], "1024x768")
        XCTAssertNil(environment["PEAR_DIRECT_LEGACY_TOUCH"])
        XCTAssertNil(environment["PEAR_MOUSE_TOUCH"])
    }

    func testMalformedStoredResolutionFallsBackToGameGeometry() {
        let id = "test.input." + UUID().uuidString
        defer { clear(id) }
        AppSettings.defaults.set(true, forKey: "legacyBridge.enabled." + id)
        for resolution in ["0x0", "nanxinf", "999999x999999", "unrecognized"] {
            AppSettings.defaults.set(resolution, forKey: "legacyBridge.resolution." + id)
            XCTAssertEqual(AppSettings.legacyResolution(for: id), "auto")
            XCTAssertNil(AppSettings.legacyEnvironment(for: id, virtualGamepad: false)["PEAR_LEGACY_LOGICAL_SIZE"])
        }
    }

    private func clear(_ id: String) {
        AppSettings.defaults.removeObject(forKey: "legacyBridge.enabled." + id)
        AppSettings.defaults.removeObject(forKey: "legacyBridge.resolution." + id)
    }
}
