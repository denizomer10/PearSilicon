import Foundation
import XCTest
@testable import PearSilicon

final class KeymapControllerTests: XCTestCase {
    func testLegacyBindingsWithoutSourceDecodeAsKeyboard() throws {
        var keymap = Keymap.empty(bundleID: "com.example.legacy")
        keymap.bindings = [
            KeymapBinding(key: "space", action: .tap(NormalizedPoint(0.5, 0.5))),
        ]
        let encoded = try KeymapCoding.encoder.encode(keymap)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var bindings = try XCTUnwrap(object["bindings"] as? [[String: Any]])
        bindings[0].removeValue(forKey: "source")
        object["bindings"] = bindings
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try KeymapCoding.decoder.decode(Keymap.self, from: legacy)
        XCTAssertEqual(decoded.bindings.first?.source, .keyboard)
        XCTAssertEqual(decoded.bindings.first?.displayKey, "SPACE")
    }

    func testControllerBindingsRoundTripAndDisplayNames() throws {
        var keymap = Keymap.empty(bundleID: "com.example.game")
        keymap.bindings = [
            KeymapBinding(key: ControllerKey.buttonA.rawValue, source: .controller,
                          action: .tap(NormalizedPoint(0.9, 0.8))),
            KeymapBinding(key: ControllerKey.leftStick.rawValue, source: .controller,
                          action: .joystick(center: NormalizedPoint(0.15, 0.75), radius: 0.1)),
            KeymapBinding(key: ControllerKey.rightStick.rawValue, source: .controller,
                          action: .mouseLook(region: .full, sensitivity: 1.4)),
        ]
        let data = try KeymapCoding.encoder.encode(keymap)
        let decoded = try KeymapCoding.decoder.decode(Keymap.self, from: data)
        XCTAssertEqual(decoded.bindings.map(\.source), [.controller, .controller, .controller])
        XCTAssertEqual(decoded.bindings.map(\.displayKey), ["A", "L STICK", "R STICK"])
        XCTAssertTrue(decoded.bindings[1].usesReservedInput)
        XCTAssertTrue(decoded.bindings[2].usesReservedInput)
        XCTAssertEqual(decoded.bindings[2].action, keymap.bindings[2].action)
    }
}
