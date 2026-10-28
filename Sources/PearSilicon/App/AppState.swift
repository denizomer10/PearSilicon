import AppKit
import Foundation
import SwiftUI

/// Global application state. The UI observes this object; the underlying
/// services (install, keymap, launch) are driven from here.
@MainActor
final class AppState: ObservableObject {

    /// The single instance shared by the UI and the app delegate (the delegate
    /// needs it to stop running games on quit).
    static let shared = AppState()

    // MARK: - Published state

    @Published var installedApps: [InstalledApp] = []
    @Published var selection: InstalledApp.ID?
    @Published var searchText: String = ""
    @Published var statusMessage: String = L10n.ready
    @Published var isBusy: Bool = false

    /// Keymap of the currently selected app, if any.
    @Published var currentKeymap: Keymap?

    /// Root directory for installed apps.
    @Published var libraryURL: URL

    /// Apps from the library that are currently running, keyed by bundle id.
    @Published private(set) var runningApps: [String: NSRunningApplication] = [:]

    /// Bundle ids whose keymapper is enabled. Default OFF: input translation is
    /// only enabled when a game is explicitly opted in.
    @Published private(set) var keymapperEnabledApps: Set<String> = []

    /// Bundle ids that should launch with Metal's performance HUD/FPS overlay.
    @Published private(set) var metalHUDEnabledApps: Set<String> = []

    /// Bundle ids allowed to take pointer lock (needed for mouse-look camera
    /// control in some games).
    @Published private(set) var pointerLockAllowedApps: Set<String> = []


    /// Default for apps without an explicit setting (also default OFF).
    @Published var keymapperDefaultEnabled: Bool = AppSettings.defaults.bool(forKey: "keymapper.defaultEnabled") {
        didSet { AppSettings.defaults.set(keymapperDefaultEnabled, forKey: "keymapper.defaultEnabled") }
    }

    // MARK: - Services

    let packageInstaller: PackageInstaller
    let launcher: AppLauncher
    let keymapStore: KeymapStore

    /// Keymapper overlays for running games, keyed by bundle id. PearSilicon owns
    /// these windows; no UI code is added to the game.
    private var overlays: [String: GameKeymapperOverlay] = [:]

    private var workspaceObservers: [NSObjectProtocol] = []

    /// Apps whose termination is in progress; used to clear the "Stopping …"
    /// status once they are gone.
    private var stoppingApps: Set<String> = []

    /// The app whose launch is still being confirmed. A process that dies during
    /// startup (a crash or a missing runtime component) must not leave the
    /// status bar showing "Launching …" forever.
    private var launchingAppID: String?

    // MARK: - Lifecycle

    init() {
        AppPaths.migrateLegacySupportDirectoryIfNeeded()
        let base = AppPaths.supportRoot
        let library = base.appendingPathComponent("Applications", isDirectory: true)
        let keymaps = base.appendingPathComponent("Keymaps", isDirectory: true)

        self.libraryURL = library
        self.packageInstaller = PackageInstaller(libraryURL: library)
        self.launcher = AppLauncher(libraryURL: library)
        self.keymapStore = KeymapStore(baseURL: keymaps)

        observeWorkspace()
    }

