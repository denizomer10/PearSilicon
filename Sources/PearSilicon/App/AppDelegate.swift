import AppKit

/// Intercepts quitting so running games opened through PearSilicon are not left
/// behind. If any are running, a warning is shown: confirming quits PearSilicon
/// *and* stops the games; cancelling keeps everything running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentToolchainWarningIfNeeded()
    }

    /// Warn when the full development toolchain is missing or not selected.
    /// The app itself can run without it, but runtime builds and project builds
    /// cannot.
    private func presentToolchainWarningIfNeeded() {
        switch DeveloperTools.toolchainStatus() {
        case .ready:
            return

        case .missing:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Full development toolchain not found"
            alert.informativeText = """
            PearSilicon needs the full toolchain for its build commands; the \
            command-line tools alone are not enough.

            Install it, open it once, then select it with:

            sudo xcode-select -s /Applications/<Toolchain>.app
            """
            alert.addButton(withTitle: "OK")

        case .installedButNotSelected(let toolchainPath, let activePath):
            let command = DeveloperTools.selectCommand(for: toolchainPath)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Development toolchain is installed but not selected"
            alert.informativeText = """
            The active developer directory is:
            \(activePath ?? "the command-line tools")

            Select the full toolchain with:

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
