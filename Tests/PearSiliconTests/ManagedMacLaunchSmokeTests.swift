import AppKit
import Foundation
import XCTest
@testable import PearSilicon

/// Compiles a minimal real Cocoa bundle, imports it through the copy-only Mac
/// service and launches it in the managed sandbox. The window is kept offscreen;
/// the test verifies process liveness and shutdown, not rendering or clicking.
@MainActor
final class ManagedMacLaunchSmokeTests: XCTestCase {

    func testMinimalNativeMacAppLaunchesAndStopsInsideTheSandbox() async throws {
        let swiftc = "/usr/bin/swiftc"
        guard FileManager.default.isExecutableFile(atPath: swiftc) else {
            throw XCTSkip("swiftc is not available")
        }
        let root = URL(fileURLWithPath: try Self.realPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("pear-mac-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source/Example.app", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let macos = source.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.pearsilicon.smoke.mac",
            "CFBundleExecutable": "Example",
            "CFBundleName": "Example",
            "CFBundleDisplayName": "Example",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
            "DTPlatformName": "macosx",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSMinimumSystemVersion": "26.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))

        let main = source.appendingPathComponent("main.swift")
        try Data("""
        import AppKit
        let app = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "PearSilicon smoke test"
        window.orderOut(nil)
        app.run()
        """.utf8).write(to: main)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: swiftc)
        compile.arguments = ["-o", macos.appendingPathComponent("Example").path, main.path, "-framework", "AppKit"]
        let pipe = Pipe()
        compile.standardOutput = pipe
        compile.standardError = pipe
        try compile.run()
        let compileOutput = pipe.fileHandleForReading.readDataToEndOfFile()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw XCTSkip(
                "Could not compile the smoke-test app: \(String(decoding: compileOutput, as: UTF8.self))"
            )
        }

        let entry = try ManagedAppService().importMacApp(from: source, libraryRoot: library)
        XCTAssertEqual(entry.platform, .macOS)

        let process = try await ManagedAppService().launch(entry, activate: false)
        defer { process.stop() }
        try await Task.sleep(for: .seconds(2))
        if !process.isRunning {
            let log = entry.dataURL.appendingPathComponent("launch.log")
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            XCTFail("The managed Mac app exited during launch (status \(process.terminationStatus.map(String.init) ?? "unknown")). Log:\n\(output.suffix(4_000))")
            return
        }
        process.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(process.isRunning, "The managed Mac app did not stop")
    }

    private static func realPath(_ url: URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
