import Darwin
import Foundation
import XCTest
@testable import PearSilicon

final class RuntimeHostServiceTests: XCTestCase {
    func testDeviceGetIsAuthenticatedImmutableReadOnlyAndStableAcrossRestart() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let expected = RuntimeDeviceProfile.defaults(bundleID: HostTestFixture.bundleID)
        let first = try fixture.start()
        defer { first.stopAndWait() }
        assertError(try HostServiceConnection.call(
            socketPath: fixture.socketPath, token: "incorrect", request: ["op": "device.get"]
        ))
        let client = try fixture.connect()
        defer { close(client) }
        for _ in 0..<4 {
            try write(fixture.authenticated(["op": "device.get"]), to: client)
            try assertDeviceProfile(read(from: client), equals: expected)
        }
        var unauthorized = fixture.authenticated(["op": "device.get"])
        unauthorized["token"] = "incorrect"
        try write(unauthorized, to: client)
        assertError(try read(from: client))
        for credentials in [["version": 99, "token": fixture.token], ["version": 1]] as [[String: Any]] {
            let fd = try fixture.connect()
            defer { close(fd) }
            try write(credentials.merging(["op": "device.get"]) { _, value in value }, to: fd)
            assertError(try read(from: fd))
        }
        let overrides: [String: Any] = [
            "op": "device.get", "bundle": "another.bundle", "model": "iPad14,3",
            "value": ["name": "cannot replace the profile"],
            "environment": ["PEAR_DEVICE_MODEL": "iPad14,3"],
        ]
        try assertDeviceProfile(fixture.call(overrides), equals: expected)
        assertError(try fixture.call(["op": "device.set", "value": overrides]))
        try assertDeviceProfile(fixture.call(["op": "device.get"]), equals: expected)
        assertStore(try fixture.call(["op": "kv.all"]), equals: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeURL.path))
        first.stopAndWait()
        let restarted = try fixture.start()
        defer { restarted.stopAndWait() }
        try assertDeviceProfile(fixture.call(["op": "device.get"]), equals: expected)
    }

    func testSuppliedDeviceProfileIsTheWholeSessionSnapshotAndIndependentOfKV() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let profile = try RuntimeDeviceProfile(bundleID: HostTestFixture.bundleID, environment: [
            "PEAR_DEVICE_MODEL": "iPad14,3", "PEAR_DEVICE_NAME": "Headless iPad", "PEAR_DEVICE_IDIOM": "IPAD",
            "PEAR_FAKE_IOS_VERSION": "17.2.1", "PEAR_FAKE_IOS_BUILD": "21C66", "PEAR_FAKE_DARWIN": "23.2.0",
        ])
        let host = try fixture.start(deviceProfile: profile)
        defer { host.stopAndWait() }
        try assertDeviceProfile(fixture.call(["op": "device.get"]), equals: profile)
        assertOK(try fixture.call([
            "op": "kv.set", "key": "device.profile",
            "value": RuntimeDeviceProfile.defaults(bundleID: HostTestFixture.bundleID).propertyList,
        ]))
        try assertDeviceProfile(fixture.call(["op": "device.get"]), equals: profile)
    }

    func testWrongBundleProfileFailsBeforeOpeningTheStoreOrListener() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let service = fixture.service(deviceProfile: .defaults(bundleID: "another.private.bundle"))
        XCTAssertThrowsError(try service.run()) {
            XCTAssertEqual($0 as? RuntimeDeviceProfileError, .invalidField("bundle"))
            XCTAssertEqual($0.localizedDescription, "device profile: invalid bundle")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dataDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
        let recovered = try fixture.start()
        defer { recovered.stopAndWait() }
        try assertDeviceProfile(fixture.call(["op": "device.get"]), equals: .defaults(bundleID: HostTestFixture.bundleID))
    }

    func testInvalidDefaultOrSuppliedBundleFailsBeforeOpeningTheStoreOrListener() throws {
        for bundle in ["", String(repeating: "a", count: 256), String(repeating: "é", count: 128), "test.pear.\0bundle", "test.pear.\u{202e}bundle"] {
            for supplied in [false, true] {
                let fixture = try HostTestFixture()
                defer { fixture.remove() }
                let profile: RuntimeDeviceProfile? = supplied ? .defaults(bundleID: bundle) : nil
                let service = RuntimeHostService(
                    socketPath: fixture.socketPath, bundleID: bundle,
                    dataDirectory: fixture.dataDirectory, token: fixture.token, deviceProfile: profile
                )
                XCTAssertThrowsError(try service.run()) {
                    XCTAssertEqual($0 as? RuntimeDeviceProfileError, .invalidField("bundle"))
                    XCTAssertEqual($0.localizedDescription, "device profile: invalid bundle")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dataDirectory.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketDirectory.path))
            }
        }
    }

    func testTypedRoundTripMissingDeletionAndRestartPersistence() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let first = try fixture.start()
        defer { first.stopAndWait() }

        let ping = try fixture.call(["op": "ping"])
        XCTAssertEqual(ping["service"] as? String, "pear-host")
        XCTAssertEqual(ping["bundle"] as? String, HostTestFixture.bundleID)
        XCTAssertEqual(HostServiceProtocol.integer(ping["version"]), 1)

        let expected: [String: Any] = [
            "text": "hello", "boolean": true, "integer": Int64(9_007_199_254_740_993),
            "real": 1.25, "data": Data([0, 1, 127, 255]),
            "largeData": Data(repeating: 0xa5, count: 400_000),
            "date": Date(timeIntervalSince1970: 1_700_000_000.125),
            "array": ["text", 42, false, Data([8, 9])] as [Any],
            "nested": ["inner": ["answer": 42], "empty": []] as [String: Any],
        ]
        for (key, value) in expected {
            assertOK(try fixture.call(["op": "kv.set", "key": key, "value": value]))
            let get = try fixture.call(["op": "kv.get", "key": key])
            assertOK(get)
            XCTAssertEqual(get["found"] as? Bool, true)
            XCTAssertTrue(NSDictionary(dictionary: ["v": try XCTUnwrap(get["value"])]).isEqual(to: ["v": value]))
        }
        let absent = try fixture.call(["op": "kv.get", "key": "absent"])
        assertOK(absent)
        XCTAssertEqual(absent["found"] as? Bool, false)
        XCTAssertNil(absent["value"])
        assertOK(try fixture.call(["op": "kv.set", "key": "temporary", "value": "delete me"]))
        assertOK(try fixture.call(["op": "kv.set", "key": "temporary"]))
        let deleted = try fixture.call(["op": "kv.get", "key": "temporary"])
        XCTAssertEqual(deleted["found"] as? Bool, false)
        XCTAssertNil(deleted["value"])
        assertStore(try fixture.call(["op": "kv.all"]), equals: expected)

        let stored = try Data(contentsOf: fixture.storeURL)
        XCTAssertTrue(stored.starts(with: Data("bplist00".utf8)))
        assertOK(try fixture.call(["op": "session.stop"]))
        try first.waitForExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketDirectory.path))

        let second = try fixture.start()
        defer { second.stopAndWait() }
        assertStore(try fixture.call(["op": "kv.all"]), equals: expected)
    }

    func testFailedPersistenceDoesNotAcknowledgeOrChangeMemory() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start()
        defer { host.stopAndWait() }
        assertOK(try fixture.call(["op": "kv.set", "key": "stable", "value": "original"]))
        let backup = fixture.storeURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: fixture.storeURL, to: backup)
        // A directory at the destination forces atomic rename to fail even
        // when tests run with privileges that would defeat chmod-based tests.
        try FileManager.default.createDirectory(at: fixture.storeURL, withIntermediateDirectories: false)
        assertError(try fixture.call(["op": "kv.set", "key": "stable", "value": "uncommitted"]))
        assertStore(try fixture.call(["op": "kv.all"]), equals: ["stable": "original"])
        assertError(try fixture.call(["op": "kv.set", "key": "stable"]))
        XCTAssertEqual(try fixture.call(["op": "kv.get", "key": "stable"])["value"] as? String, "original")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.cloudURL.path).contains { $0.hasSuffix(".tmp") })
        try FileManager.default.removeItem(at: fixture.storeURL)
        try FileManager.default.moveItem(at: backup, to: fixture.storeURL)
        assertOK(try fixture.call(["op": "kv.set", "key": "stable", "value": "committed"]))
        host.stopAndWait()
        let restarted = try fixture.start()
        defer { restarted.stopAndWait() }
        assertStore(try fixture.call(["op": "kv.all"]), equals: ["stable": "committed"])
    }

    func testStoreAndUTF8KeyLimitsAreTransactional() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start()
        defer { host.stopAndWait() }
        let limitKey = String(repeating: "é", count: 512)
        assertOK(try fixture.call(["op": "kv.set", "key": limitKey, "value": "kept"]))
        let original = try Data(contentsOf: fixture.storeURL)
        assertError(try fixture.call(["op": "kv.set", "key": "", "value": 1]))
        assertError(try fixture.call(["op": "kv.get", "key": limitKey + "a"]))
        assertError(try fixture.call([
            "op": "kv.set", "key": "oversize", "value": Data(repeating: 0x7f, count: 524_288),
        ]))
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), original)
        assertStore(try fixture.call(["op": "kv.all"]), equals: [limitKey: "kept"])
        XCTAssertThrowsError(try fixture.call(["op": "kv.set", "key": "null", "value": NSNull()]))
    }

    func testAuthenticationVersionAndOperationCheckedOnEveryRequest() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start()
        defer { host.stopAndWait() }
        for operation in ["unknown", "device"] { assertError(try fixture.call(["op": operation])) }
        assertError(try HostServiceConnection.call(
            socketPath: fixture.socketPath, token: "incorrect", request: ["op": "session.stop"]
        ))
        let fd = try fixture.connect()
        defer { close(fd) }
        var request = fixture.authenticated(["op": "ping"])
        try write(request, to: fd)
        assertOK(try read(from: fd))
        request["token"] = "incorrect"
        request["op"] = "kv.set"
        request["key"] = "not authorized"
        request["value"] = 1
        try write(request, to: fd)
        assertError(try read(from: fd))
        assertStore(try fixture.call(["op": "kv.all"]), equals: [:])

        for version: Any in [2, true, 1.0, "1"] {
            let client = try fixture.connect()
            defer { close(client) }
            var wrongVersion = fixture.authenticated(["op": "session.stop"])
            wrongVersion["version"] = version
            try write(wrongVersion, to: client)
            assertError(try read(from: client))
        }
        let versionClient = try fixture.connect()
        defer { close(versionClient) }
        try write(fixture.authenticated(["op": "ping"]), to: versionClient)
        assertOK(try read(from: versionClient))
        var second = fixture.authenticated(["op": "session.stop"])
        second["version"] = 99
        try write(second, to: versionClient)
        assertError(try read(from: versionClient))
        let missingClient = try fixture.connect()
        defer { close(missingClient) }
        try write(["op": "session.stop"], to: missingClient)
        assertError(try read(from: missingClient))
        assertOK(try fixture.call(["op": "ping"]))
    }

    func testMalformedOversizedAndNonDictionaryFrames() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start()
        defer { host.stopAndWait() }
        let xml = try PropertyListSerialization.data(fromPropertyList: ["op": "ping"], format: .xml, options: 0)
        let array = try PropertyListSerialization.data(fromPropertyList: ["not a dictionary"], format: .binary, options: 0)
        let frames = [
            Data([0, 0, 0, 0]),
            Data([0, 0x10, 0, 1]), // 1 MiB + 1: reject without waiting for its body.
            framed(Data("invalid".utf8)), framed(xml), framed(array),
        ]
        for frame in frames {
            let client = try fixture.connect()
            defer { close(client) }
            try HostServiceProtocol.writeAll(frame, to: client, deadline: HostServiceDeadline(timeout: 2))
            assertError(try read(from: client))
        }
        assertOK(try fixture.call(["op": "ping"]))
    }

    func testPartialFramesPersistentConnectionsAndClosedClients() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start()
        defer { host.stopAndWait() }
        let partial = try fixture.connect()
        defer { close(partial) }
        let message = try HostServiceProtocol.encode(fixture.authenticated(["op": "ping"]))
        let deadline = try HostServiceDeadline(timeout: 2)
        for byte in message {
            try HostServiceProtocol.writeAll(Data([byte]), to: partial, deadline: deadline)
            usleep(1_000)
        }
        assertOK(try read(from: partial))
        try write(fixture.authenticated(["op": "kv.get", "key": "missing"]), to: partial)
        XCTAssertEqual(try read(from: partial)["found"] as? Bool, false)

        let truncated = try fixture.connect()
        try HostServiceProtocol.writeAll(Data([0, 0, 1, 0, 0x62]), to: truncated, deadline: HostServiceDeadline(timeout: 2))
        close(truncated)
        let closedBeforeReply = try fixture.connect()
        try write(fixture.authenticated(["op": "ping"]), to: closedBeforeReply)
        close(closedBeforeReply)
        assertOK(try fixture.call(["op": "ping"])) // No process-global SIGPIPE handler.
    }

    func testConcurrentClientsDoNotLoseCommitsOrBlockBehindIdleClient() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start()
        defer { host.stopAndWait() }
        let idle = try fixture.connect()
        defer { close(idle) }
        try HostServiceProtocol.writeAll(Data([0, 0]), to: idle, deadline: HostServiceDeadline(timeout: 2))
        let group = DispatchGroup()
        let failures = HostTestFailures()
        for worker in 0..<6 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    for item in 0..<8 {
                        let key = "client-\(worker)-\(item)"
                        let set = try fixture.call(["op": "kv.set", "key": key, "value": item])
                        let get = try fixture.call(["op": "kv.get", "key": key])
                        if set["ok"] as? Bool != true || get["value"] as? Int != item {
                            failures.add("concurrent request did not observe its committed value")
                        }
                    }
                } catch { failures.add(error.localizedDescription) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.messages, [])
        var expected: [String: Any] = [:]
        for worker in 0..<6 {
            for item in 0..<8 { expected["client-\(worker)-\(item)"] = item }
        }
        assertStore(try fixture.call(["op": "kv.all"]), equals: expected)
        host.stopAndWait()
        let restarted = try fixture.start()
        defer { restarted.stopAndWait() }
        assertStore(try fixture.call(["op": "kv.all"]), equals: expected)
    }

    func testClientLimitAndIdleTimeoutReleaseCapacity() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start()
        defer { host.stopAndWait() }
        var clients: [Int32] = []
        defer { for client in clients { close(client) } }
        for _ in 0..<HostServiceProtocol.maximumClients {
            let client = try fixture.connect()
            clients.append(client)
            try write(fixture.authenticated(["op": "ping"]), to: client)
            assertOK(try read(from: client))
        }
        XCTAssertThrowsError(try fixture.call(["op": "ping"], timeout: 0.15))
        // A complete-frame deadline is not extended by an idle persistent peer.
        Thread.sleep(forTimeInterval: HostServiceProtocol.clientTimeout + 0.2)
        XCTAssertThrowsError(try read(from: clients[0]))
        assertOK(try fixture.call(["op": "ping"]))
    }

    func testPrivatePermissionsAndDuplicateStoreLock() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let first = try fixture.start()
        defer { first.stopAndWait() }
        var directory = stat()
        var socket = stat()
        XCTAssertEqual(lstat(fixture.socketDirectory.path, &directory), 0)
        XCTAssertEqual(lstat(fixture.socketPath, &socket), 0)
        XCTAssertEqual(directory.st_uid, getuid())
        XCTAssertEqual(directory.st_mode & 0o7777, 0o700)
        XCTAssertEqual(socket.st_uid, getuid())
        XCTAssertEqual(socket.st_mode & 0o7777, 0o600)

        let otherDirectory = fixture.root.appendingPathComponent("other-ipc", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let duplicate = RuntimeHostService(
            socketPath: otherDirectory.appendingPathComponent("host.sock").path,
            bundleID: HostTestFixture.bundleID, dataDirectory: fixture.dataDirectory, token: fixture.token
        )
        XCTAssertThrowsError(try duplicate.run()) { XCTAssertEqual($0 as? HostServiceError, .storeLocked) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherDirectory.path))
        assertOK(try fixture.call(["op": "ping"]))
        first.stopAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cloudURL.appendingPathComponent(".host.lock").path))
    }

    func testUnsafeDirectoryAndExistingSocketPathAreNeverReplaced() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        XCTAssertEqual(chmod(fixture.socketDirectory.path, 0o755), 0)
        XCTAssertThrowsError(try fixture.service().run()) { XCTAssertEqual($0 as? HostServiceError, .insecureSocketDirectory) }
        XCTAssertEqual(chmod(fixture.socketDirectory.path, 0o700), 0)
        let sentinel = Data("existing entry must survive".utf8)
        try sentinel.write(to: URL(fileURLWithPath: fixture.socketPath))
        XCTAssertThrowsError(try fixture.service().run()) { XCTAssertEqual($0 as? HostServiceError, .socketAlreadyExists) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.socketPath)), sentinel)
        XCTAssertThrowsError(try HostServiceProtocol.socketAddress("/tmp/" + String(repeating: "x", count: 120))) {
            XCTAssertEqual($0 as? HostServiceError, .pathTooLong)
        }
        XCTAssertThrowsError(try HostServiceProtocol.socketAddress("/tmp/embedded\0nul"))
    }

    func testCorruptStoreIsPreservedAndStartupResourcesAreCleaned() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.cloudURL, withIntermediateDirectories: true)
        let corrupt = Data([0xff, 0, 1, 2, 3])
        try corrupt.write(to: fixture.storeURL)
        XCTAssertThrowsError(try fixture.service().run()) { XCTAssertEqual($0 as? HostServiceError, .invalidStore) }
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketDirectory.path))
        // The failed host must also have released flock.
        try FileManager.default.removeItem(at: fixture.storeURL)
        let recovered = try fixture.start()
        defer { recovered.stopAndWait() }
        assertStore(try fixture.call(["op": "kv.all"]), equals: [:])
    }

    func testStartupTimeoutAndThreadSafeStop() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        let host = try fixture.start(startupTimeout: 0.25)
        let idle = try fixture.connect()
        defer { close(idle) }
        try host.waitForExit(timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketDirectory.path))
        let restarted = try fixture.start()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async { restarted.service.stop(); group.leave() }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        try restarted.waitForExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketDirectory.path))
    }

    func testAttachCancelsStartupTimeoutAndExitsWithAttachedProcess() throws {
        let fixture = try HostTestFixture()
        defer { fixture.remove() }
        // A non-UI, non-game helper; all persistent test data is under fixture.root.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let host = try fixture.start(startupTimeout: 0.5)
        defer { host.stopAndWait() }
        assertError(try fixture.call(["op": "session.attach", "pid": true]))
        assertError(try fixture.call(["op": "session.attach", "pid": 0]))
        assertOK(try fixture.call(["op": "session.attach", "pid": Int(process.processIdentifier)]))
        assertOK(try fixture.call(["op": "session.attach", "pid": Int(process.processIdentifier)]))
        assertError(try fixture.call(["op": "session.attach", "pid": Int(getpid())]))
        Thread.sleep(forTimeInterval: 0.65)
        assertOK(try fixture.call(["op": "ping"]))
        process.terminate()
        process.waitUntilExit()
        try host.waitForExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketDirectory.path))
    }

    func testConnectionDeadlineIsBounded() throws {
        XCTAssertThrowsError(try HostServiceConnection.call(socketPath: "/tmp/no-host", token: "test", request: [:], timeout: 0)) {
            XCTAssertEqual($0 as? HostServiceError, .invalidTimeout)
        }
        XCTAssertThrowsError(try HostServiceConnection.call(socketPath: "/tmp/no-host", token: "", request: [:])) {
            XCTAssertEqual($0 as? HostServiceError, .invalidToken)
        }
        let expired = try HostServiceDeadline(timeout: 0.001)
        usleep(3_000)
        XCTAssertThrowsError(try expired.remainingMilliseconds()) { XCTAssertEqual($0 as? HostServiceError, .timedOut) }
    }

    func testSharedFramingHandlesBackpressureIOTimeoutsAndClosedPeer() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw HostServiceError.systemCall("socketpair", errno)
        }
        let sender = descriptors[0]
        let receiver = descriptors[1]
        var receiverOpen = true
        defer { close(sender); if receiverOpen { close(receiver) } }
        try HostServiceProtocol.configureSocket(sender)
        try HostServiceProtocol.configureSocket(receiver)
        var bufferSize: Int32 = 4096
        XCTAssertEqual(setsockopt(sender, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout.size(ofValue: bufferSize))), 0)
        XCTAssertThrowsError(try HostServiceProtocol.readMessage(from: receiver, deadline: HostServiceDeadline(timeout: 0.03))) {
            XCTAssertEqual($0 as? HostServiceError, .timedOut)
        }

        let data = Data(repeating: 0x81, count: 400_000)
        let frame = try HostServiceProtocol.encode(["value": data])
        let group = DispatchGroup()
        let failures = HostTestFailures()
        group.enter()
        defer { _ = group.wait(timeout: .now() + 3) }
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try HostServiceProtocol.writeAll(frame, to: sender, deadline: HostServiceDeadline(timeout: 2)) }
            catch { failures.add(error.localizedDescription) }
        }
        usleep(10_000) // Fill the small send buffer before draining the receiver.
        let response = try HostServiceProtocol.readMessage(from: receiver, deadline: HostServiceDeadline(timeout: 2))
        XCTAssertEqual(response["value"] as? Data, data)
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(failures.messages, [])
        // The peer remains connected but stops reading: the *whole* write is bounded.
        XCTAssertThrowsError(try HostServiceProtocol.writeAll(frame, to: sender, deadline: HostServiceDeadline(timeout: 0.03))) {
            XCTAssertEqual($0 as? HostServiceError, .timedOut)
        }
        close(receiver)
        receiverOpen = false
        XCTAssertThrowsError(try HostServiceProtocol.writeAll(Data([0]), to: sender, deadline: HostServiceDeadline(timeout: 0.2)))
    }

    private func assertDeviceProfile(
        _ response: [String: Any], equals expected: RuntimeDeviceProfile,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        assertOK(response, file: file, line: line)
        XCTAssertEqual(Set(response.keys), Set(["ok", "value"]), file: file, line: line)
        let propertyList = try XCTUnwrap(response["value"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(try RuntimeDeviceProfile(propertyList: propertyList, bundleID: expected.bundleID), expected, file: file, line: line)
    }

    private func assertOK(_ response: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, true, file: file, line: line)
    }

    private func assertError(_ response: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        XCTAssertNotNil(response["error"] as? String, file: file, line: line)
    }

    private func assertStore(_ response: [String: Any], equals expected: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        assertOK(response, file: file, line: line)
        guard let actual = response["value"] as? [String: Any] else {
            XCTFail("missing store dictionary", file: file, line: line)
            return
        }
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected), file: file, line: line)
    }

    private func write(_ request: [String: Any], to fd: Int32) throws {
        try HostServiceProtocol.writeMessage(request, to: fd, deadline: HostServiceDeadline(timeout: 2))
    }

    private func read(from fd: Int32) throws -> [String: Any] {
        try HostServiceProtocol.readMessage(from: fd, deadline: HostServiceDeadline(timeout: 2))
    }

    private func framed(_ payload: Data) -> Data {
        let size = UInt32(payload.count)
        var frame = Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        frame.append(payload)
        return frame
    }
}

