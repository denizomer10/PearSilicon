import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window: a Liquid Glass platform switch, a library sidebar and a detail
/// pane. The three platforms share one window but never share launch rules:
/// iOS apps keep the compatibility runtime, Mac apps run compiled-for-macOS
/// bundles, and Wine games run in private prefixes.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var importInProgress = false
    @State private var wineExecutablePicker: WineExecutablePicker?
    @State private var wineExecutableChoice: CheckedContinuation<String?, Never>?
    @State private var chosenExecutable: String?

    var body: some View {
        VStack(spacing: 0) {
            libraryControls
            Divider()
            GeometryReader { geometry in
                let sidebarWidth = min(300, max(200, geometry.size.width * 0.23))
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(.regularMaterial)
                    Divider()
                    detail(width: max(0, geometry.size.width - sidebarWidth - 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { backdrop }
                }
                .clipped()
            }
            StatusBar(message: state.statusMessage, busy: state.isBusy, storageConnected: state.storageConnected,
                      runtimeRefresh: state.runtimeRefresh, wineEngineInstall: state.wineEngineInstall)
        }
        .navigationTitle("PearSilicon")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Backup Selected…") { beginBackup() }
                        .disabled(selectedForBackup == nil)
                    Button("Restore Backup…") { beginRestore(replacing: false) }
                    Button("Restore and Replace Existing…") { beginRestore(replacing: true) }
                } label: {
                    Label("Backup", systemImage: "externaldrive")
                }
                .disabled(state.isBusy)

                Button(action: beginImport) {
                    Label("Add Apps", systemImage: "plus")
                }
                .disabled(state.isBusy || importInProgress)
                .help("Add iOS, Mac, or Windows apps")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { await handleDrop(providers) }
            return true
        }
        .sheet(item: $wineExecutablePicker, onDismiss: finishExecutableChoice) { picker in
            WineExecutableSelectionView(
                folder: picker.folder,
                candidates: picker.executables
            ) { executable in
                chosenExecutable = executable
                wineExecutablePicker = nil
            } onCancel: {
                wineExecutablePicker = nil
            }
        }
        .sheet(item: $state.wineEngineChoiceEntry) { entry in
            WineEngineChooserSheet(entry: entry)
                .environmentObject(state)
        }
        .sheet(item: $state.wineInstalledProgramChoice) { entry in
            WineExecutableSelectionView(folder: entry.directoryURL, candidates: WineInstallation.candidates(entry), importTitle: "Use Installed Application") { path in
                state.setWineExecutable(path, for: entry)
                state.wineInstalledProgramChoice = nil
            } onCancel: { state.wineInstalledProgramChoice = nil }
        }
        .confirmationDialog(
            "Allow this downloaded app?",
            isPresented: Binding(
                get: { state.pendingQuarantineEntry != nil },
                set: { if !$0 { state.clearPendingQuarantine() } }
            )
        ) {
            if let entry = state.pendingQuarantineEntry {
                Button("Allow This App") {
                    state.allowQuarantinedApp(entry)
                }
                Button("Open Privacy & Security") {
                    state.openPrivacySecuritySettings()
                }
                Button("Later", role: .cancel) {
                    state.clearPendingQuarantine()
                }
            }
        } message: {
            Text("macOS attached a download quarantine flag to this imported copy. PearSilicon does not remove it silently. Allow it only if you trust the source; this does not notarize the app.")
        }
    }

    private var backdrop: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                RadialGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.09), .clear],
                               center: .topTrailing, startRadius: 10, endRadius: 560)
            }
    }

    private var libraryControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                storageSwitch.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                platformSwitch.fixedSize()
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) { storageSwitch }
                    .scrollIndicators(.hidden)
                platformSwitch.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var storageSwitch: some View {
        let switchingBlocked = state.isBusy || state.iOSAppsLockedForRuntimeRefresh || !state.runningGameNames.isEmpty
        return HStack(spacing: 3) {
            ForEach(state.storageLocations) { location in
                let selected = location.rootURL.standardizedFileURL == state.storageRootURL.standardizedFileURL
                Button {
                    Task { await state.selectStorageLocation(location) }
                } label: {
                    Label(location.name, systemImage: location.kind == .internal ? "internaldrive" : "externaldrive")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: location.kind == .internal ? 145 : 115)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if selected { Capsule().fill(.primary.opacity(0.11)) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(selected ? .semibold : .medium))
                .disabled(!selected && switchingBlocked)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(location.rootURL.path)
            }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage location")
    }

    private var platformSwitch: some View {
        HStack(spacing: 3) {
            ForEach(LibraryPlatform.allCases) { platform in
                let selected = state.platform == platform
                Button {
                    state.platform = platform
                } label: {
                    Label(platform.title, systemImage: platform.symbol)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            if selected { Capsule().fill(.primary.opacity(0.11)) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Platform")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(state.platform == .wine ? "Search Wine apps" : "Search apps", text: $state.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            ScrollView {
                LazyVStack(spacing: 6) {
                    if state.platform == .iOS {
                        iosRows
                    } else {
                        managedRows
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)

            if !state.libraryWarnings.isEmpty {
                Text("\(state.libraryWarnings.count) library warning(s)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(state.libraryWarnings.joined(separator: "\n"))
            }
        }
        .padding(14)

    }

    @ViewBuilder
    private var iosRows: some View {
        let apps = filtered(state.installedApps)
        if apps.isEmpty {
            emptySidebar(
                title: state.searchText.isEmpty ? "No iOS apps" : "No matching apps",
                detail: state.searchText.isEmpty ? "Drop an .ipa here or click + to install one." : "Try a different search."
            )
        } else {
            ForEach(apps) { app in
                Button {
                    state.select(app)
                } label: {
                    rowContainer(selected: state.selection == app.id) {
                        AppRowView(app: app)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L10n.launch) { Task { await state.launch(app) } }
                    if state.isRunning(app) {
                        Button("Stop", role: .destructive) { state.stop(app) }
                    }
                    Button("Backup…") { beginBackup(app) }
                    Button(L10n.revealInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
                    }
                    Divider()
                    Button(L10n.uninstall, role: .destructive) { state.uninstall(app) }
                }
            }
        }
    }

    @ViewBuilder
    private var managedRows: some View {
        let entries = filtered(state.platformEntries)
        if entries.isEmpty {
            emptySidebar(
                title: !state.searchText.isEmpty ? "No matching results" : (state.platform == .macOS ? "No Mac apps" : "No Wine games"),
                detail: !state.searchText.isEmpty ? "Try a different search." : state.platform == .macOS
                    ? "Drop a native .app here or click + to copy one into the library."
                    : (state.wineEngines.isEmpty
                       ? "Add a Windows game with +. MetalSharp Wine is downloaded and installed automatically."
                       : "Add a Windows game folder or executable with +.")
            )
        } else {
            ForEach(entries) { entry in
                Button {
                    state.select(entry)
                } label: {
                    rowContainer(selected: state.selectedManagedEntryID == entry.id) {
                        ManagedAppRowView(entry: entry)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L10n.launch) { Task { await state.launch(entry) } }
                    if state.isRunning(entry) {
                        Button("Stop", role: .destructive) { state.stop(entry) }
                    }
                    Button("Backup…") { beginBackup(entry) }
                    Button(L10n.revealInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.directoryURL])
                    }
                    Divider()
                    Button(L10n.uninstall, role: .destructive) { state.uninstall(entry) }
                }
            }
        }
    }

    private func rowContainer<Content: View>(
        selected: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptySidebar(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func filtered(_ apps: [InstalledApp]) -> [InstalledApp] {
        guard !state.searchText.isEmpty else { return apps }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(state.searchText) }
    }

    private func filtered(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        guard !state.searchText.isEmpty else { return entries }
        return entries.filter { $0.displayName.localizedCaseInsensitiveContains(state.searchText) }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(width: CGFloat) -> some View {
        switch state.platform {
        case .iOS:
            if let app = state.selectedApp {
                AppDetailView(app: app, availableWidth: width)
                    .id(app.id)
            } else {
                placeholder
            }
        case .macOS, .wine:
            if let entry = state.selectedManagedEntry {
                ManagedAppDetailView(entry: entry, availableWidth: width)
                    .id(entry.id)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Select an item", systemImage: state.platform.symbol)
        } actions: {
            Button("Add Apps", action: beginImport)
                .buttonStyle(.glass)
                .disabled(state.isBusy || importInProgress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Import

    private func beginImport() {
        guard !state.isBusy, !importInProgress else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle] + ["ipa", "exe"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an iOS .ipa, an .app bundle, a Windows .exe, or a Windows program folder."
        panel.prompt = "Add"

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { Task { await importItems(panel.urls) } }
            }
        } else if panel.runModal() == .OK {
            Task { await importItems(panel.urls) }
        }
    }

    private func importItems(_ urls: [URL]) async {
        guard !state.isBusy, !importInProgress else { return }
        importInProgress = true
        defer { importInProgress = false }
        await state.importItems(at: urls) { folder, candidates in
            await withCheckedContinuation { continuation in
                wineExecutableChoice = continuation
                wineExecutablePicker = WineExecutablePicker(folder: folder, executables: candidates)
            }
        }
    }

    private func finishExecutableChoice() {
        let continuation = wineExecutableChoice
        let choice = chosenExecutable
        wineExecutableChoice = nil
        chosenExecutable = nil
        continuation?.resume(returning: choice)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) async {
        guard !state.isBusy else { return }
        var urls: [URL] = []
        for provider in providers {
            guard let item = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier, options: nil
            ) else { continue }
            let url = (item as? URL)
                ?? (item as? NSURL).map { $0 as URL }
                ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url, url.isFileURL else { continue }
            urls.append(url)
        }
        if !urls.isEmpty {
            await importItems(urls)
        } else if !providers.isEmpty {
            state.statusMessage = L10n.error("Drop a local .ipa, .app, .exe, or Windows program folder to add it")
        }
    }

    // MARK: - Backup

    private var selectedForBackup: Any? {
        switch state.platform {
        case .iOS: state.selectedApp
        case .macOS, .wine: state.selectedManagedEntry
        }
    }

    private func beginBackup() {
        switch state.platform {
        case .iOS:
            if let app = state.selectedApp { beginBackup(app) }
        case .macOS, .wine:
            if let entry = state.selectedManagedEntry { beginBackup(entry) }
        }
    }

    private func beginBackup(_ app: InstalledApp) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pearbackup") ?? .data]
        panel.nameFieldStringValue = "\(app.displayName).pearbackup"
        panel.message = LibraryBackupService.privacyWarning
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.backup(app, to: url) }
    }

    private func beginBackup(_ entry: LibraryEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pearbackup") ?? .data]
        panel.nameFieldStringValue = "\(entry.displayName).pearbackup"
        panel.message = LibraryBackupService.privacyWarning
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.backup(entry, to: url) }
    }

    private func beginRestore(replacing: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pearbackup") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = replacing
            ? "The restored app replaces an installed app with the same identifier. The old copy is kept under Work/RestoreRollback."
            : "Existing apps are never overwritten."
        panel.prompt = "Restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.restoreBackup(from: url, replacing: replacing) }
    }
}

private struct WineExecutablePicker: Identifiable {
    let id = UUID()
    let folder: URL
    let executables: [WineExecutableCandidate]
}

/// Bottom status bar rendered as a glass strip.
struct StatusBar: View {
    let message: String
    let busy: Bool
    var storageConnected: Bool = true
    var runtimeRefresh: AppState.RuntimeRefreshProgress? = nil
    var wineEngineInstall: AppState.WineEngineInstallProgress? = nil

    var body: some View {
        HStack(spacing: 8) {
            Label(storageConnected ? "Disk connected" : "Disk disconnected",
                  systemImage: storageConnected ? "externaldrive.badge.checkmark" : "externaldrive.badge.xmark")
                .foregroundStyle(storageConnected ? Color.secondary : Color.orange)
                .font(.callout)
            Divider().frame(height: 14)
            if let install = wineEngineInstall {
                // Bottom-left: Wine engine download for Windows games.
                HStack(spacing: 8) {
                    if let fraction = install.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(minWidth: 38, maxWidth: 92)
                        Text("\(install.phase) \(Int((fraction * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(install.phase).font(.callout).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Installing \(install.name)")
                Divider().frame(height: 14)
            }
            if let refresh = runtimeRefresh {
                // Bottom-left: background iOS runtime update after a
                // PearSilicon update. The rest of the window stays usable.
                HStack(spacing: 8) {
                    ProgressView(value: refresh.fraction)
                        .progressViewStyle(.linear)
                        .frame(minWidth: 38, maxWidth: 92)
                    Text("Updating iOS apps \(min(refresh.done + 1, refresh.total))/\(refresh.total)"
                         + (refresh.current.isEmpty ? "" : " · \(refresh.current)"))
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Updating iOS apps to the new runtime")
                Divider().frame(height: 14)
            }
            if busy {
                ProgressView().controlSize(.small)
            }
            Text(message)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}
