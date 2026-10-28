// CLI.swift
//
// The `pearsilicon` command line tool. The code lives in the app target so it
// shares the installer, patcher, launcher and keymap code with the GUI; the app
// binary switches into this mode when the first argument is a known command
// (see PearSiliconMain). A tiny `pearsilicon` wrapper target execs this binary.
//
// Commands are intentionally thin: all real work is in the shared services.
import AppKit
import Darwin
import Foundation

// MARK: - Errors

enum CLIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

// MARK: - Paths

/// The same layout the GUI uses. Everything lives under Application Support.
struct CLIPaths: Sendable {
    static let shared = CLIPaths()

    let support: URL
    let library: URL
    let keymaps: URL
    let logs: URL
    let work: URL

    init() {
        AppPaths.migrateLegacySupportDirectoryIfNeeded()
        let base = AppPaths.supportRoot
        support = base
        library = base.appendingPathComponent("Applications", isDirectory: true)
        keymaps = base.appendingPathComponent("Keymaps", isDirectory: true)
        logs = base.appendingPathComponent("Logs", isDirectory: true)
        work = base.appendingPathComponent("Work", isDirectory: true)
    }
}

// MARK: - Argument parsing

struct CLIArguments {
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]
    var environment: [String: String] = [:]
}


private let booleanFlags: Set<String> = [
    "launch", "no-launch", "keys", "no-keys", "log", "wait", "follow", "system",
    "lldb", "yes", "print", "path", "generate", "json", "no-keymap", "trace", "help",
    "metal-hud", "no-metal-hud", "pointer-lock", "no-pointer-lock",
]

/// Result box for the async → sync bridge. `@unchecked Sendable` because the
/// semaphore provides the happens-before edge.
private final class AsyncBox<T: Sendable>: @unchecked Sendable {
    var value: T?
    var errorMessage: String?
}

// MARK: - CLI

@MainActor
enum CLI {

    nonisolated static func shouldHandle(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        if first.hasPrefix("-") {
            // Ignore launch-system parameters such as -psn_…, but accept the
            // standard informational flags.
            return ["--help", "-h", "--version", "-v"].contains(first)
        }
        // Any bare argument means someone invoked the binary directly. Taking the
        // CLI path for unknown commands is better than silently opening the GUI
        // because of a typo.
        return true
    }

    static func main(_ arguments: [String]) -> Never {
        do {
            exit(try run(arguments))
        } catch {
            FileHandle.standardError.write(Data("pearsilicon: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: Dispatch

    private static func run(_ arguments: [String]) throws -> Int32 {
        let command = arguments.count > 1 ? arguments[1] : "help"
        let rest = Array(arguments.dropFirst(2))

        switch command {
        case "help", "--help", "-h":
            printHelp()
            return 0
        case "version", "--version", "-v":
            printVersion()
            return 0
        default:
            break
        }

        let parsed = parse(rest)
        if parsed.flags.contains("help") {
            printHelp()
            return 0
        }

        switch command {
        case "install": return try installCommand(parsed)
        case "run": return try runCommand(parsed)
        case "launch": return try launchCommand(parsed)
        case "debug": return try debugCommand(parsed)
        case "stop": return try stopCommand(parsed)
        case "list", "ls": return try listCommand(parsed)
        case "info": return try infoCommand(parsed)
        case "uninstall", "remove": return try uninstallCommand(parsed)
        case "keymap": return try keymapCommand(parsed)
        case "keys": return try keysCommand(parsed)
        case "hud": return try hudCommand(parsed)
        case "pointerlock": return try pointerLockCommand(parsed)
        case "logs": return try logsCommand(parsed)
        case "paths": return try pathsCommand()
        case "doctor": return try doctorCommand()
        case "link", "install-cli": return try linkCommand(parsed)
        case "build": return try buildProjectCommand(parsed)
        default:
            throw CLIError.message("unknown command '\(command)'. Run `pearsilicon help`.")
        }
    }

    // MARK: Install / run

    private static func installCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let path = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon install <package|App.app> [--launch] [--keys|--no-keys] [--log]")
        }
        let app = try install(path: path, arguments: arguments)
        if arguments.flags.contains("launch") {
            return try launch(app: app, arguments: arguments, debug: false)
        }
        return 0
    }

    private static func runCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let path = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon run <package|App.app> [--no-launch] [--keys|--no-keys] [--log]")
        }
        let app = try install(path: path, arguments: arguments)
        if arguments.flags.contains("no-launch") { return 0 }
        return try launch(app: app, arguments: arguments, debug: false)
    }

