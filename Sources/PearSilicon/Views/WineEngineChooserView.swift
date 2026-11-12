import SwiftUI

/// The Wine distribution list: MetalSharp Wine first (default), then the optional
/// WineHQ builds. Used as the launch-time engine chooser and in Settings.
struct WineDistributionList: View {
    @EnvironmentObject private var state: AppState
    /// Called with the chosen distribution. In Settings this installs it; at
    /// launch it installs (if needed), links the game and starts it.
    let action: (WineDistribution) -> Void
    let actionTitle: (WineDistribution, Bool) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(WineDistribution.catalog) { distribution in
                row(distribution)
            }
        }
    }

    private func installed(_ distribution: WineDistribution) -> WineEngine? {
        state.wineEngines.first { WineDistribution.distribution(for: $0) == distribution }
    }

    private func row(_ distribution: WineDistribution) -> some View {
        let engine = installed(distribution)
        let installing = state.installingWineDistributionID == distribution.id
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: distribution.recommended ? "star.circle.fill" : "shippingbox")
                .font(.title2)
                .foregroundStyle(distribution.recommended ? Color.green : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(distribution.name).font(.callout.weight(.semibold))
                    if distribution.recommended {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                    }
                    if !distribution.nativeArm64 {
                        Text("Rosetta 2")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(distribution.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !distribution.nativeArm64 && !WineDistribution.isRosettaInstalled {
                    Text("Needs Rosetta 2, which is not installed: \(WineDistribution.rosettaInstallCommand)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let engine {
                    Text("Installed: \(engine.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if installing {
                ProgressView().controlSize(.small)
            } else if distribution.recommended {
                Button(actionTitle(distribution, engine != nil)) { action(distribution) }
                    .buttonStyle(.glassProminent)
                    .disabled(state.isBusy)
            } else {
                Button(actionTitle(distribution, engine != nil)) { action(distribution) }
                    .buttonStyle(.glass)
                    .disabled(state.isBusy)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(distribution.recommended ? Color.green.opacity(0.06) : Color.clear)
        )
    }
}

/// Shown when a Windows game is opened without an engine.
struct WineEngineChooserSheet: View {
    @EnvironmentObject private var state: AppState
    let entry: LibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a Wine engine for \(entry.displayName)")
                .font(.title3.weight(.semibold))
            Text("MetalSharp Wine runs Windows programs natively on Apple silicon and is the default. WineHQ builds are optional and need Rosetta 2.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                WineDistributionList(
                    action: { distribution in
                        Task { await state.chooseWineDistribution(distribution, for: entry) }
                    },
                    actionTitle: { _, installed in installed ? "Use" : "Install and Use" }
                )
            }
            .frame(minHeight: 320)
            HStack {
                Text("Downloads are verified with SHA-256 before installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { state.wineEngineChoiceEntry = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}
