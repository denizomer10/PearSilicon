import AppKit

/// Intercepts quitting so running games opened through PearSilicon are not left
/// behind. If any are running, a warning is shown: confirming quits PearSilicon
/// *and* stops the games; cancelling keeps everything running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

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
