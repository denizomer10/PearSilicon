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

    /// The platform shown by the top switch.
    @Published var platform: LibraryPlatform = .iOS

    /// Self-contained macOS and Wine entries.
    @Published private(set) var managedEntries: [LibraryEntry] = []
    @Published var selectedManagedEntryID: LibraryEntry.ID?
    @Published private(set) var wineEngines: [WineEngine] = []
    @Published private(set) var libraryWarnings: [String] = []

    /// Explicit, user-triggered updater state. No timer or telemetry.
    @Published private(set) var availableUpdate: AppUpdateCheck?
    @Published private(set) var stagedUpdate: StagedAppUpdate?

    /// Launchable per-platform items.
    var platformApps: [InstalledApp] {
        platform == .iOS ? installedApps : []
    }
    var platformEntries: [LibraryEntry] {
        switch platform {
        case .iOS: []
        case .macOS: managedEntries.filter { $0.platform == .macOS }
        case .wine: managedEntries.filter { $0.platform == .wine }
        }
    }
    var selectedManagedEntry: LibraryEntry? {
        guard let selectedManagedEntryID else { return nil }
        return managedEntries.first { $0.id == selectedManagedEntryID }
    }

    /// Keymap of the currently selected app, if any.
    @Published var currentKeymap: Keymap?

    /// Root directory for installed apps.
    @Published var libraryURL: URL

    /// Where all PearSilicon data lives (apps, game data, keymaps, ODR, logs).
    @Published private(set) var storageRootURL: URL

    /// Retained copy of the previous storage after a move, if any.
    @Published private(set) var previousStorageRootURL: URL?

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

    var packageInstaller: PackageInstaller
    var launcher: AppLauncher
    var keymapStore: KeymapStore
    private var packageImports: PackageImportOperations
    private let observesWorkspace: Bool
    private let managedApps = ManagedAppService()
    private let portableLibrary: PortableLibrary
    private let wineStore: WineEngineStore
    private let wineReleases = WineReleaseService()
    private lazy var updater = AppUpdateService()

    @Published private(set) var wineReleaseCheck: WineReleaseCheck?

    /// Managed launches are tracked by entry directory, never by a caller-supplied
    /// PID. Detached Wine helpers can outlive the direct child.
    private var managedRunning: [LibraryEntry.ID: ManagedAppProcess] = [:]

    /// Package imports run one at a time, in submission order. A plain `isBusy`
    /// flag is not enough: `install` suspends at its first await, so a second
    /// drop can start while the first is still running and later clear the flag
    /// for both of them.
    private struct PendingPackageImport {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var importQueue: [PendingPackageImport] = []
    private var importRunnerActive = false
    private var cancelledImportRequests: Set<UUID> = []

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

    init(
        storageRootURL explicitRoot: URL? = nil,
        packageImports: PackageImportOperations? = nil,
        observesWorkspace: Bool = true
    ) {
        if explicitRoot == nil { AppPaths.migrateLegacySupportDirectoryIfNeeded() }
        let base = explicitRoot ?? AppPaths.supportRoot
        let library = base.appendingPathComponent(PortableLibrary.iOSFolder, isDirectory: true)
        let keymaps = base.appendingPathComponent("Keymaps", isDirectory: true)

        self.libraryURL = library
        self.storageRootURL = base
        self.portableLibrary = PortableLibrary(rootURL: base)
        self.wineStore = WineEngineStore(rootURL: base.appendingPathComponent("Engines", isDirectory: true))
        self.previousStorageRootURL = explicitRoot == nil ? StorageLocationStore.shared.previousRootURL : nil
        let installer = PackageInstaller(libraryURL: library)
        self.packageInstaller = installer
        self.packageImports = packageImports ?? .live(installer: installer)
        self.observesWorkspace = observesWorkspace
        self.launcher = AppLauncher(libraryURL: library)
        self.keymapStore = KeymapStore(baseURL: keymaps)

        if observesWorkspace { observeWorkspace() }
    }

    /// Rebuilds the path-bound services after storage moved or another library
    /// was attached.
    private func reloadStorage() {
        let base = AppPaths.supportRoot
        storageRootURL = base
        previousStorageRootURL = StorageLocationStore.shared.previousRootURL
        libraryURL = base.appendingPathComponent(PortableLibrary.iOSFolder, isDirectory: true)
        packageInstaller = PackageInstaller(libraryURL: libraryURL)
        packageImports = .live(installer: packageInstaller)
        launcher = AppLauncher(libraryURL: libraryURL)
        keymapStore = KeymapStore(baseURL: base.appendingPathComponent("Keymaps", isDirectory: true))
        currentKeymap = selectedApp.flatMap { try? keymapStore.load(for: $0.id) }
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
        guard observesWorkspace else { return }
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

        managedRunning = managedRunning.filter { $0.value.isRunning }
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

    var runningManagedEntries: [LibraryEntry] {
        managedEntries.filter { isRunning($0) }
    }

    var runningGameNames: [String] {
        runningGames.map(\.displayName) + runningManagedEntries.map(\.displayName)
    }

    /// Stops every running game (used when quitting the app).
    func stopAllRunningGames() {
        for app in runningGames { stop(app) }
        for entry in runningManagedEntries { stop(entry) }
    }

    func bootstrap() async {
        do {
            try await refreshLibrary()
        } catch {
            statusMessage = L10n.error("Could not initialize library: \(error.localizedDescription)")
        }
    }

    func refreshLibrary() async throws {
        let snapshot = portableLibrary.scan()
        self.installedApps = snapshot.iosApps
        self.managedEntries = snapshot.macEntries + snapshot.wineEntries
        self.libraryWarnings = snapshot.warnings
        loadKeymapperSettings()
        reloadEngines()
        refreshRunningApps()
    }

    func reloadEngines() {
        do {
            wineEngines = try wineStore.engines()
        } catch {
            wineEngines = []
            libraryWarnings.append("Wine engines: \(error.localizedDescription)")
        }
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
        selectedManagedEntryID = nil
        currentKeymap = app.flatMap { try? keymapStore.load(for: $0.id) }
    }

    func select(_ entry: LibraryEntry?) {
        selectedManagedEntryID = entry?.id
        selection = nil
        currentKeymap = nil
    }

    // MARK: - Managed Mac / Wine apps

    func isRunning(_ entry: LibraryEntry) -> Bool {
        managedRunning[entry.id]?.isRunning == true
    }

    func launch(_ entry: LibraryEntry) async {
        guard !isBusy else { return }
        guard !isRunning(entry) else {
            statusMessage = L10n.error("\(entry.displayName) is already running")
            return
        }
        isBusy = true
        defer { finishBusyWork() }
        do {
            let engine: WineEngine?
            switch entry.platform {
            case .wine:
                guard let id = entry.manifest.wineEngineID else {
                    throw PearError.launchFailed("This game has no Wine engine selected")
                }
                guard let found = try wineStore.engine(id: id) else {
                    throw PearError.launchFailed("The selected Wine engine is no longer installed")
                }
                engine = found
            case .macOS:
                engine = nil
            case .iOS:
                throw PearError.launchFailed("Use the iOS launcher for this entry")
            }
            statusMessage = "Launching \(entry.displayName)…"
            let process = try await managedApps.launch(
                entry, engine: engine,
                metalHUDEnabled: entry.manifest.metalHUDEnabled
            )
            managedRunning[entry.id] = process
            platform = entry.platform
            selectedManagedEntryID = entry.id
            statusMessage = L10n.launching(entry.displayName)
        } catch {
            statusMessage = L10n.error("Launch failed: \(error.localizedDescription)")
        }
    }

    func stop(_ entry: LibraryEntry) {
        guard let process = managedRunning[entry.id] else { return }
        process.stop()
        managedRunning[entry.id] = nil
        statusMessage = "Stopping \(entry.displayName)…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.statusMessage = L10n.ready
        }
    }

    func uninstall(_ entry: LibraryEntry) {
        guard !isBusy else { return }
        guard !isRunning(entry) else {
            statusMessage = L10n.error("Stop \(entry.displayName) before removing it")
            return
        }
        do {
            try FileManager.default.removeItem(at: entry.directoryURL)
            managedEntries.removeAll { $0.id == entry.id }
            if selectedManagedEntryID == entry.id { selectedManagedEntryID = nil }
            statusMessage = "Removed \(entry.displayName)"
        } catch {
            statusMessage = L10n.error("Uninstall failed: \(error.localizedDescription)")
        }
    }

    func setMetalHUDEnabled(_ enabled: Bool, for entry: LibraryEntry) {
        updateManifest(entry) { $0.metalHUDEnabled = enabled }
    }

    func setWineEngine(_ engineID: String, for entry: LibraryEntry) {
        updateManifest(entry) { $0.wineEngineID = engineID }
    }

    private func updateManifest(_ entry: LibraryEntry, change: (inout LibraryManifest) -> Void) {
        do {
            var manifest = entry.manifest
            change(&manifest)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: entry.manifestURL, options: .atomic)
            if let index = managedEntries.firstIndex(where: { $0.id == entry.id }) {
                managedEntries[index] = LibraryEntry(manifest: manifest, directoryURL: entry.directoryURL)
            }
        } catch {
            statusMessage = L10n.error("Could not update \(entry.displayName): \(error.localizedDescription)")
        }
    }

    // MARK: - Backup / restore

    func backup(_ entry: LibraryEntry, to destination: URL) async {
        guard !isBusy else { return }
        guard !isRunning(entry) else {
            statusMessage = L10n.error("Stop \(entry.displayName) before backing it up")
            return
        }
        isBusy = true
        defer { finishBusyWork() }
        do {
            statusMessage = "Backing up \(entry.displayName)…"
            let output = try await LibraryBackupService().backup(entry: entry, to: destination)
            statusMessage = "Backup saved: \(output.lastPathComponent). \(LibraryBackupService.privacyWarning)"
        } catch {
            statusMessage = L10n.error("Backup failed: \(error.localizedDescription)")
        }
    }

    func backup(_ app: InstalledApp, to destination: URL) async {
        guard !isBusy else { return }
        guard !isRunning(app) else {
            statusMessage = L10n.error("Stop \(app.displayName) before backing it up")
            return
        }
        isBusy = true
        defer { finishBusyWork() }
        let workRoot = storageRootURL.appendingPathComponent("Work/Backups", isDirectory: true)
        var snapshot: URL?
        defer { if let snapshot { try? FileManager.default.removeItem(at: snapshot) } }
        do {
            statusMessage = "Preparing backup for \(app.displayName)…"
            try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
            let directory = try portableLibrary.makeIOSSnapshot(for: app, in: workRoot)
            snapshot = directory
            let manifest = try JSONDecoder().decode(
                LibraryManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent(LibraryManifest.filename))
            )
            let entry = LibraryEntry(manifest: manifest, directoryURL: directory)
            let identifier = app.id
            let service = LibraryBackupService(requireStopped: { _ in
                let running = await MainActor.run {
                    NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                        .contains { !$0.isTerminated }
                }
                if running { throw PearError.commandFailed(tool: "backup", status: 1, output: "\(identifier) is still running") }
            })
            let output = try await service.backup(entry: entry, to: destination)
            statusMessage = "Backup saved: \(output.lastPathComponent). \(LibraryBackupService.privacyWarning)"
        } catch {
            statusMessage = L10n.error("Backup failed: \(error.localizedDescription)")
        }
    }

    /// Restores into a private staging library first, then activates the entry.
    /// An existing app is moved to Work/RestoreRollback rather than overwritten.
    func restoreBackup(from archive: URL, replacing: Bool) async {
        guard !isBusy else { return }
        guard runningGames.isEmpty, runningManagedEntries.isEmpty else {
            statusMessage = L10n.error("Stop every running app before restoring a backup")
            return
        }
        isBusy = true
        defer { finishBusyWork() }
        let work = storageRootURL.appendingPathComponent("Work/Restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            statusMessage = "Restoring \(archive.lastPathComponent)…"
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let tempRoot = work.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            // The temporary root is not the live app, so a path-based running
            // guard cannot see the real process; all games were stopped above.
            let service = LibraryBackupService(requireStopped: { _ in })
            let restored = try await service.restore(from: archive, to: tempRoot)

            if restored.platform == .iOS {
                let app = try portableLibrary.installRestoredIOSEntry(
                    restored, replacing: replacing,
                    rollbackRoot: storageRootURL.appendingPathComponent("Work/RestoreRollback", isDirectory: true)
                )
                statusMessage = "Restored \(app.displayName)"
            } else {
                let destination = storageRootURL
                    .appendingPathComponent(restored.platform.rawValue, isDirectory: true)
                    .appendingPathComponent(restored.manifest.id, isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard replacing else {
                        throw PearError.invalidPackage("\(restored.displayName) is already installed; enable replace to overwrite it")
                    }
                    let rollback = storageRootURL.appendingPathComponent("Work/RestoreRollback", isDirectory: true)
                    try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(
                        at: destination,
                        to: rollback.appendingPathComponent("\(restored.manifest.id)-\(UUID().uuidString)")
                    )
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: restored.directoryURL, to: destination)
                statusMessage = "Restored \(restored.displayName)"
            }
            try await refreshLibrary()
        } catch {
            statusMessage = L10n.error("Restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Library selection

    /// Attaches an existing PearSilicon library (for example on an external
    /// disk) without copying it. The folder is read-only until it is validated
    /// as one of our roots.
    func useExistingLibrary(at folder: URL) async {
        guard !isBusy else { return }
        guard runningGames.isEmpty, runningManagedEntries.isEmpty else {
            statusMessage = L10n.error("Stop every running app before switching libraries")
            return
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let candidate = StorageLocationStore.destinationRoot(in: folder)
        guard StorageLocationStore.hasMarker(at: candidate) else {
            statusMessage = L10n.error("\(candidate.path) is not a PearSilicon library")
            return
        }
        do {
            try StorageLocationStore.shared.commit(rootURL: candidate, previousRootURL: nil)
            reloadStorage()
            try await refreshLibrary()
            statusMessage = "Using library at \(candidate.path)"
        } catch {
            statusMessage = L10n.error("Could not use that library: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage

    /// Moves every app, save, keymap, ODR pack, keychain entry and log into a
    /// PearSilicon folder inside `folderURL` (for example on an external disk).
    /// The previous copy is kept until the user removes it explicitly.
    func changeStorageLocation(to folderURL: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishBusyWork() }
        do {
            let result = try await StorageMigration().move(to: folderURL) { message in
                Task { @MainActor in self.statusMessage = message }
            }
            reloadStorage()
            try await refreshLibrary()
            statusMessage = "Storage moved to \(result.rootURL.path). The previous copy was kept for rollback."
        } catch {
            statusMessage = L10n.error("Storage move failed: \(error.localizedDescription)")
        }
    }

    func removePreviousStorageCopy() async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishBusyWork() }
        do {
            try await StorageMigration().removePreviousCopy()
            previousStorageRootURL = StorageLocationStore.shared.previousRootURL
            statusMessage = "Previous storage copy removed"
        } catch {
            statusMessage = L10n.error(error.localizedDescription)
        }
    }

    /// After the app itself was updated, push the new runtime into every
    /// installed iOS app whose fingerprint differs. Only changed components are
    /// copied; each bundle is prepared and signed in a staged copy first.
    func refreshInstalledRuntimes() async {
        guard !isBusy else { return }
        guard runningGames.isEmpty, runningManagedEntries.isEmpty else {
            statusMessage = L10n.error("Stop every running app before refreshing runtimes")
            return
        }
        guard let source = AppLauncher.runtimeLibraryURL()?.deletingLastPathComponent() else {
            statusMessage = L10n.error("No runtime was found next to PearSilicon")
            return
        }
        isBusy = true
        defer { finishBusyWork() }
        var changed = 0
        var skipped = 0
        var failures: [String] = []
        for app in installedApps {
            await Task.yield()
            statusMessage = "Checking runtime: \(app.displayName)…"
            do {
                if try packageInstaller.refreshRuntimeIfNeeded(
                    for: app, sourceRuntimeDirectory: source
                ) {
                    changed += 1
                } else {
                    skipped += 1
                }
            } catch {
                failures.append("\(app.displayName): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            statusMessage = "Runtime refresh complete: \(changed) updated, \(skipped) already current"
        } else {
            statusMessage = L10n.error(
                "Runtime refresh: \(changed) updated, \(skipped) current, \(failures.count) failed. "
                + failures.prefix(2).joined(separator: " | ")
            )
        }
    }

    // MARK: - Install

    func install(packageURLs: [URL]) async {
        guard !packageURLs.isEmpty else { return }
        guard await acquireImportSlot() else { return }
        defer { releaseImportSlot() }

        for url in packageURLs {
            // Cancellation applies to this request only, and stops the remaining
            // packages in its batch. It never cancels the active predecessor.
            if Task.isCancelled { break }
            do {
                statusMessage = L10n.installing(url.lastPathComponent)

                // A native macOS .app dropped on either tab is routed to the
                // copy-only Mac library. Nonexistent test fixtures keep the
                // historical iOS-bundle path.
                if url.pathExtension.lowercased() == "app",
                   FileManager.default.fileExists(atPath: url.path),
                   (try? PortableLibrary.classify(url)) == .macOS {
                    _ = try await importMacApp(entry: url)
                    statusMessage = "Installed Mac app: \(url.deletingPathExtension().lastPathComponent)"
                    continue
                }

                let app = try await packageImports.install(at: url)

                // Auto-generate a starting keymap if the app has none yet.
                if try keymapStore.load(for: app.id) == nil {
                    try keymapStore.save(KeymapGenerator.generate(for: app))
                }

                statusMessage = L10n.installed(app.displayName)
            } catch {
                statusMessage = L10n.error("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        try? await refreshLibrary()
    }

    /// Runs the copy-only Mac importer off the main thread; a large bundle copy
    /// must not freeze the window.
    private func importMacApp(entry url: URL) async throws -> LibraryEntry {
        let root = storageRootURL
        let service = managedApps
        return try await Task.detached(priority: .userInitiated) {
            try service.importMacApp(from: url, libraryRoot: root)
        }.value
    }

    func importWindowsFolder(at url: URL, executablePath: String, engineID: String) async {
        guard await acquireImportSlot() else { return }
        defer { releaseImportSlot() }
        do {
            statusMessage = "Importing Windows game: \(url.lastPathComponent)"
            let root = storageRootURL
            let service = managedApps
            let entry = try await Task.detached(priority: .userInitiated) {
                try service.importWindowsFolder(
                    from: url, executablePath: executablePath, libraryRoot: root,
                    engineID: engineID, displayName: nil
                )
            }.value
            try await refreshLibrary()
            platform = .wine
            selectedManagedEntryID = entry.id
            statusMessage = "Installed Windows game: \(entry.displayName)"
        } catch {
            statusMessage = L10n.error("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func importWindowsExecutable(at url: URL, engineID: String) async {
        guard await acquireImportSlot() else { return }
        defer { releaseImportSlot() }
        do {
            statusMessage = "Importing Windows program: \(url.lastPathComponent)"
            let root = storageRootURL
            let service = managedApps
            let entry = try await Task.detached(priority: .userInitiated) {
                try service.importWindowsExecutable(
                    from: url, libraryRoot: root, engineID: engineID, displayName: nil
                )
            }.value
            try await refreshLibrary()
            platform = .wine
            selectedManagedEntryID = entry.id
            statusMessage = "Installed Windows program: \(entry.displayName) — \(ManagedAppService.windowsExecutableOnlyImportHint)"
        } catch {
            statusMessage = L10n.error("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Waits for the previous import to finish. Returns false when this request
    /// was cancelled while queued, so it must not touch the library.
    private func acquireImportSlot() async -> Bool {
        // Storage changes use the same busy flag. Never overlap them with an
        // import; the user can drop the package again once the move finishes.
        if importRunnerActive || isBusy {
            let id = UUID()
            let acquired = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || cancelledImportRequests.remove(id) != nil {
                        continuation.resume(returning: false)
                    } else {
                        importQueue.append(PendingPackageImport(id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelQueuedImport(id) }
            }
            guard acquired else { return false }
        } else {
            importRunnerActive = true
        }
        isBusy = true
        return true
    }

    private func cancelQueuedImport(_ id: UUID) {
        if let index = importQueue.firstIndex(where: { $0.id == id }) {
            importQueue.remove(at: index).continuation.resume(returning: false)
        } else {
            // The cancellation handler can run before the continuation body
            // enqueues the request; remember it so it never waits forever.
            cancelledImportRequests.insert(id)
        }
    }

    private func releaseImportSlot() {
        importRunnerActive = false
        finishBusyWork()
    }

    /// Ends one exclusive operation and immediately hands the busy state to the
    /// next queued import, if any. Used by both imports and storage migrations,
    /// because an import may arrive while a storage move still owns the flag.
    private func finishBusyWork() {
        guard !importRunnerActive else { return }
        guard !importQueue.isEmpty else {
            isBusy = false
            return
        }
        // Keep the busy flag set; the resumed request owns it now.
        importRunnerActive = true
        importQueue.removeFirst().continuation.resume(returning: true)
    }

    // MARK: - Launch / uninstall

    func launch(_ app: InstalledApp) async {
        // An import or storage move may be replacing files in the library. Do
        // not read a half-written bundle or race a preparation swap.
        guard !isBusy else { return }

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
            let launchLease = try AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
            defer { launchLease.release() }
            try AppLauncher.requireStopped(app)
            let mode: PreparationMode = packageInstaller.currentPreparationMode(for: app) == .compatibilityEnvironment
                ? .compatibilityEnvironment : .compatibility
            try packageInstaller.setPreparationMode(mode, for: app, launchLease: launchLease)
            let running = try await launcher.launch(
                app, keymapURL: keymapURL, extraEnvironment: extra,
                nativeContainer: nativeContainer, launchLease: launchLease
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
        guard !isBusy else { return }
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

    // MARK: - Wine engines

    func engine(id: String?) -> WineEngine? {
        guard let id else { return nil }
        return wineEngines.first { $0.id == id }
    }

    func registerEngine(
        from url: URL, id: String, name: String, version: String,
        executablePath: String, distribution: WineEngine.Distribution,
        licenseConfirmed: Bool
    ) async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishBusyWork() }
        do {
            let store = wineStore
            let engine = try await Task.detached(priority: .userInitiated) {
                try store.registerLocalEngine(
                    from: url, id: id, name: name, version: version,
                    executablePath: executablePath, distribution: distribution,
                    licenseConfirmed: licenseConfirmed
                )
            }.value
            reloadEngines()
            statusMessage = "Registered Wine engine \(engine.name)"
        } catch {
            statusMessage = L10n.error("Engine registration failed: \(error.localizedDescription)")
        }
    }

    func downloadEngine(from url: URL, sha256: String, licenseConfirmed: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishBusyWork() }
        do {
            statusMessage = "Downloading Wine engine…"
            let store = wineStore
            let file = try await store.downloadCommunityArchive(
                from: url, sha256: sha256, licenseConfirmed: licenseConfirmed
            )
            statusMessage = "Engine archive verified and saved: \(file.path). \(WineEngineStore.communityDownloadNotice)"
        } catch {
            statusMessage = L10n.error("Engine download failed: \(error.localizedDescription)")
        }
    }

    /// Explicit check of the open-source WineHQ release feed. No timer or
    /// automatic background download.
    func checkWineRelease(channel: WineReleaseChannel) async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishBusyWork() }
        do {
            statusMessage = "Checking open-source Wine releases…"
            let check = try await wineReleases.latest(channel: channel)
            wineReleaseCheck = check
            statusMessage = "Wine \(check.tag) is available (\(check.assetName))"
        } catch {
            wineReleaseCheck = nil
            statusMessage = L10n.error("Wine release check failed: \(error.localizedDescription)")
        }
    }

    func installWineRelease() async {
        guard !isBusy, let check = wineReleaseCheck else { return }
        isBusy = true
        defer { finishBusyWork() }
        do {
            let store = wineStore
            let engine = try await wineReleases.install(check, store: store) { message in
                Task { @MainActor [weak self] in self?.statusMessage = message }
            }
            reloadEngines()
            statusMessage = "Installed \(engine.name) \(engine.version)"
        } catch {
            statusMessage = L10n.error("Wine install failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Updates

    @Published var updateChannel: UpdateChannel = {
        UpdateChannel(rawValue: AppSettings.defaults.string(forKey: "update.channel") ?? "")
            ?? .developmentBeta
    }() {
        didSet { AppSettings.defaults.set(updateChannel.rawValue, forKey: "update.channel") }
    }

    /// Explicit user action only. Never runs on launch or on a timer.
    func checkForUpdates(channel: UpdateChannel? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishBusyWork() }
        let selected = channel ?? updateChannel
        updateChannel = selected
        do {
            statusMessage = "Checking GitHub releases…"
            let update = try await updater.checkForUpdates(channel: selected)
            availableUpdate = update
            if update.isUpdateAvailable {
                statusMessage = "Update available: \(update.release.tagName)"
            } else {
                statusMessage = "PearSilicon is up to date"
            }
        } catch {
            availableUpdate = nil
            statusMessage = L10n.error("Update check failed: \(error.localizedDescription)")
        }
    }

    /// Downloads and verifies the release, but never replaces a running app.
    /// The staged bundle is revealed for an explicit relaunch/replacement.
    func stageAvailableUpdate() async {
        guard !isBusy, let update = availableUpdate, update.isUpdateAvailable else { return }
        isBusy = true
        defer { finishBusyWork() }
        do {
            statusMessage = "Downloading and verifying update…"
            let staged = try await updater.stage(update)
            stagedUpdate = staged
            statusMessage = "Update verified and staged. Quit PearSilicon before replacing the app."
            NSWorkspace.shared.activateFileViewerSelecting([staged.bundleURL])
        } catch {
            statusMessage = L10n.error("Update download failed: \(error.localizedDescription)")
        }
    }

    /// Hands the verified staged app to a relaunch helper, then quits. The
    /// helper waits for this exact process, re-verifies both bundles, swaps
    /// atomically and keeps the previous app as a rollback copy.
    func installStagedUpdateAndRelaunch() async {
        guard let staged = stagedUpdate else { return }
        guard runningGames.isEmpty, runningManagedEntries.isEmpty else {
            statusMessage = L10n.error("Stop every running app before installing an update")
            return
        }
        guard let executable = Bundle.main.executableURL else {
            statusMessage = L10n.error("This build has no executable path for the relaunch helper")
            return
        }
        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "apply-update",
                "--source", staged.bundleURL.path,
                "--parent-pid", String(getpid()),
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            statusMessage = "Installing update and relaunching…"
            try await Task.sleep(for: .milliseconds(600))
            NSApplication.shared.terminate(nil)
        } catch {
            statusMessage = L10n.error("Could not start the update helper: \(error.localizedDescription)")
        }
    }
}
