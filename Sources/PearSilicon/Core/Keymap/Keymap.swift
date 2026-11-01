import Foundation

/// A point inside the game window, normalized to 0...1 (origin top-left).
struct NormalizedPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// A rectangle inside the game window, normalized to 0...1.
struct NormalizedRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

/// The kind of gesture a binding produces. Kept separate from the associated
/// values so the editor can offer a stable picker and preserve the marker
/// position when the kind changes.
enum KeymapActionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case tap
    case hold
    case joystick
    case mouseLook
    case swipe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tap: return "Tap"
        case .hold: return "Hold"
        case .joystick: return "Joystick"
        case .mouseLook: return "Mouse Look"
        case .swipe: return "Swipe"
        }
    }

    var systemImage: String {
        switch self {
        case .tap: return "hand.tap"
        case .hold: return "hand.point.up.left.fill"
        case .joystick: return "circle.grid.cross"
        case .mouseLook: return "computermouse"
        case .swipe: return "hand.draw"
        }
    }
}

/// A single mapping action performed by a synthesized touch event.
enum KeymapAction: Codable, Hashable, Sendable {
    /// A quick tap at a fixed point.
    case tap(NormalizedPoint)
    /// A toggle-hold at a fixed point (press to hold, press again to release).
    case hold(NormalizedPoint)
    /// A virtual joystick. Driven by the keys in `wasd` (W/A/S/D).
    case joystick(center: NormalizedPoint, radius: Double)
    /// Right-hand mouse-look region.
    case mouseLook(region: NormalizedRect, sensitivity: Double)
    /// A drag/swipe between two points over `duration` seconds.
    case swipe(from: NormalizedPoint, to: NormalizedPoint, duration: Double)

    var kind: KeymapActionKind {
        switch self {
        case .tap: return .tap
        case .hold: return .hold
        case .joystick: return .joystick
        case .mouseLook: return .mouseLook
        case .swipe: return .swipe
        }
    }

    /// The marker position this action uses on the canvas.
    var marker: NormalizedPoint {
        switch self {
        case .tap(let point), .hold(let point):
            return point
        case .joystick(let center, _):
            return center
        case .mouseLook(let region, _):
            return NormalizedPoint(region.x + region.width / 2,
                                   region.y + region.height / 2)
        case .swipe(let from, _, _):
            return from
        }
    }

    /// Builds an action of `kind` at `point`, keeping the defaults sensible for
    /// a newly added binding.
    static func make(_ kind: KeymapActionKind, at point: NormalizedPoint = NormalizedPoint(0.5, 0.5)) -> KeymapAction {
        switch kind {
        case .tap:
            return .tap(point)
        case .hold:
            return .hold(point)
        case .joystick:
            return .joystick(center: point, radius: 0.10)
        case .mouseLook:
            let region = NormalizedRect(x: max(0, point.x - 0.30),
                                        y: max(0, point.y - 0.40),
                                        width: 0.60,
                                        height: 0.80)
            return .mouseLook(region: region, sensitivity: 1.0)
        case .swipe:
            return .swipe(from: point,
                          to: NormalizedPoint(min(1, point.x + 0.25), point.y),
                          duration: 0.25)
        }
    }

    /// Converts an existing action to another kind while keeping its location.
    func converted(to kind: KeymapActionKind) -> KeymapAction {
        Self.make(kind, at: marker)
    }
}

/// Where a binding's input comes from.
enum KeymapInputSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case keyboard
    case controller

    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .controller: return "Controller"
        }
    }
    var symbol: String {
        switch self {
        case .keyboard: return "keyboard"
        case .controller: return "gamecontroller"
        }
    }
}

/// Canonical controller inputs. Stored as the binding key for controller-source
/// bindings; the runtime maps GameController elements to these names.
enum ControllerKey: String, CaseIterable, Identifiable, Sendable {
    case buttonA = "buttonA"
    case buttonB = "buttonB"
    case buttonX = "buttonX"
    case buttonY = "buttonY"
    case leftShoulder = "leftShoulder"
    case rightShoulder = "rightShoulder"
    case leftTrigger = "leftTrigger"
    case rightTrigger = "rightTrigger"
    case dpadUp = "dpadUp"
    case dpadDown = "dpadDown"
    case dpadLeft = "dpadLeft"
    case dpadRight = "dpadRight"
    case menu = "menu"
    case options = "options"
    case leftStick = "leftStick"
    case rightStick = "rightStick"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .buttonA: return "A"
        case .buttonB: return "B"
        case .buttonX: return "X"
        case .buttonY: return "Y"
        case .leftShoulder: return "LB"
        case .rightShoulder: return "RB"
        case .leftTrigger: return "LT"
        case .rightTrigger: return "RT"
        case .dpadUp: return "D-Pad ↑"
        case .dpadDown: return "D-Pad ↓"
        case .dpadLeft: return "D-Pad ←"
        case .dpadRight: return "D-Pad →"
        case .menu: return "MENU"
        case .options: return "OPTIONS"
        case .leftStick: return "L STICK"
        case .rightStick: return "R STICK"
        }
    }
    var isStick: Bool { self == .leftStick || self == .rightStick }
    var isButton: Bool { !isStick && self != .leftTrigger && self != .rightTrigger }
}

/// One key/pad input -> action binding.
struct KeymapBinding: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Key identifier, e.g. "w", "space", "shift", "mouse", "buttonA", "leftStick".
    var key: String
    /// Keyboard bindings and controller bindings are independent sets; the
    /// editor's input switch selects which set is being edited.
    var source: KeymapInputSource = .keyboard
    var action: KeymapAction

    enum CodingKeys: String, CodingKey { case id, key, source, action }

    init(id: UUID = UUID(), key: String, source: KeymapInputSource = .keyboard, action: KeymapAction) {
        self.id = id
        self.key = key
        self.source = source
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decode(String.self, forKey: .key)
        source = try container.decodeIfPresent(KeymapInputSource.self, forKey: .source) ?? .keyboard
        action = try container.decode(KeymapAction.self, forKey: .action)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encode(source, forKey: .source)
        try container.encode(action, forKey: .action)
    }

    var displayKey: String { KeyNames.display(key, source: source) }

    var actionKind: String { action.kind.displayName }

    /// A joystick consumes W/A/S/D (keyboard) or the left stick; a mouse-look
    /// binding consumes pointer movement or the right stick. These names are
    /// reserved so a second binding cannot silently compete for the same input.
    var usesReservedInput: Bool {
        let normalized = key.lowercased()
        if source == .controller {
            return normalized == ControllerKey.leftStick.rawValue.lowercased()
                || normalized == ControllerKey.rightStick.rawValue.lowercased()
        }
        return normalized == "wasd" || normalized == "mouse"
    }
}

/// A complete keymap for a single app.
struct Keymap: Codable, Hashable, Sendable {
    var version: Int = 1
    var bundleID: String
    var engine: String
    var isAutoGenerated: Bool
    var createdAt: Date
    var bindings: [KeymapBinding]

    static func empty(bundleID: String) -> Keymap {
        Keymap(bundleID: bundleID, engine: "unknown",
               isAutoGenerated: false, createdAt: Date(), bindings: [])
    }
}
