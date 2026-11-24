import Foundation

enum JoyConCombineMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case separate
    case singleLeft = "single_left"
    case singleRight = "single_right"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto Pair (L + R)"
        case .separate: return "Separate (Horizontal)"
        case .singleLeft: return "Single Left Only"
        case .singleRight: return "Single Right Only"
        }
    }
}

struct ControllerSettings: Codable, Equatable, Sendable {
    var lowLatencyMode: Bool = true
    var pollingHz: Int = 250
    var leftDeadzone: Double = 0.06
    var rightDeadzone: Double = 0.06
    var triggerDeadzone: Double = 0.03
    var joyconCombineMode: JoyConCombineMode = .auto
    var nintendoButtonLayout: Bool = false
    var bleSwitch2Enabled: Bool = true
    var preferDirectHID: Bool = true
    var disabledDeviceIds: [String] = []

    private static let defaultsKey = "controller.settings.v1"

    func isDeviceEnabled(_ id: String) -> Bool {
        !disabledDeviceIds.contains(id)
    }

    mutating func setDeviceEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledDeviceIds.removeAll { $0 == id }
        } else if !disabledDeviceIds.contains(id) {
            disabledDeviceIds.append(id)
        }
    }

    static func load(from defaults: UserDefaults = AppSettings.defaults) -> ControllerSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var decoded = try? JSONDecoder().decode(ControllerSettings.self, from: data) else {
            return ControllerSettings()
        }
        // Switch 2 BLE auto-pairing is always active.
        decoded.bleSwitch2Enabled = true
        return decoded
    }

    func save(to defaults: UserDefaults = AppSettings.defaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
