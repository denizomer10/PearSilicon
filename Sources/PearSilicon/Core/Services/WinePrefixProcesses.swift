import Darwin
import Foundation

/// Finds every process that belongs to one Wine entry, whichever engine
/// (MetalSharp, WineHQ, …) started it, including programs that a launcher
/// re-executed and orphans whose parent is gone.
///
/// Wine processes rewrite their names, so they are identified by working
/// directory: Windows processes run inside the entry folder (`Prefix/drive_c/…`
/// or `Payload/…`), and the prefix's wineserver runs in
/// `/tmp/.wine-<uid>/server-<dev>-<inode>`, named after the prefix folder's
/// device and inode. Only this user's processes can be inspected or signalled.
enum WinePrefixProcesses {
    struct Member: Equatable, Sendable {
        let pid: pid_t
        /// Lowercased Windows file name (e.g. `steam.exe`), or the Unix one.
        let name: String
        let isServer: Bool
        /// Wine's own background services, which do not mean a program is open.
        var isWineService: Bool { isServer || WinePrefixProcesses.wineServices.contains(name) }
    }

    static let wineServices: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "explorer.exe", "rpcss.exe",
        "conhost.exe", "wineboot.exe", "winemenubuilder.exe", "start.exe", "tabtip.exe", "rundll32.exe",
        "mscorsvw.exe", "wineserver", "wine-preloader", "wine64-preloader",
    ]

    /// Processes of each entry, keyed by entry ID. One scan of the process table.
    static func scan(_ entries: [LibraryEntry]) -> [String: [Member]] {
        let targets: [(id: String, root: String, server: String?)] = entries.compactMap { entry in
            guard entry.platform == .wine else { return nil }
            return (entry.id, canonical(entry.directoryURL.path) + "/", serverDirectory(for: entry.prefixURL))
        }
        guard !targets.isEmpty else { return [:] }
        var result: [String: [Member]] = [:]
        for pid in userPIDs() where pid != getpid() {
            guard let cwd = workingDirectory(pid) else { continue }
            for target in targets {
                let isServer = target.server.map { cwd == $0 } ?? false
                guard isServer || cwd.hasPrefix(target.root) else { continue }
                result[target.id, default: []].append(Member(pid: pid, name: processName(pid) ?? "", isServer: isServer))
                break
            }
        }
        return result
    }

    /// Whether a Windows program (not just Wine's services) is running.
    static func hasProgram(_ members: [Member]?) -> Bool {
        members?.contains { !$0.isWineService } ?? false
    }

    /// Force-quits everything in the entry's prefix: `wineserver -k9` through
    /// the engine (SIGKILL to every client), then SIGKILL to whatever is left,
    /// including orphans and the wineserver. Returns the processes still alive.
    @discardableResult
    static func forceStop(_ entry: LibraryEntry, engine: WineEngine?, timeout: Duration = .seconds(5)) async -> [Member] {
        if let engine {
            let server = engine.executableURL.deletingLastPathComponent().appendingPathComponent("wineserver")
            if FileManager.default.isExecutableFile(atPath: server.path) {
                let kill = Process()
                kill.executableURL = server
                kill.arguments = ["-k9"]
                kill.environment = ManagedAppService.environment(for: entry, engine: engine)
                kill.standardOutput = FileHandle.nullDevice
                kill.standardError = FileHandle.nullDevice
                if (try? kill.run()) != nil {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while kill.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                    if kill.isRunning { kill.terminate() }
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let left = scan([entry])[entry.id] ?? []
            if left.isEmpty || ContinuousClock.now >= deadline { return left }
            for member in left { Darwin.kill(member.pid, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Process table

    static func serverDirectory(for prefix: URL) -> String? {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return nil }
        return "/private/tmp/.wine-\(getuid())/server-\(String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))"
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func userPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            guard let base = bytes.baseAddress, base.pointee != 0 else { return nil }
            return String(cString: base)
        }
    }

    /// Wine sets argv[0] to the Windows path (`C:\windows\system32\services.exe`).
    private static func processName(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // argc, executable path, NUL padding, then argv[0].
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        guard index < size else { return nil }
        let end = buffer[index..<size].firstIndex(of: 0) ?? size
        let argv0 = String(decoding: buffer[index..<end], as: UTF8.self)
        let last = argv0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? argv0
        return last.lowercased()
    }
}
