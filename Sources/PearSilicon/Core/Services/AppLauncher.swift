import AppKit
import Darwin
import Foundation
import PearDebugKit

/// How an app is started.
enum LaunchMethod: Sendable {
    /// `posix_spawn` the executable directly.
    ///
    /// The process inherits a good environment, but macOS never *activates* it:
    /// it gets a window and renders, yet the window server does not treat it as
    /// the foreground app, so UIKit input (mouse/touch) is never delivered.
    /// Hardware controllers still work, which is a confusing symptom.
    case direct
    /// Hand off to LaunchServices, giving a proper, activated GUI session.
    ///
    /// The modern `NSWorkspace.openApplication(at:configuration:)` API both
    /// activates the app and forwards `configuration.environment`; the legacy
    /// `open --env` CLI does neither reliably. This is the default.
    case launchServices
}

/// Launches an app from the library.
///
/// Supplies the iOSSupport search paths and per-app state. Legacy installs use
/// an `LC_LOAD_DYLIB`; environment-mode installs load the same runtime through
/// the launcher and delegate persistent KV state to a separate host process.
final class AppLauncher: @unchecked Sendable {

    /// Root of the iOS-on-Mac runtime that ships with macOS.
    private static let iOSSupportRoot = "/System/iOSSupport"

    /// iOS apps own their window layout. AppKit's `-ApplePersistenceIgnoreState`
    /// and `-NSQuitAlwaysKeepsWindows` arguments are deliberately NOT passed:
    /// each one makes several iOS apps (e.g. Candy Crush Soda) quit during
    /// startup. The rare "reopen windows?" prompt after an interrupted session
    /// is the far better trade-off.
    private static let noWindowRestoration: [String] = []

    private let libraryURL: URL
    private let logDirectory: URL
    private let fileManager = FileManager.default

    init(libraryURL: URL) {
        self.libraryURL = libraryURL
        self.logDirectory = libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent("Logs", isDirectory: true)
    }

    /// One PearDebug log session per launch. The previous run is rotated to
    /// `<id>…1.log` instead of being truncated, so a crash log survives the
    /// relaunch that usually follows it. PearDebug reads the same files.
    private func openLogSession(for app: InstalledApp, source: LogSource) -> FileHandle? {
        try? LogStore(directory: logDirectory).beginSessionHandle(appID: app.id, source: source).1
    }

    // MARK: - Public API

