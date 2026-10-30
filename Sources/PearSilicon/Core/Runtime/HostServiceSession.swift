import Darwin
import Foundation

/// A launcher-owned startup handle. After attach, the host watches the game's
/// process independently, so a short-lived CLI can exit without stopping it.
final class RuntimeHostSession: @unchecked Sendable {
    let socketPath: String
    let token: String
    let deviceProfile: RuntimeDeviceProfile
    private let process: Process
    private let socketDirectory: String

    private init(
        process: Process, socketDirectory: String, token: String, deviceProfile: RuntimeDeviceProfile
    ) {
        self.process = process
        self.socketDirectory = socketDirectory
        self.socketPath = socketDirectory + "/host.sock"
        self.token = token
        self.deviceProfile = deviceProfile
    }

    static func start(
        executableURL: URL,
        bundleID: String,
        dataDirectory: URL,
        logURL: URL,
        readinessTimeout: TimeInterval = 3,
        deviceEnvironment: [String: String] = [:]
    ) async throws -> RuntimeHostSession {
        let task = Task.detached(priority: .utility) {
            try startBlocking(
                executableURL: executableURL, bundleID: bundleID,
                dataDirectory: dataDirectory, logURL: logURL,
                readinessTimeout: readinessTimeout, deviceEnvironment: deviceEnvironment
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func startBlocking(
        executableURL: URL, bundleID: String, dataDirectory: URL,
        logURL: URL, readinessTimeout: TimeInterval, deviceEnvironment: [String: String]
    ) throws -> RuntimeHostSession {
        let deadline = try HostServiceDeadline(timeout: readinessTimeout)
        try Task.checkCancellation()
        let deviceProfile = try RuntimeDeviceProfile(bundleID: bundleID, environment: deviceEnvironment)
        let directory = try makeSocketDirectory()
        let process = Process()
        // Two independent UUIDs provide an unguessable, per-launch capability;
        // it is passed only through the environment, never argv or logs.
        let token = UUID().uuidString + UUID().uuidString
        let session = RuntimeHostSession(
            process: process, socketDirectory: directory, token: token, deviceProfile: deviceProfile
        )
        var ready = false
        defer { if !ready { session.stopBlocking() } }

        process.executableURL = executableURL
        process.arguments = [
            "host-service", "--socket", session.socketPath,
            "--bundle", bundleID, "--data", dataDirectory.path,
        ]
        process.environment = hostEnvironment(token: token, deviceEnvironment: deviceEnvironment)
        process.standardInput = FileHandle.nullDevice
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard logFD >= 0 else { throw HostServiceError.systemCall("open host log", errno) }
        let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
        defer { try? log.close() }
        process.standardOutput = log
        process.standardError = log
        try process.run()

        while true {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw PearError.launchFailed("Host service exited before readiness; see \(logURL.path)")
            }
            let remaining = try deadline.remainingMilliseconds()
            if let response = try? HostServiceConnection.call(
                socketPath: session.socketPath, token: token,
                request: ["op": "ping"], timeout: min(0.1, Double(remaining) / 1_000)
            ) {
                guard response["ok"] as? Bool == true,
                      response["service"] as? String == HostServiceProtocol.service,
                      response["bundle"] as? String == bundleID,
                      HostServiceProtocol.integer(response["version"]) == HostServiceProtocol.version else {
                    throw HostServiceError.invalidResponse
                }
                let profileResponse = try HostServiceConnection.call(
                    socketPath: session.socketPath, token: token, request: ["op": "device.get"],
                    timeout: Double(try deadline.remainingMilliseconds()) / 1_000
                )
                guard profileResponse["ok"] as? Bool == true,
                      let propertyList = profileResponse["value"] as? [String: Any] else {
                    throw HostServiceError.invalidResponse
                }
                let returnedProfile = try RuntimeDeviceProfile(propertyList: propertyList, bundleID: bundleID)
                guard returnedProfile == deviceProfile else { throw HostServiceError.invalidResponse }
                try Task.checkCancellation()
                _ = try deadline.remainingMilliseconds()
                ready = true
                return session
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func attach(to pid: pid_t) async throws {
        try await Task.detached(priority: .utility) { [self] in
            guard process.isRunning else { throw HostServiceError.connectionClosed }
            let response = try HostServiceConnection.call(
                socketPath: socketPath, token: token,
                request: ["op": "session.attach", "pid": Int(pid)]
            )
            guard response["ok"] as? Bool == true else {
                throw PearError.launchFailed("Host service could not attach to the launched process")
            }
        }.value
    }

    func stop() async {
        await Task.detached(priority: .utility) { [self] in stopBlocking() }.value
    }

    private func stopBlocking() {
        Self.terminateProcess(process)
        // The server normally removes these. A pre-bind failure or forced exit
        // may leave our endpoint; never recursively delete this directory.
        var status = stat()
        if lstat(socketPath, &status) == 0,
           status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK {
            unlink(socketPath)
        }
        rmdir(socketDirectory)
    }

    /// Only for Process objects created by this launch attempt, never a PID
    /// discovered by name. Used for host startup and direct-game rollback.
    static func terminateProcess(_ process: Process) {
        if process.isRunning {
            // The CLI handles SIGTERM with a dispatch source so the host releases
            // its lock and socket. Bound cleanup even if the child fails to exit.
            process.terminate()
            let limit = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < limit {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // waitUntilExit() can wait indefinitely for Foundation's run-loop
            // notification when run/stop occur on different executor threads,
            // even after the child has exited. Process owns asynchronous reaping;
            // bound our observation instead of starting an unbounded wait here.
            let exitLimit = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < exitLimit {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    static func makeSocketDirectory() throws -> String {
        // sockaddr_un has a 104-byte path limit on macOS. mkdtemp atomically
        // creates a short, unpredictable, UID-private directory with mode 0700.
        var template = Array("/tmp/pear-host-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            throw HostServiceError.systemCall("mkdtemp", errno)
        }
        return String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func hostEnvironment(
        token: String, base: [String: String] = ProcessInfo.processInfo.environment,
        deviceEnvironment: [String: String] = [:]
    ) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("PEAR_") }
        environment["PEAR_HOST_TOKEN"] = token
        for key in RuntimeDeviceProfile.inputEnvironmentKeys {
            environment[key] = deviceEnvironment[key]
        }
        return environment
    }
}
