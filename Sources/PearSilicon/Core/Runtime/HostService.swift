import Darwin
import Foundation

/// Owns one app's store for one launch. `run` owns resource setup/teardown;
/// stateLock protects lifecycle/client descriptors and valuesLock protects the
/// complete read/serialize/commit transaction. Worker teardown precedes unlock.
final class RuntimeHostService: @unchecked Sendable {
    private let socketPath: String
    private let bundleID: String
    private let deviceProfile: RuntimeDeviceProfile
    private let dataDirectory: URL
    private let token: String
    private let startupTimeout: TimeInterval
    private let workers = DispatchQueue(label: "com.pearsilicon.host.clients", attributes: .concurrent)
    private let lifecycleQueue = DispatchQueue(label: "com.pearsilicon.host.lifecycle")
    private let clientsFinished = DispatchGroup()
    private let availableClients = DispatchSemaphore(value: HostServiceProtocol.maximumClients)
    private let stateLock = NSLock()
    private var hasRun = false
    private var stopping = false
    private var clients = Set<Int32>()
    private var attachedPID: pid_t?
    private var processSource: (any DispatchSourceProcess)?
    private let valuesLock = NSLock()
    private var values: [String: Any] = [:]

    // Set up only by run(), then immutable until all clients have finished.
    private var socketDirectoryFD: Int32 = -1
    private var socketDirectoryIdentity: FileIdentity?
    private var socketIdentity: FileIdentity?
    private var storeDirectoryFD: Int32 = -1
    private var storeLockFD: Int32 = -1
    private let storeName = "key-values.plist"
    private var socketDirectory: String { (socketPath as NSString).deletingLastPathComponent }
    private var socketName: String { (socketPath as NSString).lastPathComponent }

    init(
        socketPath: String,
        bundleID: String,
        dataDirectory: URL,
        token: String,
        startupTimeout: TimeInterval = 15,
        deviceProfile: RuntimeDeviceProfile? = nil
    ) {
        self.socketPath = socketPath
        self.bundleID = bundleID
        self.deviceProfile = deviceProfile ?? .defaults(bundleID: bundleID)
        self.dataDirectory = dataDirectory
        self.token = token
        self.startupTimeout = startupTimeout
    }

    /// Blocking, one-shot entry point. Signal handling belongs to the CLI, not
    /// this object. All exit paths release the store lock and owned socket paths.
    func run() throws {
        stateLock.lock()
        guard !hasRun else {
            stateLock.unlock()
            throw HostServiceError.alreadyRun
        }
        hasRun = true
        let alreadyStopped = stopping
        stateLock.unlock()
        if alreadyStopped { return }

        var listener: Int32 = -1
        defer {
            stop()
            if listener >= 0 { close(listener) }
            clientsFinished.wait()
            stateLock.lock()
            let source = processSource
            processSource = nil
            stateLock.unlock()
            source?.cancel()
            cleanup()
        }

        try prepareSocketDirectory()
        guard !token.isEmpty else { throw HostServiceError.invalidToken }
        // Nonthrowing defaults may contain an invalid bundle. Revalidate the
        // whole immutable snapshot before opening the store or serving clients.
        _ = try RuntimeDeviceProfile(propertyList: deviceProfile.propertyList, bundleID: bundleID)
        // Validate configuration before opening the store; start the actual
        // unattached-session deadline only once the listener is ready.
        _ = try HostServiceDeadline(timeout: startupTimeout)
        try openStore()
        if isStopping { return }
        listener = try openListener()
        let startupDeadline = try HostServiceDeadline(timeout: startupTimeout)
        try acceptClients(listener, startupDeadline: startupDeadline)
    }

    /// May be called from any thread, including a lifecycle event handler.
    /// Shutdown wakes blocked I/O; only each descriptor's owner ever closes it.
    func stop() {
        stateLock.lock()
        stopping = true
        for client in clients { _ = shutdown(client, SHUT_RDWR) }
        stateLock.unlock()
    }

