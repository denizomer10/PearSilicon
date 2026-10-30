import Foundation
import XCTest
@testable import PearSilicon

final class DeviceProfileTests: XCTestCase {
    private let bundleID = "test.pear.device"

    func testDefaultsHaveExactlyTheCanonicalTenFieldSchema() throws {
        let profile = RuntimeDeviceProfile.defaults(bundleID: bundleID)
        let expected: [String: Any] = [
            "schema": 1, "bundle": bundleID, "model": "iPhone15,2", "name": "iPhone",
            "idiom": "phone", "systemName": "iOS", "systemVersion": "16.0",
            "systemBuild": "20A000", "darwinRelease": "22.6.0",
            "vendorIdentifier": "B4A3F689-6E09-DA2C-D424-25100162AAE5",
        ]
        XCTAssertTrue(NSDictionary(dictionary: profile.propertyList).isEqual(to: expected))
        XCTAssertEqual(profile.propertyList.count, 10)
        XCTAssertEqual(profile.bundleID, bundleID)
        XCTAssertEqual(try RuntimeDeviceProfile(bundleID: bundleID, environment: [:]), profile)
    }

    func testBundlesRejectEmptyOversizeAndUnicodeControlsInBothInitializers() {
        let invalid = [
            "", String(repeating: "a", count: 256), String(repeating: "é", count: 128),
            String(repeating: "🧪", count: 64),
        ] + ["\0", "\n", "\u{007f}", "\u{0085}", "\u{00ad}", "\u{061c}", "\u{200b}", "\u{202e}", "\u{feff}", "\u{110bd}", "\u{e0001}"].map { bundleID + $0 }
        for bundle in invalid {
            XCTAssertThrowsError(try RuntimeDeviceProfile(bundleID: bundle, environment: [:])) {
                XCTAssertEqual($0 as? RuntimeDeviceProfileError, .invalidField("bundle"))
                XCTAssertEqual($0.localizedDescription, "device profile: invalid bundle")
            }
            let unchecked = RuntimeDeviceProfile.defaults(bundleID: bundle)
            XCTAssertThrowsError(try RuntimeDeviceProfile(propertyList: unchecked.propertyList, bundleID: bundle)) {
                XCTAssertEqual($0 as? RuntimeDeviceProfileError, .invalidField("bundle"))
                XCTAssertEqual($0.localizedDescription, "device profile: invalid bundle")
            }
        }
    }

    func testBundle255UTF8ByteBoundaryAndOtherwiseUnrestrictedTextRoundTrip() throws {
        let boundaryBundles = [
            String(repeating: "a", count: 255), String(repeating: "é", count: 127) + "a",
            String(repeating: "🧪", count: 63) + "abc",
        ]
        for bundle in boundaryBundles { XCTAssertEqual(bundle.utf8.count, 255) }
        for bundle in boundaryBundles + ["a", " ", "é", " bundle / with:punctuation_-,. "] {
            let profile = try RuntimeDeviceProfile(bundleID: bundle, environment: [:])
            XCTAssertEqual(profile.bundleID, bundle)
            XCTAssertEqual(profile.runtimeEnvironment["PEAR_DEVICE_PROFILE_BUNDLE"], bundle)
            XCTAssertEqual(profile.propertyList.count, 10)
            XCTAssertEqual(try RuntimeDeviceProfile(propertyList: profile.propertyList, bundleID: bundle), profile)
        }
    }

    func testWireBundleByteLimitIsCheckedEvenWhenSwiftStringsAreCanonicallyEquivalent() {
        let composed = String(repeating: "é", count: 100)
        let decomposed = String(repeating: "e\u{0301}", count: 100)
        XCTAssertEqual(composed, decomposed)
        XCTAssertEqual(composed.utf8.count, 200)
        XCTAssertEqual(decomposed.utf8.count, 300)
        var propertyList = RuntimeDeviceProfile.defaults(bundleID: composed).propertyList
        propertyList["bundle"] = decomposed
        XCTAssertThrowsError(try RuntimeDeviceProfile(propertyList: propertyList, bundleID: composed)) {
            XCTAssertEqual($0 as? RuntimeDeviceProfileError, .invalidField("bundle"))
            XCTAssertEqual($0.localizedDescription, "device profile: invalid bundle")
        }
    }

