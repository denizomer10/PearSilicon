import CoreFoundation
import Darwin
import Foundation

/// Shared by the host and its short-lived launcher connections. This is not a
/// sandbox boundary against another process running as the same UID.
enum HostServiceProtocol {
    static let version = 1
    static let service = "pear-host"
    static let maximumFrameSize = 1_048_576
    static let maximumStoreSize = 524_288
    static let maximumKeySize = 1_024
    static let maximumClients = 8
    static let clientTimeout: TimeInterval = 2

    static func integer(_ object: Any?) -> Int? {
        guard let number = object as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let value = Int(exactly: number.int64Value),
              number.compare(NSNumber(value: value)) == .orderedSame else { return nil }
        return value
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maximumKeySize
    }

    static func encode(_ dictionary: [String: Any]) throws -> Data {
        guard PropertyListSerialization.propertyList(dictionary, isValidFor: .binary) else {
            throw HostServiceError.invalidPropertyList
        }
        let payload: Data
        do {
            payload = try PropertyListSerialization.data(
                fromPropertyList: dictionary, format: .binary, options: 0
            )
        } catch {
            // Foundation errors can contain request contents; never forward them.
            throw HostServiceError.invalidPropertyList
        }
        guard payload.count <= maximumFrameSize else { throw HostServiceError.frameTooLarge }
        let size = UInt32(payload.count)
        var frame = Data([
            UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff),
        ])
        frame.append(payload)
        return frame
    }

    static func readMessage(from fd: Int32, deadline: HostServiceDeadline) throws -> [String: Any] {
        let header = try readExactly(4, from: fd, deadline: deadline)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0 else { throw HostServiceError.invalidFrame }
        guard size <= maximumFrameSize else { throw HostServiceError.frameTooLarge }
        let payload = try readExactly(Int(size), from: fd, deadline: deadline)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: payload, options: [], format: &format)
        } catch {
            throw HostServiceError.invalidPropertyList
        }
        guard format == .binary, let dictionary = object as? [String: Any] else {
            throw HostServiceError.invalidPropertyList
        }
        return dictionary
    }

    static func writeMessage(
        _ dictionary: [String: Any], to fd: Int32, deadline: HostServiceDeadline
    ) throws {
        try writeAll(encode(dictionary), to: fd, deadline: deadline)
    }

    static func writeAll(_ data: Data, to fd: Int32, deadline: HostServiceDeadline) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = data.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0)
            }
            if count > 0 {
                offset += count
            } else if count < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
                throw HostServiceError.systemCall("send", code)
            } else {
                throw HostServiceError.connectionClosed
            }
        }
    }

    private static func readExactly(
        _ size: Int, from fd: Int32, deadline: HostServiceDeadline
    ) throws -> Data {
        var data = Data(count: size)
        var offset = 0
        while offset < size {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = data.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), size - offset, 0)
            }
            if count > 0 {
                offset += count
            } else if count < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
                throw HostServiceError.systemCall("recv", code)
            } else {
                throw HostServiceError.connectionClosed
            }
        }
        return data
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: HostServiceDeadline) throws {
        while true {
            let milliseconds = try deadline.remainingMilliseconds()
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                    throw HostServiceError.systemCall("poll", EBADF)
                }
                if descriptor.revents & (events | Int16(POLLHUP | POLLERR)) != 0 { return }
            } else if result < 0 {
                let code = errno
                if code != EINTR { throw HostServiceError.systemCall("poll", code) }
            }
        }
    }

    static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !bytes.contains(0),
              ![".", ".."].contains((path as NSString).lastPathComponent) else {
            throw HostServiceError.invalidSocketPath
        }
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HostServiceError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: bytes)
            $0[bytes.count] = 0
        }
        return address
    }

    static func configureSocket(_ fd: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw HostServiceError.systemCall("setsockopt", errno)
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HostServiceError.systemCall("fcntl", errno)
        }
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw HostServiceError.systemCall("fcntl", errno)
        }
    }

    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw HostServiceError.systemCall("getpeereid", errno)
        }
        guard uid == getuid() else { throw HostServiceError.unauthorizedPeer }
    }

    static func connect(socketPath: String, deadline: HostServiceDeadline) throws -> Int32 {
        var address = try socketAddress(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostServiceError.systemCall("socket", errno) }
        do {
            try configureSocket(fd)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                let code = errno
                guard code == EINPROGRESS || code == EINTR || code == EAGAIN || code == EWOULDBLOCK else {
                    throw HostServiceError.systemCall("connect", code)
                }
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
                    throw HostServiceError.systemCall("getsockopt", errno)
                }
                guard socketError == 0 else { throw HostServiceError.systemCall("connect", socketError) }
            }
            try verifyPeer(fd)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}

