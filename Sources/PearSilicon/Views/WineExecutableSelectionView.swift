import SwiftUI

/// Shared executable chooser for Wine imports and for repairing an existing
/// entry. Candidates are pre-sorted and the likely game program is preselected.
struct WineExecutableSelectionView: View {
    let folder: URL
    let candidates: [WineExecutableCandidate]
    let importTitle: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var selection: String?

    init(
        folder: URL,
        candidates: [WineExecutableCandidate],
        importTitle: String = "Import",
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.folder = folder
        self.candidates = candidates
        self.importTitle = importTitle
        self.onSelect = onSelect
        self.onCancel = onCancel
        _selection = State(initialValue: (candidates.first { $0.isRecommended }
            ?? candidates.first)?.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the game's executable").font(.title3.weight(.semibold))
            Text(folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            List(candidates, id: \.self, selection: $selection) { candidate in
                HStack(spacing: 8) {
                    Text(candidate.path).font(.callout.monospaced())
                    if candidate.isRecommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.green.opacity(0.22)))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onSelect(candidate.path) }
            }
            .frame(minHeight: 260)
            Text("Installers and redistributables are hidden when a game program is found. Double-click a row to select it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ManagedAppService.windowsExecutableOnlyImportHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(importTitle) {
                    if let selection { onSelect(selection) }
                }
                .buttonStyle(.glassProminent)
                .disabled(selection == nil)
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
    }
}
