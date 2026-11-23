import AppKit
import SwiftUI

/// Intercepts quitting so running games opened through PearSilicon are not left
/// behind. If any are running, a warning is shown: confirming quits PearSilicon
/// *and* stops the games; cancelling keeps everything running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static var aboutWindow: NSWindow?

    static func showAboutPanel() {
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "About PearSilicon"
        window.contentMinSize = NSSize(width: 330, height: 260)
        window.contentView = NSHostingView(rootView: PearAboutView(version: version))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        aboutWindow = window
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
