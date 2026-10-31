import AppKit
import SwiftUI

/// Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var removingPreviousCopy = false
    @State private var showingEngineSheet = false

    // Engine registration form.
    @State private var engineFolder: URL?
    @State private var engineID = ""
    @State private var engineName = ""
    @State private var engineVersion = "user-supplied"
    @State private var engineExecutablePath = "bin/wine64"
    @State private var engineLicenseConfirmed = false
    @State private var wineChannel: WineReleaseChannel = .staging

    // Community download form.
    @State private var downloadURL = ""
    @State private var downloadSHA256 = ""
    @State private var downloadLicenseConfirmed = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            library.tabItem { Label("Library", systemImage: "square.stack.3d.up") }
            wine.tabItem { Label("Wine", systemImage: "gamecontroller") }
            updates.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            keymapper.tabItem { Label("Keymapper", systemImage: "keyboard") }
        }
        .frame(width: 700, height: 580)
        .padding()
        .sheet(isPresented: $showingEngineSheet) { engineSheet }
    }

    // MARK: - General

    private var general: some View {
        Form {
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
                    if state.previousStorageRootURL != nil {
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

            Section("Portable layout") {
                Text("ios-apps, mac-apps and wine-apps are created only when the matching platform has its first item. Existing apps in the older Applications folder are still listed and keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Library warnings") {
                if state.libraryWarnings.isEmpty {
                    Text("No warnings.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.libraryWarnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
            Section("Open-source Wine — automatic") {
                Picker("Channel", selection: $wineChannel) {
                    ForEach(WineReleaseChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                Button("Check Latest Release") {
                    Task { await state.checkWineRelease(channel: wineChannel) }
                }
                .disabled(state.isBusy)
                if let check = state.wineReleaseCheck {
                    LabeledContent("Version", value: check.tag)
                    LabeledContent("Asset", value: check.assetName)
                    if check.size > 0 {
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: check.size, countStyle: .file))
                    }
                    LabeledContent("SHA-256") {
                        Text(check.sha256)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Download and Install") {
                        Task { await state.installWineRelease() }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(state.isBusy)
                }
                Text(WineEngineStore.openSourceNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Registered engines") {
                if state.wineEngines.isEmpty {
                    Text("No Wine engine registered. Check for an open-source build above or add a custom runtime.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.wineEngines) { engine in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(engine.name) \(engine.version)").font(.callout.weight(.medium))
                            Text("\(engine.distribution.rawValue) • \(engine.executableURL.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
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

            Section("Advanced: verified community archive") {
                Text(WineEngineStore.communityDownloadNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("HTTPS archive URL", text: $downloadURL)
                TextField("SHA-256 (64 hex characters)", text: $downloadSHA256)
                Toggle("I reviewed the engine license", isOn: $downloadLicenseConfirmed)
                Button("Download and Verify") {
                    guard let url = URL(string: downloadURL) else { return }
                    Task { await state.downloadEngine(from: url, sha256: downloadSHA256, licenseConfirmed: downloadLicenseConfirmed) }
                }
                .disabled(state.isBusy || !downloadLicenseConfirmed)
            }

            Section("How games are stored") {
                Text("Each Windows game gets Payload, Data and Prefix directories. Saves stay with the game and are included in its backup. Host drive mappings are removed; the launch is sandboxed. This is not a virtual machine and cannot run kernel-level anti-cheat. The macOS WineHQ packages are currently osx64; Apple silicon may require Rosetta 2.")
                    .font(.caption)
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
            Section("Release channel") {
                Picker("Channel", selection: Binding(
                    get: { state.updateChannel },
                    set: { state.updateChannel = $0 }
                )) {
                    Text("Development beta").tag(UpdateChannel.developmentBeta)
                    Text("Stable release").tag(UpdateChannel.stable)
                }
                .pickerStyle(.segmented)
                Button("Check for Updates") {
                    Task { await state.checkForUpdates(channel: state.updateChannel) }
                }
                .disabled(state.isBusy)
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

            Section("Runtime updates") {
                Text("After installing a new PearSilicon build, iOS apps keep their own runtime copy. This action checks every stopped iOS app and updates only those whose runtime fingerprint differs. Each bundle is prepared and re-signed in a staged copy first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh iOS Runtimes Now") {
                    Task { await state.refreshInstalledRuntimes() }
                }
                .disabled(state.isBusy)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Keymapper

    private var keymapper: some View {
        Form {
            Section {
                Toggle("Enable keymapper for new games by default",
                       isOn: $state.keymapperDefaultEnabled)
                Text("Keyboard/mouse keymapping is off unless enabled. Each iOS app has "
                     + "its own switch in the Keymap tab; changing it takes effect "
                     + "on the next launch. Mac and Wine games do not use the iOS keymapper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Repeat-rate protection: always on")
                    .font(.body.weight(.medium))
                Text("The keymapper drops presses less than 120 ms apart for the same key "
                     + "or 40 ms apart across keys. Releases are not rate-limited. "
                     + "This limits rapid repeats; it does not detect or prevent macros. "
                     + "The limits are not configurable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
