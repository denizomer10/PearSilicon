import SwiftUI

/// Detail pane for the selected app, split into Overview and Keymap tabs.
struct AppDetailView: View {
    @EnvironmentObject private var state: AppState
    let app: InstalledApp

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case keymap = "Keymap"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            switch tab {
            case .overview:
                overview
            case .keymap:
                KeymapEditorView(app: app)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 18) {
                appIcon

                VStack(alignment: .leading, spacing: 5) {
                    Text(app.displayName).font(.title.bold())
                    Text(app.id).font(.subheadline).foregroundStyle(.secondary)
                    Text("v\(app.shortVersion) (\(app.bundleVersion))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if state.isRunning(app) {
                    Button(role: .destructive) {
                        state.stop(app)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                }

                Button {
                    Task { await state.launch(app) }
                } label: {
                    Label(L10n.launch, systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let iconURL = app.iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.quaternary)
                .frame(width: 84, height: 84)
                .overlay(Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary))
        }
    }

    // MARK: - Overview

    private var overview: some View {
        HStack(alignment: .top, spacing: 18) {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(text: L10n.overview)
                    infoRow(L10n.bundleID, app.id)
                    infoRow(L10n.executable, app.executableName)
                    infoRow(L10n.version, "\(app.shortVersion) (\(app.bundleVersion))")
                    infoRow(L10n.minimumOS, app.minimumOSVersion ?? "—")
                    infoRow(L10n.path, app.bundleURL.path, selectable: true)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(text: "Actions")
                    Button {
                        Task { await state.launch(app) }
                    } label: {
                        Label(L10n.launch, systemImage: "play.fill")
                    }
                    .buttonStyle(.glass)

                    Divider()

                    Toggle("Metal HUD (FPS)", isOn: Binding(
                        get: { state.isMetalHUDEnabled(for: app) },
                        set: { state.setMetalHUDEnabled($0, for: app) }
                    ))
                    .toggleStyle(.switch)

                    Text(state.isRunning(app)
                         ? "Shows Metal's FPS/performance overlay. Relaunch to apply."
                         : "Shows Metal's FPS/performance overlay (Metal games only).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Allow pointer lock", isOn: Binding(
                        get: { state.isPointerLockAllowed(for: app) },
                        set: { state.setPointerLockAllowed($0, for: app) }
                    ))
                    .toggleStyle(.switch)

                    Text("Some games rotate the camera from locked mouse movement.\nTurn this off if the cursor gets trapped in the window. Relaunch to apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)



                    Divider()

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
                    } label: {
                        Label(L10n.revealInFinder, systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button {
                        let folder = AppPaths.odrDirectory(for: app.id)
                        try? FileManager.default.createDirectory(
                            at: folder, withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } label: {
                        Label("ODR packs", systemImage: "shippingbox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button(role: .destructive) {
                        state.uninstall(app)
                    } label: {
                        Label(L10n.uninstall, systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .frame(width: 260)
        }
    }

    private func infoRow(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(.callout)
            .lineLimit(2)
            .truncationMode(.middle)
        }
    }
}
