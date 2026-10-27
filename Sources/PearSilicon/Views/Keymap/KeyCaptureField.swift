import AppKit
import SwiftUI

/// Captures the next physical key press for a binding.
///
/// SwiftUI's text field is still editable for unusual names, but the keyboard
/// button lets the user press the key instead of typing it. The monitor is
/// local to the app, so it cannot observe keys while another app is focused.
@MainActor
final class KeyCaptureMonitor: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var onCapture: ((String) -> Void)?

    func start(onCapture: @escaping (String) -> Void) {
        stop()
        self.onCapture = onCapture
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard let name = KeyNames.canonical(from: event) else { return event }
            self.onCapture?(name)
            self.stop()
            return nil
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

/// A compact key field with a one-shot "press a key" recorder.
struct KeyCaptureField: View {
    @Binding var key: String
    @StateObject private var capture = KeyCaptureMonitor()

    var body: some View {
        HStack(spacing: 4) {
            TextField("Key", text: $key)
                .textFieldStyle(.plain)
                .frame(width: 62)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button {
                if capture.isRecording {
                    capture.stop()
                } else {
                    capture.start { key = $0 }
                }
            } label: {
                Image(systemName: capture.isRecording ? "record.circle.fill" : "keyboard")
                    .foregroundStyle(capture.isRecording ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(capture.isRecording
                  ? "Press any key, or click again to cancel"
                  : "Record the next key press")
        }
        .onDisappear { capture.stop() }
    }
}
