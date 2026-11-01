import AppKit
import GameController
import SwiftUI

/// Captures the next controller button (or a stick deflection) for a binding.
/// The monitor only listens while the editor is recording; it restores any
/// previous handler when it stops.
@MainActor
final class ControllerCaptureMonitor: ObservableObject {
    @Published private(set) var isRecording = false

    private var onCapture: ((String) -> Void)?
    private var controller: GCController?
    private var previousHandler: ((GCExtendedGamepad, GCControllerElement) -> Void)?
    private var connectObserver: NSObjectProtocol?

    func start(onCapture: @escaping (String) -> Void) {
        stop()
        self.onCapture = onCapture
        isRecording = true
        if let controller = GCController.controllers().first {
            attach(controller)
        } else {
            connectObserver = NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.attach(GCController.controllers().first)
                }
            }
        }
    }

    private func attach(_ controller: GCController?) {
        guard let controller, let gamepad = controller.extendedGamepad else { return }
        self.controller = controller
        previousHandler = gamepad.valueChangedHandler
        gamepad.valueChangedHandler = { [weak self] pad, _ in
            guard let self, self.isRecording, let key = Self.key(for: pad) else { return }
            self.onCapture?(key)
            self.stop()
        }
        isRecording = true
    }

    func stop() {
        if let gamepad = controller?.extendedGamepad {
            gamepad.valueChangedHandler = previousHandler
        }
        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }
        connectObserver = nil
        previousHandler = nil
        controller = nil
        onCapture = nil
        isRecording = false
    }

    private static func key(for pad: GCExtendedGamepad) -> String? {
        if pad.buttonA.isPressed { return ControllerKey.buttonA.rawValue }
        if pad.buttonB.isPressed { return ControllerKey.buttonB.rawValue }
        if pad.buttonX.isPressed { return ControllerKey.buttonX.rawValue }
        if pad.buttonY.isPressed { return ControllerKey.buttonY.rawValue }
        if pad.leftShoulder.isPressed { return ControllerKey.leftShoulder.rawValue }
        if pad.rightShoulder.isPressed { return ControllerKey.rightShoulder.rawValue }
        if pad.leftTrigger.value > 0.5 { return ControllerKey.leftTrigger.rawValue }
        if pad.rightTrigger.value > 0.5 { return ControllerKey.rightTrigger.rawValue }
        if pad.dpad.up.isPressed { return ControllerKey.dpadUp.rawValue }
        if pad.dpad.down.isPressed { return ControllerKey.dpadDown.rawValue }
        if pad.dpad.left.isPressed { return ControllerKey.dpadLeft.rawValue }
        if pad.dpad.right.isPressed { return ControllerKey.dpadRight.rawValue }
        if pad.buttonMenu.isPressed { return ControllerKey.menu.rawValue }
        if #available(macOS 11.0, *), pad.buttonOptions?.isPressed == true {
            return ControllerKey.options.rawValue
        }
        let left = pad.leftThumbstick
        if abs(left.xAxis.value) > 0.55 || abs(left.yAxis.value) > 0.55 {
            return ControllerKey.leftStick.rawValue
        }
        let right = pad.rightThumbstick
        if abs(right.xAxis.value) > 0.55 || abs(right.yAxis.value) > 0.55 {
            return ControllerKey.rightStick.rawValue
        }
        return nil
    }
}

/// Controller counterpart of `KeyCaptureField`: a menu of standard inputs plus
/// a one-shot "press a button" recorder.
struct ControllerCaptureField: View {
    @Binding var key: String
    @StateObject private var capture = ControllerCaptureMonitor()

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(ControllerKey.allCases) { item in
                    Button(item.title) { key = item.rawValue }
                }
            } label: {
                Text(ControllerKey(rawValue: key)?.title ?? "INPUT")
                    .font(.caption.weight(.medium))
                    .frame(minWidth: 64)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                if capture.isRecording {
                    capture.stop()
                } else {
                    capture.start { key = $0 }
                }
            } label: {
                Image(systemName: capture.isRecording ? "record.circle.fill" : "gamecontroller")
                    .foregroundStyle(capture.isRecording ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(capture.isRecording
                  ? "Press a controller button or move a stick"
                  : "Record the next controller input")
        }
        .onDisappear { capture.stop() }
    }
}