    private var isStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    private func prepareSocketDirectory() throws {
        _ = try HostServiceProtocol.socketAddress(socketPath)
        var status = stat()
        guard lstat(socketDirectory, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(), status.st_mode & 0o7777 == 0o700 else {
            throw HostServiceError.insecureSocketDirectory
        }
        let fd = open(socketDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HostServiceError.insecureSocketDirectory }
        var opened = stat()
        guard fstat(fd, &opened) == 0, FileIdentity(status) == FileIdentity(opened),
              opened.st_uid == getuid(), opened.st_mode & 0o7777 == 0o700 else {
            close(fd)
            throw HostServiceError.insecureSocketDirectory
        }
        socketDirectoryFD = fd
        socketDirectoryIdentity = FileIdentity(opened)
    }

    private func openListener() throws -> Int32 {
        var status = stat()
        if fstatat(socketDirectoryFD, socketName, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            // Even a stale, owned socket is not ours to unlink.
            throw HostServiceError.socketAlreadyExists
        }
        guard errno == ENOENT else { throw HostServiceError.systemCall("fstatat socket", errno) }
        var address = try HostServiceProtocol.socketAddress(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostServiceError.systemCall("socket", errno) }
        do {
            try HostServiceProtocol.configureSocket(fd)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw HostServiceError.systemCall("bind", errno) }
            guard fstatat(socketDirectoryFD, socketName, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw HostServiceError.systemCall("fstatat socket", errno)
            }
            guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == getuid() else {
                throw HostServiceError.insecureSocketDirectory
            }
            socketIdentity = FileIdentity(status)
            guard fchmodat(socketDirectoryFD, socketName, 0o600, 0) == 0 else {
                throw HostServiceError.systemCall("chmod socket", errno)
            }
            guard listen(fd, Int32(HostServiceProtocol.maximumClients)) == 0 else {
                throw HostServiceError.systemCall("listen", errno)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func acceptClients(_ listener: Int32, startupDeadline: HostServiceDeadline) throws {
        while true {
            stateLock.lock()
            let shouldStop = stopping
            let isAttached = attachedPID != nil
            stateLock.unlock()
            if shouldStop { return }
            if !isAttached, (try? startupDeadline.remainingMilliseconds()) == nil {
                stop()
                return
            }

            // A short poll bounds stop/startup-timeout latency without signals,
            // cross-thread close, or descriptor-reuse races.
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 50)
            if result < 0 {
                let code = errno
                if code == EINTR { continue }
                throw HostServiceError.systemCall("poll listener", code)
            }
            if result == 0 { continue }
            // Leave excess connections in the bounded listen backlog. In
            // particular, a reconnect must not race the old worker's EOF cleanup.
            guard availableClients.wait(timeout: .now() + 0.05) == .success else { continue }
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                let code = errno
                availableClients.signal()
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK || code == ECONNABORTED { continue }
                throw HostServiceError.systemCall("accept", code)
            }
            do {
                try HostServiceProtocol.configureSocket(client)
                try HostServiceProtocol.verifyPeer(client)
            } catch {
                close(client)
                availableClients.signal()
                continue
            }
            stateLock.lock()
            guard !stopping, clients.count < HostServiceProtocol.maximumClients else {
                stateLock.unlock()
                close(client)
                availableClients.signal()
                continue
            }
            clients.insert(client)
            clientsFinished.enter()
            stateLock.unlock()
            workers.async { [self] in
                defer {
                    stateLock.lock()
                    clients.remove(client)
                    close(client)
                    stateLock.unlock()
                    availableClients.signal()
                    clientsFinished.leave()
                }
                serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        while !isStopping {
            let request: [String: Any]
            do {
                let deadline = try HostServiceDeadline(timeout: HostServiceProtocol.clientTimeout)
                request = try HostServiceProtocol.readMessage(from: client, deadline: deadline)
                // Credentials, like the token and version, are checked for
                // EVERY request, including persistent connections.
                try HostServiceProtocol.verifyPeer(client)
            } catch {
                if let error = error as? HostServiceError,
                   [.invalidFrame, .frameTooLarge, .invalidPropertyList, .unauthorizedPeer].contains(error) {
                    sendError(error.localizedDescription, to: client)
                }
                return
            }

            let result = handle(request)
            do {
                try HostServiceProtocol.writeMessage(
                    result.response, to: client,
                    deadline: HostServiceDeadline(timeout: HostServiceProtocol.clientTimeout)
                )
            } catch {
                if result.stop { stop() }
                return
            }
            // In particular, send the authorized stop ACK before shutting down
            // its connection; teardown then waits for all in-flight commits.
            if result.stop { stop(); return }
            if result.close { return }
        }
    }

    private func sendError(_ message: String, to client: Int32) {
        try? HostServiceProtocol.writeMessage(
            failure(message), to: client, deadline: HostServiceDeadline(timeout: 0.25)
        )
    }

    private func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }

    private func handle(_ request: [String: Any]) -> (response: [String: Any], stop: Bool, close: Bool) {
        guard let suppliedToken = request["token"] as? String, tokenMatches(suppliedToken) else {
            return (failure("unauthorized request"), false, true)
        }
        guard HostServiceProtocol.integer(request["version"]) == HostServiceProtocol.version else {
            return (failure("unsupported protocol version"), false, true)
        }
        guard let operation = request["op"] as? String else {
            return (failure("missing operation"), false, false)
        }
        let response: [String: Any]
        switch operation {
        case "ping":
            response = [
                "ok": true, "service": HostServiceProtocol.service,
                "bundle": bundleID, "version": HostServiceProtocol.version,
            ]
        case "device.get":
            response = ["ok": true, "value": deviceProfile.propertyList]
        case "kv.get", "kv.set":
            guard let key = request["key"] as? String, HostServiceProtocol.validKey(key) else {
                return (failure(HostServiceError.invalidKey.localizedDescription), false, false)
            }
            valuesLock.lock()
            defer { valuesLock.unlock() }
            if operation == "kv.get" {
                if let value = values[key] {
                    response = ["ok": true, "found": true, "value": value]
                } else {
                    response = ["ok": true, "found": false]
                }
            } else {
                var candidate = values
                candidate[key] = request["value"] // Omission deletes; plist has no null value.
                do {
                    let data = try encodeStore(candidate)
                    try persist(data)
                    values = candidate
                    response = ["ok": true]
                } catch {
                    response = failure(error.localizedDescription)
                }
            }
        case "kv.all":
            valuesLock.lock()
            response = ["ok": true, "value": values]
            valuesLock.unlock()
        case "session.attach":
            guard let integer = HostServiceProtocol.integer(request["pid"]),
                  integer > 0, let pid = pid_t(exactly: integer) else {
                return (failure("invalid process identifier"), false, false)
            }
            response = attach(to: pid)
        case "session.stop":
            return (["ok": true], true, false)
        default:
            response = failure("unknown operation")
        }
        return (response, false, false)
    }

    private func tokenMatches(_ supplied: String) -> Bool {
        let expected = Array(token.utf8)
        let actual = Array(supplied.utf8)
        guard expected.count == actual.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ actual[index] }
        return difference == 0
    }

    private func attach(to pid: pid_t) -> [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopping else { return failure("session is stopping") }
        if let attachedPID {
            return attachedPID == pid ? ["ok": true] : failure("session already attached to another process")
        }
        if kill(pid, 0) != 0, errno == ESRCH { return failure("process does not exist") }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: lifecycleQueue)
        source.setEventHandler { [weak self] in self?.stop() }
        processSource = source
        attachedPID = pid
        source.activate()
        // Cover exit between the existence check and source registration.
        if kill(pid, 0) != 0, errno == ESRCH {
            stopping = true
            for client in clients { _ = shutdown(client, SHUT_RDWR) }
        }
        return ["ok": true]
    }