    func testEmptyRawInputsUseDefaultsAndOtherEnvironmentKeysAreIgnored() throws {
        var environment = Dictionary(uniqueKeysWithValues: RuntimeDeviceProfile.inputEnvironmentKeys.map { ($0, "") })
        environment["PEAR_DEVICE_PROFILE_SOURCE"] = "not-a-host"
        environment["PEAR_DEVICE_PROFILE_BUNDLE"] = "another.bundle"
        environment["PEAR_DEVICE_VENDOR_UUID"] = "00000000-0000-0000-0000-000000000000"
        environment["PEAR_DEVICE_UI_DETAILS"] = "1"
        environment["PEAR_DEVICE_MEMORY"] = "1"
        XCTAssertEqual(
            try RuntimeDeviceProfile(bundleID: bundleID, environment: environment),
            .defaults(bundleID: bundleID)
        )
    }

    func testOverridesPreserveTextExceptForIdiomNormalization() throws {
        let profile = try RuntimeDeviceProfile(bundleID: bundleID, environment: [
            "PEAR_DEVICE_MODEL": "iPad14,3_Test-a", "PEAR_DEVICE_NAME": "Diagnostic iPad 🧪",
            "PEAR_DEVICE_IDIOM": "iPaD", "PEAR_FAKE_IOS_VERSION": "0016.000.0",
            "PEAR_FAKE_IOS_BUILD": "20A000.diag-1_ok", "PEAR_FAKE_DARWIN": "0022.0006.0000",
        ])
        XCTAssertEqual(profile.model, "iPad14,3_Test-a")
        XCTAssertEqual(profile.name, "Diagnostic iPad 🧪")
        XCTAssertEqual(profile.idiom, "pad")
        XCTAssertEqual(profile.systemName, "iOS")
        XCTAssertEqual(profile.systemVersion, "0016.000.0")
        XCTAssertEqual(profile.systemBuild, "20A000.diag-1_ok")
        XCTAssertEqual(profile.darwinRelease, "0022.0006.0000")
        for (raw, canonical) in [
            ("phone", "phone"), ("PHONE", "phone"), ("iphone", "phone"), ("iPhone", "phone"),
            ("pad", "pad"), ("PaD", "pad"), ("ipad", "pad"), ("IPAD", "pad"),
        ] {
            XCTAssertEqual(try RuntimeDeviceProfile(
                bundleID: bundleID, environment: ["PEAR_DEVICE_IDIOM": raw]
            ).idiom, canonical)
        }
    }

    func testRuntimeEnvironmentIsOnlyTheCanonicalSnapshotAndDoesNotEnableHooks() {
        let profile = RuntimeDeviceProfile.defaults(bundleID: bundleID)
        XCTAssertEqual(RuntimeDeviceProfile.inputEnvironmentKeys, Set([
            "PEAR_DEVICE_MODEL", "PEAR_DEVICE_NAME", "PEAR_DEVICE_IDIOM",
            "PEAR_FAKE_IOS_VERSION", "PEAR_FAKE_IOS_BUILD", "PEAR_FAKE_DARWIN",
        ]))
        XCTAssertEqual(profile.runtimeEnvironment, [
            "PEAR_DEVICE_MODEL": "iPhone15,2", "PEAR_DEVICE_NAME": "iPhone",
            "PEAR_DEVICE_IDIOM": "phone", "PEAR_FAKE_IOS_VERSION": "16.0",
            "PEAR_FAKE_IOS_BUILD": "20A000", "PEAR_FAKE_DARWIN": "22.6.0",
            "PEAR_DEVICE_PROFILE_SOURCE": "host-v1", "PEAR_DEVICE_PROFILE_BUNDLE": bundleID,
            "PEAR_DEVICE_VENDOR_UUID": "B4A3F689-6E09-DA2C-D424-25100162AAE5",
        ])
        XCTAssertNil(profile.runtimeEnvironment["PEAR_DEVICE_UI_DETAILS"])
    }

