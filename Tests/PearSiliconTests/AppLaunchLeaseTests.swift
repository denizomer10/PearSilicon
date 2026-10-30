import Darwin
import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class AppLaunchLeaseTests: XCTestCase {
    func testSameAppIsExclusiveUntilReleaseAndCannotReuseReleasedLease() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.acquire()
        defer { first.release() }
        XCTAssertThrowsError(try fixture.acquire()) { error in
            XCTAssertTrue(error.localizedDescription.contains("in progress"))
        }
        try first.validate(appID: fixture.app.id, libraryURL: fixture.library)
        XCTAssertThrowsError(try first.validate(appID: "another app", libraryURL: fixture.library))
        first.release()
        first.release()
        XCTAssertThrowsError(try first.validate(appID: fixture.app.id, libraryURL: fixture.library))
        let next = try fixture.acquire()
        defer { next.release() }
        XCTAssertEqual(first.fileURL, next.fileURL)
    }

    func testLeaseExcludesAnotherProcessNotOnlyAnotherSwiftObject() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lease = try fixture.acquire()
        defer { lease.release() }
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("Python 3 is required for the headless interprocess flock test")
        }
        func attempt() throws -> Int32 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: python)
            child.arguments = ["-c", """
                import fcntl, os, sys
                with open(sys.argv[1], 'r+b') as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        sys.exit(73)
                """, lease.fileURL.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            return child.terminationStatus
        }
        XCTAssertEqual(try attempt(), 73)
        lease.release()
        XCTAssertEqual(try attempt(), 0)
    }

    func testDifferentAppsCanProceedAndLockPermissionsArePrivate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.acquire()
        defer { first.release() }
        let other = try AppLaunchLease.acquire(appID: "com.pearsilicon.other-test", libraryURL: fixture.library)
        defer { other.release() }
        XCTAssertNotEqual(first.fileURL, other.fileURL)
        var status = stat()
        XCTAssertEqual(lstat(first.fileURL.path, &status), 0)
        XCTAssertEqual(status.st_uid, getuid())
        XCTAssertEqual(status.st_mode & 0o7777, 0o600)
        XCTAssertEqual(lstat(first.fileURL.deletingLastPathComponent().path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o700)
    }

    func testUnsafeDirectoryAndSymlinkCannotBecomeLaunchLocks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("Runtime/LaunchLocks")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        XCTAssertThrowsError(try fixture.acquire())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lease = try fixture.acquire()
        lease.release()
        let outside = fixture.root.appendingPathComponent("untouched")
        try Data("sentinel".utf8).write(to: outside)
        try FileManager.default.removeItem(at: lease.fileURL)
        try FileManager.default.createSymbolicLink(at: lease.fileURL, withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.acquire())
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "sentinel")
    }

    func testInstallerAndLauncherCannotBypassAnInProgressTransaction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lease = try fixture.acquire()
        defer { lease.release() }
        let installer = PackageInstaller(libraryURL: fixture.library)
        XCTAssertThrowsError(try installer.setPreparationMode(.compatibility, for: fixture.app)) { error in
            XCTAssertTrue(error.localizedDescription.contains("in progress"))
        }
        do {
            _ = try await AppLauncher(libraryURL: fixture.library).launch(
                fixture.app, keymapURL: nil, activate: false
            )
            XCTFail("A concurrent launch must fail before reading/spawning the app")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in progress"))
        }
    }

    private struct Fixture {
        let root: URL
        var library: URL { root.appendingPathComponent("Applications", isDirectory: true) }
        var app: InstalledApp {
            InstalledApp(
                id: "com.pearsilicon.launch-lease-test", displayName: "Example", bundleName: "Example",
                shortVersion: "1", bundleVersion: "1", minimumOSVersion: "14",
                bundleURL: library.appendingPathComponent("Example.app"), executableName: "Example",
                iconURL: nil, installedAt: Date()
            )
        }
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pear-lease-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func acquire() throws -> AppLaunchLease {
            try AppLaunchLease.acquire(appID: app.id, libraryURL: library)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
