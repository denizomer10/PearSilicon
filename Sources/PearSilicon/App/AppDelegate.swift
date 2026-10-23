import AppKit

/// Intercepts quitting so running games opened through PearSilicon are not left
/// behind. If any are running, a warning is shown: confirming quits PearSilicon
/// *and* stops the games; cancelling keeps everything running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentXcodeWarningIfNeeded()
    }

    /// Warn when the full Xcode is missing or not selected. The app itself can
    /// run without it, but installing/building tooling, the runtime build and
    /// `pearsilicon xcode` cannot.
    private func presentXcodeWarningIfNeeded() {
        switch DeveloperTools.xcodeStatus() {
        case .ready:
            return

        case .missing:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Xcode is not installed"
            alert.informativeText = """
            PearSilicon needs the full Xcode for its developer tooling; the Command Line Tools alone are not enough.

            Install Xcode from the store, then run:

            sudo xcode-select -s /Applications/Xcode.app
            """
            alert.addButton(withTitle: "Open Store")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(DeveloperTools.xcodeStoreURL)
            }

        case .installedButNotSelected(let xcodePath, let activePath):
            let command = DeveloperTools.selectCommand(for: xcodePath)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Xcode is installed but not selected"
            alert.informativeText = """
            macOS is currently using:
            \(activePath ?? "the Command Line Tools")

            Switch to Xcode:

            \(command)
            """
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        let games = state.runningGames
        guard !games.isEmpty else { return .terminateNow }

        let names = games.map(\.displayName).joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = games.count == 1
            ? "A game is still running"
            : "\(games.count) games are still running"
        alert.informativeText = "Quitting PearSilicon will also stop: \(names)."
        alert.addButton(withTitle: "Quit and Stop Games")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel // stay in the app
        }
        state.stopAllRunningGames()
        return .terminateNow
    }
}