    // MARK: - Store (one lifetime flock, serialized memory/disk transactions)

    private func openStore() throws {
        let cloud = dataDirectory.appendingPathComponent("Library/Cloud", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: cloud, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw HostServiceError.systemCall("create store directory", Int32(clamping: (error as NSError).code))
        }
        storeDirectoryFD = open(cloud.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard storeDirectoryFD >= 0 else { throw HostServiceError.systemCall("open store directory", errno) }
        storeLockFD = openat(storeDirectoryFD, ".host.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard storeLockFD >= 0 else { throw HostServiceError.systemCall("open store lock", errno) }
        var status = stat()
        guard fstat(storeLockFD, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1 else {
            throw HostServiceError.invalidStore
        }
        while flock(storeLockFD, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN { throw HostServiceError.storeLocked }
            throw HostServiceError.systemCall("flock", code)
        }
        guard fchmod(storeLockFD, 0o600) == 0 else { throw HostServiceError.systemCall("chmod store lock", errno) }
        valuesLock.lock()
        defer { valuesLock.unlock() }
        values = try loadValues()
    }

    private func loadValues() throws -> [String: Any] {
        let fd = openat(storeDirectoryFD, storeName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [:] }
            throw HostServiceError.systemCall("open store", errno)
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw HostServiceError.invalidStore
        }
        guard status.st_size >= 0, status.st_size <= HostServiceProtocol.maximumStoreSize else {
            throw HostServiceError.storeTooLarge
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw HostServiceError.systemCall("read store", code)
            }
            guard data.count + count <= HostServiceProtocol.maximumStoreSize else {
                throw HostServiceError.storeTooLarge
            }
            data.append(contentsOf: chunk.prefix(count))
        }
        let object: Any
        do {
            // Accept valid legacy XML stores, but all new commits are binary.
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw HostServiceError.invalidStore
        }
        guard let dictionary = object as? [String: Any], dictionary.keys.allSatisfy(HostServiceProtocol.validKey) else {
            throw HostServiceError.invalidStore
        }
        _ = try encodeStore(dictionary)
        return dictionary
    }

    private func encodeStore(_ dictionary: [String: Any]) throws -> Data {
        guard PropertyListSerialization.propertyList(dictionary, isValidFor: .binary) else {
            throw HostServiceError.invalidStore
        }
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        } catch {
            throw HostServiceError.invalidStore
        }
        guard data.count <= HostServiceProtocol.maximumStoreSize else { throw HostServiceError.storeTooLarge }
        return data
    }

