import XCTest
@testable import PearSilicon

final class CLIArgumentsTests: XCTestCase {
    func testArchitectureFlagsNeverConsumeFollowingAppName() {
        for flag in ["env-injection", "load-command", "sandboxed", "background"] {
            let parsed = CLI.parse(["--" + flag, "com.example.game"])
            XCTAssertEqual(parsed.positionals, ["com.example.game"])
            XCTAssertTrue(parsed.flags.contains(flag))
            XCTAssertNil(parsed.options[flag])
        }
    }

    func testFlagsEnvironmentAndExplicitPositionalsCanBeCombined() {
        let parsed = CLI.parse([
            "--env-injection", "--background", "--env", "PEAR_HOME_DIR=/tmp/test container",
            "--", "An App",
        ])
        XCTAssertEqual(parsed.positionals, ["An App"])
        XCTAssertEqual(parsed.flags, ["env-injection", "background"])
        XCTAssertEqual(parsed.environment, ["PEAR_HOME_DIR": "/tmp/test container"])
    }

    func testEnvironmentModeIsPreservedUntilExplicitlyChanged() throws {
        XCTAssertEqual(try CLI.requestedPreparationMode(CLI.parse([]), current: .compatibilityEnvironment), .compatibilityEnvironment)
        XCTAssertEqual(try CLI.requestedPreparationMode(CLI.parse(["--load-command"]), current: .compatibilityEnvironment), .compatibility)
        XCTAssertEqual(try CLI.requestedPreparationMode(CLI.parse(["--env-injection"]), current: .compatibility), .compatibilityEnvironment)
        XCTAssertEqual(try CLI.requestedPreparationMode(CLI.parse([]), current: .nativeContainer), .compatibility)
    }

    func testConflictingArchitectureFlagsAreRejected() {
        XCTAssertThrowsError(try CLI.requestedPreparationMode(
            CLI.parse(["--env-injection", "--load-command"]), current: .compatibility
        ))
    }

    func testSandboxedEnvironmentModeNeverSilentlyFallsBack() throws {
        XCTAssertThrowsError(try CLI.requestedPreparationMode(
            CLI.parse(["--env-injection", "--sandboxed"]), current: .compatibility
        ))
        XCTAssertThrowsError(try CLI.requestedPreparationMode(
            CLI.parse(["--sandboxed"]), current: .compatibilityEnvironment
        ))
        XCTAssertEqual(try CLI.requestedPreparationMode(
            CLI.parse(["--sandboxed", "--load-command"]), current: .compatibilityEnvironment
        ), .compatibility)
    }
}
