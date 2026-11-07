import Foundation

/// A physical input that drives one virtual gamepad control.
///
/// Keys use the same canonical names as `KeyNames`/the keymap, so the editor
/// and the runtime agree on physical-key names instead of keyboard layout
/// characters. Mouse buttons store AppKit's `buttonNumber` (`0` left,
/// `1` right, `2` middle, …).
struct VirtualPadInput: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case key
        case mouse
        /// Explicitly cleared binding. `nil` from `input(for:)` is different:
        /// a missing control falls back to the default, `.none` stays empty.
        case none
    }

    var kind: Kind
    var value: String

    static func key(_ name: String) -> VirtualPadInput {
        VirtualPadInput(kind: .key, value: name.lowercased())
    }

    static func mouse(_ button: Int) -> VirtualPadInput {
        VirtualPadInput(kind: .mouse, value: String(button))
    }

    static let none = VirtualPadInput(kind: .none, value: "")

    var displayName: String {
        switch kind {
        case .key:
            return KeyNames.display(value)
        case .mouse:
            switch Int(value) {
            case 0: return "Mouse Left"
            case 1: return "Mouse Right"
            case 2: return "Mouse Middle"
            default: return "Mouse \(value)"
            }
        case .none:
            return "Unassigned"
        }
    }
}

/// Controls exposed by the hidden `GCVirtualController`.
enum VirtualPadControl: String, CaseIterable, Codable, Identifiable, Sendable {
    case buttonA = "a"
    case buttonB = "b"
    case buttonX = "x"
    case buttonY = "y"
    case leftShoulder = "l1"
    case rightShoulder = "r1"
    case leftTrigger = "l2"
    case rightTrigger = "r2"
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case menu
    case options
    case leftStickButton = "l3"
    case rightStickButton = "r3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttonA: return "A"
        case .buttonB: return "B"
        case .buttonX: return "X"
        case .buttonY: return "Y"
        case .leftShoulder: return "L1"
        case .rightShoulder: return "R1"
        case .leftTrigger: return "L2"
        case .rightTrigger: return "R2"
        case .dpadUp: return "D-Pad ↑"
        case .dpadDown: return "D-Pad ↓"
        case .dpadLeft: return "D-Pad ←"
        case .dpadRight: return "D-Pad →"
        case .menu: return "Menu"
        case .options: return "Options"
        case .leftStickButton: return "L3 (stick)"
        case .rightStickButton: return "R3 (stick)"
        }
    }

    var isDirection: Bool {
        switch self {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return true
        default: return false
        }
    }
}

/// Directions of the virtual left thumbstick.
enum VirtualPadStickDirection: String, CaseIterable, Codable, Identifiable, Sendable {
    case up
    case down
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: return "Stick ↑"
        case .down: return "Stick ↓"
        case .left: return "Stick ←"
        case .right: return "Stick →"
        }
    }
}

/// Per-game keyboard/mouse → virtual gamepad translation.
///
/// The runtime consumes `environmentValue` as JSON. `buttons` maps canonical
/// key names to control ids, `mouseButtons` maps AppKit button numbers, and
/// `leftStick` maps stick directions to canonical key names.
struct VirtualGamepadMapping: Codable, Hashable, Sendable {
    var buttons: [VirtualPadControl: VirtualPadInput]
    var leftStick: [VirtualPadStickDirection: String]
    var mouseSensitivity: Double
    /// Flips the vertical mouse-to-right-stick direction when the host reports
    /// the opposite axis sign from the game.
    var invertVerticalLook: Bool

    static let standard = VirtualGamepadMapping(
        buttons: [
            .buttonA: .key("space"),
            .buttonB: .key("shift"),
            .buttonX: .key("e"),
            .buttonY: .key("r"),
            .leftShoulder: .key("q"),
            .rightShoulder: .key("f"),
            .leftTrigger: .mouse(1),
            .rightTrigger: .mouse(0),
            .dpadUp: .key("up"),
            .dpadDown: .key("down"),
            .dpadLeft: .key("left"),
            .dpadRight: .key("right"),
            .menu: .key("enter"),
            .options: .key("tab")
        ],
        leftStick: [.up: "w", .down: "s", .left: "a", .right: "d"],
        mouseSensitivity: 1,
        invertVerticalLook: false
    )