    private func persist(_ data: Data) throws {
        let temporaryName = ".key-values-\(UUID().uuidString).tmp"
        var fd = openat(storeDirectoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostServiceError.systemCall("create store transaction", errno) }
        defer {
            if fd >= 0 { close(fd) }
            _ = unlinkat(storeDirectoryFD, temporaryName, 0)
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count > 0 { offset += count; continue }
            let code = count == 0 ? EIO : errno
            if code == EINTR { continue }
            throw HostServiceError.systemCall("write store transaction", code)
        }
        while fsync(fd) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw HostServiceError.systemCall("sync store transaction", code)
        }
        let closeResult = close(fd)
        fd = -1
        guard closeResult == 0 else { throw HostServiceError.systemCall("close store transaction", errno) }
        // Atomic rename is the commit point. There are no fallible operations
        // after this before memory is replaced and the success ACK is emitted.
        guard renameat(storeDirectoryFD, temporaryName, storeDirectoryFD, storeName) == 0 else {
            throw HostServiceError.systemCall("commit store transaction", errno)
        }
    }

    private func cleanup() {
        if socketDirectoryFD >= 0, let identity = socketIdentity {
            var status = stat()
            if fstatat(socketDirectoryFD, socketName, &status, AT_SYMLINK_NOFOLLOW) == 0,
               identity == FileIdentity(status), status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK {
                _ = unlinkat(socketDirectoryFD, socketName, 0)
            }
        }
        if socketDirectoryFD >= 0 { close(socketDirectoryFD); socketDirectoryFD = -1 }
        if let identity = socketDirectoryIdentity {
            var status = stat()
            if lstat(socketDirectory, &status) == 0, identity == FileIdentity(status), status.st_uid == getuid() {
                // Never recursively remove this directory or somebody else's entries.
                _ = rmdir(socketDirectory)
            }
        }
        if storeDirectoryFD >= 0 { close(storeDirectoryFD); storeDirectoryFD = -1 }
        // Do not unlink .host.lock: a replacement inode could admit two writers.
        if storeLockFD >= 0 { close(storeLockFD); storeLockFD = -1 }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ status: stat) { device = status.st_dev; inode = status.st_ino }
    }
}
