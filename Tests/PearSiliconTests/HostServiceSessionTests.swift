import Darwin
import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class HostServiceSessionTests: XCTestCase {
    func testSocketDirectoryIsShortPrivateAndUnique() throws {
        let first = try RuntimeHostSession.makeSocketDirectory()
        let second = try RuntimeHostSession.makeSocketDirectory()
        defer { rmdir(first); rmdir(second) }
        XCTAssertNotEqual(first, second)
        XCTAssertLessThan((first + "/host.sock").utf8.count, 104)
        var status = stat()
        XCTAssertEqual(lstat(first, &status), 0)
        XCTAssertEqual(status.st_uid, getuid())
        XCTAssertEqual(status.st_mode & 0o7777, 0o700)
    }

    func testHostNeverInheritsGameInjectionOrCapabilities() {
        let environment = RuntimeHostSession.hostEnvironment(token: "new launch", base: [
            "PATH": "/usr/bin:/bin", "HOME": "/tmp/test-home",
            "DYLD_INSERT_LIBRARIES": "/unwanted.dylib", "DYLD_LIBRARY_PATH": "/unwanted",
            "PEAR_HOST_SOCKET": "/other-game.sock", "PEAR_HOST_TOKEN": "old launch",
            "PEAR_HOME_DIR": "/other-game", "PEAR_LAUNCHER_INJECTION": "1",
        ])
        XCTAssertEqual(environment, [
            "PATH": "/usr/bin:/bin", "HOME": "/tmp/test-home", "PEAR_HOST_TOKEN": "new launch",
        ])
    }

    func testHostEnvironmentSuppressesInheritedProfileAndForwardsOnlyExplicitRawInputs() {
        let raw: [String: String] = [
            "PEAR_DEVICE_MODEL": "iPad14,3", "PEAR_DEVICE_NAME": "Headless iPad", "PEAR_DEVICE_IDIOM": "IPAD",
            "PEAR_FAKE_IOS_VERSION": "17.2.1", "PEAR_FAKE_IOS_BUILD": "21C66", "PEAR_FAKE_DARWIN": "23.2.0",
        ]
        var base = raw
        base["PATH"] = "/usr/bin:/bin"
        base["PEAR_DEVICE_PROFILE_SOURCE"] = "old-source"
        base["PEAR_DEVICE_PROFILE_BUNDLE"] = "other.bundle"
        base["PEAR_DEVICE_VENDOR_UUID"] = "old-uuid"
        XCTAssertEqual(RuntimeHostSession.hostEnvironment(token: "new", base: base), [
            "PATH": "/usr/bin:/bin", "PEAR_HOST_TOKEN": "new",
        ])
        var explicit = raw
        explicit["PEAR_HOST_TOKEN"] = "must-not-override-token"
        explicit["PEAR_DEVICE_PROFILE_SOURCE"] = "must-not-override-source"
        explicit["PEAR_DEVICE_VENDOR_UUID"] = "must-not-override-uuid"
        explicit["PEAR_DEVICE_UI_DETAILS"] = "1"
        explicit["DYLD_INSERT_LIBRARIES"] = "/must-not-load.dylib"
        explicit["UNRELATED"] = "must-not-forward"
        let expected = raw.merging(["PATH": "/usr/bin:/bin", "PEAR_HOST_TOKEN": "new"]) { _, value in value }
        XCTAssertEqual(RuntimeHostSession.hostEnvironment(token: "new", base: base, deviceEnvironment: explicit), expected)
        XCTAssertEqual(RuntimeHostSession.hostEnvironment(
            token: "new", base: base, deviceEnvironment: ["PEAR_DEVICE_MODEL": ""]
        ), ["PATH": "/usr/bin:/bin", "PEAR_HOST_TOKEN": "new", "PEAR_DEVICE_MODEL": ""])
    }

    func testRealCLICustomProfileHandshakeCachesTheCanonicalSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment: [String: String] = [
            "PEAR_DEVICE_MODEL": "iPad14,3", "PEAR_DEVICE_NAME": "Headless iPad", "PEAR_DEVICE_IDIOM": "IPAD",
            "PEAR_FAKE_IOS_VERSION": "0017.02.1", "PEAR_FAKE_IOS_BUILD": "21C66", "PEAR_FAKE_DARWIN": "23.2.0",
            "PEAR_DEVICE_VENDOR_UUID": "untrusted-input", "PEAR_DEVICE_PROFILE_SOURCE": "untrusted-input",
        ]
        let expected = try RuntimeDeviceProfile(bundleID: Fixture.bundleID, environment: environment)
        let session = try await fixture.start(deviceEnvironment: environment)
        do {
            XCTAssertEqual(session.deviceProfile, expected)
            XCTAssertEqual(session.deviceProfile.runtimeEnvironment["PEAR_DEVICE_IDIOM"], "pad")
            let response = try HostServiceConnection.call(
                socketPath: session.socketPath, token: session.token, request: ["op": "device.get"]
            )
            let propertyList = try XCTUnwrap(response["value"] as? [String: Any])
            XCTAssertEqual(try RuntimeDeviceProfile(propertyList: propertyList, bundleID: Fixture.bundleID), expected)
        } catch {
            await session.stop()
            throw error
        }
        let directory = (session.socketPath as NSString).deletingLastPathComponent
        await session.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testCustomProfileHandshakeCachesTheVerifiedSnapshotWithoutCLIIntegration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = ["PEAR_DEVICE_MODEL": "iPad14,3", "PEAR_DEVICE_IDIOM": "IPAD", "PEAR_DEVICE_NAME": "Headless iPad"]
        let expected = try RuntimeDeviceProfile(bundleID: Fixture.bundleID, environment: environment)
        let executable = try fixture.profileHost(response: ["ok": true, "value": expected.propertyList])
        let session = try await fixture.start(executable: executable, deviceEnvironment: environment)
        XCTAssertEqual(session.deviceProfile, expected)
        XCTAssertEqual(session.deviceProfile.runtimeEnvironment["PEAR_DEVICE_IDIOM"], "pad")
        await session.stop()
        try assertLoggedChildExited(fixture.log)
    }

    func testInvalidRawProfileFailsBeforeSpawningOrCreatingLaunchResources() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = fixture.root.appendingPathComponent("must-not-start")
        try Data("#!/bin/sh\nexit 77\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            let session = try await fixture.start(executable: executable, deviceEnvironment: [
                "PEAR_DEVICE_MODEL": "private-invalid/model",
            ])
            await session.stop()
            XCTFail("Invalid device input must fail before spawning the host")
        } catch {
            XCTAssertEqual(error as? RuntimeDeviceProfileError, .invalidField("model"))
            XCTAssertEqual(error.localizedDescription, "device profile: invalid model")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("data").path))
    }

    func testProfileHandshakeRejectsMissingInvalidAndMismatchedSnapshotsAndCleansTheChild() async throws {
        let valid = RuntimeDeviceProfile.defaults(bundleID: Fixture.bundleID)
        var booleanSchema = valid.propertyList
        booleanSchema["schema"] = true
        var invalidIdentifier = valid.propertyList
        invalidIdentifier["vendorIdentifier"] = "00000000-0000-0000-0000-000000000000"
        var noncanonical = valid.propertyList
        noncanonical["idiom"] = "iPhone"
        let mismatch = try RuntimeDeviceProfile(bundleID: Fixture.bundleID, environment: ["PEAR_DEVICE_NAME": "Different name"])
        let invalidResponse = HostServiceError.invalidResponse.localizedDescription
        let cases: [(response: [String: Any], expectedError: String)] = [
            (["ok": false, "error": "unknown operation"], invalidResponse),
            (["ok": true], invalidResponse),
            (["ok": true, "value": "not a profile"], invalidResponse),
            (["ok": true, "value": booleanSchema], "device profile: invalid schema"),
            (["ok": true, "value": invalidIdentifier], "device profile: invalid vendorIdentifier"),
            (["ok": true, "value": noncanonical], "device profile: invalid idiom"),
            (["ok": true, "value": RuntimeDeviceProfile.defaults(bundleID: "another.bundle").propertyList], "device profile: invalid bundle"),
            (["ok": true, "value": mismatch.propertyList], invalidResponse),
        ]
        for test in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let executable = try fixture.profileHost(response: test.response)
            do {
                let session = try await fixture.start(executable: executable)
                await session.stop()
                XCTFail("An unverified profile must not produce a launch session")
            } catch {
                XCTAssertEqual(error.localizedDescription, test.expectedError)
            }
            try assertLoggedChildExited(fixture.log)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("data").path))
        }
    }

    func testProfileFetchUsesTheOriginalReadinessDeadlineAndCleansTheChild() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.profileHost(
            response: ["ok": true, "value": RuntimeDeviceProfile.defaults(bundleID: Fixture.bundleID).propertyList],
            startupDelay: 0.2, profileDelay: 0.5
        )
        let started = ContinuousClock.now
        do {
            let session = try await fixture.start(executable: executable, timeout: 0.45)
            await session.stop()
            XCTFail("Fetching the profile must not start a fresh readiness deadline")
        } catch {
            XCTAssertEqual(error as? HostServiceError, .timedOut)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        try assertLoggedChildExited(fixture.log)
    }

    func testRealCLIReadinessAttachHandleReleaseAndProcessExitCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var session: RuntimeHostSession? = try await fixture.start()
        let socket = try XCTUnwrap(session?.socketPath)
        let token = try XCTUnwrap(session?.token)
        XCTAssertEqual(session?.deviceProfile, .defaults(bundleID: Fixture.bundleID))
        let directory = (socket as NSString).deletingLastPathComponent
        var status = stat()
        XCTAssertEqual(lstat(socket, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o600)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        do {
            try await session?.attach(to: child.processIdentifier)
        } catch {
            await session?.stop()
            throw error
        }
        session = nil // The host must outlive the launcher's startup handle.
        XCTAssertEqual(try HostServiceConnection.call(
            socketPath: socket, token: token, request: ["op": "ping"]
        )["ok"] as? Bool, true)
        child.terminate()
        child.waitUntilExit()
        let deadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: directory), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testRealCLIStopAndDuplicateStoreFailureCleanTheirEndpoints() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try await fixture.start()
        do {
            let duplicate = try await fixture.start()
            await duplicate.stop()
            XCTFail("A second host must not become another writer")
        } catch {
            // A startup failure is explicit, while the first host stays usable.
            XCTAssertEqual(try HostServiceConnection.call(
                socketPath: session.socketPath, token: session.token, request: ["op": "ping"]
            )["ok"] as? Bool, true)
        }
        let directory = (session.socketPath as NSString).deletingLastPathComponent
        await session.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testRepeatedCrossExecutorStopsFinishAndRemoveEndpoints() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for _ in 0..<8 {
            let session = try await fixture.start()
            let directory = (session.socketPath as NSString).deletingLastPathComponent
            let started = ContinuousClock.now
            await session.stop()
            XCTAssertLessThan(started.duration(to: .now), .seconds(3))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
        }
    }

    func testReadinessTimeoutAndCancellationTerminateOnlyTheirHeadlessChild() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sleeper = fixture.root.appendingPathComponent("not-a-host")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$$\" \"$3\"\nexec /bin/sleep 30\n".utf8).write(to: sleeper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        do {
            let session = try await fixture.start(executable: sleeper, timeout: 0.75)
            await session.stop()
            XCTFail("An unrelated executable must not pass readiness")
        } catch {
            XCTAssertEqual(error as? HostServiceError, .timedOut)
        }
        try assertLoggedChildExited(fixture.log)
        try Data().write(to: fixture.log)
        let task = Task { try await fixture.start(executable: sleeper) }
        // Cancellation may legitimately happen before the child executes. Wait
        // for this child's handshake so the test can assert its exact PID and
        // endpoint were cleaned, rather than assuming a spawn timing.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: fixture.log, encoding: .utf8),
               text.split(separator: "\n").count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do {
            let session = try await task.value
            await session.stop()
            XCTFail("Cancelled startup must not return a session")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try assertLoggedChildExited(fixture.log)
    }

    private func assertLoggedChildExited(_ log: URL) throws {
        let text = try String(contentsOf: log, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "Expected child PID and endpoint, got: \(text.debugDescription)")
        let pid = try XCTUnwrap(lines.first.flatMap { pid_t($0) })
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let socket = try XCTUnwrap(lines.last).description
        XCTAssertFalse(FileManager.default.fileExists(atPath: (socket as NSString).deletingLastPathComponent))
    }

    private struct Fixture: Sendable {
        static let bundleID = "com.pearsilicon.session-test"
        let root: URL
        let cli: URL
        var log: URL { root.appendingPathComponent("host.log") }
        init() throws {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            cli = repo.appendingPathComponent(".build/debug/PearSilicon")
            guard FileManager.default.isExecutableFile(atPath: cli.path) else {
                throw XCTSkip("Build the headless CLI with swift build before running session integration tests")
            }
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pear-session-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func start(
            executable: URL? = nil, timeout: TimeInterval = 3, deviceEnvironment: [String: String] = [:]
        ) async throws -> RuntimeHostSession {
            try await RuntimeHostSession.start(
                executableURL: executable ?? cli, bundleID: Self.bundleID,
                dataDirectory: root.appendingPathComponent("data", isDirectory: true),
                logURL: log, readinessTimeout: timeout, deviceEnvironment: deviceEnvironment
            )
        }
        func profileHost(
            response: [String: Any], startupDelay: TimeInterval = 0, profileDelay: TimeInterval = 0
        ) throws -> URL {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
                throw XCTSkip("The temporary headless protocol stub requires /usr/bin/python3")
            }
            let payload = try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
            let script = """
                #!/usr/bin/python3
                import base64, os, plistlib, socket, struct, sys, time
                options = dict(zip(sys.argv[2::2], sys.argv[3::2]))
                endpoint = options["--socket"]
                print(os.getpid(), flush=True)
                print(endpoint, flush=True)
                time.sleep(\(startupDelay))
                reply = plistlib.loads(base64.b64decode("\(payload.base64EncodedString())"))
                server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                server.bind(endpoint)
                server.listen(8)
                def read_exact(peer, count):
                    data = b""
                    while len(data) < count:
                        chunk = peer.recv(count - len(data))
                        if not chunk:
                            raise EOFError()
                        data += chunk
                    return data
                while True:
                    with server.accept()[0] as peer:
                        peer.settimeout(2)
                        try:
                            size = struct.unpack(">I", read_exact(peer, 4))[0]
                            request = plistlib.loads(read_exact(peer, size))
                            if request.get("token") != os.environ["PEAR_HOST_TOKEN"] or request.get("version") != 1:
                                response = {"ok": False, "error": "unauthorized"}
                            elif request.get("op") == "ping":
                                response = {"ok": True, "service": "pear-host", "version": 1, "bundle": options["--bundle"]}
                            elif request.get("op") == "device.get":
                                time.sleep(\(profileDelay))
                                response = reply
                            else:
                                response = {"ok": False, "error": "unknown operation"}
                            data = plistlib.dumps(response, fmt=plistlib.FMT_BINARY)
                            peer.sendall(struct.pack(">I", len(data)) + data)
                        except (OSError, EOFError):
                            pass
                """
            let executable = root.appendingPathComponent("profile-host")
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return executable
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
