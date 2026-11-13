import Foundation
import XCTest
@testable import PearSilicon

/// Opt-in: runs the real installer on a clone of an installed OpenGL ES game
/// and checks the exclusive ANGLE layout. Never touches the installed game or
/// its saves: the clone lives in its own library with its own bundle ID.
///
///   PEAR_LIVE_ANGLE_APP=/path/to/Game.app        installed, prepared iOS app
///   PEAR_LIVE_ANGLE_LIBRARY=/path/to/test-library  created if missing
///   PEAR_LIVE_ANGLE_RUNTIME=…/build/libPearRuntime.dylib  (default: repo build)
final class LiveANGLEExclusiveTests: XCTestCase {
    func testInstallerPreparesExclusiveANGLECopy() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["PEAR_LIVE_ANGLE_APP"],
              let libraryPath = environment["PEAR_LIVE_ANGLE_LIBRARY"] else {
            throw XCTSkip("set PEAR_LIVE_ANGLE_APP and PEAR_LIVE_ANGLE_LIBRARY to run")
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = URL(fileURLWithPath: environment["PEAR_LIVE_ANGLE_RUNTIME"]
            ?? repository.appendingPathComponent("build/libPearRuntime.dylib").path)
        let source = URL(fileURLWithPath: sourcePath)
        let library = URL(fileURLWithPath: libraryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let info = try XCTUnwrap(NSDictionary(contentsOf: source.appendingPathComponent("Info.plist")) as? [String: Any])
        let identifier = try XCTUnwrap(info["CFBundleIdentifier"] as? String) + ".angleexclusive"
        let bundle = library.appendingPathComponent(identifier + ".app", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), "refusing to overwrite \(bundle.path)")
        _ = try Shell.run("/bin/cp", ["-cR", source.path, bundle.path])
        var copied = info
        copied["CFBundleIdentifier"] = identifier
        copied["CFBundleDisplayName"] = ((info["CFBundleDisplayName"] as? String) ?? "Game") + " ANGLE"
        try PropertyListSerialization.data(fromPropertyList: copied, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))

        var tools = PackageInstaller.PreparationTools()
        tools.runtimeLibraryURL = { runtime }
        tools.requireStopped = { _ in }
        let installer = PackageInstaller(libraryURL: library, preparationTools: tools)
        let app = try installer.makeInstalledApp(fromBundleAt: bundle)
        try installer.setPreparationMode(.compatibility, for: app, force: true)

        let frameworks = bundle.appendingPathComponent("Frameworks")
        for component in ["libPearRuntime.dylib", "libPearOpenGLES.dylib", "PearANGLE/libEGL.dylib", "PearANGLE/libGLESv2.dylib"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: frameworks.appendingPathComponent(component).path), component)
        }
        // No image of the app may still depend on the system OpenGL ES.
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil))
        var images = 0, bridged = 0
        while let item = enumerator.nextObject() as? URL {
            guard let handle = try? FileHandle(forReadingFrom: item) else { continue }
            let magic = (try? handle.read(upToCount: 4)) ?? Data()
            try? handle.close()
            guard magic == Data([0xcf, 0xfa, 0xed, 0xfe]) || magic == Data([0xca, 0xfe, 0xba, 0xbe]) else { continue }
            images += 1
            let dependencies = try Shell.run("/usr/bin/otool", ["-L", item.path])
            XCTAssertFalse(dependencies.contains("OpenGLES.framework"), "system OpenGL ES dependency in \(item.lastPathComponent)")
            if dependencies.contains("libPearOpenGLES.dylib") { bridged += 1 }
        }
        XCTAssertGreaterThan(images, 0)
        XCTAssertGreaterThan(bridged, 0, "an OpenGL ES game must load the bridge")
        _ = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
        print("PREPARED \(bundle.path) images=\(images) bridged=\(bridged)")
    }
}