    init(
        buttons: [VirtualPadControl: VirtualPadInput] = [:],
        leftStick: [VirtualPadStickDirection: String] = [:],
        mouseSensitivity: Double = 1,
        invertVerticalLook: Bool = false
    ) {
        self.buttons = buttons
        self.leftStick = leftStick
        self.mouseSensitivity = min(max(mouseSensitivity, 0.2), 3)
        self.invertVerticalLook = invertVerticalLook
    }

    /// Returns the effective binding. Missing controls (for example a profile
    /// saved before a control existed) fall back to the default; `.none` is an
    /// explicit clear and returns `nil`.
    func input(for control: VirtualPadControl) -> VirtualPadInput? {
        guard let stored = buttons[control] else {
            return Self.standard.buttons[control]
        }
        return stored.kind == .none ? nil : stored
    }

    mutating func setInput(_ input: VirtualPadInput?, for control: VirtualPadControl) {
        buttons[control] = input ?? VirtualPadInput.none
    }

    /// Empty means unassigned; a missing direction falls back to the default.
    func stickKey(_ direction: VirtualPadStickDirection) -> String {
        leftStick[direction] ?? Self.standard.leftStick[direction] ?? ""
    }

    mutating func setStickKey(_ key: String, for direction: VirtualPadStickDirection) {
        leftStick[direction] = key.lowercased()
    }

    /// Canonical key names assigned to more than one control (buttons and
    /// D-pad share the runtime's `buttons` map, so duplicates would silently
    /// drop a binding). Stick keys use a separate map and may overlap.
    var duplicateButtonKeys: [String] {
        var counts: [String: Int] = [:]
        for control in VirtualPadControl.allCases {
            guard let input = input(for: control), input.kind == .key, !input.value.isEmpty else { continue }
            counts[input.value, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    // MARK: - Runtime encoding

    /// JSON consumed by `VirtualGamepadShim.mm`.
    var environmentValue: String {
        var buttons: [String: String] = [:]
        var mouseButtons: [String: String] = [:]

        for control in VirtualPadControl.allCases {
            guard let input = input(for: control) else { continue }
            switch input.kind {
            case .key where !input.value.isEmpty:
                buttons[input.value] = control.rawValue
            case .mouse:
                mouseButtons[input.value] = control.rawValue
            default:
                break
            }
        }

        var stick: [String: String] = [:]
        for direction in VirtualPadStickDirection.allCases {
            let key = stickKey(direction)
            if !key.isEmpty { stick[direction.rawValue] = key }
        }

        let root: [String: Any] = [
            "buttons": buttons,
            "mouseButtons": mouseButtons,
            "leftStick": stick,
            "sensitivity": mouseSensitivity,
            "invertY": invertVerticalLook
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case buttons
        case leftStick
        case mouseSensitivity
        case invertVerticalLook
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawButtons = try container.decodeIfPresent([String: VirtualPadInput].self, forKey: .buttons) ?? [:]
        buttons = Dictionary(uniqueKeysWithValues: rawButtons.compactMap { key, value in
            guard let control = VirtualPadControl(rawValue: key) else { return nil }
            return (control, value)
        })
        let rawStick = try container.decodeIfPresent([String: String].self, forKey: .leftStick) ?? [:]
        leftStick = Dictionary(uniqueKeysWithValues: rawStick.compactMap { key, value in
            guard let direction = VirtualPadStickDirection(rawValue: key) else { return nil }
            return (direction, value.lowercased())
        })
        mouseSensitivity = min(max(try container.decodeIfPresent(Double.self, forKey: .mouseSensitivity) ?? 1, 0.2), 3)
        invertVerticalLook = try container.decodeIfPresent(Bool.self, forKey: .invertVerticalLook) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let rawButtons = Dictionary(uniqueKeysWithValues: buttons.map { ($0.key.rawValue, $0.value) })
        try container.encode(rawButtons, forKey: .buttons)
        let rawStick = Dictionary(uniqueKeysWithValues: leftStick.map { ($0.key.rawValue, $0.value) })
        try container.encode(rawStick, forKey: .leftStick)
        try container.encode(mouseSensitivity, forKey: .mouseSensitivity)
        try container.encode(invertVerticalLook, forKey: .invertVerticalLook)
    }
}
