import AppKit
import Darwin
import Foundation

/// Recognizes 32-bit (armv7/armv7s) iOS executables.
///
/// Mac Catalyst preparation and `/System/iOSSupport` are arm64-only, so such a
/// binary can never be loaded by macOS itself. It is installed untouched and run
/// by PearLegacyEngine instead.
enum LegacyIOSBinary {
    // Mach-O magics are compared as raw leading bytes: a thin little-endian
    // 32-bit image starts with `ce fa ed fe`. Reading them as a big-endian
    // integer would confuse MH_MAGIC32 with FAT_CIGAM.
    private static let thin32: [UInt8] = [0xce, 0xfa, 0xed, 0xfe]
    private static let thin64: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe]
    private static let fat32: [UInt8] = [0xca, 0xfe, 0xba, 0xbe]
    private static let fat64: [UInt8] = [0xca, 0xfe, 0xba, 0xbf]

    private static let cpuTypeARM: UInt32 = 12
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    /// True when the executable carries an ARM (32-bit) slice and no arm64 slice.
    /// An unreadable or ASCII/binary-plist "executable" is not legacy.
    static func isLegacy32Bit(executableAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }

        let magic = [UInt8](header.prefix(4))
        if magic == thin32 { return true }
        if magic == thin64 { return false }
        guard magic == fat32 || magic == fat64 else { return false }

        let count = Int(be32(header, 4))
        guard count > 0, count <= 64 else { return false }
        let entrySize = magic == fat64 ? 32 : 20
        try? handle.seek(toOffset: 8)
        guard let table = try? handle.read(upToCount: count * entrySize),
              table.count == count * entrySize else { return false }

        var has32 = false
        var has64 = false
        for index in 0..<count {
            let cpu = be32(table, index * entrySize)
            if cpu == cpuTypeARM { has32 = true }
            if cpu == cpuTypeARM64 { has64 = true }
        }
        return has32 && !has64
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }
}

/// A located PearLegacyEngine installation: the `touchHLE` executable plus the
/// resources it needs (`touchHLE_dylibs/angle`, `touchHLE_fonts`, options).
struct LegacyRuntime: Sendable {
    /// Explicit override, mainly for development builds of the engine.
    static let environmentOverride = "PEAR_LEGACY_ENGINE_HOME"

    let homeURL: URL
    let executableURL: URL

    var angleLibraryURL: URL

    /// ANGLE lives beside a release build but under `vendor/angle/out` in a source
    /// checkout, so both layouts are accepted.
    static func resolveAngleLibrary(in home: URL) -> URL? {
        let candidates = [
            home.appendingPathComponent("touchHLE_dylibs/angle", isDirectory: true),
            home.appendingPathComponent("vendor/angle/out/MacMetal", isDirectory: true)
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("libEGL.dylib").path)
        }
    }

    /// Finds the best available engine installation.
    ///
    /// Order: explicit override, PearSilicon's own support directory (where the
    /// app installs it), the app bundle's resources, then source-checkout
    /// layouts so a repository build works without copying anything.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportRoot: URL = AppPaths.supportRoot,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        resourceRoot: URL? = Bundle.main.resourceURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LegacyRuntime? {
        for home in candidateHomes(
            environment: environment,
            supportRoot: supportRoot,
            currentDirectory: currentDirectory,
            resourceRoot: resourceRoot,
            homeDirectory: homeDirectory
        ) {
            for binary in ["touchHLE", "target/release/touchHLE", "target/debug/touchHLE"] {
                let executable = home.appendingPathComponent(binary)
                guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
                let resolvedHome = home.resolvingSymlinksInPath()
                guard let angle = resolveAngleLibrary(in: resolvedHome) else { continue }
                return LegacyRuntime(
                    homeURL: resolvedHome,
                    executableURL: executable.resolvingSymlinksInPath(),
                    angleLibraryURL: angle
                )
            }
        }
        return nil
    }

    private static func candidateHomes(
        environment: [String: String],
        supportRoot: URL,
        currentDirectory: URL,
        resourceRoot: URL?,
        homeDirectory: URL
    ) -> [URL] {
        var homes: [URL] = []
        if let override = environment[environmentOverride], !override.isEmpty {
            homes.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        homes.append(supportRoot.appendingPathComponent("PearLegacyEngine", isDirectory: true))
        if let resources = resourceRoot {
            homes.append(resources.appendingPathComponent("PearLegacyEngine", isDirectory: true))
        }
        for parent in [currentDirectory, homeDirectory] {
            homes.append(parent.appendingPathComponent("PearLegacyEngine", isDirectory: true))
            homes.append(
                parent.deletingLastPathComponent()
                    .appendingPathComponent("PearLegacyEngine", isDirectory: true)
            )
        }
        return homes
    }
}

/// Launches 32-bit iOS apps inside PearLegacyEngine.
///
/// The engine is one ordinary process per app, so the system never reports it as
/// an `NSRunningApplication` for the app's bundle identifier. The registry below
/// is therefore the source of truth for "is this app running", which keeps the
/// existing launch, stop and keymapper-overlay UI working unchanged.
@MainActor
final class LegacyAppLauncher {
    static let shared = LegacyAppLauncher()

    private var processes: [String: Process] = [:]

    /// A pid file lets a separately launched instance (the CLI) see and stop an
    /// engine process owned by the GUI, and vice versa.
    static var pidDirectory: URL {
        AppPaths.supportRoot
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("LegacyProcesses", isDirectory: true)
    }

    private static func pidFileURL(for appID: String) -> URL? {
        guard !appID.isEmpty, !appID.contains("/"), !appID.contains("\\"),
              !appID.utf8.contains(0), appID != ".", appID != ".." else { return nil }
        return pidDirectory.appendingPathComponent("\(appID).pid")
    }

