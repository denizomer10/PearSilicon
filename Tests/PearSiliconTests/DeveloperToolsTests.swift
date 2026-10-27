import XCTest
@testable import PearSilicon

final class DeveloperToolsTests: XCTestCase {

    private let toolchain = "/Applications/Developer.app"
    private let commandLineTools = "/Library/Developer/CommandLineTools"

    func testSelectCommandUsesContentsDeveloper() {
        let command = DeveloperTools.selectCommand(for: toolchain)
        XCTAssertEqual(
            command,
            "sudo xcode-select -s \"/Applications/Developer.app/Contents/Developer\""
        )
    }

    func testToolchainStatusEquatable() {
        XCTAssertTrue(DeveloperTools.ToolchainStatus.ready.isReady)
        XCTAssertFalse(DeveloperTools.ToolchainStatus.missing.isReady)
        XCTAssertFalse(
            DeveloperTools.ToolchainStatus
                .installedButNotSelected(toolchainPath: toolchain, activePath: nil)
                .isReady
        )
    }

    func testStatusReadyWhenToolchainIsSelected() {
        let status = DeveloperTools.status(
            activePath: "/Applications/Developer.app/Contents/Developer",
            installedPath: toolchain
        )
        XCTAssertEqual(status, .ready)
    }

    func testStatusMissingWithoutToolchain() {
        let status = DeveloperTools.status(
            activePath: commandLineTools,
            installedPath: nil
        )
        XCTAssertEqual(status, .missing)
    }

    func testStatusInstalledButNotSelected() {
        let status = DeveloperTools.status(
            activePath: commandLineTools,
            installedPath: toolchain
        )
        XCTAssertEqual(
            status,
            .installedButNotSelected(toolchainPath: toolchain, activePath: commandLineTools)
        )
    }

    func testStatusInstalledButNothingSelected() {
        let status = DeveloperTools.status(activePath: nil, installedPath: toolchain)
        XCTAssertEqual(
            status,
            .installedButNotSelected(toolchainPath: toolchain, activePath: nil)
        )
    }
}
