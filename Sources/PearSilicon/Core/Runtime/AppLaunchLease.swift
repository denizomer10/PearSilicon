import CryptoKit
import Darwin
import Foundation

/// Serializes preparation and launch across GUI/CLI processes. It is a short
/// transaction lease, not the host's separate lifetime KV-writer lock.
final class AppLaunchLease: @unchecked Sendable {
    let fileURL: URL
    private let appID: String
    private let supportPath: String
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32, fileURL: URL, appID: String, supportPath: String) {
        self.descriptor = descriptor
        self.fileURL = fileURL
        self.appID = appID
        self.supportPath = supportPath
    }

    static func acquire(appID: String, libraryURL: URL) throws -> AppLaunchLease {
        let support = libraryURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let directory = support.appendingPathComponent("Runtime/LaunchLocks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw HostServiceError.systemCall("open launch lock directory", errno) }
        defer { close(directoryFD) }
        var status = stat()
        guard fstat(directoryFD, &status) == 0, status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o700 else {
            throw PearError.launchFailed("Launch lock directory must be UID-owned with mode 0700")
        }
        let name = SHA256.hash(data: Data(appID.utf8))
            .map { String(format: "%02x", $0) }.joined() + ".lock"
        let fd = openat(directoryFD, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostServiceError.systemCall("open launch lock", errno) }
        var ownsDescriptor = true
        defer { if ownsDescriptor { close(fd) } }
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1 else {
            throw PearError.launchFailed("Unsafe launch lock file")
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw PearError.launchFailed("Another launch or preparation of this app is already in progress")
            }
            throw HostServiceError.systemCall("lock launch", errno)
        }
        guard fchmod(fd, 0o600) == 0 else { throw HostServiceError.systemCall("chmod launch lock", errno) }
        ownsDescriptor = false
        return AppLaunchLease(
            descriptor: fd, fileURL: directory.appendingPathComponent(name),
            appID: appID, supportPath: support.path
        )
    }

    func validate(appID: String, libraryURL: URL) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0, self.appID == appID,
              supportPath == libraryURL.deletingLastPathComponent().resolvingSymlinksInPath().path else {
            throw PearError.launchFailed("Invalid or released app launch lease")
        }
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        // Keep the file: unlinking a flock inode would admit another writer.
    }

    deinit { release() }
}
