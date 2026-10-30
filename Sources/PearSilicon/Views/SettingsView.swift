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
                Text("Experimental: copies managed apps and data, retaining the previous copy. "
                     + "Close games and keep a separate backup first. Launch moved apps through "
                     + "PearSilicon; direct launches may use default paths. External-disk "
                     + "operation has not been tested end to end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Storage location — experimental")
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
        panel.message = "Experimental move: choose a destination folder. Keep a backup and test the moved apps before removing the previous copy."
        panel.directoryURL = state.storageRootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.changeStorageLocation(to: url) }
    }

    private var keymapper: some View {
        Form {
            Section {
                Toggle("Enable keymapper for new games by default",
                       isOn: $state.keymapperDefaultEnabled)
                Text("Keyboard/mouse keymapping is off unless enabled. Each game has "
                     + "its own switch in the Keymap tab; changing it takes effect "
                     + "on the next launch. Saved bindings can reload while the "
                     + "keymapper is active. Other compatibility hooks can still run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Repeat-rate protection: always on")
                    .font(.body.weight(.medium))
                Text("The keymapper drops presses less than 120 ms apart for the same key "
                     + "or 40 ms apart across keys. Releases are not rate-limited. "
                     + "This limits rapid repeats; it does not detect or prevent macros. "
                     + "The limits are not configurable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
