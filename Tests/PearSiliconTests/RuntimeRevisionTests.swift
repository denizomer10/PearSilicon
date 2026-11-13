import Foundation
import XCTest
@testable import PearSilicon

/// The installer re-signs the runtime inside each app. A refreshed app must be
/// recognized as current (content equal apart from the signature), and a real
/// code change must still be detected.
final class RuntimeRevisionTests: XCTestCase {
    private func compileDylib(_ source: String, to url: URL) throws {
        let c = url.deletingPathExtension().appendingPathExtension("c")
        try source.write(to: c, atomically: true, encoding: .utf8)
        do {
            _ = try Shell.run("/usr/bin/xcrun", ["clang", "-dynamiclib", "-arch", "arm64", c.path, "-o", url.path])
        } catch {
            throw XCTSkip("clang is not available: \(error.localizedDescription)")
        }
    }

    func testResignedRuntimeIsCurrentAndChangedCodeIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-revision-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Resources", isDirectory: true)
        let installed = root.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = source.appendingPathComponent("libPearRuntime.dylib")
        try compileDylib("int pear_runtime_version(void) { return 1; }\n", to: runtime)
        // Shipped with optional components the app does not use.
        try compileDylib("int cxx_tag(void) { return 0; }\n", to: source.appendingPathComponent("libcxxcompat.dylib"))
        let copy = installed.appendingPathComponent("libPearRuntime.dylib")
        try FileManager.default.copyItem(at: runtime, to: copy)
        _ = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", copy.path])
        XCTAssertNotEqual(try RuntimeRevision.sha256(of: runtime), try RuntimeRevision.sha256(of: copy),
                          "re-signing should change the raw bytes")

        XCTAssertTrue(try RuntimeRevision.installedRuntimeMatches(installed: installed, source: source))

        // A new PearSilicon build with different runtime code.
        try FileManager.default.removeItem(at: runtime)
        try compileDylib("int pear_runtime_version(void) { return 2; }\n", to: runtime)
        XCTAssertFalse(try RuntimeRevision.installedRuntimeMatches(installed: installed, source: source))

        // No runtime installed at all.
        try FileManager.default.removeItem(at: copy)
        XCTAssertFalse(try RuntimeRevision.installedRuntimeMatches(installed: installed, source: source))
    }

    /// Directory components (PearANGLE, MarketplaceKit.framework) are compared
    /// by their entries' paths relative to the component. In an unresolved
    /// /var/... temporary path the directory enumerator reports /private/var
    /// paths; the comparison must still see identical trees as current.
    func testDirectoryComponentsMatchUnderSymlinkedTemporaryPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-tree-\(UUID().uuidString)")
        XCTAssertFalse(root.path.hasPrefix("/private/"), "the test needs the unresolved temporary path")
        let source = root.appendingPathComponent("Resources", isDirectory: true)
        let installed = root.appendingPathComponent("Frameworks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for base in [source, installed] {
            let angle = base.appendingPathComponent("PearANGLE", isDirectory: true)
            try FileManager.default.createDirectory(at: angle, withIntermediateDirectories: true)
            try Data("runtime".utf8).write(to: base.appendingPathComponent("libPearRuntime.dylib"))
            try Data("bridge".utf8).write(to: base.appendingPathComponent("libPearOpenGLES.dylib"))
            try Data("egl".utf8).write(to: angle.appendingPathComponent("libEGL.dylib"))
            try Data("gles".utf8).write(to: angle.appendingPathComponent("libGLESv2.dylib"))
        }
        XCTAssertTrue(try RuntimeRevision.installedRuntimeMatches(installed: installed, source: source))

        try Data("gles v2".utf8).write(to: source.appendingPathComponent("PearANGLE/libGLESv2.dylib"))
        XCTAssertFalse(try RuntimeRevision.installedRuntimeMatches(installed: installed, source: source))

        try FileManager.default.removeItem(at: installed.appendingPathComponent("PearANGLE"))
        XCTAssertFalse(try RuntimeRevision.installedRuntimeMatches(installed: installed, source: source),
                       "a missing required ANGLE component is never current")
    }
}
