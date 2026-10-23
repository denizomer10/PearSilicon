import SwiftUI

struct PearSiliconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    await appState.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

@main
enum PearSiliconMain {
    static func main() {
        // The same binary is both the GUI and the CLI. A bare argument takes the
        // CLI path (so a typo reports an error instead of opening the GUI); a
        // normal launch (Finder, `open`, with or without `-psn_…`) reaches
        // SwiftUI.
        if CLI.shouldHandle(CommandLine.arguments) {
            MainActor.assumeIsolated {
                CLI.main(CommandLine.arguments)
            }
        } else {
            PearSiliconApp.main()
        }
    }
}
