import Foundation
import XCTest
@testable import PearSilicon

final class PearHostPreparerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["PEAR_RUNTIME_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("PearHostPreparerTests-\(UUID().uuidString)", isDirectory: true)
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

        let metal = "MetalKit.framework/MetalKit"
        try Data("updated MetalKit".utf8).write(to: host.appendingPathComponent(metal))
        let changed = try XCTUnwrap(PearHostPreparer.runtimeSnapshot(host)).changedComponents(in: bundle)
        XCTAssertEqual(changed, ["MetalKit.framework"])
        XCTAssertTrue(try PearHostPreparer.refreshHostFrameworksIfStale(bundleURL: bundle, hostDir: host))
        let installedMetal = frameworks.appendingPathComponent(metal)
        XCTAssertEqual(try String(contentsOf: installedMetal, encoding: .utf8), "updated MetalKit")
        try FileManager.default.removeItem(at: installedMetal)
        XCTAssertTrue(try PearHostPreparer.refreshHostFrameworksIfStale(bundleURL: bundle, hostDir: host))
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
        let oldFrameworkPath = "/Volumes/OldLibrary/Game.app/Frameworks"
        try run(clang, ["-target", "arm64-apple-ios14.0-macabi", mainSource.path, shim.path,
                        "-Wl,-headerpad,0x1000", "-Wl,-rpath,\(oldFrameworkPath)", "-o", exe.path])
        let runtime = frameworks.appendingPathComponent("libPearRuntime.dylib")
        XCTAssertTrue(try BinaryPatcher.addLoadDylib(at: exe, path: runtime.path))
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: exe, containing: "libPearRuntime"))

        try PearHostPreparer.prepare(bundleURL: bundle, executableName: "Game", hostDir: host)

        XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: exe, containing: "libPearRuntime"))
        XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: exe, containing: "libPearOpenGLES"))
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: exe, containing: "@rpath/OpenGLES.framework/OpenGLES"))
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: exe, containing: "@rpath/UIKit.framework/UIKit"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertTrue(PearHostPreparer.isPrepared(bundle))
        XCTAssertEqual(try BinaryPatcher.buildPlatform(at: exe), BinaryPatcher.Platform.macOS)
        let commands = try String(decoding: toolOutput("/usr/bin/otool", ["-l", exe.path]), as: UTF8.self)
        XCTAssertFalse(commands.contains(oldFrameworkPath))
        XCTAssertTrue(commands.contains("@executable_path/Frameworks"))
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
        #import <MetalKit/MetalKit.h>
        #import <WebKit/WebKit.h>
        #include <dlfcn.h>
        @interface NSLayoutConstraint (PearHostProbe)
        - (void)autoInstall;
        @end
        @implementation NSLayoutConstraint (PearHostProbe)
        - (void)autoInstall { self.active = YES; }
        @end
        @interface AppDelegate : UIResponder <UIApplicationDelegate, MTKViewDelegate>
        @property (nonatomic, strong) UIWindow *window;
        @property (nonatomic, strong) UILabel *label;
        @property (nonatomic) NSUInteger metalFrames;
        @end
        @implementation AppDelegate
        - (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
        - (void)drawInMTKView:(MTKView *)view { self.metalFrames++; }

        - (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
          self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
          UIViewController *vc = [UIViewController new];
          self.label = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, 280, 40)];
          self.label.text = @"PearHost";
          [vc.view addSubview:self.label];
          UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(20, 100, 20, 20)];
          UIGraphicsBeginImageContext(CGSizeMake(20, 20));
          CGContextRef context = UIGraphicsGetCurrentContext();
          CGContextSetRGBFillColor(context, 0, 0, 0, 1);
          CGContextFillRect(context, CGRectMake(0, 0, 20, 20));
          imageView.image = UIGraphicsGetImageFromCurrentImageContext();
          UIGraphicsEndImageContext();
          imageView.transform = CGAffineTransformMakeTranslation(12, 8);
          [vc.view addSubview:imageView];
          NSLayoutConstraint *constraint = [NSLayoutConstraint constraintWithItem:imageView
            attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil
            attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:20];
          [constraint autoInstall];
          NSLayoutConstraint *anchorConstraint = [imageView.topAnchor
            constraintEqualToAnchor:vc.view.topAnchor constant:100];
          [NSLayoutConstraint activateConstraints:@[anchorConstraint]];
          WKWebViewConfiguration *webConfiguration = [WKWebViewConfiguration new];
          webConfiguration.allowsInlineMediaPlayback = YES;
          webConfiguration.dataDetectorTypes = WKDataDetectorTypePhoneNumber;
          WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectMake(20, 160, 280, 160)
            configuration:webConfiguration];
          webView.scrollView.bounces = NO;
          webView.scrollView.opaque = NO;
          UIColor *scrollBackground = UIColor.clearColor;
          webView.scrollView.backgroundColor = scrollBackground;
          if (@available(iOS 26.0, *)) {
            webView.scrollView.topEdgeEffect.hidden = YES;
          }
          webView.opaque = NO;
          [vc.view addSubview:webView];
          MTKView *metalView = [[MTKView alloc] initWithFrame:CGRectMake(20, 340, 80, 80)];
          metalView.delegate = self;
          metalView.enableSetNeedsDisplay = YES;
          [vc.view addSubview:metalView];
          self.window.rootViewController = vc;
          [self.window makeKeyAndVisible];
          metalView.paused = NO;
          metalView.enableSetNeedsDisplay = NO;
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            BOOL imageRendered = imageView.image != nil && imageView.layer.contents != nil;
            BOOL transformApplied = CGRectGetMinX(imageView.frame) == 32 && CGRectGetMinY(imageView.frame) == 108;
            BOOL anchorsLinked = anchorConstraint.isActive && anchorConstraint.firstItem == imageView &&
              anchorConstraint.secondItem == vc.view && anchorConstraint.constant == 100;
            BOOL webViewMounted = webView.window != nil && !webView.scrollView.isOpaque &&
              webView.scrollView.backgroundColor == scrollBackground &&
              webConfiguration.allowsInlineMediaPlayback &&
              webConfiguration.dataDetectorTypes == WKDataDetectorTypePhoneNumber;
            void *uiKit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
            void *activeSymbol = uiKit ? dlsym(uiKit, "UIApplicationDidBecomeActiveNotification") : NULL;
            NSString *active = activeSymbol ? *(__unsafe_unretained NSString **)activeSymbol : nil;
            BOOL dynamicUIKitLoaded = [active isEqualToString:UIApplicationDidBecomeActiveNotification];
            if (uiKit) dlclose(uiKit);
            void *gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY);
            BOOL glesLoaded = gles && dlsym(gles, "OBJC_CLASS_$_EAGLContext") != NULL;
            if (gles) dlclose(gles);
            void *relativeGLES = dlopen("@rpath/OpenGLES.framework/OpenGLES", RTLD_LAZY);
            if (relativeGLES) dlclose(relativeGLES);
            BOOL success = self.label.layer.contents != nil && self.window.isKeyWindow &&
              imageRendered && transformApplied && constraint.isActive && anchorsLinked && webViewMounted &&
              dynamicUIKitLoaded && glesLoaded && relativeGLES && self.metalFrames > 1;
            if (!success) NSLog(@"PearHost checks: label=%d key=%d image=%d transform=%d constraint=%d anchors=%d web=%d UIKit=%d GLES=%d rpath=%d frames=%lu",
              self.label.layer.contents != nil, self.window.isKeyWindow, imageRendered, transformApplied,
              constraint.isActive, anchorsLinked, webViewMounted, dynamicUIKitLoaded, glesLoaded,
              relativeGLES != NULL, (unsigned long)self.metalFrames);
            exit(success ? 0 : 3);
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
                                   "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreGraphics",
                                   "-framework", "WebKit", "-framework", "MetalKit", "-Wl,-headerpad,0x2000",
                                   source.path, "-o", exe.path])

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.pearsilicon.tests.pearhost",
            "CFBundleExecutable": "E2E",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "PearHost E2E"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
        var signingCommands: [[String]] = []
        let tools = PackageInstaller.PreparationTools(run: { tool, arguments in
            if tool == "/usr/bin/codesign", arguments.contains("--sign") { signingCommands.append(arguments) }
            return try Shell.run(tool, arguments)
        })
        let installer = PackageInstaller(libraryURL: root, preparationTools: tools)
        let app = try installer.makeInstalledApp(fromBundleAt: bundle)
        XCTAssertTrue(try installer.refreshRuntimeIfNeeded(for: app, source: .pearHost(host)))
        XCTAssertTrue(PearHostPreparer.isPrepared(bundle))
        XCTAssertFalse(try installer.refreshRuntimeIfNeeded(for: app, source: .pearHost(host)))
        signingCommands.removeAll()
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Frameworks/MetalKit.framework"))
        XCTAssertTrue(try installer.refreshRuntimeIfNeeded(for: app, source: .pearHost(host)))
        XCTAssertFalse(try installer.refreshRuntimeIfNeeded(for: app, source: .pearHost(host)))
        XCTAssertTrue(signingCommands.contains { $0.last?.hasSuffix("/MetalKit.framework") == true })
        XCTAssertFalse(signingCommands.contains { $0.last?.hasSuffix("/UIKit.framework") == true })

        let proc = Process()
        proc.executableURL = exe
        proc.standardOutput = Pipe()
        let errors = Pipe()
        proc.standardError = errors
        try proc.run()
        let deadline = Date().addingTimeInterval(30)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if proc.isRunning { proc.terminate(); XCTFail("PearHost app did not finish") }
        proc.waitUntilExit()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(proc.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
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