/// One absolute monotonic deadline covers connect, all partial I/O, and the reply.
struct HostServiceDeadline: Sendable {
    private let end: UInt64

    init(timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else {
            throw HostServiceError.invalidTimeout
        }
        end = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    }

    func remainingMilliseconds() throws -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { throw HostServiceError.timedOut }
        return Int32(min((end - now + 999_999) / 1_000_000, UInt64(Int32.max)))
    }
}

enum HostServiceConnection {
    /// Opens one authenticated connection per call. An `ok: false` response is
    /// returned to the caller; transport, framing, and local encoding errors throw.
    static func call(
        socketPath: String,
        token: String,
        request: [String: Any],
        timeout: TimeInterval = 2
    ) throws -> [String: Any] {
        guard !token.isEmpty else { throw HostServiceError.invalidToken }
        let deadline = try HostServiceDeadline(timeout: timeout)
        var authenticated = request
        authenticated["version"] = HostServiceProtocol.version
        authenticated["token"] = token
        let frame = try HostServiceProtocol.encode(authenticated)
        let fd = try HostServiceProtocol.connect(socketPath: socketPath, deadline: deadline)
        defer { close(fd) }
        try HostServiceProtocol.writeAll(frame, to: fd, deadline: deadline)
        let response = try HostServiceProtocol.readMessage(from: fd, deadline: deadline)
        guard let ok = response["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID(),
              ok.boolValue || response["error"] is String else {
            throw HostServiceError.invalidResponse
        }
        return response
    }
}

enum HostServiceError: LocalizedError, Equatable {
    case systemCall(String, Int32)
    case invalidSocketPath
    case pathTooLong
    case insecureSocketDirectory
    case socketAlreadyExists
    case unauthorizedPeer
    case invalidToken
    case invalidTimeout
    case timedOut
    case connectionClosed
    case invalidFrame
    case frameTooLarge
    case invalidPropertyList
    case invalidResponse
    case storeLocked
    case invalidStore
    case storeTooLarge
    case invalidKey
    case alreadyRun

    var errorDescription: String? {
        switch self {
        case .systemCall(let operation, let code): return "host service: \(operation) failed (\(code))"
        case .invalidSocketPath: return "host service: invalid absolute socket path"
        case .pathTooLong: return "host service: socket path too long"
        case .insecureSocketDirectory: return "host service: socket parent must be an existing, UID-owned directory with mode 0700"
        case .socketAlreadyExists: return "host service: socket path already exists; refusing to replace it"
        case .unauthorizedPeer: return "host service: unauthorized peer UID"
        case .invalidToken: return "host service: a nonempty launch token is required"
        case .invalidTimeout: return "host service: timeout must be finite and in (0, 86400] seconds"
        case .timedOut: return "host service: connection timed out"
        case .connectionClosed: return "host service: connection closed"
        case .invalidFrame: return "host service: invalid frame length"
        case .frameTooLarge: return "host service: frame exceeds 1 MiB"
        case .invalidPropertyList: return "host service: expected a binary property list dictionary"
        case .invalidResponse: return "host service: invalid response"
        case .storeLocked: return "host service: another host already owns this app's store"
        case .invalidStore: return "host service: existing store is invalid; preserved without changes"
        case .storeTooLarge: return "host service: store exceeds 512 KiB"
        case .invalidKey: return "host service: key must contain 1...1024 UTF-8 bytes"
        case .alreadyRun: return "host service: run may only be called once"
        }
    }
}
