import Foundation
import XCTest
@testable import PearSilicon

final class VirtualGamepadMappingTests: XCTestCase {
    func testStandardMappingExposesExpectedDefaults() {
        let mapping = VirtualGamepadMapping.standard
        XCTAssertEqual(mapping.input(for: .buttonA), .key("space"))
        XCTAssertEqual(mapping.input(for: .buttonB), .key("shift"))
        XCTAssertEqual(mapping.input(for: .leftShoulder), .key("q"))
        XCTAssertEqual(mapping.input(for: .rightTrigger), .mouse(0))
        XCTAssertEqual(mapping.input(for: .leftTrigger), .mouse(1))
        XCTAssertEqual(mapping.input(for: .dpadUp), .key("up"))
        XCTAssertEqual(mapping.input(for: .menu), .key("enter"))
        XCTAssertNil(mapping.input(for: .leftStickButton))
        XCTAssertEqual(mapping.stickKey(.up), "w")
        XCTAssertEqual(mapping.stickKey(.left), "a")
        XCTAssertEqual(mapping.mouseSensitivity, 1)
        XCTAssertFalse(mapping.invertVerticalLook)
    }

    func testMissingControlFallsBackToDefaultButClearStaysEmpty() {
        var mapping = VirtualGamepadMapping()
        // Missing from the stored profile: the default remains available.
        XCTAssertEqual(mapping.input(for: .buttonA), .key("space"))

        mapping.setInput(nil, for: .buttonA)
        XCTAssertNil(mapping.input(for: .buttonA))
        // Clearing a different control does not disturb the default of another.
        XCTAssertEqual(mapping.input(for: .buttonX), .key("e"))
    }

    func testEnvironmentValueEncodesRuntimeContract() throws {
        let value = VirtualGamepadMapping.standard.environmentValue
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        )
        let buttons = try XCTUnwrap(root["buttons"] as? [String: String])
        XCTAssertEqual(buttons["space"], "a")
        XCTAssertEqual(buttons["shift"], "b")
        XCTAssertEqual(buttons["q"], "l1")
        XCTAssertEqual(buttons["up"], "dpadUp")
        XCTAssertEqual(buttons.count, 12) // 14 controls minus two mouse triggers.

        let mouse = try XCTUnwrap(root["mouseButtons"] as? [String: String])
        XCTAssertEqual(mouse["1"], "l2")
        XCTAssertEqual(mouse["0"], "r2")

        let stick = try XCTUnwrap(root["leftStick"] as? [String: String])
        XCTAssertEqual(stick["up"], "w")
        XCTAssertEqual(stick["down"], "s")

        XCTAssertEqual((root["sensitivity"] as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual((root["invertY"] as? NSNumber)?.boolValue, false)
    }

    func testClearIsOmittedFromEnvironmentValue() throws {
        var mapping = VirtualGamepadMapping.standard
        mapping.setInput(nil, for: .buttonA)
        mapping.setInput(nil, for: .leftTrigger)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(mapping.environmentValue.utf8)) as? [String: Any]
        )
        let buttons = try XCTUnwrap(root["buttons"] as? [String: String])
        XCTAssertNil(buttons["space"])
        XCTAssertEqual(buttons["e"], "x")

        let mouse = try XCTUnwrap(root["mouseButtons"] as? [String: String])
        XCTAssertNil(mouse["1"])
        XCTAssertEqual(mouse["0"], "r2")
    }

    func testCodableRoundTripPreservesClearsAndClampsSensitivity() throws {
        var mapping = VirtualGamepadMapping.standard
        mapping.setInput(.mouse(2), for: .buttonY)
        mapping.setInput(nil, for: .buttonX)
        mapping.setStickKey("I", for: .up)
        mapping.mouseSensitivity = 9
        mapping.invertVerticalLook = true

        let decoded = try JSONDecoder().decode(
            VirtualGamepadMapping.self,
            from: JSONEncoder().encode(mapping)
        )
        XCTAssertEqual(decoded.input(for: .buttonY), .mouse(2))
        XCTAssertNil(decoded.input(for: .buttonX))
        XCTAssertEqual(decoded.input(for: .buttonA), .key("space"))
        XCTAssertEqual(decoded.stickKey(.up), "i")
        XCTAssertEqual(decoded.mouseSensitivity, 3)
        XCTAssertTrue(decoded.invertVerticalLook)
    }

    func testUnknownPersistedKeysAreIgnored() throws {
        let json = """
        {"buttons":{"space":{"kind":"key","value":"space"},"bogus":{"kind":"key","value":"b"}},
         "leftStick":{"up":"w","sideways":"x"},"mouseSensitivity":9}
        """
        let decoded = try JSONDecoder().decode(
            VirtualGamepadMapping.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.input(for: .buttonA), .key("space"))
        XCTAssertEqual(decoded.input(for: .buttonB), .key("shift")) // default
        XCTAssertEqual(decoded.input(for: .options), .key("tab")) // default
        XCTAssertEqual(decoded.stickKey(.up), "w")
        XCTAssertEqual(decoded.stickKey(.down), "s") // default
        XCTAssertEqual(decoded.mouseSensitivity, 3)
        XCTAssertFalse(decoded.invertVerticalLook) // absent field keeps the default
    }

    func testDuplicateButtonKeysIncludesDpadAndSkipsClearedBindings() {
        var mapping = VirtualGamepadMapping.standard
        mapping.setInput(.key("space"), for: .buttonB)
        mapping.setInput(.key("up"), for: .dpadDown)
        mapping.setInput(nil, for: .buttonX)

        XCTAssertEqual(mapping.duplicateButtonKeys, ["space", "up"])
    }

    func testPersistenceRoundTripsPerBundleAndRejectsInvalidData() {
        let id = "test.virtualpad." + UUID().uuidString
        let key = "virtualGamepad.map." + id
        defer { AppSettings.defaults.removeObject(forKey: key) }

        var mapping = VirtualGamepadMapping.standard
        mapping.setInput(.mouse(2), for: .buttonY)
        mapping.setInput(nil, for: .buttonA)
        mapping.setStickKey("I", for: .up)
        mapping.mouseSensitivity = 2.4
        mapping.invertVerticalLook = true
        AppSettings.setVirtualGamepadMapping(mapping, for: id)

        let loaded = AppSettings.virtualGamepadMapping(for: id)
        XCTAssertEqual(loaded.input(for: .buttonY), .mouse(2))
        XCTAssertNil(loaded.input(for: .buttonA))
        XCTAssertEqual(loaded.stickKey(.up), "i")
        XCTAssertEqual(loaded.mouseSensitivity, 2.4, accuracy: 0.0001)
        XCTAssertTrue(loaded.invertVerticalLook)

        AppSettings.defaults.set(Data("not json".utf8), forKey: key)
        XCTAssertEqual(AppSettings.virtualGamepadMapping(for: id), .standard)
    }
}
