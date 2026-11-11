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

    func testCatalogOffersPearWineWhiskyWineAndWineHQOnly() {
        XCTAssertEqual(WineDistribution.catalog.map(\.id), ["pearwine", "whiskywine", "winehq-staging", "winehq-devel"])
    }

    func testVersionLabelsDropFilePrefixAndExtension() {
        XCTAssertEqual(WineDistributionInstaller.versionLabel(asset: "WS12WhiskyWine2.5.0_3.tar.xz", pattern: "WS12WhiskyWine*.tar.xz"), "2.5.0_3")
        XCTAssertEqual(WineDistributionInstaller.versionLabel(asset: "wine-devel-11.21-osx64.tar.xz", pattern: "wine-devel-*.tar.xz"), "11.21-osx64")
    }

    /// An asset without a published digest must not borrow the next asset's.
    func testReleasePageDigestStaysWithinOneAsset() {
        let marker = "/o/r/releases/download/v1/"
        let html = """
        <a href="\(marker)A_old.tar.xz">A_old</a> <span>no digest</span>
        <a href="\(marker)A_new.tar.xz">A_new</a> <span>sha256:\(String(repeating: "ab", count: 32))</span>
        """
        XCTAssertNil(WineDistributionInstaller.digest(of: marker + "A_old.tar.xz", in: html, nextEntry: marker))
        XCTAssertEqual(WineDistributionInstaller.digest(of: marker + "A_new.tar.xz", in: html, nextEntry: marker),
                       String(repeating: "ab", count: 32))
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
            engine("whiskywine-2.5.0_3", .fork),
            engine("pearwine-1.0.0", .pearWine),
        ])
        XCTAssertEqual(ordered.map(\.id), ["pearwine-1.0.0", "whiskywine-2.5.0_3", "wine-staging-11.21", "custom"])
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

/// Installs any catalog distribution from its live source into a temporary
/// store. Opt-in: PEAR_LIVE_WINE_DISTRIBUTION=<catalog id> (downloads it).
final class WineDistributionLiveInstallTests: XCTestCase {
    func testInstallsSelectedDistribution() async throws {
        guard let id = ProcessInfo.processInfo.environment["PEAR_LIVE_WINE_DISTRIBUTION"] else {
            throw XCTSkip("Set PEAR_LIVE_WINE_DISTRIBUTION to a catalog id to download and install it.")
        }
        let distribution = try XCTUnwrap(WineDistribution.catalog.first { $0.id == id }, "unknown id \(id)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wine-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(rootURL: root.appendingPathComponent("Engines", isDirectory: true))
        let engine = try await WineDistributionInstaller().install(distribution, store: store) { print("[install]", $0) }
        try engine.validate()
        XCTAssertEqual(WineDistribution.distribution(for: engine)?.id, id)
        // The installed loader must actually start.
        let process = Process()
        process.executableURL = engine.executableURL
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("[install] \(engine.name) \(engine.version) -> \(engine.executablePath): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.lowercased().contains("wine"))
    }
}

/// Live: the rate-limit fallback (public release pages) must resolve the same
/// asset, URL and SHA-256 as the API. Opt-in: PEAR_LIVE_WINE_LOOKUP=1.
final class WineDistributionLiveLookupTests: XCTestCase {
    func testReleasePageFallbackMatchesAPI() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEAR_LIVE_WINE_LOOKUP"] == "1", "Set PEAR_LIVE_WINE_LOOKUP=1.")
        let repository = "Sikarugir-App/Engines", pattern = "WS12WhiskyWine*.tar.xz"
        let api = try await WineDistributionInstaller.latestAsset(repository: repository, pattern: pattern)
        let pages = try await WineDistributionInstaller.latestAssetFromReleasePages(repository: repository, pattern: pattern)
        print("[lookup] api:", api.name, api.sha256, "pages:", pages.name, pages.sha256)
        XCTAssertEqual(api.name, pages.name)
        XCTAssertEqual(api.url, pages.url)
        XCTAssertEqual(api.sha256, pages.sha256)
        XCTAssertEqual(api.version, "2.5.0_3")
    }
}
