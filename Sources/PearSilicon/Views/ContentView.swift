import SwiftUI
import UniformTypeIdentifiers

/// Main window: library sidebar on the left, detail on the right.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label(L10n.install, systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(state.isBusy)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: packageContentTypes,
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
        .safeAreaInset(edge: .bottom) {
            StatusBar(message: state.statusMessage, busy: state.isBusy)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $state.selection) {
            if filteredApps.isEmpty {
                Text(L10n.emptyLibrary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(filteredApps) { app in
                    AppRowView(app: app)
                        .tag(app.id)
                        .contextMenu {
                            Button(L10n.launch) { Task { await state.launch(app) } }
                            if state.isRunning(app) {
                                Button("Stop", role: .destructive) { state.stop(app) }
                            }
                            Button(L10n.revealInFinder) {
                                NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
                            }
                            Divider()
                            Button(L10n.uninstall, role: .destructive) { state.uninstall(app) }
                        }
                }
            }
        }
        .searchable(text: $state.searchText, prompt: L10n.search)
        .navigationTitle(L10n.library)
    }

    private var filteredApps: [InstalledApp] {
        guard !state.searchText.isEmpty else { return state.installedApps }
        return state.installedApps.filter {
            $0.displayName.localizedCaseInsensitiveContains(state.searchText)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let app = state.selectedApp {
            AppDetailView(app: app)
                .id(app.id)
        } else {
            ContentUnavailableView(
                L10n.noSelection,
                systemImage: "cube.transparent",
                description: Text(L10n.emptyLibrary)
            )
        }
    }

    // MARK: - Drop

    /// IPA packages and toolchain-built `.app` bundles can be dropped anywhere
    /// on the window.
    private var packageContentTypes: [UTType] {
        ["ipa", "app", "app package"].compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    private static let packageExtensions: Set<String> = ["ipa", "app"]

    private func handleDrop(_ providers: [NSItemProvider]) async {
        guard !state.isBusy else { return }
        var urls: [URL] = []
        for provider in providers {
            guard let item = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
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
            state.statusMessage = L10n.error("Drop an .ipa package or an .app bundle to install it")
        }
    }
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