private struct HostTestFixture: Sendable {
    static let bundleID = "test.pear.host"
    let root: URL
    let socketDirectory: URL
    let socketPath: String
    let dataDirectory: URL
    let token = UUID().uuidString
    var cloudURL: URL { dataDirectory.appendingPathComponent("Library/Cloud", isDirectory: true) }
    var storeURL: URL { cloudURL.appendingPathComponent("key-values.plist") }

    init() throws {
        // Keep below Darwin's sockaddr_un path limit, even with a long TMPDIR.
        root = URL(fileURLWithPath: "/tmp/ph-" + UUID().uuidString, isDirectory: true)
        socketDirectory = root.appendingPathComponent("ipc", isDirectory: true)
        socketPath = socketDirectory.appendingPathComponent("host.sock").path
        dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try prepareSocketDirectory()
    }

    func prepareSocketDirectory() throws {
        if !FileManager.default.fileExists(atPath: socketDirectory.path) {
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }

    func service(startupTimeout: TimeInterval = 15, deviceProfile: RuntimeDeviceProfile? = nil) -> RuntimeHostService {
        RuntimeHostService(
            socketPath: socketPath, bundleID: Self.bundleID, dataDirectory: dataDirectory, token: token,
            startupTimeout: startupTimeout, deviceProfile: deviceProfile
        )
    }

    func start(startupTimeout: TimeInterval = 15, deviceProfile: RuntimeDeviceProfile? = nil) throws -> HostTestRun {
        try prepareSocketDirectory()
        let run = HostTestRun(service: service(startupTimeout: startupTimeout, deviceProfile: deviceProfile))
        do {
            let end = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while DispatchTime.now().uptimeNanoseconds < end {
                if run.isFinished {
                    try run.waitForExit()
                    throw HostTestError.stoppedBeforeReady
                }
                if let response = try? call(["op": "ping"], timeout: 0.15), response["ok"] as? Bool == true { return run }
                usleep(10_000)
            }
            throw HostTestError.readinessTimedOut
        } catch {
            run.stopAndWait()
            throw error
        }
    }

    func call(_ request: [String: Any], timeout: TimeInterval = 2) throws -> [String: Any] {
        try HostServiceConnection.call(socketPath: socketPath, token: token, request: request, timeout: timeout)
    }

    func authenticated(_ request: [String: Any]) -> [String: Any] {
        var result = request
        result["version"] = 1
        result["token"] = token
        return result
    }

    func connect() throws -> Int32 {
        try HostServiceProtocol.connect(socketPath: socketPath, deadline: HostServiceDeadline(timeout: 2))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class HostTestRun: @unchecked Sendable {
    let service: RuntimeHostService
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var failure: (any Error)?

    init(service: RuntimeHostService) {
        self.service = service
        finished.enter()
        DispatchQueue.global().async { [self] in
            do { try service.run() }
            catch { lock.lock(); failure = error; lock.unlock() }
            finished.leave()
        }
    }

    var isFinished: Bool { finished.wait(timeout: .now()) == .success }

    func waitForExit(timeout: TimeInterval = 3) throws {
        guard finished.wait(timeout: .now() + timeout) == .success else { throw HostTestError.shutdownTimedOut }
        lock.lock()
        let error = failure
        lock.unlock()
        if let error { throw error }
    }

    func stopAndWait() {
        service.stop()
        _ = finished.wait(timeout: .now() + 3)
    }
}

private final class HostTestFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ message: String) { lock.lock(); storage.append(message); lock.unlock() }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private enum HostTestError: Error {
    case stoppedBeforeReady
    case readinessTimedOut
    case shutdownTimedOut
}
