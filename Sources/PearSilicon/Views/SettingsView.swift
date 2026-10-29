import SwiftUI

/// Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var removingPreviousCopy = false

    var body: some View {
        TabView {
            general
                .tabItem { Label(L10n.settings, systemImage: "gearshape") }
            keymapper
                .tabItem { Label("Keymapper", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 420)
        .padding()
    }

    private var general: some View {
        Form {
            LabeledContent(L10n.library) {
                Text(state.libraryURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Section {
                LabeledContent("Storage folder") {
                    Text(state.storageRootURL.path)
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
                Text("Apps, game data, keymaps, ODR packs, keychain entries and logs all live "
                     + "in this one folder, so it can live on an external disk. Moving copies "
                     + "everything to the new location and keeps the old copy as a rollback. "
                     + "Running games must be closed first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Storage location")
            }
        }
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
        panel.message = "Choose a folder (for example on an external disk). Apps and game data will be copied into a PearSilicon folder here."
        panel.directoryURL = state.storageRootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.changeStorageLocation(to: url) }
    }

    private var keymapper: some View {
        Form {
            Section {
                Toggle("Enable keymapper for new games by default",
                       isOn: $state.keymapperDefaultEnabled)
                Text("Input translation is off unless a game opts in. Each game also has "
                     + "its own switch in the Keymap tab. Turning it on enables the "
                     + "input layer; when off, the game runs with no input translation "
                     + "and no overlay button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Repeat-rate protection: always on")
                    .font(.body.weight(.medium))
                Text("The keymapper rejects implausibly fast repeated presses, both "
                     + "for one key and across all keys, so it cannot be driven by "
                     + "a held key or a macro tool. Releases are never blocked. "
                     + "This protection is not configurable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