    func testByteLimitsAndNumericComponentBoundsAreInclusive() throws {
        let model = "A" + String(repeating: "9,_-", count: 15) + "zz"
        let name = String(repeating: "é", count: 63) + "a"
        let build = "1" + String(repeating: "a", count: 63)
        XCTAssertEqual(model.utf8.count, 63)
        XCTAssertEqual(name.utf8.count, 127)
        let profile = try RuntimeDeviceProfile(bundleID: bundleID, environment: [
            "PEAR_DEVICE_MODEL": model, "PEAR_DEVICE_NAME": name, "PEAR_FAKE_IOS_BUILD": build,
        ])
        XCTAssertEqual(profile.model, model)
        XCTAssertEqual(profile.name, name)
        XCTAssertEqual(profile.systemBuild, build)
        for version in ["0", "9999", "0000", "1.2", "9999.0000.1234", "01.02.03"] {
            for key in ["PEAR_FAKE_IOS_VERSION", "PEAR_FAKE_DARWIN"] {
                let profile = try RuntimeDeviceProfile(bundleID: bundleID, environment: [key: version])
                XCTAssertEqual(key == "PEAR_FAKE_IOS_VERSION" ? profile.systemVersion : profile.darwinRelease, version)
            }
        }
    }

    func testMalformedModelsBuildsAndIdiomsReportOnlyTheirField() {
        for value in ["1Phone", "_Phone", "iPhone.2", "iPhoné", "iPhone/2", "iPhone 2", "A\0B", "A\n", "A" + String(repeating: "b", count: 63)] {
            assertInvalidInput("PEAR_DEVICE_MODEL", value: value, field: "model")
        }
        for value in [".20A", "_20A", "-20A", "20 A", "20A/1", "20Ä", "20A\0", "20A\n", String(repeating: "A", count: 65)] {
            assertInvalidInput("PEAR_FAKE_IOS_BUILD", value: value, field: "systemBuild")
        }
        for value in ["tablet", "unknown-private-value", " phone", "phone ", "pad\n", "1"] {
            assertInvalidInput("PEAR_DEVICE_IDIOM", value: value, field: "idiom")
        }
    }

    func testNamesRejectUnicodeControlsAndExcessUTF8BytesWithoutTrimming() throws {
        for value in ["a\0b", "a\nb", "a\tb", "a\u{001f}b", "a\u{007f}b", "a\u{0085}b", "a\u{202e}b", String(repeating: "a", count: 128), String(repeating: "é", count: 64)] {
            assertInvalidInput("PEAR_DEVICE_NAME", value: value, field: "name")
        }
        XCTAssertEqual(try RuntimeDeviceProfile(
            bundleID: bundleID, environment: ["PEAR_DEVICE_NAME": " iPhone é "]
        ).name, " iPhone é ")
    }

    func testVersionsRejectEmptyComponentsNonASCIIDigitsAndOversizeComponents() {
        let invalid = [".", "1.", ".1", "1..2", "1.2.3.4", "10000", "1.00000", "-1", "+1", "1e2", "1.2beta", "１.２", "١.٢", " 1", "1 ", "1\n", "1\0"]
        for value in invalid {
            assertInvalidInput("PEAR_FAKE_IOS_VERSION", value: value, field: "systemVersion")
            assertInvalidInput("PEAR_FAKE_DARWIN", value: value, field: "darwinRelease")
        }
    }

    func testWireRoundTripPreservesTheValueAndDoesNotExposeMutableStorage() throws {
        let profile = try RuntimeDeviceProfile(bundleID: bundleID, environment: [
            "PEAR_DEVICE_MODEL": "iPad14,3", "PEAR_DEVICE_IDIOM": "iPad", "PEAR_DEVICE_NAME": "Test iPad",
        ])
        let data = try PropertyListSerialization.data(fromPropertyList: profile.propertyList, format: .binary, options: 0)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(try RuntimeDeviceProfile(propertyList: decoded, bundleID: bundleID), profile)
        var dictionary = profile.propertyList
        dictionary["model"] = "changed"
        var environment = profile.runtimeEnvironment
        environment["PEAR_DEVICE_MODEL"] = "changed"
        XCTAssertEqual(profile.model, "iPad14,3")
        XCTAssertEqual(profile.propertyList["model"] as? String, "iPad14,3")
        XCTAssertEqual(profile.runtimeEnvironment["PEAR_DEVICE_MODEL"], "iPad14,3")
    }

    func testWireRequiresExactFieldsAndStrictTypesIncludingNonBooleanIntegerSchema() {
        let valid = RuntimeDeviceProfile.defaults(bundleID: bundleID).propertyList
        for field in valid.keys {
            var missing = valid
            missing.removeValue(forKey: field)
            assertInvalidWire(missing, field: field)
        }
        var extra = valid
        extra["untrusted-private-extra-key"] = "untrusted-private-value"
        assertInvalidWire(extra, field: "schema")
        for value: Any in [true, false, 1.0, Float(1), "1", 0, 2, -1, UInt64.max, Int64.min, Data(), [1]] {
            var invalid = valid
            invalid["schema"] = value
            assertInvalidWire(invalid, field: "schema")
        }
        for field in valid.keys where field != "schema" {
            for value: Any in [true, false, 1, 1.0, Data(), ["text"], ["text": "value"]] {
                var invalid = valid
                invalid[field] = value
                assertInvalidWire(invalid, field: field)
            }
        }
    }

