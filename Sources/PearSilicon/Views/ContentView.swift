import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window: a Liquid Glass platform switch, a library sidebar and a detail
/// pane. The three platforms share one window but never share launch rules:
/// iOS apps keep the compatibility runtime, Mac apps run compiled-for-macOS
/// bundles, and Wine games run in private prefixes.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingImporter = false
    @State private var wineExecutablePicker: WineExecutablePicker?
    @State private var alert: AlertPayload?

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topBar
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 1)
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 310)
                    Rectangle()
                        .fill(.white.opacity(0.06))
                        .frame(width: 1)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                StatusBar(message: state.statusMessage, busy: state.isBusy)
            }
        }
        .frame(minWidth: 1040, minHeight: 660)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await state.install(packageURLs: urls) }
            case .failure(let error):
                state.statusMessage = L10n.error(error.localizedDescription)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { await handleDrop(providers) }
            return true
        }
        .sheet(item: $wineExecutablePicker) { picker in
            WineExecutableSelectionView(
                folder: picker.folder,
                candidates: picker.executables
            ) { executable in
                wineExecutablePicker = nil
                Task {
                    await state.importWindowsFolder(
                        at: picker.folder, executablePath: executable, engineID: picker.engineID
                    )
                }
            } onCancel: {
                wineExecutablePicker = nil
            }
        }
        .alert(item: $alert) { payload in
            Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("OK")))
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
        LinearGradient(
            colors: [Color(red: 0.05, green: 0.07, blue: 0.12), Color(red: 0.02, green: 0.03, blue: 0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 520, height: 520)
                .blur(radius: 160)
                .offset(x: 160, y: -240)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(colors: [.mint, .cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("PearSilicon")
                    .font(.title3.weight(.semibold))
            }
            .frame(width: 225, alignment: .leading)

            Spacer(minLength: 8)
            platformSwitch
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button {
                    beginImport()
                } label: {
                    Label(installLabel, systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .disabled(state.isBusy)

                Menu {
                    Button("Backup Selected…") { beginBackup() }
                        .disabled(selectedForBackup == nil)
                    Button("Restore Backup…") { beginRestore(replacing: false) }
                    Button("Restore and Replace Existing…") { beginRestore(replacing: true) }
                } label: {
                    Label("Backup", systemImage: "externaldrive")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(state.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial.opacity(0.35))
    }

    private var platformSwitch: some View {
        HStack(spacing: 4) {
            ForEach(LibraryPlatform.allCases) { platform in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { state.platform = platform }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: platform.symbol)
                        Text(platform.title)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.platform == platform ? .primary : .secondary)
                .background {
                    if state.platform == platform {
                        Capsule()
                            .fill(.white.opacity(0.14))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                    }
                }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(state.platform == .wine ? "Search games" : "Search apps", text: $state.searchText)
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
                title: "No iOS apps",
                detail: "Drop an .ipa here or click + to install one."
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
                title: state.platform == .macOS ? "No Mac apps" : "No Wine games",
                detail: state.platform == .macOS
                    ? "Drop a native .app here or click + to copy one into the library."
                    : (state.wineEngines.isEmpty
                       ? "Register a Wine engine in Settings, then add a Windows game."
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
                    .fill(selected ? Color.white.opacity(0.12) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Color.white.opacity(0.14) : Color.clear, lineWidth: 1)
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
    private var detail: some View {
        switch state.platform {
        case .iOS:
            if let app = state.selectedApp {
                AppDetailView(app: app)
                    .id(app.id)
            } else {
                placeholder
            }
        case .macOS, .wine:
            if let entry = state.selectedManagedEntry {
                ManagedAppDetailView(entry: entry)
                    .id(entry.id)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            state.platform == .iOS ? "Select an iOS app"
                : (state.platform == .macOS ? "Select a Mac app" : "Select a Wine game"),
            systemImage: state.platform.symbol,
            description: Text(state.platform == .wine
                ? "Windows games run in a private prefix with their saves stored in the game's own folder."
                : "Click + to install, or drop a package into the window.")
        )
    }

    // MARK: - Import

    private var installLabel: String {
        switch state.platform {
        case .iOS: "Add iOS App"
        case .macOS: "Add Mac App"
        case .wine: "Add Windows Game"
        }
    }

    private var importTypes: [UTType] {
        switch state.platform {
        case .iOS:
            return ["ipa", "app"].compactMap { UTType(filenameExtension: $0) } + [.data]
        case .macOS:
            return [.applicationBundle, .application]
        case .wine:
            return [.data]
        }
    }

    private func beginImport() {
        switch state.platform {
        case .iOS:
            showingImporter = true
        case .macOS:
            showingImporter = true
        case .wine:
            addWindowsGame()
        }
    }

    private func addWindowsGame() {
        guard let engine = state.wineEngines.first else {
            alert = AlertPayload(
                title: "No Wine engine",
                message: "Register an open-source Wine engine in Settings before adding a Windows game. PearSilicon can download the latest WineHQ Stable, Staging or Development build for you."
            )
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the game's program folder (recommended) or a single .exe. An executable-only import does not include DLLs or assets."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "exe" else {
                alert = AlertPayload(title: "Unsupported file", message: "Choose a Windows .exe or a program folder.")
                return
            }
            Task { await state.importWindowsExecutable(at: url, engineID: engine.id) }
            return
        }

        let candidates = WineExecutableDiscovery.candidates(in: url)
        if candidates.isEmpty {
            // A common dead end: the game was already imported and the original
            // download folder is now empty. Take the user to the existing entry
            // instead of asking for a path again.
            if let existing = state.wineEntry(withID: url.lastPathComponent) {
                state.platform = .wine
                state.select(existing)
                alert = AlertPayload(
                    title: "Already in your library",
                    message: "This folder has no executable because \u{201C}\(existing.displayName)\u{201D} is already imported. It is selected in the Wine list; press Launch."
                )
            } else {
                alert = AlertPayload(
                    title: "No executable found",
                    message: "This folder does not contain a Windows .exe. Choose the folder that contains the game program, or select the .exe itself. If you already added this game, open the Wine tab and select it instead."
                )
            }
        } else if candidates.count == 1 {
            Task {
                await state.importWindowsFolder(
                    at: url, executablePath: candidates[0].path, engineID: engine.id
                )
            }
        } else {
            wineExecutablePicker = WineExecutablePicker(
                folder: url, executables: candidates, engineID: engine.id
            )
        }
    }

    // MARK: - Drop

    private static let packageExtensions: Set<String> = ["ipa", "app"]

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
            guard let url, Self.packageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            urls.append(url)
        }
        if !urls.isEmpty {
            await state.install(packageURLs: urls)
        } else if !providers.isEmpty {
            state.statusMessage = L10n.error("Drop a local .ipa archive or .app bundle to install it")
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

private struct AlertPayload: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct WineExecutablePicker: Identifiable {
    let id = UUID()
    let folder: URL
    let executables: [WineExecutableCandidate]
    let engineID: String
}

/// Bottom status bar rendered as a glass strip.
struct StatusBar: View {
    let message: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            }
            Text(message)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Rectangle())
    }
}
