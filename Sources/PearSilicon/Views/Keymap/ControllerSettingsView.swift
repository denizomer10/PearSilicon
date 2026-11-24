import SwiftUI

/// Controller management view inside Settings (⌘,).
/// Manages Bluetooth/USB/BLE controllers (DualSense, Xbox, Switch Pro, Switch Joy-Con,
/// Switch 2 Joy-Con 2 via pure-Rust CoreBluetooth + IOKit HID), Optical Mouse Mode,
/// per-controller enable/disable, and low-latency tuning.
struct ControllerSettingsView: View {
    @StateObject private var bridge = RustControllerBridge()
    @State private var settings = ControllerSettings.load()
    @State private var selectedDeviceID: String?

    private var activeDevice: RustControllerDevice? {
        if let id = selectedDeviceID, let match = bridge.devices.first(where: { $0.id == id }) {
            return match
        }
        return bridge.devices.first
    }

    var body: some View {
        Form {
            detectedControllersSection
            if let dev = activeDevice {
                liveInputPreviewSection(dev)
            }
            gyroAndHapticsSection
            lowLatencySettingsSection
        }
        .formStyle(.grouped)
        .onAppear {
            bridge.start(with: settings)
        }
        .onDisappear {
            bridge.stopPolling()
        }
        .onChange(of: settings) { _, updated in
            updated.save()
            bridge.applyConfig(updated)
        }
    }

    private var detectedControllersSection: some View {
        Section {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(bridge.engineLoaded ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(bridge.engineLoaded ? "Pure-Rust Engine Active — Auto-Pairing Ready" : "Engine Unavailable")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let err = bridge.loadError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if bridge.devices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No controllers detected yet.")
                        .font(.callout.weight(.medium))
                    Text("Pair DualSense, Xbox, Switch Pro / Joy-Con via Bluetooth or USB, or press sync on Switch 2 Joy-Cons for automatic BLE discovery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(bridge.devices) { dev in
                    deviceRow(dev)
                }
            }
        } header: {
            Text("Detected Controllers")
        }
    }

    private func deviceRow(_ dev: RustControllerDevice) -> some View {
        let selected = activeDevice?.id == dev.id
        let enabledBinding = Binding<Bool>(
            get: { settings.isDeviceEnabled(dev.id) },
            set: { settings.setDeviceEnabled(dev.id, enabled: $0) }
        )

        return HStack(spacing: 12) {
            Button {
                selectedDeviceID = dev.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName(for: dev.kind))
                        .font(.title3)
                        .frame(width: 24)
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.name)
                            .font(.callout.weight(.semibold))
                        Text("\(dev.kindDisplay) · \(dev.transport)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if dev.reportRateHz > 0 {
                        Text("\(dev.reportRateHz) Hz")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if dev.latencyUs > 0 {
                        let ms = Double(dev.latencyUs) / 1000.0
                        Text(String(format: "%.1f ms", ms))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ms < 10 ? .green : .secondary)
                    }
                    if let battery = dev.batteryPercent {
                        Label("\(battery)%", systemImage: battery > 25 ? "battery.75" : "battery.25")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Enable or disable this controller")
        }
        .opacity(settings.isDeviceEnabled(dev.id) ? 1.0 : 0.55)
    }

    private func liveInputPreviewSection(_ dev: RustControllerDevice) -> some View {
        Section("Live Input Preview — \(dev.name)") {
            HStack(spacing: 20) {
                stickPad(label: "Left Stick", x: dev.state.leftX, y: dev.state.leftY)
                stickPad(label: "Right Stick", x: dev.state.rightX, y: dev.state.rightY)

                VStack(alignment: .leading, spacing: 8) {
                    triggerBar(label: "L2", value: dev.state.l2)
                    triggerBar(label: "R2", value: dev.state.r2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pressed Buttons")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(dev.state.buttons.isEmpty ? "None" : dev.state.buttons.joined(separator: "  "))
                            .font(.caption.monospaced())
                            .lineLimit(2)
                        if let raw = dev.rawHex, !raw.isEmpty {
                            Text(raw)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
    }

    private var gyroAndHapticsSection: some View {
        Section("Gyro (IMU) & Haptics") {
            if let dev = activeDevice {
                let gx = dev.state.gyroX ?? 0
                let gy = dev.state.gyroY ?? 0
                let gz = dev.state.gyroZ ?? 0
                let ax = dev.state.accelX ?? 0
                let ay = dev.state.accelY ?? 0
                let az = dev.state.accelZ ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "Gyro (deg/s): X %+.1f   Y %+.1f   Z %+.1f", gx, gy, gz))
                        .font(.system(.caption, design: .monospaced))
                    Text(String(format: "Accel (G):    X %+.2f   Y %+.2f   Z %+.2f", ax, ay, az))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Connect a controller to view live 6-axis Gyro & Accelerometer telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Test Haptics (Rumble)") {
                    bridge.testHaptics()
                }
                .disabled(bridge.devices.isEmpty)
                Spacer()
                Text("Sends HD Rumble pulse to connected Switch 2 Joy-Con")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lowLatencySettingsSection: some View {
        Section("Low-Latency & Controller Tuning") {
            Toggle("Low-Latency Direct Rust Engine (USER_INTERACTIVE)", isOn: $settings.lowLatencyMode)
            Toggle("Prefer Direct HID/BLE over macOS Coalescing", isOn: $settings.preferDirectHID)
            Toggle("Keep Nintendo A/B & X/Y Button Labels", isOn: $settings.nintendoButtonLayout)

            Picker("Target Dispatch Rate", selection: $settings.pollingHz) {
                Text("125 Hz").tag(125)
                Text("250 Hz").tag(250)
                Text("500 Hz").tag(500)
                Text("1000 Hz").tag(1000)
            }

            Picker("Joy-Con Pairing Mode", selection: $settings.joyconCombineMode) {
                ForEach(JoyConCombineMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            sliderRow(title: "Left Stick Deadzone", value: $settings.leftDeadzone, range: 0...0.35, suffix: "%", scale: 100)
            sliderRow(title: "Right Stick Deadzone", value: $settings.rightDeadzone, range: 0...0.35, suffix: "%", scale: 100)
            sliderRow(title: "Trigger (L2/R2) Deadzone", value: $settings.triggerDeadzone, range: 0...0.25, suffix: "%", scale: 100)

            HStack {
                Spacer()
                Button("Reset Defaults") {
                    settings = ControllerSettings()
                }
            }
        }
    }

    private func stickPad(label: String, x: Double, y: Double) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 68, height: 68)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .offset(x: x * 26, y: -y * 26)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerBar(label: String, value: Double) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .frame(width: 24, alignment: .leading)
            ProgressView(value: min(max(value, 0), 1))
                .frame(width: 110)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        scale: Double = 1
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Slider(value: value, in: range, step: scale == 1 ? 0.1 : 0.01)
                .frame(width: 180)
            let formatted = scale == 1
                ? String(format: "%.1f%@", value.wrappedValue, suffix)
                : "\(Int((value.wrappedValue * scale).rounded()))\(suffix)"
            Text(formatted)
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func iconName(for kind: String) -> String {
        if kind.contains("joycon") { return "l.joystick.press.down" }
        if kind.contains("dualsense") || kind.contains("dualshock") { return "playstation.logo" }
        if kind.contains("xbox") { return "xbox.logo" }
        return "gamecontroller.fill"
    }
}
