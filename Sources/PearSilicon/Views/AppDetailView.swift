import SwiftUI

/// Detail pane for the selected app, split into Overview and Keymap tabs.
struct AppDetailView: View {
    @EnvironmentObject private var state: AppState
    let app: InstalledApp
    let availableWidth: CGFloat

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case keymap = "Keymap"
        var id: String { rawValue }
        var symbol: String { self == .overview ? "square.grid.2x2" : "keyboard" }
    }

    @State private var tab: Tab = .overview
    @Namespace private var tabNamespace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                detailControls
                switch tab {
                case .overview: overview
                case .keymap: KeymapEditorView(app: app, availableWidth: min(1120, availableWidth) - 40)
                }
            }
            .padding(20)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .defaultScrollAnchor(.top)
    }

    // MARK: - Header

    private var header: some View {
        GlassCard(cornerRadius: 28) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    appIcon
                    gameTitle.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    launchControl
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        appIcon
                        gameTitle
                    }
                    launchControl
                }
            }
        }
    }

    private var gameTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.displayName)
                .font(.title.weight(.semibold))
                .lineLimit(2)
            Text(app.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    statusPill
                    if app.shortVersion != "—" {
                        metaBadge("v\(app.shortVersion)", symbol: "shippingbox")
                    }
                }
                statusPill
            }
        }
    }

    private var launchControl: some View {
        Group {
            if state.isRunning(app) {
                Button(role: .destructive) { state.stop(app) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    Task { await state.launch(app) }
                } label: {
                    Label(L10n.launch, systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.isBusy || state.iOSAppsLockedForRuntimeRefresh)
            }
        }
        .fixedSize()
    }

    private var statusPill: some View {
        StatusPill(
            text: state.isRunning(app) ? "Running" : "Ready",
            tone: state.isRunning(app) ? .positive : .neutral,
            symbol: state.isRunning(app) ? "circle.fill" : nil
        )
    }

    private func metaBadge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var appIcon: some View {
        if let iconURL = app.iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.quaternary)
                .frame(width: 68, height: 68)
                .overlay(Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary))
        }
    }

    // MARK: - Tabs

    private var detailControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                tabBar
                Spacer(minLength: 2)
                fileActions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                tabBar
                ViewThatFits(in: .horizontal) {
                    fileActions.fixedSize()
                    fileActions.labelStyle(.iconOnly)
                }
            }
        }
    }

    private var fileActions: some View {
        HStack(spacing: 6) {
            fileAction(L10n.revealInFinder, symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
            }
            if state.isLegacy32Bit(app) {
                fileAction("Save Data", symbol: "externaldrive") {
                    let folder = AppPaths.legacySandboxDirectory(for: app.id)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            } else {
                fileAction("ODR packs", symbol: "shippingbox") {
                    let folder = AppPaths.odrDirectory(for: app.id)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            fileAction(L10n.uninstall, symbol: "trash", role: .destructive) {
                state.uninstall(app)
            }
            .disabled(state.isBusy || state.iOSAppsLockedForRuntimeRefresh || state.isRunning(app))
        }
        .controlSize(.small)
        .buttonStyle(.glass)
    }

    private func fileAction(_ title: String, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
        }
        .help(title)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.24)) { tab = item }
                } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .background {
                            if tab == item {
                                Capsule()
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .foregroundStyle(tab == item ? .primary : .secondary)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }

    // MARK: - Overview

    private var overview: some View {
        let wide = availableWidth >= 720
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
        return layout {
            actionsCard.frame(maxWidth: .infinity, alignment: .topLeading)
            detailsCard.frame(maxWidth: wide ? min(320, availableWidth * 0.37) : .infinity, alignment: .topLeading)
        }
        .padding(.bottom, 4)
    }

    private var detailsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: L10n.overview)
                infoRow(L10n.bundleID, app.id)
                infoRow(L10n.executable, app.executableName)
                infoRow(
                    "Architecture",
                    state.isLegacy32Bit(app)
                        ? "32-bit iOS (PearLegacyEngine)"
                        : "64-bit iOS (Native Apple Silicon)"
                )
                infoRow(L10n.version, app.shortVersion)
                infoRow(L10n.minimumOS, app.minimumOSVersion ?? "—")
                infoRow(L10n.path, app.bundleURL.path, selectable: true)
            }
        }
    }

    private var actionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Game settings")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow {
                        Text("Game Mode")
                        Toggle("Game Mode", isOn: Binding(
                            get: { state.isGameModeEnabled(for: app) },
                            set: { state.setGameModeEnabled($0, for: app) }
                        ))
                        .labelsHidden()
                        .help("Enable low-latency tuning. Changes apply on relaunch.")
                        .gridColumnAlignment(.trailing)
                    }

                    GridRow {
                        Text("Render Resolution")
                        Picker("Render Resolution", selection: Binding(
                            get: { state.renderScale(for: app) },
                            set: { state.setRenderScale($0, for: app) }
                        )) {
                            ForEach(AppSettings.renderScaleChoices, id: \.value) { choice in
                                Text(choice.title).tag(choice.value)
                            }
                        }
                        .labelsHidden()
                        .help("Lower the internal resolution to reduce GPU load. Changes apply on relaunch.")
                    }

                    GridRow {
                        Text("Performance HUD (FPS)")
                        Toggle("Performance HUD (FPS)", isOn: Binding(
                            get: { state.isMetalHUDEnabled(for: app) },
                            set: { state.setMetalHUDEnabled($0, for: app) }
                        ))
                        .labelsHidden()
                        .help("Show frame rate and Metal performance metrics. Changes apply on relaunch.")
                    }

                    GridRow {
                        Text("Allow pointer lock")
                        Toggle("Allow pointer lock", isOn: Binding(
                            get: { state.isPointerLockAllowed(for: app) },
                            set: { state.setPointerLockAllowed($0, for: app) }
                        ))
                        .labelsHidden()
                        .help("Allow mouse-look controls to capture the pointer.")
                    }
                }
                .font(.callout)
                .controlSize(.small)
                .toggleStyle(.switch)
            }
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