    func launch(_ app: InstalledApp, keymapURL: URL?, extraEnvironment: [String: String] = [:], method: LaunchMethod = .launchServices, nativeContainer: Bool = false, sandboxed: Bool = false, activate: Bool = true, launchLease: AppLaunchLease? = nil) async throws -> NSRunningApplication? {
        let lease = try launchLease ?? AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
        defer { if launchLease == nil { lease.release() } }
        try lease.validate(appID: app.id, libraryURL: libraryURL)
        guard fileManager.fileExists(atPath: app.executableURL.path) else {
            throw PearError.missingExecutable(app.executableName)
        }

        try await Self.requireStopped(app)
        if Self.isLegacy32BitApp(app) {
            return try await launchLegacy32Bit(
                app,
                keymapURL: keymapURL,
                extraEnvironment: extraEnvironment,
                activate: activate
            )
        }
        let environmentMode = fileManager.fileExists(
            atPath: PackageInstaller.injectionMarkerURL(in: app.bundleURL).path
        )
        if environmentMode {
            guard !nativeContainer && !sandboxed else {
                throw PearError.launchFailed(
                    "Launcher injection is not supported by this sandbox-exec launch path. Select --load-command explicitly instead."
                )
            }
            guard fileManager.fileExists(atPath: app.bundleURL
                .appendingPathComponent("Frameworks/libPearRuntime.dylib").path),
                  !BinaryPatcher.hasLoadDylib(at: app.executableURL, containing: "libPearRuntime") else {
                throw PearError.launchFailed("Inconsistent launcher-injection preparation; prepare the app again before launching")
            }

        }

        // Some games need a one-line options change to be usable at all (the
        // value is read at boot, before the runtime could influence it).
        GameTweaks.applyBeforeLaunch(
            bundleID: app.id,
            supportRoot: libraryURL.deletingLastPathComponent()
        )

        if nativeContainer {
            AppPaths.migrateToNativeContainerIfNeeded(for: app.id)
        } else {
            try AppDataLifecycle(root: libraryURL.deletingLastPathComponent()).importNativeData(
                id: app.id, source: AppPaths.nativeContainerData(for: app.id))
        }

        var env = buildEnvironment(app: app, keymapURL: keymapURL, extra: extraEnvironment,
                                   nativeContainer: nativeContainer)
        let host: RuntimeHostSession?
        if environmentMode {
            guard let executable = Bundle.main.executableURL,
                  let home = env["PEAR_HOME_DIR"] else {
                throw PearError.launchFailed("Host service launch configuration is incomplete")
            }
            // Fail before starting the game if an authenticated host is not
            // ready. Never silently switch the bundle back to load-command mode.
            host = try await RuntimeHostSession.start(
                executableURL: executable, bundleID: app.id,
                dataDirectory: URL(fileURLWithPath: home, isDirectory: true),
                logURL: logDirectory.appendingPathComponent("\(app.id).host.log"),
                deviceEnvironment: env
            )
            if let host {
                env["PEAR_HOST_SOCKET"] = host.socketPath
                env["PEAR_HOST_TOKEN"] = host.token
                // Resolved and authenticated before dyld can run early device
                // hooks. They read this immutable startup snapshot, never IPC.
                env.merge(host.deviceProfile.runtimeEnvironment) { _, canonical in canonical }
            }
        } else {
            host = nil
        }

        var running: NSRunningApplication?
        var spawnedProcess: Process?
        do {
            try Task.checkCancellation()
            let pid: pid_t
            if nativeContainer || sandboxed {
                let process = try spawnSandboxed(app, env: env, activate: activate)
                spawnedProcess = process
                pid = process.processIdentifier
                running = NSRunningApplication(processIdentifier: pid)
            } else {
                switch method {
                case .direct:
                    let process = try spawnDirect(app, env: env)
                    spawnedProcess = process
                    pid = process.processIdentifier
                    running = NSRunningApplication(processIdentifier: pid)
                case .launchServices:
                    // LaunchServices owns stdout here; the runtime writes its
                    // own log at <id>.log. Start a PearDebug session so each
                    // launch gets a fresh log and the previous run is kept as
                    // <id>.1.log instead of everything being appended.
                    if env["PEAR_LOG_FILE"] == nil {
                        try? openLogSession(for: app, source: .runtime)?.close()
                    }
                    running = try await openViaLaunchServices(app, env: env, activate: activate)
                    pid = running?.processIdentifier ?? 0
                }
            }
            if let host {
                guard pid > 0 else {
                    throw PearError.launchFailed("Could not determine the process for the host-backed session")
                }
                try await host.attach(to: pid)
            }
            return running
        } catch {
            if let host {
                // Only roll back the result of this launch attempt. The
                // preflight rejects existing instances before preparation.
                if let spawnedProcess {
                    await Task.detached(priority: .utility) {
                        RuntimeHostSession.terminateProcess(spawnedProcess)
                    }.value
                } else if let running {
                    await Self.rollBackApplication(running)
                }
                await host.stop()
            }
            throw error
        }
    }

    @MainActor
    static func requireStopped(_ app: InstalledApp) throws {
        guard !isRunning(appID: app.id) else {
            throw PearError.launchFailed("This app is already running; close it before launching again or changing preparation mode")
        }
    }

    static func isLegacy32BitApp(_ app: InstalledApp) -> Bool {
        BinaryPatcher.fileIsLegacy32BitARM(app.executableURL)
    }

    private static let legacyPIDLock = NSLock()
    nonisolated(unsafe) private static var legacyRunningPIDs: [String: pid_t] = [:]

    private static var logsDirectoryURL: URL {
        AppPaths.supportRoot.appendingPathComponent("Logs", isDirectory: true)
    }

    private static func pidFileURL(for appID: String) -> URL {
        logsDirectoryURL.appendingPathComponent("\(appID).legacy.pid")
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 || errno == EPERM {
            if let running = NSRunningApplication(processIdentifier: pid) {
                return !running.isTerminated
            }
            return true
        }
        return false
    }

