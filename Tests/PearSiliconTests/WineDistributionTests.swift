import Foundation
import XCTest
@testable import PearSilicon

final class WineDistributionTests: XCTestCase {
    func testPearWineIsFirstAndRecommended() {
        XCTAssertEqual(WineDistribution.catalog.first?.id, "pearwine")
        XCTAssertTrue(WineDistribution.catalog.first?.recommended == true)
        XCTAssertEqual(WineDistribution.catalog.filter(\.recommended).count, 1)
    }

    func testAssetPatternMatching() {
        let match = WineDistributionInstaller.matches
        XCTAssertTrue(match("metalsharp-wine-6.0-arm64.tar.xz", "metalsharp-wine-*-arm64.tar.xz"))
        XCTAssertFalse(match("MetalSharp-Wine-6.0-arm64.zip", "metalsharp-wine-*-arm64.tar.xz"))
        XCTAssertTrue(match("WS12WineSikarugir11.0_1.tar.xz", "WS12WineSikarugir11.0*.tar.xz"))
        XCTAssertFalse(match("WS11WineSikarugir11.0.tar.xz", "WS12WineSikarugir11.0*.tar.xz"))
        XCTAssertTrue(match("WS12WhiskyWine2.5.0_3.tar.xz", "WS12WhiskyWine*.tar.xz"))
    }

    func testManifestDecodesPublishedFormat() throws {
        let json = """
        {"schema":"pearwine/v1","name":"PearWine","version":"1.0.0","wine":"11.20","architecture":"arm64",
         "base":{"name":"MetalSharp Wine 6.0","repository":"metalsharp/MetalSharp-Wine","tag":"v6.0",
           "url":"https://github.com/metalsharp/MetalSharp-Wine/releases/download/v6.0/metalsharp-wine-6.0-arm64.tar.xz",
           "asset":"metalsharp-wine-6.0-arm64.tar.xz",
           "sha256":"a728f41ef4cd600ea45bbc1e1fd9bb35fb1a0fa4327ca0cfad311738f93160a6","size":962820908,
           "root":"metalsharp-wine-6.0-arm64","executable":"bin/wine"},
         "overlay":{"asset":"pearwine-1.0.0-overlay.tar.gz",
           "url":"https://github.com/denizomer10/PearWine/releases/download/v1.0.0/pearwine-1.0.0-overlay.tar.gz",
           "sha256":"156db75594d4bca5328bce6bef38c7d50e673e070802dea0146a2418e32b37a6"},
         "environment":{"WINEMSYNC":"1"}}
        """
        let manifest = try JSONDecoder().decode(PearWineManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertNotNil(WineReleaseService.normalizedHash(manifest.base.sha256))
        XCTAssertEqual(manifest.overlay?.asset, "pearwine-1.0.0-overlay.tar.gz")
        XCTAssertLessThanOrEqual(manifest.base.size, WineReleaseService.maximumDownloadBytes)
    }

    func testEnvironmentDefaultsIgnoreUnsafeKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pearwine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let share = root.appendingPathComponent("Runtime/share/pearwine", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        try """
        # comment
        WINEMSYNC=1
        DYLD_INSERT_LIBRARIES=/tmp/evil.dylib
        WINEPREFIX=/
        lowercase=1
        METALSHARP_CONFINE_CURSOR=1
        """.write(to: share.appendingPathComponent("pearwine.env"), atomically: true, encoding: .utf8)
        let engine = WineEngine(id: "pearwine-1.0.0", name: "PearWine", version: "1.0.0", rootURL: root,
                                executablePath: "Runtime/bin/wine", distribution: .pearWine)
        XCTAssertEqual(WineDistributionInstaller.environmentDefaults(for: engine),
                       ["WINEMSYNC": "1", "METALSHARP_CONFINE_CURSOR": "1"])
    }

    func testInstalledEnginesAreOrderedPearWineFirst() {
        let root = URL(fileURLWithPath: "/tmp")
        func engine(_ id: String, _ distribution: WineEngine.Distribution) -> WineEngine {
            WineEngine(id: id, name: id, version: "1", rootURL: root, executablePath: "Runtime/bin/wine",
                       distribution: distribution)
        }
        let ordered = WineDistribution.ordered([
            engine("wine-staging-11.21", .wineHQ),
            engine("custom", .community),
            engine("metalsharp-v6.0", .fork),
            engine("pearwine-1.0.0", .pearWine),
        ])
        XCTAssertEqual(ordered.map(\.id), ["pearwine-1.0.0", "metalsharp-v6.0", "wine-staging-11.21", "custom"])
    }
}

/// Full PearWine install from the live release into a temporary store.
/// Downloads about 1 GB, so it runs only with PEAR_LIVE_PEARWINE_INSTALL=1.
final class PearWineLiveInstallTests: XCTestCase {
    func testInstallsPearWineEndToEnd() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEAR_LIVE_PEARWINE_INSTALL"] == "1",
                          "Set PEAR_LIVE_PEARWINE_INSTALL=1 to download and install PearWine.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pearwine-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(rootURL: root.appendingPathComponent("Engines", isDirectory: true))
        let engine = try await WineDistributionInstaller().install(.pearWine, store: store) { print("[install]", $0) }
        try engine.validate()
        XCTAssertEqual(engine.distribution, .pearWine)
        XCTAssertTrue(engine.executablePath.hasSuffix(".app/Contents/MacOS/wine"), engine.executablePath)
        XCTAssertEqual(WineDistributionInstaller.environmentDefaults(for: engine)["WINEMSYNC"], "1")
        XCTAssertNotNil(WineDistributionInstaller.registryDefaults(for: engine))
        XCTAssertEqual(try store.engines().map(\.id), [engine.id])
        print("[install] registered \(engine.name) \(engine.version) -> \(engine.executableURL.path)")
    }
}
