import AppKit
import SwiftUI

/// Owns the keymapper UI for a running game, as **PearSilicon's own windows**
/// placed over the game window.
///
/// This is deliberate: no UI code is added to the game process, which keeps the
/// runtime's footprint to touch synthesis only and does not disturb the game's
/// view hierarchy. Two panels are
/// used:
///
/// * a small always-on-top button, at the top-right of the game window, and
/// * the editor, which covers the game window while open.
///
/// The button is a *small* window on purpose: a click outside its frame falls
/// through to the game, whereas a full-window transparent overlay would swallow
/// every click.
@MainActor
final class GameKeymapperOverlay {

    private let bundleID: String
    private let keymapStore: KeymapStore

    private var gamePID: pid_t?
    private var buttonPanel: NSPanel?
    private var editorPanel: NSPanel?
    private var timer: Timer?

    init(bundleID: String, keymapStore: KeymapStore) {
        self.bundleID = bundleID
        self.keymapStore = keymapStore
    }

    // MARK: - Lifecycle

    func attach(pid: pid_t) {
        gamePID = pid
        startTracking()
        showButton()
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        editorPanel?.close()
        editorPanel = nil
        buttonPanel?.close()
        buttonPanel = nil
        gamePID = nil
    }

    private func startTracking() {
        timer?.invalidate()
        // Follow the game window as it moves/resizes; also notice when it closes.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func reposition() {
        guard let rect = gameWindowRect() else {
            if editorPanel == nil { detach() } // game gone and not editing
            return
        }
        if let buttonPanel, buttonPanel.isVisible { place(buttonPanel, in: rect) }
        if let editorPanel, editorPanel.isVisible { place(editorPanel, in: rect) }
    }

    // MARK: - Game window geometry

    /// The game's main window rectangle, in AppKit screen coordinates.
    private func gameWindowRect() -> CGRect? {
        guard let pid = gamePID else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: CGRect?
        for window in list {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if best == nil || rect.width * rect.height > best!.width * best!.height {
                best = rect
            }
        }
        guard let cg = best else { return nil }
        return Self.appKitRect(fromCGWindowRect: cg)
    }

    /// CGWindowList rects use a top-left origin on the main display; AppKit uses a
    /// bottom-left origin.
    private static func appKitRect(fromCGWindowRect cg: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: cg.midX, y: cg.minY)) }
            ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 0
        let screenTop = screen?.frame.minY ?? 0
        return CGRect(x: cg.minX,
                      y: screenTop + screenHeight - cg.minY - cg.height,
                      width: cg.width, height: cg.height)
    }

    // MARK: - Button panel

    private func showButton() {
        guard buttonPanel == nil, let rect = gameWindowRect() else { return }
        let size: CGFloat = 40
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let button = NSButton(title: "⌘", target: self, action: #selector(openEditor))
        button.bezelStyle = .circular
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        button.layer?.cornerRadius = size / 2
        button.contentTintColor = .white
        button.font = .systemFont(ofSize: 17, weight: .semibold)
        button.frame = CGRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = button

        place(panel, in: rect)
        panel.orderFrontRegardless()
        buttonPanel = panel
    }

    /// Positions `panel` at the top-right of the game window rect (with a margin).
    private func place(_ panel: NSPanel, in rect: CGRect) {
        let size = panel.frame.size
        let margin: CGFloat = 10
        let origin = CGPoint(x: rect.maxX - size.width - margin,
                             y: rect.maxY - size.height - margin)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Editor

    @objc private func openEditor() {
        guard editorPanel == nil, let rect = gameWindowRect() else { return }

        let keymap = (try? keymapStore.load(for: bundleID)) ?? Keymap.empty(bundleID: bundleID)

        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = KeymapperOverlayView(
            keymap: keymap,
            onSave: { [weak self] updated in
                self?.save(updated)
                self?.closeEditor()
            },
            onCancel: { [weak self] in self?.closeEditor() }
        )
        panel.contentView = NSHostingView(rootView: view)

        place(panel, in: rect)
        panel.makeKeyAndOrderFront(nil)
        editorPanel = panel
        buttonPanel?.orderOut(nil)
    }

    private func closeEditor() {
        editorPanel?.close()
        editorPanel = nil
        buttonPanel?.orderFrontRegardless()
    }

    private func save(_ keymap: Keymap) {
        var updated = keymap
        updated.isAutoGenerated = false
        try? keymapStore.save(updated)
    }
}
