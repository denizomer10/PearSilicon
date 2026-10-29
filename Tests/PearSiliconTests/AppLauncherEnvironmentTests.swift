import Foundation
import XCTest
@testable import PearSilicon

final class AppLauncherEnvironmentTests: XCTestCase {
    func testLegacyLaunchDoesNotInheritAnotherGamesHostOrInjection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = fixture.launcher.buildEnvironment(
            app: fixture.app, keymapURL: nil, extra: [:], nativeContainer: false,
            baseEnvironment: [
                "HOME": "/tmp/launcher-test-home", "PEAR_HOST_SOCKET": "/old.sock",
                "PEAR_HOST_TOKEN": "old token", "DYLD_INSERT_LIBRARIES": "/old.dylib",
                "PEAR_LAUNCHER_INJECTION": "1",
                "PEAR_DEVICE_PROFILE_SOURCE": "host-v1", "PEAR_DEVICE_PROFILE_BUNDLE": "another.bundle",
                "PEAR_DEVICE_VENDOR_UUID": "00000000-0000-0000-0000-000000000000",
            ]
        )
        for key in ["PEAR_HOST_SOCKET", "PEAR_HOST_TOKEN", "DYLD_INSERT_LIBRARIES", "PEAR_LAUNCHER_INJECTION",
                    "PEAR_DEVICE_PROFILE_SOURCE", "PEAR_DEVICE_PROFILE_BUNDLE", "PEAR_DEVICE_VENDOR_UUID"] {
            XCTAssertNil(environment[key])
        }
        XCTAssertEqual(environment["PEAR_HOME_DIR"], fixture.root
            .appendingPathComponent("Games").appendingPathComponent(fixture.app.id).path)
    }

    func testEnvironmentModeUsesInstalledRuntimeAndPreservesExplicitDataRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("environment\n".utf8).write(to: PackageInstaller.injectionMarkerURL(in: fixture.app.bundleURL))
        let runtime = fixture.app.bundleURL.appendingPathComponent("Frameworks/libPearRuntime.dylib")
        try Data().write(to: runtime)
        let home = fixture.root.appendingPathComponent("selected-data").path
        let environment = fixture.launcher.buildEnvironment(
            app: fixture.app, keymapURL: nil, extra: ["PEAR_HOME_DIR": home],
            nativeContainer: false, baseEnvironment: [:]
        )
        XCTAssertEqual(environment["DYLD_INSERT_LIBRARIES"], runtime.path)
        XCTAssertEqual(environment["PEAR_LAUNCHER_INJECTION"], "1")
        XCTAssertEqual(environment["PEAR_HOME_DIR"], home)
        XCTAssertNil(environment["PEAR_HOST_SOCKET"]) // Supplied only after authenticated readiness.
        XCTAssertNil(environment["PEAR_HOST_TOKEN"])
    }

    func testDeviceOverridesRemainRawUntilHostResolvesThemAndManagedMetadataCannotBeInjected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let raw = [
            "PEAR_DEVICE_MODEL": "iPad14,3", "PEAR_DEVICE_IDIOM": "IPAD",
            "PEAR_DEVICE_NAME": "Test iPad", "PEAR_FAKE_IOS_VERSION": "17.2.1",
            "PEAR_FAKE_IOS_BUILD": "21C66", "PEAR_FAKE_DARWIN": "23.2.0",
            "PEAR_DEVICE_PROFILE_SOURCE": "unverified", "PEAR_DEVICE_PROFILE_BUNDLE": "wrong.bundle",
            "PEAR_DEVICE_VENDOR_UUID": "unverified", "PEAR_DEVICE_UI_DETAILS": "1",
            "PEAR_NO_DEVICE_UI": "1", "PEAR_NO_DEVICE_SHIM": "1",
        ]
        let environment = fixture.launcher.buildEnvironment(
            app: fixture.app, keymapURL: nil, extra: raw, nativeContainer: false, baseEnvironment: [:]
        )
        for key in RuntimeDeviceProfile.inputEnvironmentKeys {
            XCTAssertEqual(environment[key], raw[key])
        }
        for key in ["PEAR_DEVICE_PROFILE_SOURCE", "PEAR_DEVICE_PROFILE_BUNDLE", "PEAR_DEVICE_VENDOR_UUID"] {
            XCTAssertNil(environment[key])
        }
        for key in ["PEAR_DEVICE_UI_DETAILS", "PEAR_NO_DEVICE_UI", "PEAR_NO_DEVICE_SHIM"] {
            XCTAssertEqual(environment[key], "1")
        }
        let profile = try RuntimeDeviceProfile(bundleID: fixture.app.id, environment: environment)
        var handedOff = environment
        handedOff.merge(profile.runtimeEnvironment) { _, canonical in canonical }
        XCTAssertEqual(handedOff["PEAR_DEVICE_IDIOM"], "pad")
        XCTAssertEqual(handedOff["PEAR_DEVICE_PROFILE_SOURCE"], "host-v1")
        XCTAssertEqual(handedOff["PEAR_DEVICE_PROFILE_BUNDLE"], fixture.app.id)
        XCTAssertEqual(handedOff["PEAR_DEVICE_VENDOR_UUID"], profile.vendorIdentifier)
        XCTAssertNil(handedOff["PEAR_DEVICE_UNAME"])
        XCTAssertNil(handedOff["PEAR_DEVICE_KERNEL"])
        XCTAssertNil(handedOff["PEAR_SPOOF_OS_VERSION"])
    }

    @MainActor
    func testUnsupportedSandboxCombinationFailsBeforeAnyAppLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("environment\n".utf8).write(to: PackageInstaller.injectionMarkerURL(in: fixture.app.bundleURL))
        do {
            _ = try await fixture.launcher.launch(
                fixture.app, keymapURL: nil, sandboxed: true, activate: false
            )
            XCTFail("Unsupported launch must be rejected before starting a process")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sandbox-exec"))
        }
    }

    private struct Fixture {
        let root: URL
        let app: InstalledApp
        var launcher: AppLauncher { AppLauncher(libraryURL: root.appendingPathComponent("Applications")) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pear-env-test-\(UUID().uuidString)")
            let bundle = root.appendingPathComponent("Applications/Example.app")
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("Frameworks"), withIntermediateDirectories: true
            )
            try Data().write(to: bundle.appendingPathComponent("Example"))
            app = InstalledApp(
                id: "com.pearsilicon.env-test", displayName: "Example", bundleName: "Example",
                shortVersion: "1.0", bundleVersion: "1", minimumOSVersion: "14.0",
                bundleURL: bundle, executableName: "Example", iconURL: nil, installedAt: Date()
            )
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