    // MARK: - Running apps

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRunningApps() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRunningApps() }
        })

        // The CLI installs/removes apps in the same library. Refresh when it says
        // the library changed, so an open window stays in sync.
        workspaceObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.pearsilicon.libraryChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in try? await self?.refreshLibrary() }
        })
        refreshRunningApps()
    }

    func refreshRunningApps() {
        let ids = Set(installedApps.map(\.id))
        var map: [String: NSRunningApplication] = [:]
        for running in NSWorkspace.shared.runningApplications {
            if let bundleID = running.bundleIdentifier, ids.contains(bundleID), !running.isTerminated {
                map[bundleID] = running
            }
        }
        runningApps = map

        // A launch is only "pending" until the app shows up as running. Once it
        // does, clear the transient status; the app is now the user's focus.
        if let launching = launchingAppID, map[launching] != nil {
            launchingAppID = nil
            if statusMessage.hasPrefix("Launching ") { statusMessage = L10n.ready }
        }

        // Drop the transient "Stopping …" status once those apps are gone.
        let finished = stoppingApps.filter { map[$0] == nil }
        if !finished.isEmpty {
            stoppingApps.subtract(finished)
            if statusMessage.hasPrefix("Stopping ") { statusMessage = L10n.ready }
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        runningApps[app.id]?.isTerminated == false
    }

    /// Stops a running game (terminates the process) and removes its overlay.
    /// The Stop control disappears immediately; the status line is cleared once
    /// the process is actually gone.
    func stop(_ app: InstalledApp) {
        guard let running = runningApps[app.id] else { return }
        overlays[app.id]?.detach()
        overlays[app.id] = nil
        runningApps[app.id] = nil // hide Stop right away
        stoppingApps.insert(app.id)
        running.terminate()
        statusMessage = "Stopping \(app.displayName)…"

        // Reconcile: notifications normally arrive, but a game can take a moment
        // (or ignore SIGTERM). Escalate, then clear the status.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            if let still = NSRunningApplication(processIdentifier: running.processIdentifier),
               !still.isTerminated {
                still.forceTerminate()
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.refreshRunningApps()
            self.stoppingApps.remove(app.id)
            if self.statusMessage.hasPrefix("Stopping ") { self.statusMessage = L10n.ready }
        }
    }

    /// Games from the library that are currently running.
    var runningGames: [InstalledApp] {
        installedApps.filter { isRunning($0) }
    }

    /// Stops every running game (used when quitting the app).
    func stopAllRunningGames() {
        for app in runningGames { stop(app) }
    }

    func bootstrap() async {
        do {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            try await refreshLibrary()
        } catch {
            statusMessage = L10n.error("Could not initialize library: \(error.localizedDescription)")
        }
    }

    func refreshLibrary() async throws {
        let apps = try packageInstaller.scanLibrary()
        self.installedApps = apps.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        loadKeymapperSettings()
        refreshRunningApps()
    }

    // MARK: - Keymapper toggle (default OFF)

    private func loadKeymapperSettings() {
        var enabled: Set<String> = []
        var hud: Set<String> = []
        var pointerLock: Set<String> = []
        for app in installedApps {
            let key = "keymapper.enabled." + app.id
            if let stored = AppSettings.defaults.object(forKey: key) as? Bool, stored {
                enabled.insert(app.id)
            }
            if AppSettings.defaults.bool(forKey: "metalHUD.enabled." + app.id) {
                hud.insert(app.id)
            }
            if AppSettings.pointerLockAllowed(for: app.id) {
                pointerLock.insert(app.id)
            }
        }
        keymapperEnabledApps = enabled
        metalHUDEnabledApps = hud
        pointerLockAllowedApps = pointerLock
    }

    func isKeymapperEnabled(for app: InstalledApp) -> Bool {
        keymapperEnabledApps.contains(app.id) || (keymapperDefaultEnabled && !hasExplicitSetting(app.id))
    }

    private func hasExplicitSetting(_ bundleID: String) -> Bool {
        AppSettings.defaults.object(forKey: "keymapper.enabled." + bundleID) != nil
    }

    /// Enables/disables input translation for an app. Takes effect on next launch
    /// (input translation is decided when the process starts).
    func setKeymapperEnabled(_ enabled: Bool, for app: InstalledApp) {
        AppSettings.defaults.set(enabled, forKey: "keymapper.enabled." + app.id)
        if enabled { keymapperEnabledApps.insert(app.id) } else { keymapperEnabledApps.remove(app.id) }
    }

    // MARK: - Metal HUD

    func isMetalHUDEnabled(for app: InstalledApp) -> Bool {
        metalHUDEnabledApps.contains(app.id)
    }

    /// Shows Metal's performance overlay (FPS, frame time, GPU time). Takes
    /// effect on the next launch: the env var is read when the process starts.
    func setMetalHUDEnabled(_ enabled: Bool, for app: InstalledApp) {
        AppSettings.defaults.set(enabled, forKey: "metalHUD.enabled." + app.id)
        if enabled { metalHUDEnabledApps.insert(app.id) } else { metalHUDEnabledApps.remove(app.id) }
    }

    // MARK: - Pointer lock

    func isPointerLockAllowed(for app: InstalledApp) -> Bool {
        pointerLockAllowedApps.contains(app.id)
    }

    /// Allows/disallows the game's own pointer lock. Games that use relative
    /// mouse motion for the camera need it; games that trap the cursor do not.
    /// Applied on the next launch.
    func setPointerLockAllowed(_ allowed: Bool, for app: InstalledApp) {
        AppSettings.setPointerLockAllowed(allowed, for: app.id)
        if allowed { pointerLockAllowedApps.insert(app.id) } else { pointerLockAllowedApps.remove(app.id) }
    }

    // MARK: - Selection

    var selectedApp: InstalledApp? {
        guard let selection else { return nil }
        return installedApps.first { $0.id == selection }
    }

    func select(_ app: InstalledApp?) {
        selection = app?.id
        currentKeymap = app.flatMap { try? keymapStore.load(for: $0.id) }
    }

    // MARK: - Install

    func install(packageURLs: [URL]) async {
        isBusy = true
        defer { isBusy = false }

        for url in packageURLs {
            do {
                statusMessage = L10n.installing(url.lastPathComponent)
                let app = try await packageInstaller.install(packageAt: url)

                // Auto-generate a starting keymap if the app has none yet.
                if try keymapStore.load(for: app.id) == nil {
                    try keymapStore.save(KeymapGenerator.generate(for: app))
                }

                if !packageInstaller.corruptedFiles.isEmpty {
                    statusMessage = L10n.installedCorrupted(app.displayName, files: packageInstaller.corruptedFiles)
                } else if packageInstaller.unpreparedBinaries.isEmpty {
                    statusMessage = L10n.installed(app.displayName)
                } else {
                    statusMessage = L10n.installedUnprepared(app.displayName)
                }
            } catch {
                statusMessage = L10n.error("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        try? await refreshLibrary()
    }

    // MARK: - Launch / uninstall

    func launch(_ app: InstalledApp) async {
        // Input translation is opted in per game and default OFF. When disabled,
        // no keymap is passed, so the runtime installs no input handlers.
        let enabled = isKeymapperEnabled(for: app)
        let keymapURL = enabled ? keymapStore.fileURL(for: app.id) : nil
        var extra: [String: String] = [:]
        if isMetalHUDEnabled(for: app) {
            extra["MTL_HUD_ENABLED"] = "1"
        }
        if isPointerLockAllowed(for: app) {
            extra["PEAR_ALLOW_POINTER_LOCK"] = "1"
        }
        // The iOS-like filesystem view is part of the base environment.
        extra["PEAR_IOS_SANDBOX"] = "1"

        let nativeContainer = false
        do {
            try? packageInstaller.setPreparationMode(.compatibility, for: app)
            let running = try await launcher.launch(
                app, keymapURL: keymapURL, extraEnvironment: extra,
                nativeContainer: nativeContainer
            )
            statusMessage = L10n.launching(app.displayName)
            launchingAppID = app.id

            // Reconcile a launch that never becomes visible: if the process is
            // not running a few seconds later, say so instead of leaving the
            // status bar stuck on "Launching".
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.launchingAppID == app.id else { return }
                self.refreshRunningApps()
                if self.launchingAppID == app.id {
                    self.launchingAppID = nil
                    if self.statusMessage.hasPrefix("Launching ") {
                        self.statusMessage = L10n.error("\(app.displayName) exited during launch")
                    }
                }
            }

            // Own the keymapper UI from here: a small overlay button + editor over
            // the game window. The game process stays free of added UI.
            overlays[app.id]?.detach()
            if enabled, let pid = running?.processIdentifier {
                let overlay = GameKeymapperOverlay(bundleID: app.id, keymapStore: keymapStore)
                overlay.attach(pid: pid)
                overlays[app.id] = overlay
            }
            refreshRunningApps()
        } catch {
            statusMessage = L10n.error("Launch failed: \(error.localizedDescription)")
        }
    }

    func uninstall(_ app: InstalledApp) {
        do {
            overlays[app.id]?.detach()
            overlays[app.id] = nil
            try packageInstaller.uninstall(app)
            try? keymapStore.delete(for: app.id)
            installedApps.removeAll { $0.id == app.id }
            if selection == app.id {
                selection = nil
                currentKeymap = nil
            }
            statusMessage = L10n.removed(app.displayName)
        } catch {
            statusMessage = L10n.error("Uninstall failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Keymap

    func generateKeymap(for app: InstalledApp) {
        do {
            let keymap = KeymapGenerator.generate(for: app)
            try keymapStore.save(keymap)
            currentKeymap = keymap
            statusMessage = "Keymap generated for \(app.displayName)"
        } catch {
            statusMessage = L10n.error("Keymap generation failed: \(error.localizedDescription)")
        }
    }

    func saveKeymap(_ keymap: Keymap) {
        do {
            try keymapStore.save(keymap)
            currentKeymap = keymap
            statusMessage = "Keymap saved"
        } catch {
            statusMessage = L10n.error("Could not save keymap: \(error.localizedDescription)")
        }
    }

    // MARK: - Overlay

    /// Shows the keymapper overlay over `app` if it is currently running. Lets the
    /// UI be opened for a game launched outside the app (or after a relaunch).
    func openOverlay(for app: InstalledApp) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first,
              !running.isTerminated else {
            statusMessage = L10n.error("\(app.displayName) is not running")
            return
        }
        let overlay = overlays[app.id] ?? GameKeymapperOverlay(bundleID: app.id, keymapStore: keymapStore)
        overlay.attach(pid: running.processIdentifier)
        overlays[app.id] = overlay
        statusMessage = "Keymapper overlay: \(app.displayName)"
    }
}
