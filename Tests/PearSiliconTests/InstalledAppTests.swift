import XCTest
@testable import PearSilicon

final class InstalledAppTests: XCTestCase {

    func testExecutableURLComposition() {
        let app = InstalledApp(
            id: "com.example.game",
            displayName: "Example",
            bundleName: "Example",
            shortVersion: "1.0",
            bundleVersion: "1",
            minimumOSVersion: "14.0",
            bundleURL: URL(fileURLWithPath: "/tmp/Example.app"),
            executableName: "Example",
            iconURL: nil,
            installedAt: Date()
        )
        XCTAssertEqual(
            app.executableURL.path,
            "/tmp/Example.app/Example"
        )
    }
}
