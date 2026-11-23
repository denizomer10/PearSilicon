import AppKit
import Combine
import SwiftUI

/// Keeps the editor aligned with the game content when the game runs in
/// another process. The game owns its title bar and can still be moved there.
@MainActor
final class GameKeymapperOverlay {
    private let bundleID: String
    private let keymapStore: KeymapStore
    private let onSave: (Keymap) throws -> Void

    private var game: NSRunningApplication?
    private var windowID: CGWindowID?
    private var nextWindowSearch = ContinuousClock.now
    private var editorPanel: NSPanel?
    private var timer: Timer?
    private var hitRegions: [CGRect] = []
    private let keymapUpdates = PassthroughSubject<Keymap, Never>()

    init(bundleID: String, keymapStore: KeymapStore, onSave: @escaping (Keymap) throws -> Void) {
        self.bundleID = bundleID
        self.keymapStore = keymapStore
        self.onSave = onSave
    }

    func attach(pid: pid_t) {
        guard game?.processIdentifier != pid || timer == nil else { return }
        detach()
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return }
        game = running
        // Common modes continue tracking during a title-bar drag or resize.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackWindow() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        trackWindow()
    }

    func updateKeymap(_ keymap: Keymap) {
        keymapUpdates.send(keymap)
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        editorPanel?.close()
        editorPanel = nil
        game = nil
        windowID = nil
        nextWindowSearch = .now
        hitRegions = []
    }

    private func trackWindow() {
        guard let game, !game.isTerminated else {
            detach()
            return
        }
        let isEditing = editorPanel?.isKeyWindow == true
        guard isEditing || game.isActive else {
            if editorPanel?.isVisible == true { editorPanel?.orderOut(nil) }
            return
        }
        guard let rect = gameContentRect(pid: game.processIdentifier) else {
            if editorPanel?.isVisible == true { editorPanel?.orderOut(nil) }
            return
        }
        let panel = editorPanel ?? makeEditor(frame: rect)
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        if NSEvent.pressedMouseButtons == 0 {
            let cursor = NSEvent.mouseLocation
            let point = CGPoint(x: cursor.x - rect.minX, y: rect.maxY - cursor.y)
            panel.ignoresMouseEvents = !hitRegions.contains { $0.contains(point) }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func gameContentRect(pid: pid_t) -> CGRect? {
        let description: [[String: Any]]
        if let id = windowID {
            description = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]] ?? []
        } else {
            guard ContinuousClock.now >= nextWindowSearch else { return nil }
            nextWindowSearch = .now + .milliseconds(200)
            description = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        }
        let gameWindows = description.compactMap { window -> (CGWindowID, CGRect)? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowIsOnscreen as String] as? Bool == true,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 160, rect.height >= 100 else { return nil }
            return (id, rect)
        }
        guard let (id, bounds) = gameWindows.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
            windowID = nil
            return nil
        }
        windowID = id
        return Self.contentRect(for: bounds, screens: NSScreen.screens.map(\.frame))
    }

    static func contentRect(for bounds: CGRect, screens: [CGRect]) -> CGRect {
        let displayTop = screens.first?.maxY ?? 0
        let frame = CGRect(x: bounds.minX, y: displayTop - bounds.maxY, width: bounds.width, height: bounds.height)
        let fullscreen = screens.contains {
            abs($0.width - frame.width) < 2 && abs($0.height - frame.height) < 2
                && abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2
        }
        return fullscreen ? frame : NSWindow.contentRect(forFrameRect: frame, styleMask: [.titled, .resizable])
    }

    private func makeEditor(frame: CGRect) -> NSPanel {
        let panel = KeymapperPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.title = "Keymapper"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let keymap = (try? keymapStore.loadManual(for: bundleID)) ?? Keymap.empty(bundleID: bundleID)
        let view = NSHostingView(rootView: KeymapperOverlayView(keymap: keymap, updates: keymapUpdates.eraseToAnyPublisher(), onSave: onSave) { [weak self] regions in
            self?.hitRegions = regions
        })
        view.sizingOptions = []
        panel.contentView = view
        editorPanel = panel
        return panel
    }
}

private final class KeymapperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
