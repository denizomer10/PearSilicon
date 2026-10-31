import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ManagedAppRowView: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).lineLimit(1)
                Text(entry.platform == .wine
                     ? (stateEngineLabel)
                     : entry.manifest.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var stateEngineLabel: String {
        entry.manifest.wineEngineID.map { "Wine • \($0)" } ?? "Wine engine not selected"
    }

    @ViewBuilder
    private var icon: some View {
        if entry.platform == .macOS {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.payloadURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [.purple.opacity(0.8), .blue.opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "gamecontroller.fill").foregroundStyle(.white))
        }
    }
}

struct ManagedAppDetailView: View {
    @EnvironmentObject private var state: AppState
    let entry: LibraryEntry
    @State private var confirmingUninstall = false
    @State private var confirmingQuarantine = false

    private var running: Bool { state.isRunning(entry) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(alignment: .top, spacing: 18) {
                    infoCard
                    actionCard
                        .frame(width: 280)
                }
                isolationNote
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog(
            "Remove the quarantine flag from this managed copy?",
            isPresented: $confirmingQuarantine
        ) {
            Button("Allow This App", role: .destructive) {
                state.allowQuarantinedApp(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This bypasses Gatekeeper only for this imported copy. Do it only if you trust the app's source. The original download is not changed and the app is still not notarized.")
        }
        .confirmationDialog(
            "Remove \(entry.displayName)? This deletes its app files, data and Wine prefix.",
            isPresented: $confirmingUninstall
        ) {
            Button("Remove", role: .destructive) { state.uninstall(entry) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 18) {
                icon
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.displayName).font(.title.bold())
                    Text(entry.platform.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.12)))
                    Text("v\(entry.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if running {
                    Button(role: .destructive) {
                        state.stop(entry)
                    } label: {
                        Label("Stop", systemImage: "stop.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                }
                Button {
                    Task { await state.launch(entry) }
                } label: {
                    Label(L10n.launch, systemImage: "play.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(running)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if entry.platform == .macOS {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.payloadURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [.purple.opacity(0.85), .blue.opacity(0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 84, height: 84)
                .overlay(Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.white))
        }
    }

    private var infoCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: L10n.overview)
                infoRow("Identifier", entry.manifest.id)
                infoRow("Version", entry.manifest.version)
                infoRow("Payload", entry.payloadURL.path, selectable: true)
                infoRow("Data", entry.dataURL.path, selectable: true)
                if entry.platform == .wine {
                    infoRow("Wine prefix", entry.prefixURL.path, selectable: true)
                    infoRow("Engine", entry.manifest.wineEngineID ?? "not selected")
                }
                infoRow("Installed", entry.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var actionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Actions")
                Button {
                    Task { await state.launch(entry) }
                } label: {
                    Label(L10n.launch, systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(running)

                if entry.platform == .wine {
                    enginePicker
                }

                Toggle("Metal HUD (FPS)", isOn: Binding(
                    get: { entry.manifest.metalHUDEnabled },
                    set: { state.setMetalHUDEnabled($0, for: entry) }
                ))
                .toggleStyle(.switch)
                Text("Shows Metal's FPS/performance overlay. Relaunch to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.isQuarantined(entry) {
                    Button {
                        confirmingQuarantine = true
                    } label: {
                        Label("Allow This App…", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Text("The imported copy still carries macOS's download quarantine flag. Allow it only if you trust the source; this does not notarize the app.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Button {
                    beginBackup()
                } label: {
                    Label("Backup…", systemImage: "externaldrive").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(running)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.directoryURL])
                } label: {
                    Label(L10n.revealInFinder, systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                if entry.platform == .wine {
                    Button {
                        try? FileManager.default.createDirectory(at: entry.dataURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([entry.dataURL])
                    } label: {
                        Label("Open Saves", systemImage: "internaldrive").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }

                Button(role: .destructive) {
                    confirmingUninstall = true
                } label: {
                    Label(L10n.uninstall, systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(running)
            }
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wine engine").font(.caption).foregroundStyle(.secondary)
            if state.wineEngines.isEmpty {
                Text("No engine registered. Add one in Settings.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Picker("Wine engine", selection: Binding(
                    get: { entry.manifest.wineEngineID ?? state.wineEngines[0].id },
                    set: { state.setWineEngine($0, for: entry) }
                )) {
                    ForEach(state.wineEngines) { engine in
                        Text("\(engine.name) \(engine.version)").tag(engine.id)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var isolationNote: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(entry.platform == .wine ? "Private Wine prefix" : "Native Mac app",
                      systemImage: entry.platform == .wine ? "lock.shield" : "desktopcomputer")
                    .font(.callout.weight(.medium))
                Text(entry.platform == .wine
                     ? "Windows games run with a per-game prefix. Host drive mappings are removed and the process is sandboxed. This is process-level isolation, not a virtual machine; a game that needs a kernel driver or anti-cheat will not work."
                     : ManagedAppService.isolationNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if selectable { Text(value).textSelection(.enabled) } else { Text(value) }
            }
            .font(.callout)
            .lineLimit(2)
            .truncationMode(.middle)
        }
    }

    private func beginBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pearbackup") ?? .data]
        panel.nameFieldStringValue = "\(entry.displayName).pearbackup"
        panel.message = LibraryBackupService.privacyWarning
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.backup(entry, to: url) }
    }
}
