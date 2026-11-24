import AppKit
import SwiftUI

/// Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmingCleanStart = false
    @State private var removingPreviousCopy = false
    @State private var showingEngineSheet = false

    // Engine registration form.
    @State private var engineFolder: URL?
    @State private var engineID = ""
    @State private var engineName = ""
    @State private var engineVersion = "user-supplied"
    @State private var engineExecutablePath = "bin/wine64"
    @State private var engineLicenseConfirmed = false

    // Community download form.
    @State private var downloadURL = ""
    @State private var downloadLicenseConfirmed = false

    // Engine removal confirmation.
    @State private var engineToRemove: WineEngine?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            ControllerSettingsView().tabItem { Label("Controllers", systemImage: "gamecontroller.fill") }
            library.tabItem { Label("Library", systemImage: "square.stack.3d.up") }
            wine.tabItem { Label("Wine", systemImage: "gamecontroller") }
            updates.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 460, idealWidth: 620, minHeight: 380, idealHeight: 540)
        .sheet(isPresented: $showingEngineSheet) { engineSheet }
        .alert(
            "Remove Wine engine?",
            isPresented: Binding(
                get: { engineToRemove != nil },
                set: { if !$0 { engineToRemove = nil } }
            ),
            presenting: engineToRemove
        ) { engine in
            Button("Remove", role: .destructive) {
                engineToRemove = nil
                Task { await state.removeWineEngine(engine) }
            }
            Button("Cancel", role: .cancel) { engineToRemove = nil }
        } message: { engine in
            Text("\(engine.name) \(engine.version) will be deleted. Game data and prefixes are not removed; games that used it must be relinked to another engine.")
        }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Input") {
                Toggle("Enable keymapper for new games by default", isOn: $state.keymapperDefaultEnabled)
            }

            Section("Downloaded Mac apps") {
                Toggle("Automatically allow imported Mac apps", isOn: $state.autoApproveImportedMacApps)
                Text("Off by default. When enabled, PearSilicon removes the macOS download quarantine flag from each imported Mac app copy. This is the same one-time approval macOS asks for in Privacy & Security, but it is applied automatically to apps you import. It does not notarize the app, and absolute host paths remain reachable. Only enable it for sources you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Privacy & Security") {
                    state.openPrivacySecuritySettings()
                }
            }
        }
        .formStyle(.grouped)

    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Storage Here"
        panel.message = "Choose a destination folder. The previous copy is kept for rollback."
        panel.directoryURL = state.storageRootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.changeStorageLocation(to: url) }
    }

    // MARK: - Library

    private var library: some View {
        Form {
            Section("Use an existing library") {
                Button("Open Existing Library…") { chooseExistingLibrary() }
                    .disabled(state.isBusy)
                Text("Select a PearSilicon folder (or a disk containing one) to open its apps, games and saves in place. Nothing is copied. A folder is only accepted when it carries the .pear-storage-root marker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage folder") {
                LabeledContent("Root") {
                    Text(state.storageRootURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("iOS library") {
                    Text(state.libraryURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("Previous copy") {
                    Text(state.previousStorageRootURL?.path ?? "none")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Move Storage…") { chooseStorageFolder() }
                        .disabled(state.isBusy)
                    if let previous = state.previousStorageRootURL,
                       previous.standardizedFileURL != state.storageRootURL.standardizedFileURL {
                        Button("Remove Previous Copy…", role: .destructive) {
                            removingPreviousCopy = true
                        }
                        .disabled(state.isBusy)
                    }
                }
                Text("A move copies apps, saves, keymaps, ODR, keychain data, Mac app data and Wine prefixes, verifies the copy, then switches over. The previous copy is kept until you remove it. Close every game first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clean start") {
                Button("Reset PearSilicon Library…", role: .destructive) { confirmingCleanStart = true }
                    .disabled(state.isBusy)
                Text("Deletes all apps, saves, downloads, retained saves, Wine engines and prefixes in the current library. The external disk and files outside this library are preserved. Close all apps first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("iOS runtimes") {
                Button("Refresh iOS Runtimes Now") {
                    Task { await state.refreshInstalledRuntimes() }
                }
                .buttonStyle(.glass)
                .disabled(state.isBusy || state.iOSAppsLockedForRuntimeRefresh)
                if let progress = state.runtimeRefresh {
                    ProgressView(value: progress.fraction) {
                        Text("Refreshing \(progress.current) (\(progress.done)/\(progress.total))")
                    }
                } else if let result = state.runtimeRefreshStatus {
                    Text(result).font(.caption).textSelection(.enabled)
                }
                Text("PearHost is refreshed automatically after a PearSilicon update.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !state.libraryWarnings.isEmpty {
                Section("Library warnings") {
                    ForEach(Array(state.libraryWarnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Start from scratch? All library data will be permanently deleted.", isPresented: $confirmingCleanStart) {
            Button("Delete Everything and Reset", role: .destructive) { Task { await state.cleanStart() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove the previous storage copy? This cannot be undone.",
            isPresented: $removingPreviousCopy
        ) {
            Button("Remove Previous Copy", role: .destructive) {
                Task { await state.removePreviousStorageCopy() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.previousStorageRootURL?.path ?? "")
        }
    }

    private func chooseExistingLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Library"
        panel.message = "Choose a PearSilicon storage root or a disk that contains one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.useExistingLibrary(at: url) }
    }

    // MARK: - Wine

    private var wine: some View {
        Form {
            Section("Wine updates") {
                if let installed = state.wineEngines.first {
                    LabeledContent("Installed version", value: installed.version)
                }
                Button("Check for Wine Updates") {
                    Task { await state.checkForMetalSharpUpdate() }
                }
                .buttonStyle(.glass)
                .disabled(state.isBusy)
                if let update = state.metalSharpUpdate {
                    Button(state.wineEngines.isEmpty ? "Install \(update.version)" : "Update to \(update.version)") {
                        Task { await state.applyMetalSharpUpdate() }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(state.isBusy || state.runningManagedEntries.contains { $0.platform == .wine })
                }
                if let status = state.wineUpdateStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Wine engines for Apple silicon") {
                WineDistributionList(
                    action: { distribution in
                        Task { _ = await state.installWineDistribution(distribution) }
                    },
                    actionTitle: { _, installed in installed ? "Installed" : "Install" },
                    allowsInstalledSelection: false
                )
                Text("Windows games use MetalSharp Wine. PearSilicon installs it automatically when you add your first Windows game.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Registered engines") {
                if state.wineEngines.isEmpty {
                    Text("No Wine engine installed yet. MetalSharp Wine is installed automatically when you add a Windows game, or install it above now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.wineEngines) { engine in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(engine.name) \(engine.version)").font(.callout.weight(.medium))
                                Text("\(engine.distribution.rawValue) • \(engine.executableURL.path)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Button(role: .destructive) {
                                engineToRemove = engine
                            } label: {
                                Label("Remove", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.glass)
                            .help("Remove this Wine engine (game prefixes are kept)")
                            .disabled(state.isBusy)
                        }
                    }
                }
                HStack {
                    Button("Add Local Engine…") { showingEngineSheet = true }
                        .disabled(state.isBusy)
                    Button("Open Engines Folder") {
                        let folder = state.storageRootURL.appendingPathComponent("Engines", isDirectory: true)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }

            Section("Community engine from GitHub") {
                Text(CommunityWineService.notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://github.com/owner/repo", text: $downloadURL)
                Toggle("I reviewed the engine license", isOn: $downloadLicenseConfirmed)
                Button("Download Latest") {
                    Task {
                        await state.downloadCommunityEngine(
                            from: downloadURL, licenseConfirmed: downloadLicenseConfirmed
                        )
                    }
                }
                .disabled(state.isBusy || !downloadLicenseConfirmed)
                Text("The newest release archive is selected automatically. If the repository has no release, its source ZIP is downloaded and extracted. A hash is not requested; GitHub's published digest is checked when present.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }


        }
        .formStyle(.grouped)
    }

    private var engineSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Register a Wine engine").font(.title3.weight(.semibold))
            Text("PearSilicon copies the chosen runtime into its Engines folder. It never executes the engine or accepts a license for you.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("Runtime folder") {
                    HStack {
                        Text(engineFolder?.path ?? "not selected")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseEngineFolder() }
                    }
                }
                TextField("Identifier", text: $engineID)
                TextField("Display name", text: $engineName)
                TextField("Version", text: $engineVersion)
                TextField("Native Wine executable (relative to folder)", text: $engineExecutablePath)
                Toggle("I reviewed this engine's license", isOn: $engineLicenseConfirmed)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { showingEngineSheet = false }
                Button("Register") {
                    guard let folder = engineFolder else { return }
                    let id = engineID
                    let name = engineName
                    let version = engineVersion
                    let executable = engineExecutablePath
                    let license = engineLicenseConfirmed
                    showingEngineSheet = false
                    Task {
                        await state.registerEngine(
                            from: folder, id: id, name: name, version: version,
                            executablePath: executable, distribution: .community,
                            licenseConfirmed: license
                        )
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(engineFolder == nil || engineID.isEmpty || engineName.isEmpty || !engineLicenseConfirmed)
            }
        }
        .padding(22)
        .frame(width: 600, height: 520)
    }

    private func chooseEngineFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Runtime"
        panel.message = "Choose a self-contained Wine runtime directory."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engineFolder = url
        if engineID.isEmpty {
            engineID = url.lastPathComponent.lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }
        if engineName.isEmpty { engineName = url.lastPathComponent }
        for candidate in ["bin/wine64", "wine64", "bin/wine", "wine"] {
            if FileManager.default.isExecutableFile(atPath: url.appendingPathComponent(candidate).path) {
                engineExecutablePath = candidate
                break
            }
        }
    }

    // MARK: - Updates

    private var updates: some View {
        Form {
            Section("Updates") {
                LabeledContent("Current version", value: "Development Beta")
                LabeledContent("Version", value: Self.appVersion)
                Button("Check for Updates") {
                    Task { await state.checkForUpdates() }
                }
                .disabled(state.isBusy)
                Toggle("Update automatically", isOn: $state.automaticUpdatesEnabled)
                if let status = state.automaticUpdateStatus {
                    Text(status)
                        .font(.caption)
                }
                Text("PearSilicon follows the development release channel. With automatic updates on, it checks at launch and every six hours, downloads and verifies a new build in the background, and installs it with a relaunch once no game or app is running. After an update, macOS may ask you to allow the new build in System Settings → Privacy & Security (Open Anyway), because PearSilicon is not notarized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let update = state.availableUpdate {
                Section("Available release") {
                    LabeledContent("Tag", value: update.release.tagName)
                    LabeledContent("Asset", value: update.asset.name)
                    LabeledContent("Status", value: update.isUpdateAvailable
                        ? "New build available (\(update.reason?.rawValue ?? "unknown"))"
                        : "Up to date")
                    if update.isUpdateAvailable {
                        Button("Download and Verify") {
                            Task { await state.stageAvailableUpdate() }
                        }
                        .disabled(state.isBusy)
                    }
                }
            }

            if let staged = state.stagedUpdate {
                Section("Staged update") {
                    Text(staged.bundleURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Reveal Staged App in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([staged.bundleURL])
                    }
                    Button("Install and Relaunch PearSilicon") {
                        Task { await state.installStagedUpdateAndRelaunch() }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(state.isBusy)
                    Text("The download was verified against GitHub's SHA-256 and the app's signature. The helper waits for this app to quit, verifies the staged and installed bundles again, swaps them atomically, and keeps the previous app as a rollback copy. Save your work before continuing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }


        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var about: some View {
        PearAboutView(version: Self.appVersion)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

struct PearAboutView: View {
    let version: String

    var body: some View {
        ScrollView {
            VStack(spacing: 15) {
                PearBrand.logo
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(.rect(cornerRadius: 22))
                VStack(spacing: 6) {
                    Text("PearSilicon").font(.largeTitle.weight(.semibold))
                    Text(version).font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("iOS, Mac and Windows games on Apple silicon")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(36)
            .frame(maxWidth: 440)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
            .padding(30)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .frame(maxHeight: .infinity)
    }

}
