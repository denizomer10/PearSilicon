import Foundation
import XCTest
@testable import PearSilicon

final class AppCompatibilityTests: XCTestCase {
    func testSDKMajorParsesPhoneAndMacSDKNames() {
        XCTAssertEqual(AppCompatibility.sdkMajor(from: "iphoneos10.3"), 10)
        XCTAssertEqual(AppCompatibility.sdkMajor(from: "iphoneos16.2"), 16)
        XCTAssertEqual(AppCompatibility.sdkMajor(from: "macosx14.0"), 14)
        XCTAssertEqual(AppCompatibility.sdkMajor(from: "17.0"), 17)
        XCTAssertNil(AppCompatibility.sdkMajor(from: nil))
        XCTAssertNil(AppCompatibility.sdkMajor(from: ""))
        XCTAssertNil(AppCompatibility.sdkMajor(from: "iphoneos"))
        XCTAssertNil(AppCompatibility.sdkMajor(from: "iphoneosbeta"))
    }

    func testLegacyRuleMatchesTheRuntime() {
        // Scene-less and built with an SDK older than iOS 15.
        XCTAssertTrue(AppCompatibility.make(from: ["DTSDKName": "iphoneos10.3"]).isLegacyRuntime)
        XCTAssertTrue(AppCompatibility.make(from: ["DTSDKName": "iphoneos14.5"]).isLegacyRuntime)

        // iOS 15+ SDK without scenes is modern.
        XCTAssertFalse(AppCompatibility.make(from: ["DTSDKName": "iphoneos16.2"]).isLegacyRuntime)
        XCTAssertFalse(AppCompatibility.make(from: ["DTSDKName": "iphoneos15.0"]).isLegacyRuntime)

        // A scene manifest always means modern.
        XCTAssertFalse(AppCompatibility.make(from: [
            "DTSDKName": "iphoneos10.3",
            "UIApplicationSceneManifest": [String: Any](),
        ]).isLegacyRuntime)

        // Missing or unreadable SDK information is treated as modern.
        XCTAssertFalse(AppCompatibility.make(from: [:]).isLegacyRuntime)
        XCTAssertFalse(AppCompatibility.modern.isLegacyRuntime)
    }

    func testDetectReadsRootInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = ["DTSDKName": "iphoneos9.3", "CFBundleIdentifier": "test.fake"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))

        let detected = AppCompatibility.detect(bundleURL: bundle)
        XCTAssertTrue(detected.isLegacyRuntime)
        XCTAssertEqual(detected.sdkName, "iphoneos9.3")
        XCTAssertEqual(detected.sdkMajor, 9)

        // Missing bundles never crash or claim legacy.
        let missing = AppCompatibility.detect(bundleURL: root.appendingPathComponent("Missing.app"))
        XCTAssertFalse(missing.isLegacyRuntime)
        XCTAssertNil(missing.sdkName)
    }
}
