import XCTest
@testable import PearSilicon

final class DeveloperToolsTests: XCTestCase {

    func testSelectCommandUsesContentsDeveloper() {
        let command = DeveloperTools.selectCommand(for: "/Applications/Xcode.app")
        XCTAssertEqual(
            command,
            "sudo xcode-select -s \"/Applications/Xcode.app/Contents/Developer\""
        )
    }

    func testXcodeStatusEquatable() {
        XCTAssertTrue(DeveloperTools.XcodeStatus.ready.isReady)
        XCTAssertFalse(DeveloperTools.XcodeStatus.missing.isReady)
        XCTAssertFalse(
            DeveloperTools.XcodeStatus
                .installedButNotSelected(xcodePath: "/Applications/Xcode.app", activePath: nil)
                .isReady
        )
    }

    func testStatusReadyWhenXcodeIsSelected() {
        let status = DeveloperTools.status(
            activePath: "/Applications/Xcode.app/Contents/Developer",
            installedPath: "/Applications/Xcode.app"
        )
        XCTAssertEqual(status, .ready)
    }

    func testStatusMissingWithoutXcode() {
        let status = DeveloperTools.status(
            activePath: "/Library/Developer/CommandLineTools",
            installedPath: nil
        )
        XCTAssertEqual(status, .missing)
    }

    func testStatusInstalledButNotSelected() {
        let status = DeveloperTools.status(
            activePath: "/Library/Developer/CommandLineTools",
            installedPath: "/Applications/Xcode.app"
        )
        XCTAssertEqual(
            status,
            .installedButNotSelected(
                xcodePath: "/Applications/Xcode.app",
                activePath: "/Library/Developer/CommandLineTools"
            )
        )
    }

    func testStatusInstalledButNothingSelected() {
        let status = DeveloperTools.status(activePath: nil, installedPath: "/Applications/Xcode.app")
        XCTAssertEqual(
            status,
            .installedButNotSelected(xcodePath: "/Applications/Xcode.app", activePath: nil)
        )
    }
}
