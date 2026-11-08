import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import PearSilicon

/// Opt-in process-level test of a real IPA in a disposable library. No input is
/// generated; validating gameplay and mouse coordinates requires a person.
@MainActor
final class IOSInputSmokeTests: XCTestCase {
    func testRealIPAStartsWithMouseFallback() async throws {
        guard let path = ProcessInfo.processInfo.environment["PEAR_INPUT_TEST_IPA"], !path.isEmpty else {
            throw XCTSkip("Set PEAR_INPUT_TEST_IPA to a real IPA for an isolated launch check")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("pear-input-smoke-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("ios-apps", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = PackageInstaller(libraryURL: library)
        let app = try await installer.install(packageAt: URL(fileURLWithPath: path))
        let log = root.appendingPathComponent("runtime.log")
        let launcher = AppLauncher(libraryURL: library)
        var environment = ["PEAR_MOUSE_TOUCH": "1", "PEAR_LOG_FILE": log.path, "PEAR_IOS_SANDBOX": "1"]
        if ProcessInfo.processInfo.environment["PEAR_INPUT_TEST_DIAGNOSTICS"] == "1" {
            environment["PEAR_DEBUG_VIEWS"] = "1"
            environment["PEAR_DEBUG_METAL"] = "1"
        }
        if ProcessInfo.processInfo.environment["PEAR_LEGACY_CONTAINER_LAYOUT"] == "1" {
            environment["PEAR_LEGACY_CONTAINER_LAYOUT"] = "1"
        }
        if ProcessInfo.processInfo.environment["PEAR_LEGACY_ATTACH_LAYER"] == "1" {
            environment["PEAR_LEGACY_ATTACH_LAYER"] = "1"
        }
        for flag in ["PEAR_LEGACY_WINDOW_LAYER_ONLY", "PEAR_DIRECT_LEGACY_TOUCH"] {
            if ProcessInfo.processInfo.environment[flag] == "1" { environment[flag] = "1" }
        }
        if let size = ProcessInfo.processInfo.environment["PEAR_LEGACY_LOGICAL_SIZE"] { environment["PEAR_LEGACY_LOGICAL_SIZE"] = size }
        let virtualPadTest = ProcessInfo.processInfo.environment["PEAR_INPUT_TEST_VIRTUAL_PAD"] == "1"
        if virtualPadTest {
            environment["PEAR_VIRTUAL_GAMEPAD"] = "1"
            environment["PEAR_ALLOW_POINTER_LOCK"] = "1"
        }
        let running = try await launcher.launch(app, keymapURL: nil, extraEnvironment: environment, activate: false)
        guard let running else { return XCTFail("Launch did not return a process") }
        defer { if !running.isTerminated { running.forceTerminate() } }
        try await Task.sleep(for: .seconds(12))
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        if let destination = ProcessInfo.processInfo.environment["PEAR_INPUT_TEST_LOG"], !destination.isEmpty {
            try output.write(toFile: destination, atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(running.isTerminated, "Game exited during launch: \(output.suffix(4000))")
        if virtualPadTest {
            XCTAssertTrue(output.contains("[virtual-pad] connected=1"), "Virtual controller did not connect: \(output.suffix(4000))")
        } else {
            XCTAssertTrue(output.contains("mouse-to-touch fallback installed"), "Fallback was not installed: \(output.suffix(4000))")
        }
        if ProcessInfo.processInfo.environment["PEAR_INPUT_TEST_REQUIRE_WINDOW"] == "1" {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let sizes = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == running.processIdentifier }
                .compactMap { entry -> CGRect? in
                    guard let bounds = entry[kCGWindowBounds as String] as? [String: NSNumber],
                          let width = bounds["Width"], let height = bounds["Height"] else { return nil }
                    return CGRect(x: 0, y: 0, width: width.doubleValue, height: height.doubleValue)
                }
            XCTAssertTrue(sizes.contains { $0.width > 100 && $0.height > 100 },
                          "No non-empty on-screen window. Bounds: \(sizes)")
        }
        XCTAssertFalse(output.contains("[PearRuntime][signal]"))
        XCTAssertFalse(output.contains("[PearRuntime][exception]"))
        running.terminate()
        for _ in 0..<50 where !running.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
        if !running.isTerminated {
            running.forceTerminate()
            for _ in 0..<50 where !running.isTerminated { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(running.isTerminated, "Game did not stop")
    }
}