    static func recordLegacyRunning(appID: String, pid: pid_t) {
        legacyPIDLock.lock()
        legacyRunningPIDs[appID] = pid
        legacyPIDLock.unlock()
        try? FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: pidFileURL(for: appID), options: .atomic)
    }

    static func clearLegacyRunning(appID: String, matchingPID: pid_t? = nil) {
        legacyPIDLock.lock()
        if let matchingPID {
            if legacyRunningPIDs[appID] == matchingPID {
                legacyRunningPIDs.removeValue(forKey: appID)
            }
        } else {
            legacyRunningPIDs.removeValue(forKey: appID)
        }
        legacyPIDLock.unlock()
        let url = pidFileURL(for: appID)
        if let matchingPID,
           let content = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let recorded = pid_t(content),
           recorded != matchingPID {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    static func legacyRunningPID(for appID: String) -> pid_t? {
        legacyPIDLock.lock()
        let inMemory = legacyRunningPIDs[appID]
        legacyPIDLock.unlock()
        if let pid = inMemory {
            if isProcessAlive(pid) { return pid }
            clearLegacyRunning(appID: appID, matchingPID: pid)
        }
        let url = pidFileURL(for: appID)
        if let content = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = pid_t(content) {
            if isProcessAlive(pid) {
                legacyPIDLock.lock()
                legacyRunningPIDs[appID] = pid
                legacyPIDLock.unlock()
                return pid
            }
            try? FileManager.default.removeItem(at: url)
        }
        return nil
    }

    @MainActor
    static func runningApplication(for appID: String) -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: appID)
            .first(where: { !$0.isTerminated }) {
            return running
        }
        if let pid = legacyRunningPID(for: appID),
           let running = NSRunningApplication(processIdentifier: pid),
           !running.isTerminated {
            return running
        }
        return nil
    }

    @MainActor
    static func isRunning(appID: String) -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: appID)
            .contains(where: { !$0.isTerminated }) {
            return true
        }
        return legacyRunningPID(for: appID) != nil
    }

    @MainActor
    private static func rollBackApplication(_ running: NSRunningApplication) async {
        guard !running.isTerminated else { return }
        running.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !running.isTerminated, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !running.isTerminated { running.forceTerminate() }
    }

    // MARK: - Environment

    func buildEnvironment(app: InstalledApp, keymapURL: URL?, extra: [String: String], nativeContainer: Bool, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = baseEnvironment
        // Per-app input settings must not leak from a parent game or shell.
        env.removeValue(forKey: "PEAR_ALLOW_POINTER_LOCK")
        env.removeValue(forKey: "PEAR_MOUSE_TOUCH")
        env.removeValue(forKey: "PEAR_GRAPHICS_BACKEND")
        env.removeValue(forKey: "PEAR_ANGLE_LIB_DIR")
        env.removeValue(forKey: "PEAR_VIRTUAL_GAMEPAD")
        env.removeValue(forKey: "PEAR_VIRTUAL_GAMEPAD_MAP")
        env.removeValue(forKey: "PEAR_FPS_HUD")
        for key in ["PEAR_LEGACY_ATTACH_LAYER", "PEAR_LEGACY_WINDOW_LAYER_ONLY", "PEAR_LEGACY_LOGICAL_SIZE", "PEAR_DIRECT_LEGACY_TOUCH"] {
            env.removeValue(forKey: key)
        }
        let managedProfileKeys = ["PEAR_DEVICE_PROFILE_SOURCE", "PEAR_DEVICE_PROFILE_BUNDLE", "PEAR_DEVICE_VENDOR_UUID"]
        // A launcher may itself have been started from a compatibility session.
        // Never forward another game's capability, insertion, or profile metadata.
        for key in ["PEAR_HOST_SOCKET", "PEAR_HOST_TOKEN", "PEAR_LAUNCHER_INJECTION", "DYLD_INSERT_LIBRARIES"] + managedProfileKeys {
            env.removeValue(forKey: key)
        }

        // Route iOS framework lookups to the system iOS-on-Mac runtime.
        let frameworks = "\(Self.iOSSupportRoot)/System/Library/Frameworks"
        let libraries = "\(Self.iOSSupportRoot)/usr/lib"
        env["DYLD_FRAMEWORK_PATH"] = frameworks
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = frameworks
        env["DYLD_LIBRARY_PATH"] = libraries
        env["DYLD_FALLBACK_LIBRARY_PATH"] = libraries

        if nativeContainer {
            // The App Sandbox already makes the container the app's home. These
            // values also cover Foundation paths that consult the environment
            // directly, and keep temporary files inside the same view.
            let data = AppPaths.nativeContainerData(for: app.id)
            try? fileManager.createDirectory(at: data, withIntermediateDirectories: true)
            let temporary = data.appendingPathComponent("tmp", isDirectory: true)
            try? fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
            env["CFFIXED_USER_HOME"] = data.path
            env["HOME"] = data.path
            env["TMPDIR"] = temporary.path
            for (key, value) in extra where !managedProfileKeys.contains(key) { env[key] = value }
            return env
        }

        // Where the runtime keeps this app's keychain-backed data.
        let support = libraryURL.deletingLastPathComponent()
        // The whole support root travels together (apps, data, keymaps, ODR,
        // keychain, logs); tell the runtime which root this launch uses so its
        // fallback paths never scatter data back to the internal disk.
        env["PEAR_SUPPORT_ROOT"] = support.path
        env["PEAR_KEYCHAIN_DIR"] = support
            .appendingPathComponent("Keychain", isDirectory: true)
            .appendingPathComponent(app.id, isDirectory: true).path
        env["PEAR_ODR_PATH"] = support
            .appendingPathComponent("ODR", isDirectory: true)
            .appendingPathComponent(app.id, isDirectory: true).path

        let compatibilityData = support.appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(app.id, isDirectory: true)
        env["PEAR_HOME_DIR"] = compatibilityData.path
        env["HOME"] = compatibilityData.path
        env["CFFIXED_USER_HOME"] = compatibilityData.path
        env["TMPDIR"] = compatibilityData.appendingPathComponent("tmp").path + "/"

        // The runtime is normally loaded via an `LC_LOAD_DYLIB` entry. The
        // experimental environment mode keeps that command out of the app
        // binary and asks the launcher to insert the same library instead.
        // The app carries a marker written by the installer.
        let injectionMarker = app.bundleURL
            .appendingPathComponent("Frameworks/.pear-injection")
        let injectedRuntime = app.bundleURL
            .appendingPathComponent("Frameworks/libPearRuntime.dylib")
        if fileManager.fileExists(atPath: injectionMarker.path),
           fileManager.fileExists(atPath: injectedRuntime.path) {
            env["DYLD_INSERT_LIBRARIES"] = injectedRuntime.path
            env["PEAR_LAUNCHER_INJECTION"] = "1"
        }

        if let keymapURL, fileManager.fileExists(atPath: keymapURL.path) {
            env["PEAR_KEYMAP"] = keymapURL.path
        }
        // Controller compatibility defaults: many iOS games whitelist only the
        // controller families the vendor documents and miss a connection that
        // happens before their observer is installed. The runtime normalizes
        // other controllers and replays the connection; PEAR_CONTROLLER_NATIVE=1
        // opts out (extra environment is applied below and wins).
        if env["PEAR_CONTROLLER_NATIVE"] != "1" {
            env["PEAR_CONTROLLER_COMPAT"] = env["PEAR_CONTROLLER_COMPAT"] ?? "1"
            env["PEAR_CONTROLLER_REPLAY"] = env["PEAR_CONTROLLER_REPLAY"] ?? "1"
        }
        // Only the verified host handoff may add managed profile metadata.
        for (key, value) in extra where !managedProfileKeys.contains(key) { env[key] = value }
        return env
    }

    // MARK: - Native sandbox

    /// The experimental sandbox-exec route. A legacy load-command runtime may
    /// still be present; this permissive profile is not an iOS device emulator
    /// or a strong per-app isolation boundary.
    private func spawnSandboxed(_ app: InstalledApp, env: [String: String], activate: Bool) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.nativeIsolationProfile(), app.executableURL.path]
            + Self.noWindowRestoration
        process.currentDirectoryURL = app.bundleURL
        process.environment = env

        if let handle = openLogSession(for: app, source: .macApp) {
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        let pid = process.processIdentifier
        // A directly spawned process is not made frontmost by LaunchServices.
        // Activate it once it has a connection to the window server.
        if activate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            }
        }
        return process
    }

    /// Denies selected host paths. `(allow default)` means this does not confine
    /// all writes to the app's container.
    private static func nativeIsolationProfile() -> String {
        let readDenied = [
            "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/libexec",
            "/Applications", "/Library/MobileSubstrate", "/var/jb",
            "/private/var/jb", "/private/var/lib/apt", "/private/var/lib/cydia",
            "/private/var/stash", "/private/var/tmp/cydia.log",
            "/private/var/mobile/Library/SBSettings",
        ]
        let writeDenied = [
            "/Applications", "/Library", "/System", "/usr", "/bin", "/sbin",
            "/private/etc", "/private/var/jb",
        ]
        var rules = "(version 1)(allow default)"
        for path in readDenied {
            rules += "(deny file-read* (subpath \"\(path)\"))"
        }
        for path in writeDenied {
            rules += "(deny file-write* (subpath \"\(path)\"))"
        }
        return rules
    }

    // MARK: - Direct spawn

    private func spawnDirect(_ app: InstalledApp, env: [String: String]) throws -> Process {
        let process = Process()
        process.executableURL = app.executableURL
        process.arguments = Self.noWindowRestoration
        process.currentDirectoryURL = app.bundleURL
        process.environment = env

        // Redirect output to a log file. Never leave it on an undrained pipe:
        // once the pipe buffer fills the child blocks on write and the app
        // appears to hang (a white screen).
        if let handle = openLogSession(for: app, source: .runtime) {
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        return process
    }

    // MARK: - LaunchServices

    /// Launches through LaunchServices. This is what makes the app behave like a
    /// real foreground app: the window server delivers UIKit input to it and
    /// system UI (sign-in sheets, game overlays) can be
    /// presented. A plain `posix_spawn` produces a window that renders but never
    /// receives mouse/touch events.
    ///
    /// `openApplication` calls its completion handler on the main queue, so this
    /// must not block the main thread while waiting for it.
    @MainActor
    private func openViaLaunchServices(_ app: InstalledApp, env: [String: String], activate: Bool) async throws -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = activate
        configuration.environment = env
        configuration.arguments = Self.noWindowRestoration

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication?, Error>) in
            NSWorkspace.shared.openApplication(at: app.bundleURL, configuration: configuration) { running, error in
                if let error {
                    continuation.resume(throwing: PearError.launchFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: running)
                }
            }
        }
    }

    // MARK: - Runtime lookup

    /// Locates the runtime dylib. Looked up in order:
    ///   1. `PEARSILICON_RUNTIME` (explicit override)
    ///   2. the PearSilicon app bundle's Resources
    ///   3. next to the running executable
    ///   4. a repo checkout next to a SwiftPM build product
    ///   5. an installed PearSilicon.app
    ///   6. the shared Application Support directory
    static func runtimeLibraryURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["PEARSILICON_RUNTIME"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("libPearRuntime.dylib"))
        }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exeDir {
            candidates.append(exeDir.appendingPathComponent("libPearRuntime.dylib"))
        }

        let home = fileManager.homeDirectoryForCurrentUser

        // `.build/<config>/PearSilicon` → repo root → build/libPearRuntime.dylib.
        // Preferred over an installed app so a development build uses its own
        // freshly built runtime.
        if let exeDir {
            candidates.append(exeDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("build/libPearRuntime.dylib"))
        }

        for app in ["/Applications/PearSilicon.app", "\(home.path)/Applications/PearSilicon.app"] {
            candidates.append(URL(fileURLWithPath: app)
                .appendingPathComponent("Contents/Resources/libPearRuntime.dylib"))
        }

        candidates.append(AppPaths.supportRoot.appendingPathComponent("libPearRuntime.dylib"))

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Locates the MarketplaceKit compatibility stub shipped next to the
    /// runtime. Store builds link the framework, but the host provides it as
    /// resources only, so the installer needs this binary to satisfy the
    /// weak references at launch.
    static func marketplaceKitStubURL() -> URL? {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["PEARSILICON_MARKETPLACEKIT"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fileManager.fileExists(atPath: url.path) { return url }
        }

        guard let runtime = runtimeLibraryURL() else { return nil }
        let stub = runtime.deletingLastPathComponent()
            .appendingPathComponent("MarketplaceKit.framework", isDirectory: true)
        return fileManager.fileExists(atPath: stub.path) ? stub : nil
    }

    // MARK: - PearLegacyEngine (32-bit iOS compatibility layer)

    private func launchLegacy32Bit(
        _ app: InstalledApp,
        keymapURL: URL?,
        extraEnvironment: [String: String],
        activate: Bool
    ) async throws -> NSRunningApplication? {
        guard let engineURL = Self.legacyEngineExecutableURL() else {
            throw PearError.missingRuntimeComponent("PearLegacyEngine")
        }
        guard let resourceDir = Self.legacyEngineResourceDirectory(for: engineURL) else {
            throw PearError.missingRuntimeComponent("PearLegacyEngine runtime resources")
        }

        let sandboxRoot = AppPaths.legacyRoot
        try? fileManager.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        for key in ["PEAR_HOST_SOCKET", "PEAR_HOST_TOKEN", "PEAR_LAUNCHER_INJECTION", "DYLD_INSERT_LIBRARIES",
                    "DYLD_FRAMEWORK_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"] {
            env.removeValue(forKey: key)
        }
        for (key, value) in extraEnvironment {
            env[key] = value
        }
        // The engine replays these bindings as synthetic touches, since an
        // arm64 runtime dylib cannot be injected into an emulated 32-bit app.
        if let keymapURL, fileManager.fileExists(atPath: keymapURL.path) {
            env["PEAR_KEYMAP"] = keymapURL.path
        }
        env["PEAR_LEGACY_SANDBOX_ROOT"] = sandboxRoot.path
        env["PEAR_LEGACY_RESOURCES_DIR"] = resourceDir.path
        env["SDL_APP_NAME"] = app.displayName

        let hostExecutableURL = try Self.prepareLegacyHostExecutable(
            for: app,
            engineURL: engineURL,
            resourceDir: resourceDir
        )

        var args = [app.bundleURL.path]
        if AppSettings.legacyLargeWindow(for: app.id) {
            args.append("--large-window")
        }
        if AppSettings.legacyFullscreen(for: app.id) {
            args.append("--fullscreen")
        }
        // The engine renders through ANGLE on Metal, so Apple's Metal HUD works
        // for 32-bit games and shows more (FPS, GPU time, frame intervals).
        // The engine's own segment overlay is never enabled as well, so only
        // one FPS meter appears; --print-fps keeps FPS in the log for PearDebug.
        env.removeValue(forKey: "PEAR_FPS_HUD")
        if AppSettings.defaults.bool(forKey: "metalHUD.enabled." + app.id)
            || extraEnvironment["MTL_HUD_ENABLED"] == "1" {
            env["MTL_HUD_ENABLED"] = "1"
            args.append("--print-fps")
        } else {
            env.removeValue(forKey: "MTL_HUD_ENABLED")
        }

        let angle = resourceDir.appendingPathComponent("touchHLE_dylibs/angle", isDirectory: true)
        if fileManager.fileExists(atPath: angle.appendingPathComponent("libEGL.dylib").path) {
            env["PEAR_ANGLE_LIB_DIR"] = angle.path
        }
        // LaunchServices gives the child no pipe; the engine appends its own
        // output to this PearDebug session file.
        if let (logURL, handle) = try? LogStore(directory: logDirectory)
            .beginSessionHandle(appID: app.id, source: .legacyEngine) {
            try? handle.close()
            env["PEAR_LEGACY_LOG_FILE"] = logURL.path
        }

        // Launched through LaunchServices rather than as a child process: a
        // spawned binary is an anonymous process to RunningBoard even inside an
        // app bundle, and macOS Game Mode only engages for a real app that it
        // can identify as a game.
        let hostBundleURL = hostExecutableURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let running = try await Self.openLegacyHost(
            at: hostBundleURL, arguments: args, environment: env, activate: activate
        )
        let pid = running.processIdentifier
        Self.recordLegacyRunning(appID: app.id, pid: pid)
        return running
    }

    @MainActor
    private static func openLegacyHost(
        at bundleURL: URL, arguments: [String], environment: [String: String], activate: Bool
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = activate
        configuration.environment = environment
        configuration.arguments = arguments
        configuration.addsToRecentItems = false
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { running, error in
                if let running {
                    continuation.resume(returning: running)
                } else {
                    continuation.resume(throwing: PearError.launchFailed(
                        error?.localizedDescription ?? "PearLegacyEngine did not start"))
                }
            }
        }
    }

    /// Creates a lightweight macOS `.app` host bundle for a 32-bit iOS game so
    /// macOS WindowServer, menu bar, and Activity Monitor display only the
    /// game's own name and icon with no engine branding.
    private static func prepareLegacyHostExecutable(
        for app: InstalledApp,
        engineURL: URL,
        resourceDir: URL
    ) throws -> URL {
        let fm = FileManager.default
        let safeName = app.displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executableName = safeName.isEmpty ? app.executableName : safeName

        let hostBundleURL = AppPaths.legacyHostBundle(for: app.id)
        // Earlier builds kept the host under Application Support, where macOS
        // never enables Game Mode for it. Remove that copy.
        let oldHost = AppPaths.legacyRoot
            .appendingPathComponent("Hosts", isDirectory: true)
            .appendingPathComponent("\(app.id).app", isDirectory: true)
        if fm.fileExists(atPath: oldHost.path) {
            _ = try? Shell.run(Self.lsregisterPath, ["-u", oldHost.path])
            try? fm.removeItem(at: oldHost)
        }
        let contentsURL = hostBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // The engine finds its resources through PEAR_LEGACY_RESOURCES_DIR and
        // PEAR_ANGLE_LIB_DIR. Links to them inside the bundle (older builds)
        // point outside it and invalidate the bundle signature, and macOS does
        // not treat an app with a broken signature as a game.
        var removedLinks = false
        for resName in ["touchHLE_default_options.txt", "touchHLE_dylibs", "touchHLE_fonts"] {
            let dst = resourcesURL.appendingPathComponent(resName)
            if (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil {
                try? fm.removeItem(at: dst)
                removedLinks = true
            }
        }

        var iconFileName: String?
        if let iconURL = app.iconURL, fm.fileExists(atPath: iconURL.path) {
            let ext = iconURL.pathExtension.isEmpty ? "png" : iconURL.pathExtension
            let destName = "AppIcon.\(ext)"
            let destIcon = resourcesURL.appendingPathComponent(destName)
            try? fm.removeItem(at: destIcon)
            if (try? fm.copyItem(at: iconURL, to: destIcon)) != nil {
                iconFileName = destName
            }
        }

        let hostExeURL = macOSURL.appendingPathComponent(executableName)
        let copyNeedsUpdate: Bool = {
            guard fm.isExecutableFile(atPath: hostExeURL.path),
                  let srcAttr = try? fm.attributesOfItem(atPath: engineURL.path),
                  let dstAttr = try? fm.attributesOfItem(atPath: hostExeURL.path),
                  let srcSize = srcAttr[.size] as? NSNumber,
                  let dstSize = dstAttr[.size] as? NSNumber,
                  let srcDate = srcAttr[.modificationDate] as? Date,
                  let dstDate = dstAttr[.modificationDate] as? Date
            else { return true }
            return srcSize != dstSize || srcDate > dstDate
        }()

        if copyNeedsUpdate {
            try? fm.removeItem(at: hostExeURL)
            try fm.copyItem(at: engineURL, to: hostExeURL)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostExeURL.path)
        }

        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": executableName,
            // Not the game's own ID: the iOS bundle in the library is
            // registered with LaunchServices under that ID (platform iOS, no
            // category), and macOS resolved the host to it, so Game Mode and
            // the games category never applied to the running host.
            "CFBundleIdentifier": legacyHostBundleIdentifier(for: app.id),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": app.displayName,
            "CFBundleDisplayName": app.displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": app.shortVersion,
            "CFBundleVersion": app.bundleVersion,
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true
        ]
        GameModeInfo.apply(to: &plist)
        if let iconFileName {
            plist["CFBundleIconFile"] = iconFileName
        }

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        var plistChanged = false
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
           (try? Data(contentsOf: infoPlistURL)) != data {
            try? data.write(to: infoPlistURL, options: .atomic)
            plistChanged = true
        }

        // Sign the whole bundle so the Info.plist (games category, Game Mode
        // keys) is sealed into the signature, then tell LaunchServices about
        // it. An unsealed host was never evaluated as a game by macOS.
        if copyNeedsUpdate || plistChanged || removedLinks {
            _ = try? Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", hostBundleURL.path])
            _ = try? Shell.run(Self.lsregisterPath, ["-f", hostBundleURL.path])
        }

        return hostExeURL
    }

    /// Bundle identifier of the macOS host bundle that runs a 32-bit game.
    static func legacyHostBundleIdentifier(for appID: String) -> String {
        "com.pearsilicon.legacy." + appID
    }

    static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Locates the PearLegacyEngine (`touchHLE`) 32-bit iOS compatibility binary.
    static func legacyEngineExecutableURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["PEARSILICON_LEGACY_ENGINE"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    candidates.append(url.appendingPathComponent("touchHLE"))
                    candidates.append(url.appendingPathComponent("target/release/touchHLE"))
                    candidates.append(url.appendingPathComponent("target/debug/touchHLE"))
                } else {
                    candidates.append(url)
                }
            }
        }

        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("PearLegacyEngine/touchHLE"))
            candidates.append(resources.appendingPathComponent("touchHLE"))
        }

        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("PearLegacyEngine/touchHLE"))
            candidates.append(exeDir.appendingPathComponent("touchHLE"))
            let repoRoot = exeDir.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(repoRoot.appendingPathComponent("build/PearLegacyEngine/touchHLE"))
            candidates.append(repoRoot.deletingLastPathComponent().appendingPathComponent("PearLegacyEngine/target/release/touchHLE"))
            candidates.append(repoRoot.deletingLastPathComponent().appendingPathComponent("PearLegacyEngine/target/debug/touchHLE"))
        }

        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("PearLegacyEngine/target/release/touchHLE"))
        candidates.append(home.appendingPathComponent("PearLegacyEngine/target/debug/touchHLE"))

        for app in ["/Applications/PearSilicon.app", "\(home.path)/Applications/PearSilicon.app"] {
            candidates.append(URL(fileURLWithPath: app)
                .appendingPathComponent("Contents/Resources/PearLegacyEngine/touchHLE"))
        }

        candidates.append(AppPaths.supportRoot.appendingPathComponent("PearLegacyEngine/touchHLE"))

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Locates the directory containing `touchHLE_default_options.txt`,
    /// `touchHLE_dylibs`, and `touchHLE_fonts` for a resolved engine executable.
    static func legacyEngineResourceDirectory(for engineURL: URL) -> URL? {
        let fileManager = FileManager.default
        let exeDir = engineURL.deletingLastPathComponent()
        let candidates = [
            exeDir,
            exeDir.deletingLastPathComponent(),
            exeDir.deletingLastPathComponent().deletingLastPathComponent(),
            Bundle.main.resourceURL?.appendingPathComponent("PearLegacyEngine", isDirectory: true),
            Bundle.main.resourceURL,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("PearLegacyEngine", isDirectory: true),
            AppPaths.supportRoot.appendingPathComponent("PearLegacyEngine", isDirectory: true)
        ].compactMap { $0 }

        return candidates.first { dir in
            fileManager.fileExists(atPath: dir.appendingPathComponent("touchHLE_default_options.txt").path)
                && fileManager.fileExists(atPath: dir.appendingPathComponent("touchHLE_dylibs").path)
                && fileManager.fileExists(atPath: dir.appendingPathComponent("touchHLE_fonts").path)
        }
    }
}
