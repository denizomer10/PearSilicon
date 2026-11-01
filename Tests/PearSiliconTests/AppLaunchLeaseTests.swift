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

    func testUninstallCannotBypassAnInProgressTransaction() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.app.bundleURL, withIntermediateDirectories: true)
        let resource = fixture.app.bundleURL.appendingPathComponent("untouched")
        let data = Data("installed resource".utf8)
        try data.write(to: resource)
        let lease = try fixture.acquire()
        defer { lease.release() }
        var tools = PackageInstaller.PreparationTools()
        tools.requireStopped = { _ in }
        let installer = PackageInstaller(libraryURL: fixture.library, preparationTools: tools)

        XCTAssertThrowsError(try installer.uninstall(fixture.app)) {
            XCTAssertTrue($0.localizedDescription.contains("in progress"))
        }

        XCTAssertEqual(try? Data(contentsOf: resource), data)
        try lease.validate(appID: fixture.app.id, libraryURL: fixture.library)
        lease.release()
        try installer.uninstall(fixture.app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.bundleURL.path))
    }

    func testBackgroundContentionNeverAdmitsTwoWritersOrStrandsLease() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let appID = fixture.app.id
        let library = fixture.library
        let first = try fixture.acquire()
        defer { first.release() }
        let inode = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)[.systemFileNumber] as? NSNumber

        @Sendable func contend(_ results: ContentionResults) {
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                for _ in 0..<20 {
                    do {
                        let lease = try AppLaunchLease.acquire(appID: appID, libraryURL: library)
                        results.enter()
                        do { try lease.validate(appID: appID, libraryURL: library) }
                        catch { results.unexpected(error) }
                        usleep(250)
                        results.leave()
                        lease.release()
                    } catch {
                        if error.localizedDescription.contains("in progress") { results.contended() }
                        else { results.unexpected(error) }
                    }
                }
            }
        }

        let blocked = ContentionResults()
        contend(blocked)
        let blockedState = blocked.snapshot()
        XCTAssertEqual(blockedState.acquired, 0)
        XCTAssertEqual(blockedState.contended, 240)
        XCTAssertTrue(blockedState.errors.isEmpty, "\(blockedState.errors)")
        first.release()

        let progress = ContentionResults()
        contend(progress)
        let progressState = progress.snapshot()
        XCTAssertGreaterThan(progressState.acquired, 0)
        XCTAssertEqual(progressState.acquired + progressState.contended, 240)
        XCTAssertEqual(progressState.maximumWriters, 1)
        XCTAssertTrue(progressState.errors.isEmpty, "\(progressState.errors)")
        let next = try fixture.acquire()
        defer { next.release() }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: next.fileURL.path)[.systemFileNumber] as? NSNumber, inode)
    }

    private final class ContentionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var acquired = 0
        private var contention = 0
        private var writers = 0
        private var maximumWriters = 0
        private var errors: [String] = []

        func enter() {
            lock.lock()
            defer { lock.unlock() }
            acquired += 1
            writers += 1
            maximumWriters = max(maximumWriters, writers)
        }

        func leave() {
            lock.lock()
            defer { lock.unlock() }
            writers -= 1
        }

        func contended() {
            lock.lock()
            defer { lock.unlock() }
            contention += 1
        }

        func unexpected(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            errors.append(error.localizedDescription)
        }

        func snapshot() -> (acquired: Int, contended: Int, maximumWriters: Int, errors: [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (acquired, contention, maximumWriters, errors)
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
