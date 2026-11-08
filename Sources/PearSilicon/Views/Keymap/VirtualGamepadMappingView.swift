import AppKit
import SwiftUI

/// Captures the next key or mouse button for a virtual gamepad control.
///
/// Escape cancels instead of being recorded: the runtime reserves it to release
/// mouse capture, so binding it here would never fire.
@MainActor
final class VirtualPadCaptureMonitor: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var onCapture: ((VirtualPadInput) -> Void)?

    func start(onCapture: @escaping (VirtualPadInput) -> Void) {
        stop()
        self.onCapture = onCapture
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.isRecording else { return event }

            switch event.type {
            case .leftMouseDown:
                self.onCapture?(.mouse(0))
                self.stop()
                return nil
            case .rightMouseDown:
                self.onCapture?(.mouse(1))
                self.stop()
                return nil
            case .otherMouseDown:
                self.onCapture?(.mouse(event.buttonNumber))
                self.stop()
                return nil
            default:
                break
            }

            if event.type == .keyDown, event.keyCode == 53 {
                self.stop()
                return nil
            }

            if event.type == .keyDown || event.type == .flagsChanged,
               let name = KeyNames.canonical(from: event) {
                self.onCapture?(.key(name))
                self.stop()
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onCapture = nil
        isRecording = false
    }
}

/// One editable control row: label, captured input and a clear button.
private struct VirtualPadControlRow: View {
    let control: VirtualPadControl
    let input: VirtualPadInput?
    let onChange: (VirtualPadInput?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(control.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)

            VirtualPadCaptureField(input: input, onChange: onChange)

            Button {
                onChange(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .disabled(input == nil)
            .help("Clear this binding")
        }
    }
}

/// A press-to-bind field that accepts both keyboard keys and mouse buttons.
private struct VirtualPadCaptureField: View {
    let input: VirtualPadInput?
    let onChange: (VirtualPadInput?) -> Void

    @StateObject private var capture = VirtualPadCaptureMonitor()

    var body: some View {
        Button {
            if capture.isRecording {
                capture.stop()
            } else {
                capture.start { onChange($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: capture.isRecording
                      ? "record.circle.fill"
                      : (input?.kind == .mouse ? "computermouse" : "keyboard"))
                    .foregroundStyle(capture.isRecording ? .red : .secondary)
                Text(capture.isRecording ? "Press a key or mouse button…" : (input?.displayName ?? "Unassigned"))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onDisappear { capture.stop() }
        .help("Click, then press a key or mouse button. Escape cancels.")
    }
}

private struct VirtualPadStickRow: View {
    let direction: VirtualPadStickDirection
    let key: String
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(direction.title)
                .font(.callout.weight(.medium))
                .frame(width: 82, alignment: .leading)
            KeyCaptureField(key: Binding(get: { key }, set: { onChange($0) }))
            Spacer(minLength: 0)
        }
    }
}

/// Per-game keyboard/mouse → virtual gamepad mapping editor.
struct VirtualGamepadMappingEditor: View {
    @Binding var mapping: VirtualGamepadMapping

    private let columns = [
        GridItem(.flexible(minimum: 210), spacing: 12),
        GridItem(.flexible(minimum: 210), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Buttons and D-pad")
                    .font(.headline)
                Spacer()
                Button {
                    mapping = .standard
                } label: {
                    Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Text("Click a field, then press a key or mouse button. Escape is reserved for releasing mouse capture.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(VirtualPadControl.allCases) { control in
                    VirtualPadControlRow(control: control, input: mapping.input(for: control)) { input in
                        mapping.setInput(input, for: control)
                    }
                }
            }

            if !mapping.duplicateButtonKeys.isEmpty {
                Label(
                    "Used more than once: " + mapping.duplicateButtonKeys.map { KeyNames.display($0) }.joined(separator: ", "),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            Text("Left stick")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(VirtualPadStickDirection.allCases) { direction in
                    VirtualPadStickRow(direction: direction, key: mapping.stickKey(direction)) { key in
                        mapping.setStickKey(key, for: direction)
                    }
                }
            }

            HStack(spacing: 10) {
                Text("Mouse sensitivity")
                    .font(.callout)
                    .frame(width: 130, alignment: .leading)
                Slider(value: $mapping.mouseSensitivity, in: 0.2...3.0)
                Text(String(format: "%.1f×", mapping.mouseSensitivity))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            Toggle("Invert vertical look", isOn: $mapping.invertVerticalLook)
                .font(.callout)
        }
    }
}
