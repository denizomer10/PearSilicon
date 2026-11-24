import Combine
import GameController
import PearControllerHID
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
    private let hidMonitor = PearHIDGamepadMonitor()
    private var hidMonitoring = false
    private var hidGamepad: PearHIDGamepad?
    private let rustBridge = RustControllerBridge()
    private var rustStarted = false
    private var rustCancellable: AnyCancellable?
    private var rustCaptureCancellable: AnyCancellable?
    private var rustDevice: RustControllerDevice?
    private var previousHandler: ((GCPhysicalInputProfile, GCControllerElement) -> Void)?
    private var recordingSession: UUID?
    private var tracker = ControllerPressTracker()

    func refreshConnection(excluding disconnected: GCController? = nil) {
        if !rustStarted {
            rustStarted = true
            rustBridge.start(with: ControllerSettings.load(), interval: 1.0 / 15.0)
            rustCancellable = rustBridge.$devices
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshConnection()
                }
        }
        if !hidMonitoring {
            hidMonitor.connectionChanged = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshConnection() }
            }
            hidMonitoring = hidMonitor.start()
        }
        let connected = GCController.controllers().filter {
            $0 !== disconnected && !$0.isSnapshot && $0.extendedGamepad != nil
        }
        let activeRust = rustBridge.devices.first(where: { $0.connected && $0.enabled })
        if let controller, connected.contains(where: { $0 === controller }) { return }
        if connected.isEmpty, let hidGamepad, hidMonitor.gamepads.contains(where: { $0 === hidGamepad }) { return }
        if connected.isEmpty, hidMonitor.gamepads.isEmpty, let rustDevice, activeRust?.id == rustDevice.id { return }
        stop()
        hidGamepad = connected.isEmpty ? hidMonitor.gamepads.first : nil
        controller = connected.first ?? hidGamepad?.controller
        rustDevice = (controller == nil) ? activeRust : nil
        deviceName = rustDevice?.name ?? hidGamepad?.name ?? controller.map { device in
            if let name = device.vendorName, !name.isEmpty { return name }
            return device.productCategory
        }
    }

    func start(id: UUID, action: KeymapActionKind, onCapture: @escaping (ControllerKey) -> Void) {
        stop()
        if let rustDev = rustDevice {
            let session = UUID()
            let initial = Self.pressedKeys(on: rustDev.state)
            tracker = ControllerPressTracker(held: initial)
            recordingSession = session
            recordingID = id
            prompt = action == .joystick || action == .mouseLook ? "Move a stick to bind it." : "Press a controller button to bind it."
            rustCaptureCancellable = rustBridge.$devices
                .receive(on: RunLoop.main)
                .sink { [weak self] devs in
                    guard let self, let current = devs.first(where: { $0.id == rustDev.id }) else { return }
                    self.capture(Self.pressedKeys(on: current.state), session: session, action: action, onCapture: onCapture)
                }
            return
        }
        guard let controller, let pad = controller.extendedGamepad else { return }
        let session = UUID()
        tracker = ControllerPressTracker(held: Self.pressedKeys(on: pad))
        let profile = controller.physicalInputProfile
        recordingSession = session
        recordingID = id
        prompt = action == .joystick || action == .mouseLook ? "Move a stick to bind it." : "Press a controller button to bind it."
        if let hidGamepad {
            hidMonitor.inputChanged = { [weak self, weak hidGamepad] gamepad, _ in
                guard gamepad === hidGamepad, let pad = gamepad.controller.extendedGamepad else { return }
                MainActor.assumeIsolated {
                    self?.capture(Self.pressedKeys(on: pad), session: session, action: action, onCapture: onCapture)
                }
            }
            return
        }
        let handler = profile.valueDidChangeHandler
        previousHandler = handler
        profile.valueDidChangeHandler = { [weak self, weak pad] profile, element in
            handler?(profile, element)
            guard let pad else { return }
            let pressed = Self.pressedKeys(on: pad)
            Task { @MainActor [weak self] in
                self?.capture(pressed, session: session, action: action, onCapture: onCapture)
            }
        }
    }

    func stop() {
        if recordingSession != nil, hidGamepad == nil, rustDevice == nil {
            controller?.physicalInputProfile.valueDidChangeHandler = previousHandler
        }
        rustCaptureCancellable?.cancel()
        rustCaptureCancellable = nil
        hidMonitor.inputChanged = nil
        previousHandler = nil
        recordingSession = nil
        recordingID = nil
        prompt = nil
    }

    private nonisolated static func pressedKeys(on state: RustControllerDeviceState) -> [ControllerKey] {
        var pressed: [ControllerKey] = []
        for name in state.buttons {
            switch name {
            case "A": pressed.append(.buttonA)
            case "B": pressed.append(.buttonB)
            case "X": pressed.append(.buttonX)
            case "Y": pressed.append(.buttonY)
            case "L1": pressed.append(.leftShoulder)
            case "R1": pressed.append(.rightShoulder)
            case "L2": pressed.append(.leftTrigger)
            case "R2": pressed.append(.rightTrigger)
            case "Up": pressed.append(.dpadUp)
            case "Down": pressed.append(.dpadDown)
            case "Left": pressed.append(.dpadLeft)
            case "Right": pressed.append(.dpadRight)
            case "Menu": pressed.append(.menu)
            case "Options": pressed.append(.options)
            default: break
            }
        }
        if state.l2 > 0.5 && !pressed.contains(.leftTrigger) { pressed.append(.leftTrigger) }
        if state.r2 > 0.5 && !pressed.contains(.rightTrigger) { pressed.append(.rightTrigger) }
        if abs(state.leftX) > 0.55 || abs(state.leftY) > 0.55 { pressed.append(.leftStick) }
        if abs(state.rightX) > 0.55 || abs(state.rightY) > 0.55 { pressed.append(.rightStick) }
        return pressed
    }

    private func capture(
        _ pressed: [ControllerKey], session: UUID, action: KeymapActionKind, onCapture: (ControllerKey) -> Void
    ) {
        guard recordingSession == session, let key = tracker.nextKey(in: pressed, for: action) else { return }
        stop()
        onCapture(key)
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
