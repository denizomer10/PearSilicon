import GameController
import SwiftUI

/// Resolves fresh presses so an input held before recording does not win.
struct ControllerPressTracker {
    private var held: Set<ControllerKey>

    init(held: [ControllerKey] = []) {
        self.held = Set(held)
    }

    mutating func nextKey(in pressed: [ControllerKey], for action: KeymapActionKind) -> ControllerKey? {
        let next = pressed.first { !held.contains($0) && Self.accepts($0, for: action) }
        held = Set(pressed)
        return next
    }

    static func accepts(_ key: ControllerKey, for action: KeymapActionKind) -> Bool {
        switch action {
        case .joystick, .mouseLook: key.isStick
        case .tap, .hold, .swipe: !key.isStick
        }
    }
}

/// One recorder per editor. Only the named, connected controller can assign a
/// binding, and starting another recording cancels the previous one.
@MainActor
final class ControllerCaptureMonitor: ObservableObject {
    @Published private(set) var deviceName: String?
    @Published private(set) var recordingID: UUID?
    @Published private(set) var prompt: String?

    private var controller: GCController?
    private var previousHandler: GCExtendedGamepadValueChangedHandler?
    private var recordingSession: UUID?
    private var tracker = ControllerPressTracker()

    func refreshConnection(excluding disconnected: GCController? = nil) {
        let connected = GCController.controllers().filter {
            $0 !== disconnected && !$0.isSnapshot && $0.extendedGamepad != nil
        }
        if let controller, connected.contains(where: { $0 === controller }) { return }
        stop()
        controller = connected.first
        deviceName = controller.map { device in
            if let name = device.vendorName, !name.isEmpty { return name }
            return device.productCategory
        }
    }

    func start(id: UUID, action: KeymapActionKind, onCapture: @escaping (ControllerKey) -> Void) {
        stop()
        guard let pad = controller?.extendedGamepad else { return }
        let session = UUID()
        tracker = ControllerPressTracker(held: Self.pressedKeys(on: pad))
        let handler = pad.valueChangedHandler
        previousHandler = handler
        recordingSession = session
        recordingID = id
        prompt = action == .joystick || action == .mouseLook ? "Move a stick to bind it." : "Press a controller button to bind it."
        pad.valueChangedHandler = { [weak self] pad, element in
            handler?(pad, element)
            let pressed = Self.pressedKeys(on: pad)
            Task { @MainActor [weak self] in
                guard let self, self.recordingSession == session,
                      let key = self.tracker.nextKey(in: pressed, for: action) else { return }
                self.stop()
                onCapture(key)
            }
        }
    }

    func stop() {
        if recordingSession != nil {
            controller?.extendedGamepad?.valueChangedHandler = previousHandler
        }
        previousHandler = nil
        recordingSession = nil
        recordingID = nil
        prompt = nil
    }

    private nonisolated static func pressedKeys(on pad: GCExtendedGamepad) -> [ControllerKey] {
        let buttons: [(ControllerKey, GCControllerButtonInput?)] = [
            (.buttonA, pad.buttonA), (.buttonB, pad.buttonB), (.buttonX, pad.buttonX), (.buttonY, pad.buttonY),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder),
            (.leftTrigger, pad.leftTrigger), (.rightTrigger, pad.rightTrigger),
            (.dpadUp, pad.dpad.up), (.dpadDown, pad.dpad.down), (.dpadLeft, pad.dpad.left), (.dpadRight, pad.dpad.right),
            (.menu, pad.buttonMenu), (.options, pad.buttonOptions)
        ]
        var pressed = buttons.compactMap { key, button in
            (button?.value ?? 0) > 0.5 ? key : nil
        }
        for (key, stick) in [(ControllerKey.leftStick, pad.leftThumbstick), (.rightStick, pad.rightThumbstick)] {
            if abs(stick.xAxis.value) > 0.55 || abs(stick.yAxis.value) > 0.55 {
                pressed.append(key)
            }
        }
        return pressed
    }
}
