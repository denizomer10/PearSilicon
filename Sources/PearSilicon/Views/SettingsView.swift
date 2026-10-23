import SwiftUI

/// Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            general
                .tabItem { Label(L10n.settings, systemImage: "gearshape") }
            keymapper
                .tabItem { Label("Keymapper", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 280)
        .padding()
    }

    private var general: some View {
        Form {
            LabeledContent(L10n.library) {
                Text(state.libraryURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
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