    private static func install(path: String, arguments: CLIArguments) throws -> InstalledApp {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError.message("not found: \(url.path)")
        }

        let installer = PackageInstaller(libraryURL: CLIPaths.shared.library)
        let extensionName = url.pathExtension.lowercased()

        let mode: PreparationMode = .compatibility
        let app: InstalledApp
        if isDirectory.boolValue && extensionName == "app" {
            app = try awaitBridge { try await installer.installBundle(at: url, mode: mode) }
        } else if !isDirectory.boolValue {
            app = try awaitBridge { try await installer.install(packageAt: url, mode: mode) }
        } else {
            throw CLIError.message("expected a package file or an .app bundle, got \(url.lastPathComponent)")
        }

        let store = KeymapStore(baseURL: CLIPaths.shared.keymaps)
        if !arguments.flags.contains("no-keymap"), (try store.load(for: app.id)) == nil {
            try store.save(KeymapGenerator.generate(for: app))
            print("keymap: generated \(store.fileURL(for: app.id).path)")
        }

        notifyLibraryChanged()
        print("installed \(app.displayName) [\(app.id)]")
        print("  bundle: \(app.bundleURL.path)")
        print("  mode: \(mode.rawValue)")
        if !installer.corruptedFiles.isEmpty {
            print("  warning: \(installer.corruptedFiles.count) file(s) failed their CRC check and may be damaged:")
            for file in installer.corruptedFiles.prefix(5) {
                print("    \(file)")
            }
            if installer.corruptedFiles.count > 5 {
                print("    … and \(installer.corruptedFiles.count - 5) more")
            }
            print("  re-download the app package if the app crashes.")
        }
        return app
    }

    // MARK: Launch / debug

    private static func launchCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon launch <bundle-id|name> [--keys|--no-keys] [--log] [--wait]")
        }
        let app = try resolveApp(query)
        return try launch(app: app, arguments: arguments, debug: false)
    }

    private static func debugCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon debug <bundle-id|name> [--keys|--no-keys] [--lldb]")
        }
        let app = try resolveApp(query)
        return try launch(app: app, arguments: arguments, debug: true)
    }

    private static func launch(app: InstalledApp, arguments: CLIArguments, debug: Bool) throws -> Int32 {
        let paths = CLIPaths.shared
        let store = KeymapStore(baseURL: paths.keymaps)
        let enabled = keymapperEnabled(for: app, arguments: arguments)
        let hasKeymap = store.exists(for: app.id)
        let keymapURL = enabled && hasKeymap ? store.fileURL(for: app.id) : nil

        let wantsLog = debug || arguments.flags.contains("log") || arguments.flags.contains("trace")
        var logPath: String?
        if wantsLog {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let url = paths.logs.appendingPathComponent("\(app.id).log")
            try Data().write(to: url) // truncate so `tail` starts at the new run
            logPath = url.path
        }

        var environment = arguments.environment
        if debug || arguments.flags.contains("trace") {
            environment["PEAR_DEBUG_TOUCH"] = "1"
        }
        if let logPath {
            environment["PEAR_LOG_FILE"] = logPath
        }

        let hudEnabled: Bool
        if arguments.flags.contains("metal-hud") {
            hudEnabled = true
        } else if arguments.flags.contains("no-metal-hud") {
            hudEnabled = false
        } else {
            hudEnabled = (AppSettings.defaults.object(forKey: "metalHUD.enabled." + app.id) as? Bool) ?? false
        }
        if hudEnabled {
            environment["MTL_HUD_ENABLED"] = "1"
        }

        let pointerLock: Bool
        if arguments.flags.contains("pointer-lock") {
            pointerLock = true
        } else if arguments.flags.contains("no-pointer-lock") {
            pointerLock = false
        } else {
            pointerLock = AppSettings.pointerLockAllowed(for: app.id)
        }
        if pointerLock {
            environment["PEAR_ALLOW_POINTER_LOCK"] = "1"
        }

        let nativeContainer = false

        // The iOS-like filesystem view is always applied.
        environment["PEAR_IOS_SANDBOX"] = "1"
        let launchEnvironment = environment

        // A previously prepared native app must be switched back so the
        // runtime is present before a normal launch.
        let installer = PackageInstaller(libraryURL: paths.library)
        try? installer.setPreparationMode(.compatibility, for: app)

        let launcher = AppLauncher(libraryURL: paths.library)
        let pid: pid_t = try awaitBridge {
            let running = try await launcher.launch(
                app, keymapURL: keymapURL, extraEnvironment: launchEnvironment,
                nativeContainer: nativeContainer
            )
            return running?.processIdentifier ?? 0
        }

        if pid > 0 {
            print("launched \(app.displayName) [\(app.id)] pid \(pid)")
        } else {
            print("launched \(app.displayName) [\(app.id)]")
        }
        print("  keymap: \(keymapState(enabled: enabled, hasFile: hasKeymap, url: keymapURL))")
        print("  metal HUD: \(hudEnabled ? "on" : "off")")
        print("  pointer lock: \(pointerLock ? "allowed" : "disabled")")
        print("  mode: compatibility runtime")
        print("  container: iOS-like ")
        if let logPath { print("  log:    \(logPath)") }

        if arguments.flags.contains("lldb") {
            guard pid > 0 else { throw CLIError.message("could not determine the pid") }
            print("attaching lldb to \(pid)…")
            Thread.sleep(forTimeInterval: 1.0)
            try Shell.runStreaming("/usr/bin/lldb", ["-p", "\(pid)"])
            return 0
        }

        if let logPath {
            followLog(path: logPath, pid: pid > 0 ? pid : nil, name: app.displayName)
        } else if arguments.flags.contains("wait") {
            waitForExit(pid: pid, name: app.displayName)
        }
        return 0
    }

    // MARK: Stop / list / info

    private static func stopCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon stop <bundle-id|name>")
        }
        let app = try resolveApp(query)
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.id).first else {
            throw CLIError.message("\(app.displayName) is not running")
        }

        print("stopping \(app.displayName) [\(app.id)]…")
        running.terminate()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            guard let current = NSRunningApplication(processIdentifier: running.processIdentifier),
                  !current.isTerminated else { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let current = NSRunningApplication(processIdentifier: running.processIdentifier),
           !current.isTerminated {
            current.forceTerminate()
        }
        print("stopped")
        return 0
    }

    private static func listCommand(_ arguments: CLIArguments) throws -> Int32 {
        let apps = try PackageInstaller(libraryURL: CLIPaths.shared.library).scanLibrary()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        if arguments.flags.contains("json") {
            let rows: [[String: Any]] = apps.map { app in
                [
                    "bundleID": app.id,
                    "name": app.displayName,
                    "version": app.shortVersion,
                    "running": running.contains(app.id),
                    "path": app.bundleURL.path,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        }

        guard !apps.isEmpty else {
            print("library is empty (\(CLIPaths.shared.library.path))")
            return 0
        }

        let rows = apps.map { app in
            (app.displayName, app.id, app.shortVersion, running.contains(app.id) ? "running" : "-")
        }
        let nameWidth = max(rows.map { $0.0.count }.max() ?? 4, 4)
        let idWidth = max(rows.map { $0.1.count }.max() ?? 9, 9)
        let versionWidth = max(rows.map { $0.2.count }.max() ?? 7, 7)

        func pad(_ string: String, _ width: Int) -> String {
            string + String(repeating: " ", count: max(0, width - string.count))
        }
        print("\(pad("NAME", nameWidth))  \(pad("BUNDLE ID", idWidth))  \(pad("VERSION", versionWidth))  STATE")
        for row in rows {
            print("\(pad(row.0, nameWidth))  \(pad(row.1, idWidth))  \(pad(row.2, versionWidth))  \(row.3)")
        }
        return 0
    }

    private static func infoCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon info <bundle-id|name>")
        }
        let app = try resolveApp(query)
        let paths = CLIPaths.shared
        let store = KeymapStore(baseURL: paths.keymaps)
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
            .first?.processIdentifier

        print("name:        \(app.displayName)")
        print("bundle id:   \(app.id)")
        print("version:     \(app.shortVersion) (\(app.bundleVersion))")
        print("min iOS:     \(app.minimumOSVersion ?? "—")")
        print("bundle:      \(app.bundleURL.path)")
        print("data:        \(paths.support.appendingPathComponent("Games/\(app.id)").path)")
        print("keymap:      \(store.fileURL(for: app.id).path)\(store.exists(for: app.id) ? "" : " (missing)")")
        print("log:         \(paths.logs.appendingPathComponent("\(app.id).log").path)")
        print("running:     \(pid.map { "yes (pid \($0))" } ?? "no")")
        print("pointer lock: \(AppSettings.pointerLockAllowed(for: app.id) ? "allowed" : "disabled")")
        print("metal HUD:   \((((AppSettings.defaults.object(forKey: "metalHUD.enabled." + app.id) as? Bool) ?? false) ? "on" : "off"))")
        print("runtime:     \(AppLauncher.runtimeLibraryURL()?.path ?? "not found")")
        return 0
    }

    // MARK: Uninstall

    private static func uninstallCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon uninstall <bundle-id|name> [--yes]")
        }
        let app = try resolveApp(query)

        if !arguments.flags.contains("yes"), isatty(STDIN_FILENO) != 0 {
            print("remove \(app.displayName) [\(app.id)]? [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
                print("cancelled")
                return 1
            }
        }

        try PackageInstaller(libraryURL: CLIPaths.shared.library).uninstall(app)
        try? KeymapStore(baseURL: CLIPaths.shared.keymaps).delete(for: app.id)
        notifyLibraryChanged()
        print("removed \(app.displayName) [\(app.id)]")
        return 0
    }

    // MARK: Keymap

    private static func keymapCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon keymap <bundle-id|name> [--print|--path|--generate|--set <file>]")
        }
        let app = try resolveApp(query)
        let store = KeymapStore(baseURL: CLIPaths.shared.keymaps)

        if arguments.flags.contains("generate") {
            let keymap = KeymapGenerator.generate(for: app)
            try store.save(keymap)
            print("generated \(store.fileURL(for: app.id).path)")
            return 0
        }

        if let source = arguments.options["set"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            let keymap = try KeymapCoding.decoder.decode(Keymap.self, from: data)
            guard keymap.bundleID == app.id else {
                throw CLIError.message(
                    "keymap is for \(keymap.bundleID), not \(app.id). Edit bundleID or use --generate."
                )
            }
            try store.save(keymap)
            print("saved \(store.fileURL(for: app.id).path)")
            return 0
        }

        if arguments.flags.contains("path") {
            print(store.fileURL(for: app.id).path)
            return 0
        }

        guard let keymap = try store.load(for: app.id) else {
            throw CLIError.message("no keymap for \(app.id); run with --generate or edit it in the app")
        }
        let data = try KeymapCoding.encoder.encode(keymap)
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    /// Prints or persists the per-app keymapper toggle (the GUI's switch). Takes
    /// effect on the next launch, because input handlers are installed when the
    /// game process starts.
    private static func keysCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon keys <bundle-id|name> [on|off]")
        }
        let app = try resolveApp(query)
        let key = "keymapper.enabled." + app.id
        let defaults = AppSettings.defaults

        guard let state = arguments.positionals.dropFirst().first else {
            let enabled = (defaults.object(forKey: key) as? Bool)
                ?? defaults.bool(forKey: "keymapper.defaultEnabled")
            print("keymapper: \(enabled ? "on" : "off") for \(app.displayName) [\(app.id)]")
            return 0
        }

        switch state.lowercased() {
        case "on", "1", "true", "yes":
            defaults.set(true, forKey: key)
        case "off", "0", "false", "no":
            defaults.set(false, forKey: key)
        default:
            throw CLIError.message("expected 'on' or 'off', got '\(state)'")
        }
        notifyLibraryChanged()
        print("keymapper \(state.lowercased()) for \(app.displayName) — relaunch to apply")
        return 0
    }

    /// Prints or persists the per-app Metal HUD toggle (the GUI's switch). Takes
    /// effect on the next launch, when the environment is read.
    private static func hudCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon hud <bundle-id|name> [on|off]")
        }
        let app = try resolveApp(query)
        let key = "metalHUD.enabled." + app.id
        let defaults = AppSettings.defaults

        guard let state = arguments.positionals.dropFirst().first else {
            let enabled = defaults.bool(forKey: key)
            print("metal HUD: \(enabled ? "on" : "off") for \(app.displayName) [\(app.id)]")
            return 0
        }

        switch state.lowercased() {
        case "on", "1", "true", "yes":
            defaults.set(true, forKey: key)
        case "off", "0", "false", "no":
            defaults.set(false, forKey: key)
        default:
            throw CLIError.message("expected 'on' or 'off', got '\(state)'")
        }
        notifyLibraryChanged()
        print("metal HUD \(state.lowercased()) for \(app.displayName) — relaunch to apply")
        return 0
    }

    /// Prints or persists the per-app pointer-lock allowance. Games that rotate
    /// the camera from relative mouse motion need it; games that trap the
    /// cursor can have it disabled per app.
    private static func pointerLockCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon pointerlock <bundle-id|name> [on|off]")
        }
        let app = try resolveApp(query)

        guard let state = arguments.positionals.dropFirst().first else {
            let allowed = AppSettings.pointerLockAllowed(for: app.id)
            print("pointer lock: \(allowed ? "allowed" : "disabled") for \(app.displayName) [\(app.id)]")
            return 0
        }

        switch state.lowercased() {
        case "on", "1", "true", "yes":
            AppSettings.setPointerLockAllowed(true, for: app.id)
        case "off", "0", "false", "no":
            AppSettings.setPointerLockAllowed(false, for: app.id)
        default:
            throw CLIError.message("expected 'on' or 'off', got '\(state)'")
        }
        notifyLibraryChanged()
        print("pointer lock \(state.lowercased()) for \(app.displayName) — relaunch to apply")
        return 0
    }

    // MARK: Logs

    private static func logsCommand(_ arguments: CLIArguments) throws -> Int32 {
        guard let query = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon logs <bundle-id|name> [--follow] [--system]")
        }
        let app = try resolveApp(query)

        if arguments.flags.contains("system") {
            try Shell.runStreaming("/usr/bin/log", [
                "stream", "--style", "compact",
                "--predicate", "subsystem == \"com.pearsilicon.runtime\"",
            ])
            return 0
        }

        let path = CLIPaths.shared.logs.appendingPathComponent("\(app.id).log").path
        guard FileManager.default.fileExists(atPath: path) else {
            print("no log file at \(path)")
            print("launch with --log (or use `pearsilicon debug`) to create one")
            return 1
        }

        if arguments.flags.contains("follow") {
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
                .first?.processIdentifier
            followLog(path: path, pid: pid, name: app.displayName)
        } else {
            print(try String(contentsOfFile: path, encoding: .utf8), terminator: "")
        }
        return 0
    }

    // MARK: Paths / link

    private static func pathsCommand() throws -> Int32 {
        let paths = CLIPaths.shared
        print("support:  \(paths.support.path)")
        print("library:  \(paths.library.path)")
        print("keymaps:  \(paths.keymaps.path)")
        print("logs:     \(paths.logs.path)")
        print("work:     \(paths.work.path)")
        print("runtime:  \(AppLauncher.runtimeLibraryURL()?.path ?? "not found")")
        return 0
    }

    private static func doctorCommand() throws -> Int32 {
        let architecture = (try? Shell.run("/usr/bin/uname", ["-m"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        print("macOS:    \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("arch:     \(architecture)")

        switch DeveloperTools.toolchainStatus() {
        case .ready:
            print("toolchain:ready (\(DeveloperTools.activeDeveloperDirectory() ?? "selected"))")
        case .missing:
            print("toolchain: NOT INSTALLED")
            print("          install the full development toolchain, then run:")
            print("            sudo xcode-select -s /Applications/<Toolchain>.app")
        case .installedButNotSelected(let toolchainPath, let activePath):
            print("toolchain: installed at \(toolchainPath), but not selected")
            print("          active: \(activePath ?? "unknown")")
            print("          run: \(DeveloperTools.selectCommand(for: toolchainPath))")
        }

        let runtime = AppLauncher.runtimeLibraryURL()?.path
        print("runtime:  \(runtime ?? "NOT FOUND")")

        let apps = (try? PackageInstaller(libraryURL: CLIPaths.shared.library).scanLibrary()) ?? []
        print("library:  \(CLIPaths.shared.library.path) (\(apps.count) apps)")
        return 0
    }

    private static func linkCommand(_ arguments: CLIArguments) throws -> Int32 {
        let target = arguments.options["to"] ?? "/usr/local/bin/pearsilicon"
        let source = Bundle.main.executableURL?.path
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: target).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: target) {
            try? fileManager.removeItem(atPath: target)
        }
        do {
            try fileManager.createSymbolicLink(atPath: target, withDestinationPath: source)
            print("linked \(target) → \(source)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("""
            could not create \(target): \(error.localizedDescription)

            Run this once with sudo:
              sudo ln -sf "\(source)" "\(target)"

            """.utf8))
            return 1
        }
    }

    // MARK: Project build

    private static func buildProjectCommand(_ arguments: CLIArguments) throws -> Int32 {
        switch DeveloperTools.toolchainStatus() {
        case .ready:
            break
        case .missing:
            throw CLIError.message("""
            The full development toolchain is not installed. Install it, open it once, then run:
              sudo xcode-select -s /Applications/<Toolchain>.app
            """)
        case .installedButNotSelected(let toolchainPath, _):
            throw CLIError.message("""
            The development toolchain is installed but not selected. Run:
              \(DeveloperTools.selectCommand(for: toolchainPath))
            """)
        }

        guard let project = arguments.positionals.first else {
            throw CLIError.message("usage: pearsilicon build <project.xcodeproj|project.xcworkspace> --scheme <name> [--configuration Debug]")
        }
        guard let scheme = arguments.options["scheme"] else {
            throw CLIError.message("--scheme is required")
        }
        let configuration = arguments.options["configuration"] ?? "Debug"
        let destination = arguments.options["destination"] ?? "generic/platform=iOS"

        let derivedData = CLIPaths.shared.work.appendingPathComponent("ProjectBuildData", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)

        var baseArguments: [String]
        if project.hasSuffix(".xcworkspace") {
            baseArguments = ["-workspace", project]
        } else {
            baseArguments = ["-project", project]
        }
        baseArguments += [
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination,
            "-derivedDataPath", derivedData.path,
        ]

        print("reading build settings…")
        let settingsOutput = try Shell.run("/usr/bin/xcodebuild", baseArguments + ["-showBuildSettings"])
        let settings = parseBuildSettings(settingsOutput)
        guard let productsDirectory = settings["BUILT_PRODUCTS_DIR"],
              let productName = settings["FULL_PRODUCT_NAME"] else {
            throw CLIError.message("could not read BUILT_PRODUCTS_DIR / FULL_PRODUCT_NAME from the project builder")
        }

        print("building \(scheme) (\(configuration)) for \(destination)…")
        try Shell.runStreaming("/usr/bin/xcodebuild", baseArguments + [
            "build",
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
        ])

        let appURL = URL(fileURLWithPath: productsDirectory).appendingPathComponent(productName)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CLIError.message("build succeeded but \(appURL.path) was not found")
        }

        let app = try install(path: appURL.path, arguments: arguments)
        if arguments.flags.contains("no-launch") { return 0 }
        return try launch(app: app, arguments: arguments, debug: false)
    }

    private static func parseBuildSettings(_ output: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: " = ") else { continue }
            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { settings[key] = value }
        }
        return settings
    }

    // MARK: Helpers

    private static func resolveApp(_ query: String) throws -> InstalledApp {
        let apps = try PackageInstaller(libraryURL: CLIPaths.shared.library).scanLibrary()
        if let exact = apps.first(where: { $0.id == query }) { return exact }

        let matches = apps.filter {
            $0.displayName.caseInsensitiveCompare(query) == .orderedSame
                || $0.bundleName.caseInsensitiveCompare(query) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            let list = matches.map { "\($0.displayName) [\($0.id)]" }.joined(separator: "\n  ")
            throw CLIError.message("'\(query)' is ambiguous:\n  \(list)")
        }

        if apps.isEmpty {
            throw CLIError.message("not installed: \(query) (the library is empty)")
        }
        let available = apps.map { "\($0.id)  \($0.displayName)" }.joined(separator: "\n  ")
        throw CLIError.message("not installed: \(query)\n\ninstalled apps:\n  \(available)")
    }

    /// Keymapper is opt-in and off by default, matching the GUI. The CLI shares
    /// the same UserDefaults domain (it runs as the same bundle).
    private static func keymapperEnabled(for app: InstalledApp, arguments: CLIArguments) -> Bool {
        if arguments.flags.contains("keys") { return true }
        if arguments.flags.contains("no-keys") { return false }
        let defaults = AppSettings.defaults
        if let stored = defaults.object(forKey: "keymapper.enabled." + app.id) as? Bool {
            return stored
        }
        return defaults.bool(forKey: "keymapper.defaultEnabled")
    }

    private static func keymapState(enabled: Bool, hasFile: Bool, url: URL?) -> String {
        if !enabled { return "disabled" }
        guard hasFile else { return "enabled, but no keymap file (generate one with `pearsilicon keymap … --generate`)" }
        return url?.path ?? "enabled"
    }

    private static func notifyLibraryChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.pearsilicon.libraryChanged"),
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    /// Runs an async service call from the synchronous CLI, pumping the main run
    /// loop so main-actor work and NSWorkspace callbacks make progress.
    private static func awaitBridge<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = AsyncBox<T>()
        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor in
            do { box.value = try await operation() }
            catch { box.errorMessage = error.localizedDescription }
            semaphore.signal()
        }

        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        if let value = box.value { return value }
        throw CLIError.message(box.errorMessage ?? "operation failed")
    }

    private static func waitForExit(pid: pid_t, name: String?) {
        guard pid > 0 else { return }
        var misses = 0
        while true {
            if let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated {
                misses = 0
            } else {
                misses += 1
                if misses >= 3 { break }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if let name { print("\(name) exited") }
    }

    private static func followLog(path: String, pid: pid_t?, name: String?) {
        print("— log: \(path) (Ctrl-C to stop) —")
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-n", "+1", "-f", path]
        tail.standardOutput = FileHandle.standardOutput
        tail.standardError = FileHandle.standardError
        do { try tail.run() } catch {
            print("could not follow log: \(error.localizedDescription)")
            return
        }

        if let pid {
            waitForExit(pid: pid, name: name)
            tail.terminate()
            tail.waitUntilExit()
        } else {
            tail.waitUntilExit()
        }
    }

    private static func parse(_ arguments: [String]) -> CLIArguments {
        var parsed = CLIArguments()
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                parsed.positionals += arguments[(index + 1)...]
                break
            }

            guard token.hasPrefix("-"), token != "-" else {
                parsed.positionals.append(token)
                index += 1
                continue
            }

            var name = token.hasPrefix("--") ? String(token.dropFirst(2)) : String(token.dropFirst())
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }

            if name == "env" {
                if value == nil, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    value = arguments[index + 1]
                    index += 1
                }
                if let value, let equals = value.firstIndex(of: "=") {
                    let key = String(value[..<equals])
                    let val = String(value[value.index(after: equals)...])
                    parsed.environment[key] = val
                }
            } else if booleanFlags.contains(name) {
                parsed.flags.insert(name)
            } else if let value {
                parsed.options[name] = value
            } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                parsed.options[name] = arguments[index + 1]
                index += 1
            } else {
                parsed.flags.insert(name)
            }
            index += 1
        }
        return parsed
    }

    // MARK: Help

    private static func printVersion() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.7"
        print("pearsilicon \(version)")
    }

    private static func printHelp() {
        print("""
        pearsilicon — install and run iOS apps natively on arm64 macOS

        USAGE
          pearsilicon <command> [options]

        COMMANDS
          install <package|app>    Prepare and install an app package or a toolchain-built .app
          run <package|app>        install + launch (use --no-launch to stop after install)
          launch <id|name>     Launch an installed app
          debug <id|name>      Launch with touch logging and follow the log
          stop <id|name>       Terminate a running app
          list                 List installed apps (--json for machine output)
          info <id|name>       Show paths, version, keymap and runtime info
          uninstall <id|name>  Remove an app and its keymap (--yes to skip the prompt)
          keymap <id|name>     Print the keymap (--path, --generate, --set <file>)
          keys <id|name> [on|off]  Print or set the keymapper toggle
          hud <id|name> [on|off]   Print or set the Metal HUD/FPS overlay
          pointerlock <id|name> [on|off]  Allow or disallow the game's pointer lock
          logs <id|name>       Print or follow the log (--follow, --system)
          paths                Show the Application Support layout
          doctor               Check toolchain, runtime and library readiness
          link                 Symlink this binary to /usr/local/bin/pearsilicon
          build <project>      Build a scheme for a device, install and launch it

        COMMON OPTIONS
          --keys / --no-keys   Force the keymapper on or off for this launch
          --metal-hud / --no-metal-hud  Force the Metal HUD/FPS overlay on or off
          --pointer-lock / --no-pointer-lock  Force the game's pointer lock on or off
          --log                Write a log file and follow it
          --wait               Wait for the app to exit
          --env KEY=VALUE      Extra environment variable (repeatable)
          --trace              Shorthand for debug touch logging
          --lldb               (debug) attach LLDB to the launched process

        PROJECT BUILD
          Build for a device (not the simulator) and hand the product to PearSilicon:

            pearsilicon build ~/Code/MyApp/MyApp.xcodeproj --scheme MyApp

          Or use the scheme's Run action: set the executable to
          /Applications/PearSilicon.app/Contents/MacOS/PearSilicon and pass

            run "$(BUILT_PRODUCTS_DIR)/$(FULL_PRODUCT_NAME)" --log

          as the arguments. PearSilicon patches and signs the bundle, loads the
          runtime and launches it activated — no simulator involved.

        EXAMPLES
          pearsilicon install ~/Downloads/App.app --launch
          pearsilicon run ~/Downloads/App.app --keys --log
          pearsilicon debug com.example.game --lldb
          pearsilicon logs com.example.game --follow
          pearsilicon keymap com.example.game --generate
          pearsilicon keys com.example.game on
          pearsilicon hud com.example.game on
          pearsilicon pointerlock com.example.game on
          pearsilicon run ~/Downloads/App.app --metal-hud
          pearsilicon doctor
        """)
    }
}
