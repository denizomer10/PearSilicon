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
/// Environment always includes the `/System/iOSSupport` dyld search paths and,
/// when available, the app's keymap (`PEAR_KEYMAP`) and keychain directory
/// (`PEAR_KEYCHAIN_DIR`). The runtime itself is loaded via an `LC_LOAD_DYLIB`
/// entry inside the bundle, not through the environment.
final class AppLauncher: @unchecked Sendable {

    /// Root of the iOS-on-Mac runtime that ships with macOS.
    private static let iOSSupportRoot = "/System/iOSSupport"

    /// iOS apps own their window layout, so macOS state restoration only ever
    /// produces a "reopen windows?" prompt after an interrupted session. Passed
    /// as arguments (not environment) because AppKit reads them from the
    /// argument domain.
    private static let noWindowRestoration = [
        "-ApplePersistenceIgnoreState", "YES",
        "-NSQuitAlwaysKeepsWindows", "NO"
    ]

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

    func launch(_ app: InstalledApp, keymapURL: URL?, extraEnvironment: [String: String] = [:], method: LaunchMethod = .launchServices, nativeContainer: Bool = false, sandboxed: Bool = false) async throws -> NSRunningApplication? {
        guard fileManager.fileExists(atPath: app.executableURL.path) else {
            throw PearError.missingExecutable(app.executableName)
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

        let env = buildEnvironment(app: app, keymapURL: keymapURL, extra: extraEnvironment,
                                   nativeContainer: nativeContainer)

        if nativeContainer {
            return try spawnSandboxed(app, env: env)
        }

        // Experimental: keep the compatibility environment but apply the
        // kernel sandbox profile as well. Note: under sandbox-exec dyld ignores
        // DYLD_INSERT_LIBRARIES for these processes, so this path only loads a
        // runtime that is referenced by an LC_LOAD_DYLIB. It exists to measure
        // the sandbox/injection trade-off, not as a default.
        if sandboxed {
            return try spawnSandboxed(app, env: env)
        }

        switch method {
        case .direct:
            try spawnDirect(app, env: env)
            return nil
        case .launchServices:
            return try await openViaLaunchServices(app, env: env)
        }
    }

    // MARK: - Environment

    private func buildEnvironment(app: InstalledApp, keymapURL: URL?, extra: [String: String], nativeContainer: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

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
            for (key, value) in extra { env[key] = value }
            return env
        }

        // Where the runtime keeps this app's keychain-backed data.
        let support = libraryURL.deletingLastPathComponent()
        env["PEAR_KEYCHAIN_DIR"] = support
            .appendingPathComponent("Keychain", isDirectory: true)
            .appendingPathComponent(app.id, isDirectory: true).path

        // A previous native-container run may have moved the app's data into
        // the macOS container. Point the path shim there when the old location
        // no longer has the data, so a compatibility launch does not start a
        // fresh download.
        let containerData = AppPaths.nativeContainerData(for: app.id)
        let oldDocuments = AppPaths.gamesRoot
            .appendingPathComponent(app.id, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
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
        }

        if let keymapURL, fileManager.fileExists(atPath: keymapURL.path) {
            env["PEAR_KEYMAP"] = keymapURL.path
        }
        for (key, value) in extra { env[key] = value }
        return env
    }

    // MARK: - Native sandbox

    /// Starts the app through `sandbox-exec`, which applies the profile in the
    /// kernel before the executable runs. No compatibility library is loaded
    /// and the game bundle is untouched apart from the platform patch.
    private func spawnSandboxed(_ app: InstalledApp, env: [String: String]) throws -> NSRunningApplication? {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Hides host-only paths and prevents writes outside the app's container.
    /// The app still reaches its own container through the normal home path.
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

    private func spawnDirect(_ app: InstalledApp, env: [String: String]) throws {
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
    private func openViaLaunchServices(_ app: InstalledApp, env: [String: String]) async throws -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
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