    /// Whether `pid` still names a live process.
    private static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func writePID(_ pid: pid_t, for appID: String) {
        guard let url = pidFileURL(for: appID) else { return }
        try? FileManager.default.createDirectory(
            at: pidDirectory, withIntermediateDirectories: true
        )
        try? Data("\(pid)".utf8).write(to: url, options: .atomic)
    }

    private static func clearPID(for appID: String) {
        guard let url = pidFileURL(for: appID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Reads a recorded engine pid, discarding the record when it is stale.
    static func recordedPID(for appID: String) -> pid_t? {
        guard let url = pidFileURL(for: appID),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              isAlive(pid) else {
            clearPID(for: appID)
            return nil
        }
        return pid
    }

    /// Running app bundle identifiers mapped to the engine's process id.
    var runningProcessIdentifiers: [String: pid_t] {
        var identifiers = processes.compactMapValues { $0.isRunning ? $0.processIdentifier : nil }
        for url in (try? FileManager.default.contentsOfDirectory(
            at: Self.pidDirectory, includingPropertiesForKeys: nil
        )) ?? [] where url.pathExtension == "pid" {
            let appID = url.deletingPathExtension().lastPathComponent
            if identifiers[appID] == nil, let pid = Self.recordedPID(for: appID) {
                identifiers[appID] = pid
            }
        }
        return identifiers
    }

    func isRunning(_ appID: String) -> Bool {
        processes[appID]?.isRunning == true || Self.recordedPID(for: appID) != nil
    }

    /// Starts the engine for `app`.
    ///
    /// `PEAR_LEGACY_SANDBOX_ROOT` gives every app its own emulated device tree,
    /// so saves stay per-app and next to the other library data.
    func launch(
        _ app: InstalledApp,
        keymapURL: URL?,
        metalHUDEnabled: Bool
    ) throws -> pid_t {
        guard let runtime = LegacyRuntime.locate() else {
            throw PearError.missingRuntimeComponent(
                "PearLegacyEngine (\(LegacyRuntime.environmentOverride) ile 32-bit çalışma zamanının "
                + "kurulu olduğu klasörü gösterebilirsiniz)"
            )
        }
        guard !isRunning(app.id) else {
            throw PearError.launchFailed("\(app.displayName) zaten çalışıyor")
        }
        guard FileManager.default.fileExists(atPath: app.executableURL.path) else {
            throw PearError.missingExecutable(app.executableName)
        }

        let sandbox = AppPaths.gamesRoot.appendingPathComponent(app.id, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = [app.bundleURL.path]
        process.currentDirectoryURL = runtime.homeURL
        process.environment = environment(
            runtime: runtime, app: app, sandbox: sandbox,
            keymapURL: keymapURL, metalHUDEnabled: metalHUDEnabled
        )
        process.standardOutput = logHandle(named: "\(app.id).legacy.log")
        process.standardError = process.standardOutput

        let appID = app.id
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                Self.clearPID(for: appID)
                if let self, self.processes[appID] === finished {
                    self.processes[appID] = nil
                }
                // The engine is a bare executable, so workspace notifications are
                // not guaranteed; tell the UI it should re-read running state.
                NotificationCenter.default.post(name: .legacyProcessExited, object: nil)
            }
        }

        try process.run()
        processes[appID] = process
        Self.writePID(process.processIdentifier, for: appID)

        // The engine opens its own SDL window asynchronously; activating the
        // process now is enough for the window server to treat it as the
        // foreground app once it appears.
        NSRunningApplication(processIdentifier: process.processIdentifier)?.activate()
        return process.processIdentifier
    }

    /// Stops the engine process for `app`, if it is one of ours.
    @discardableResult
    func terminate(_ appID: String) -> Bool {
        defer { Self.clearPID(for: appID) }
        if let process = processes[appID], process.isRunning {
            process.terminate()
            processes[appID] = nil
            return true
        }
        processes[appID] = nil
        // The process may have been started by another PearSilicon instance.
        guard let pid = Self.recordedPID(for: appID) else { return false }
        return Self.terminateProcess(pid: pid)
    }

    /// Stops an engine process this instance does not own, escalating politely.
    static func terminateProcess(pid: pid_t) -> Bool {
        guard isAlive(pid) else { return false }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(pid, SIGKILL)
        return true
    }

    private func environment(
        runtime: LegacyRuntime,
        app: InstalledApp,
        sandbox: URL,
        keymapURL: URL?,
        metalHUDEnabled: Bool
    ) -> [String: String] {
        // Inherit the user's environment (SDL needs a usable PATH/HOME/TMPDIR)
        // but drop anything dyld or a previous PearSilicon launch injected: the
        // engine is a normal host process, not a prepared app.
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("PEAR_") || key == "MTL_HUD_ENABLED" {
            env.removeValue(forKey: key)
        }

        env["PEAR_LEGACY_RESOURCES_DIR"] = runtime.homeURL.path
        env["PEAR_LEGACY_SANDBOX_ROOT"] = sandbox.path
        env["PEAR_ANGLE_LIB_DIR"] = runtime.angleLibraryURL.path
        if metalHUDEnabled {
            env["MTL_HUD_ENABLED"] = "1"
        }
        if let keymapURL {
            env["PEAR_KEYMAP"] = keymapURL.path
        }
        return env
    }

    private func logHandle(named name: String) -> FileHandle? {
        let directory = AppPaths.supportRoot.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        return handle
    }
}

extension Notification.Name {
    /// Posted when a PearLegacyEngine process exits, however it was started.
    static let legacyProcessExited = Notification.Name("com.pearsilicon.legacyProcessExited")
}
