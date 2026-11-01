import AppKit

/// Intercepts quitting so running games opened through PearSilicon are not left
/// behind. If any are running, a warning is shown: confirming quits PearSilicon
/// *and* stops the games; cancelling keeps everything running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Custom About panel: a channel label followed by the real version code so
    /// users can tell exactly which build they are running.
    static func showAboutPanel() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let alert = NSAlert()
        alert.messageText = "PearSilicon"
        alert.informativeText = "Development Beta\nVersion \(version) (\(build))"
        alert.icon = NSApplication.shared.applicationIconImage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        let names = state.runningGameNames
        guard !names.isEmpty else { return .terminateNow }

        let joined = names.joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? "A game is still running"
            : "\(names.count) games are still running"
        alert.informativeText = "Quitting PearSilicon will also stop: \(joined)."
        alert.addButton(withTitle: "Quit and Stop Games")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel // stay in the app
        }
        state.stopAllRunningGames()
        return .terminateNow
    }
}
