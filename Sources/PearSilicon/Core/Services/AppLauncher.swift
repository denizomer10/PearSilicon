import AppKit
import Foundation

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

    // MARK: - Public API

    func launch(_ app: InstalledApp, keymapURL: URL?, extraEnvironment: [String: String] = [:], method: LaunchMethod = .launchServices, nativeContainer: Bool = false, sandboxed: Bool = false, activate: Bool = true, launchLease: AppLaunchLease? = nil) async throws -> NSRunningApplication? {
        let lease = try launchLease ?? AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
        defer { if launchLease == nil { lease.release() } }
        try lease.validate(appID: app.id, libraryURL: libraryURL)
        guard fileManager.fileExists(atPath: app.executableURL.path) else {
            throw PearError.missingExecutable(app.executableName)
        }

        try await Self.requireStopped(app)
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
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
            .contains(where: { !$0.isTerminated }) else {
            throw PearError.launchFailed("This app is already running; close it before launching again or changing preparation mode")
        }
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

        // A previous native-container run may have moved the app's data into
        // the macOS container. Point the path shim there when the old location
        // no longer has the data, so a compatibility launch does not start a
        // fresh download.
        let containerData = AppPaths.nativeContainerData(for: app.id)
        let compatibilityData = support.appendingPathComponent("Games", isDirectory: true)
            .appendingPathComponent(app.id, isDirectory: true)
        env["PEAR_HOME_DIR"] = compatibilityData.path
        let oldDocuments = compatibilityData.appendingPathComponent("Documents", isDirectory: true)
        let containerDocuments = containerData.appendingPathComponent("Documents", isDirectory: true)
        if fileManager.fileExists(atPath: containerDocuments.path),
           !fileManager.fileExists(atPath: oldDocuments.path) {
            env["PEAR_HOME_DIR"] = containerData.path
        }

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

        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("\(app.id).native.log")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
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
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("\(app.id).log")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
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
}
