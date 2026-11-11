import Foundation
import XCTest
@testable import PearSilicon

final class UpdateAutomationTests: XCTestCase {
    func testOrdinaryBundleIsNotTranslocated() throws {
        let url = URL(fileURLWithPath: "/Applications/PearSilicon.app")
        XCTAssertFalse(AppTranslocation.isTranslocated(url))
        XCTAssertEqual(AppTranslocation.originalURL(for: url), url)
    }

    @MainActor
    func testGatekeeperGuidanceNamesTheSettingToUse() {
        let message = CLI.gatekeeperApprovalMessage(appName: "PearSilicon")
        XCTAssertTrue(message.contains("Privacy & Security"))
        XCTAssertTrue(message.contains("Open Anyway"))
        XCTAssertTrue(CLI.privacySecuritySettingsURL.hasPrefix("x-apple.systempreferences:"))
    }

    func testAutomaticUpdatesDefaultToOn() {
        let key = "updates.automatic"
        let saved = AppSettings.defaults.object(forKey: key)
        defer { AppSettings.defaults.set(saved, forKey: key) }
        AppSettings.defaults.removeObject(forKey: key)
        XCTAssertTrue(AppSettings.automaticUpdates)
        AppSettings.automaticUpdates = false
        XCTAssertFalse(AppSettings.automaticUpdates)
    }

    /// Test runners and bare SwiftPM builds must never replace an app.
    @MainActor
    func testTestProcessNeverUpdatesItself() {
        XCTAssertFalse(AppState.canUpdateAutomatically)
    }
}
