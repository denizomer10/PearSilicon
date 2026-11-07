import SwiftUI

/// Detail pane for the selected app, split into Overview and Keymap tabs.
struct AppDetailView: View {
    @EnvironmentObject private var state: AppState
    let app: InstalledApp

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case keymap = "Keymap"
        var id: String { rawValue }
        var symbol: String { self == .overview ? "square.grid.2x2" : "keyboard" }
    }

    @State private var tab: Tab = .overview
    @Namespace private var tabNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            tabBar

            switch tab {
            case .overview:
                ScrollView { overview }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .keymap:
                KeymapEditorView(app: app)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var compatibility: AppCompatibility {
        state.compatibility(for: app)
    }

    private var header: some View {
        GlassCard(cornerRadius: 24) {
            HStack(alignment: .center, spacing: 18) {
                appIcon

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Text(app.displayName)
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .lineLimit(1)
                        statusPill
                    }
                    Text(app.id)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 7) {
                        metaBadge("v\(app.shortVersion) (\(app.bundleVersion))", symbol: "shippingbox")
                        if let minimum = app.minimumOSVersion {
                            metaBadge("iOS \(minimum)+", symbol: "iphone")
                        }
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if state.isRunning(app) {
                        Button(role: .destructive) {
                            state.stop(app)
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                        .tint(.red)
                    }

                    Button {
                        Task { await state.launch(app) }
                    } label: {
                        Label(L10n.launch, systemImage: "play.fill")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .fixedSize()
            }
        }
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
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.quaternary)
                .frame(width: 84, height: 84)
                .overlay(Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary))
        }
    }

    // MARK: - Tabs

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
                .foregroundStyle(tab == item ? .primary : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: 330, alignment: .leading)
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }

    // MARK: - Overview

    private var overview: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                detailsCard
                compatibilityCard
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 16) {
                actionsCard
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 4)
    }

    private var detailsCard: some View {
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
    }

    private var compatibilityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SectionTitle(text: "Compatibility")
                    Spacer()
                    StatusPill(text: "Automatic", tone: .neutral, symbol: "sparkles")
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: compatibility.isLegacyRuntime
                          ? "wrench.and.screwdriver.fill" : "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(compatibility.isLegacyRuntime ? Color.orange : Color.green)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(compatibility.summary)
                            .font(.callout.weight(.medium))
                        Text(compatibility.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().opacity(0.45)

                bridgeRow("Window bridge", enabled: state.isLegacyBridgeEnabled(for: app))
                bridgeRow("Mouse → touch", enabled: state.isMouseTouchFallbackEnabled(for: app))

                if state.hasCompatibilityOverride(for: app) {
                    Divider().opacity(0.45)
                    HStack(spacing: 8) {
                        Text("Manual override active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use automatic") {
                            withAnimation(.snappy(duration: 0.2)) {
                                state.clearCompatibilityOverrides(for: app)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }

                Text("Applied automatically on launch. Overrides are available from the command line.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bridgeRow(_ title: String, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
            Text(title).font(.callout)
            Spacer()
            Text(enabled ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var actionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Actions")

                Button {
                    Task { await state.launch(app) }
                } label: {
                    Label(L10n.launch, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Metal HUD (FPS)", isOn: Binding(
                        get: { state.isMetalHUDEnabled(for: app) },
                        set: { state.setMetalHUDEnabled($0, for: app) }
                    ))
                    .toggleStyle(.switch)
                    Text("Metal performance overlay. Relaunch to apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Allow pointer lock", isOn: Binding(
                        get: { state.isPointerLockAllowed(for: app) },
                        set: { state.setPointerLockAllowed($0, for: app) }
                    ))
                    .toggleStyle(.switch)
                    Text("Needed for mouse-look cameras. Turn it off if the cursor gets trapped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.45)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                    actionButton(L10n.revealInFinder, symbol: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
                    }
                    actionButton("ODR packs", symbol: "shippingbox") {
                        let folder = AppPaths.odrDirectory(for: app.id)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    actionButton(L10n.uninstall, symbol: "trash", destructive: true) {
                        state.uninstall(app)
                    }
                }
            }
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
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