    func testWireIsCanonicalAndBoundToBundleAndComputedVendorIdentifier() {
        let valid = RuntimeDeviceProfile.defaults(bundleID: bundleID).propertyList
        for (field, values) in [
            "bundle": ["another.private.bundle", ""], "systemName": ["iPadOS", "ios", ""],
            "model": ["", "1Phone"], "name": ["", "bad\nname"],
            "idiom": ["", "PHONE", "iphone", "iPad", "unknown"],
            "systemVersion": ["", "1.2.3.4"], "systemBuild": ["", ".bad"],
            "darwinRelease": ["", "1."],
            "vendorIdentifier": [
                "", "private-invalid-uuid", "00000000-0000-0000-0000-000000000000",
                "b4a3f689-6e09-da2c-d424-25100162aae5", "6D65E7B3-97F2-6817-6DA0-6954C23B0F58",
            ],
        ] {
            for value in values {
                var invalid = valid
                invalid[field] = value
                assertInvalidWire(invalid, field: field)
            }
        }
        var changedModel = valid
        changedModel["model"] = "iPad14,3"
        assertInvalidWire(changedModel, field: "vendorIdentifier")
    }

    func testVendorIdentifierMatchesLegacyLittleEndianBytesAndIsBundleAndModelScoped() throws {
        let profile = RuntimeDeviceProfile.defaults(bundleID: bundleID)
        let identifier = try XCTUnwrap(UUID(uuidString: profile.vendorIdentifier))
        var uuid = identifier.uuid
        XCTAssertEqual(withUnsafeBytes(of: &uuid) { Array($0) }, [
            0xb4, 0xa3, 0xf6, 0x89, 0x6e, 0x09, 0xda, 0x2c,
            0xd4, 0x24, 0x25, 0x10, 0x01, 0x62, 0xaa, 0xe5,
        ])
        XCTAssertNotEqual(profile.vendorIdentifier, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(RuntimeDeviceProfile.defaults(bundleID: bundleID), profile)
        XCTAssertEqual(try RuntimeDeviceProfile(bundleID: bundleID, environment: [
            "PEAR_DEVICE_MODEL": "iPad14,3",
        ]).vendorIdentifier, "6D65E7B3-97F2-6817-6DA0-6954C23B0F58")
        XCTAssertEqual(RuntimeDeviceProfile.defaults(bundleID: "test.pear.other").vendorIdentifier, "9E76E8E9-1651-9A93-AEA0-0A876EBDF075")
        XCTAssertEqual(RuntimeDeviceProfile.defaults(bundleID: "test.pear.é").vendorIdentifier, "6AD16AC7-F9CD-D327-4A42-4EFDC7C701E3")
        XCTAssertEqual(try RuntimeDeviceProfile(bundleID: bundleID, environment: [
            "PEAR_DEVICE_NAME": "Another name", "PEAR_DEVICE_IDIOM": "pad", "PEAR_FAKE_IOS_VERSION": "17",
            "PEAR_FAKE_IOS_BUILD": "21A", "PEAR_FAKE_DARWIN": "23",
        ]).vendorIdentifier, profile.vendorIdentifier)
    }

    private func assertInvalidInput(_ key: String, value: String, field: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RuntimeDeviceProfile(bundleID: bundleID, environment: [key: value]), file: file, line: line) {
            XCTAssertEqual($0 as? RuntimeDeviceProfileError, .invalidField(field), file: file, line: line)
            XCTAssertEqual($0.localizedDescription, "device profile: invalid \(field)", file: file, line: line)
        }
    }

    private func assertInvalidWire(_ propertyList: [String: Any], field: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RuntimeDeviceProfile(propertyList: propertyList, bundleID: bundleID), file: file, line: line) {
            XCTAssertEqual($0 as? RuntimeDeviceProfileError, .invalidField(field), file: file, line: line)
            XCTAssertEqual($0.localizedDescription, "device profile: invalid \(field)", file: file, line: line)
        }
    }
}
