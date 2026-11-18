import Foundation
import XCTest
@testable import PearSilicon

final class PearHostPreparerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearHostPreparerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Stale framework copies

    func testRebuiltHostReplacesFrameworkCopiesInPreparedBundle() throws {
        let host = try makeHost(uikitContents: "build-1")
        let bundle = root.appendingPathComponent("Game.app", isDirectory: true)
        let frameworks = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)

        // First launch after preparation: copies are current.
        XCTAssertTrue(try PearHostPreparer.refreshHostFrameworksIfStale(bundleURL: bundle, hostDir: host))
        XCTAssertEqual(try uikitCopy(in: bundle), "build-1")
        XCTAssertTrue(PearHostPreparer.isPrepared(bundle))
        XCTAssertFalse(try PearHostPreparer.refreshHostFrameworksIfStale(bundleURL: bundle, hostDir: host))

        // The runtime is rebuilt: the bundle picks the new PearHost up.
        let uikit = host.appendingPathComponent("UIKit.framework/UIKit")
        try Data("build-2 (rebuilt)".utf8).write(to: uikit)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: uikit.path)
        XCTAssertTrue(try PearHostPreparer.refreshHostFrameworksIfStale(bundleURL: bundle, hostDir: host))
        XCTAssertEqual(try uikitCopy(in: bundle), "build-2 (rebuilt)")
        XCTAssertEqual(
            try String(contentsOf: bundle.appendingPathComponent("Frameworks/PearANGLE/libEGL.dylib"), encoding: .utf8),
            "egl"
        )
        XCTAssertFalse(try PearHostPreparer.refreshHostFrameworksIfStale(bundleURL: bundle, hostDir: host))
    }

    // MARK: - Switching a Catalyst-prepared bundle to PearHost

    func testPreparationDropsCatalystRuntimeAndRedirectsANGLEShimToPearHostOpenGLES() throws {
        guard let clang = which("clang") else { throw XCTSkip("clang is required to build the fixture executable") }
        let host = try makeHost(uikitContents: "host")
        let bundle = root.appendingPathComponent("Game.app", isDirectory: true)
        let frameworks = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)

        // What a Catalyst preparation leaves behind: the ANGLE shim replacing
        // OpenGLES, and the PearRuntime dylib appended as the last load command.
        let shim = frameworks.appendingPathComponent("libPearOpenGLES.dylib")
        let shimSource = root.appendingPathComponent("shim.c")
        try "int pear_gl_probe(void) { return 7; }\n".write(to: shimSource, atomically: true, encoding: .utf8)
        try run(clang, ["-target", "arm64-apple-ios14.0-macabi", "-dynamiclib", shimSource.path, "-install_name", shim.path, "-o", shim.path])
        let exe = bundle.appendingPathComponent("Game")
        let mainSource = root.appendingPathComponent("main.c")
        try "int pear_gl_probe(void);\nint main(void) { return pear_gl_probe() == 7 ? 0 : 1; }\n"
            .write(to: mainSource, atomically: true, encoding: .utf8)
        try run(clang, ["-target", "arm64-apple-ios14.0-macabi", mainSource.path, shim.path, "-Wl,-headerpad,0x1000", "-o", exe.path])
        let runtime = frameworks.appendingPathComponent("libPearRuntime.dylib")
        XCTAssertTrue(try BinaryPatcher.addLoadDylib(at: exe, path: runtime.path))
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: exe, containing: "libPearRuntime"))

        try PearHostPreparer.prepare(bundleURL: bundle, executableName: "Game", hostDir: host)

        XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: exe, containing: "libPearRuntime"))
        XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: exe, containing: "libPearOpenGLES"))
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: exe, containing: "@rpath/OpenGLES.framework/OpenGLES"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertTrue(PearHostPreparer.isPrepared(bundle))
        XCTAssertEqual(try BinaryPatcher.buildPlatform(at: exe), BinaryPatcher.Platform.macOS)
        XCTAssertTrue(try String(decoding: toolOutput("/usr/bin/vtool", ["-show-build", exe.path]), as: UTF8.self)
            .contains("minos 26.0"))

        // Preparing the same bundle again is a no-op for the retargeted image.
        XCTAssertNoThrow(try PearHostPreparer.prepare(bundleURL: bundle, executableName: "Game", hostDir: host))
        XCTAssertEqual(try BinaryPatcher.buildPlatform(at: exe), BinaryPatcher.Platform.macOS)
    }

    // MARK: - End to end (opt-in)

    /// Builds a small iOS-platform UIKit app, prepares it with the app's own
    /// PearHostPreparer against runtime/build/host, and runs it: launch,
    /// window, drawRect: rendering through PearHost's Rust UIKit.
    func testPreparedIOSAppLaunchesOnPearHost() throws {
        guard ProcessInfo.processInfo.environment["PEAR_HOST_E2E"] == "1" else {
            throw XCTSkip("Set PEAR_HOST_E2E=1 (needs runtime/build/host and the iPhoneOS SDK)")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = repo.appendingPathComponent("runtime/build/host", isDirectory: true)
        guard FileManager.default.fileExists(atPath: host.appendingPathComponent("UIKit.framework/UIKit").path) else {
            throw XCTSkip("run runtime/host/build-host.sh first")
        }
        let bundle = root.appendingPathComponent("E2E.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("main.m")
        try """
        #import <UIKit/UIKit.h>
        @interface AppDelegate : UIResponder <UIApplicationDelegate>
        @property (nonatomic, strong) UIWindow *window;
        @property (nonatomic, strong) UILabel *label;
        @end
        @implementation AppDelegate
        - (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
          self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
          UIViewController *vc = [UIViewController new];
          self.label = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, 280, 40)];
          self.label.text = @"PearHost";
          [vc.view addSubview:self.label];
          self.window.rootViewController = vc;
          [self.window makeKeyAndVisible];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            exit(self.label.layer.contents != nil && self.window.isKeyWindow ? 0 : 3);
          });
          return YES;
        }
        @end
        int main(int argc, char *argv[]) {
          @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let exe = bundle.appendingPathComponent("E2E")
        try run("/usr/bin/xcrun", ["--sdk", "iphoneos", "clang", "-fobjc-arc", "-target", "arm64-apple-ios14.0",
                                   "-framework", "UIKit", "-framework", "Foundation", "-Wl,-headerpad,0x2000",
                                   source.path, "-o", exe.path])

        try PearHostPreparer.prepare(bundleURL: bundle, executableName: "E2E", hostDir: host)
        XCTAssertTrue(PearHostPreparer.isPrepared(bundle))

        let proc = Process()
        proc.executableURL = exe
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        let deadline = Date().addingTimeInterval(30)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if proc.isRunning { proc.terminate(); XCTFail("PearHost app did not finish") }
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    // MARK: - Helpers

    private func makeHost(uikitContents: String) throws -> URL {
        let host = root.appendingPathComponent("host", isDirectory: true)
        let fm = FileManager.default
        for fw in ["UIKit", "OpenGLES", "MetalKit", "iAd"] {
            let dir = host.appendingPathComponent("\(fw).framework", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data((fw == "UIKit" ? uikitContents : fw).utf8).write(to: dir.appendingPathComponent(fw))
        }
        let angle = host.appendingPathComponent("PearANGLE", isDirectory: true)
        try fm.createDirectory(at: angle, withIntermediateDirectories: true)
        try Data("egl".utf8).write(to: angle.appendingPathComponent("libEGL.dylib"))
        return host
    }

    private func uikitCopy(in bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Frameworks/UIKit.framework/UIKit"), encoding: .utf8)
    }

    private func toolOutput(_ tool: String, _ args: [String]) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return data
    }

    private func which(_ tool: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--find", tool]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return proc.terminationStatus == 0 && !path.isEmpty ? path : nil
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "PearHostPreparerTests", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(tool) failed: \(String(decoding: message, as: UTF8.self))",
            ])
        }
    }
}
