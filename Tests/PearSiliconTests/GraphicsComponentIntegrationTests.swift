import Foundation
import XCTest
@testable import PearSilicon

/// Opt-in real download of the optional graphics components. It writes only to a
/// unique temporary engine root and removes it afterwards. It does not launch a
/// game or modify the user's installed engines.
final class GraphicsComponentIntegrationTests: XCTestCase {

    func testInstallsDXMTAndKosmicKrispFromTheirReleaseFeeds() async throws {
        guard ProcessInfo.processInfo.environment["PEAR_GRAPHICS_INTEGRATION"] == "1" else {
            throw XCTSkip("Set PEAR_GRAPHICS_INTEGRATION=1 to download the graphics components")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-graphics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = GraphicsComponentService()

        let dxmt = try await service.latestDXMT()
        XCTAssertTrue(dxmt.name.hasSuffix("-builtin.tar.gz"))
        XCTAssertEqual(dxmt.sha256.count, 64)
        let dxmtRoot = try await service.installDXMT(dxmt, engineRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dxmtRoot.appendingPathComponent("x86_64-windows/d3d11.dll").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dxmtRoot.appendingPathComponent("x86_64-unix/winemetal.so").path
        ))

        let kosmic = try await service.latestKosmicKrisp()
        XCTAssertTrue(kosmic.name.hasSuffix(".pkg"))
        let kosmicRoot = try await service.installKosmicKrisp(kosmic, engineRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: kosmicRoot.appendingPathComponent("lib/avk143/libvulkan_kosmickrisp.dylib").path
        ))
        let archs = try Shell.run(
            "/usr/bin/lipo", ["-archs", kosmicRoot.appendingPathComponent("lib/avk143/libvulkan_kosmickrisp.dylib").path]
        )
        XCTAssertTrue(archs.contains("arm64"))
    }
}
