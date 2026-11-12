import Foundation
import XCTest
@testable import PearSilicon

final class WineDistributionTests: XCTestCase {
    func testMetalSharpIsFirstAndTheOnlyDefault() {
        XCTAssertEqual(WineDistribution.catalog.first?.id, "metalsharp")
        XCTAssertTrue(WineDistribution.catalog.first?.recommended == true)
        XCTAssertEqual(WineDistribution.catalog.filter(\.recommended).count, 1)
        XCTAssertEqual(WineDistribution.metalSharp.homepage?.absoluteString, "https://github.com/metalsharp/MetalSharp-Wine")
        XCTAssertTrue(WineDistribution.metalSharp.nativeArm64)
    }

    func testCatalogOffersMetalSharpAndOptionalWineHQOnly() {
        XCTAssertEqual(WineDistribution.catalog.map(\.id), ["metalsharp", "winehq-staging", "winehq-devel"])
        XCTAssertTrue(WineDistribution.catalog.dropFirst().allSatisfy { !$0.nativeArm64 && !$0.recommended })
    }

    /// The signed arm64 app ZIP, never the x86_64 build or the unsigned tarball.
    func testMetalSharpPicksTheSignedArm64App() {
        guard case .githubRelease(let repository, let pattern) = WineDistribution.metalSharp.source else {
            return XCTFail("MetalSharp must come from its GitHub releases")
        }
        XCTAssertEqual(repository, "metalsharp/MetalSharp-Wine")
        let match = WineDistributionInstaller.matches
        XCTAssertTrue(match("MetalSharp-Wine-6.0-arm64.zip", pattern))
        XCTAssertFalse(match("MetalSharp-Wine-6.0-x86_64.zip", pattern))
        XCTAssertFalse(match("metalsharp-wine-6.0-arm64.tar.xz", pattern))
        XCTAssertFalse(match("SHA256SUMS", pattern))
        XCTAssertEqual(WineDistributionInstaller.versionLabel(asset: "MetalSharp-Wine-6.0-arm64.zip", pattern: pattern), "6.0")
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

    /// Engines installed as "PearWine" are the signed MetalSharp app: they keep
    /// their ID (games stay linked) and load as MetalSharp Wine 6.0.
    func testInstalledPearWineEngineLoadsAsMetalSharp() throws {
        let json = """
        {"distribution":"pearWine","executablePath":"Runtime/MetalSharp-Wine.app/Contents/MacOS/wine",
         "id":"pearwine-1.0.1","name":"PearWine","rootURL":"file:///tmp/pearwine-1.0.1/","version":"1.0.1 (Wine 11.20)"}
        """
        let engine = try JSONDecoder().decode(WineEngine.self, from: Data(json.utf8))
        XCTAssertEqual(engine.id, "pearwine-1.0.1")
        XCTAssertEqual(engine.distribution, .metalSharp)
        XCTAssertEqual(engine.name, "MetalSharp Wine")
        XCTAssertEqual(engine.version, "6.0 (Wine 11.20)")
        XCTAssertEqual(WineDistribution.distribution(for: engine), .metalSharp)
        let again = try JSONDecoder().decode(WineEngine.self, from: JSONEncoder().encode(engine))
        XCTAssertEqual(again, engine)
        XCTAssertThrowsError(try JSONDecoder().decode(WineEngine.self, from: Data(json.replacingOccurrences(of: "pearWine", with: "mystery").utf8)))
    }

    func testMetalSharpDefaultsApplyOnlyToMetalSharp() {
        let root = URL(fileURLWithPath: "/tmp")
        let metal = WineEngine(id: "metalsharp-6.0-arm64", name: "MetalSharp Wine", version: "6.0-arm64", rootURL: root,
                               executablePath: "Runtime/MetalSharp-Wine.app/Contents/MacOS/wine", distribution: .metalSharp)
        let hq = WineEngine(id: "wine-staging-11.21", name: "WineHQ", version: "11.21", rootURL: root,
                            executablePath: "Runtime/bin/wine", distribution: .wineHQ)
        XCTAssertTrue(MetalSharpDefaults.applies(to: metal))
        XCTAssertFalse(MetalSharpDefaults.applies(to: hq))
        XCTAssertEqual(MetalSharpDefaults.environment["WINEMSYNC"], "1")
        XCTAssertTrue(MetalSharpDefaults.registry.hasPrefix("Windows Registry Editor Version 5.00\n"))
        XCTAssertTrue(MetalSharpDefaults.registry.contains(#"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#))
        XCTAssertTrue(MetalSharpDefaults.registry.contains(#""UseGCMouse"="Y""#))
    }

    func testInstalledEnginesAreOrderedMetalSharpFirst() {
        let root = URL(fileURLWithPath: "/tmp")
        func engine(_ id: String, _ distribution: WineEngine.Distribution) -> WineEngine {
            WineEngine(id: id, name: id, version: "1", rootURL: root, executablePath: "Runtime/bin/wine",
                       distribution: distribution)
        }
        let ordered = WineDistribution.ordered([
            engine("wine-staging-11.21", .wineHQ),
            engine("custom", .community),
            engine("pearwine-1.0.1", .metalSharp),
        ])
        XCTAssertEqual(ordered.map(\.id), ["pearwine-1.0.1", "wine-staging-11.21", "custom"])
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
        // The same progress hook the status bar uses during automatic installs.
        final class Fractions: @unchecked Sendable {
            private let lock = NSLock(); private var values: [Double] = []
            func add(_ value: Double) { lock.withLock { values.append(value) } }
            var all: [Double] { lock.withLock { values } }
        }
        let fractions = Fractions()
        let engine = try await WineDownloadProgress.$handler.withValue({ fractions.add($0) }) {
            try await WineDistributionInstaller().install(distribution, store: store) { print("[install]", $0) }
        }
        try engine.validate()
        XCTAssertEqual(WineDistribution.distribution(for: engine)?.id, id)
        let reported = fractions.all
        print("[install] progress updates: \(reported.count), last \(reported.last ?? -1)")
        XCTAssertGreaterThan(reported.count, 10)
        XCTAssertEqual(reported.last ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(reported, reported.sorted())
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
        let repository = "metalsharp/MetalSharp-Wine", pattern = "MetalSharp-Wine-*-arm64.zip"
        let api = try await WineDistributionInstaller.latestAsset(repository: repository, pattern: pattern)
        let pages = try await WineDistributionInstaller.latestAssetFromReleasePages(repository: repository, pattern: pattern)
        print("[lookup] api:", api.name, api.sha256, "pages:", pages.name, pages.sha256)
        XCTAssertEqual(api.name, pages.name)
        XCTAssertEqual(api.url, pages.url)
        XCTAssertEqual(api.sha256, pages.sha256)
        XCTAssertEqual(api.version, "6.0")
    }
}

/// Read-only: loads a real engine store and checks every engine still
/// validates and MetalSharp is preferred. Opt-in: PEAR_INSTALLED_WINE_ENGINES=<Engines folder>.
final class InstalledWineEngineStoreTests: XCTestCase {
    func testInstalledEnginesLoadAsMetalSharpFirst() throws {
        guard let path = ProcessInfo.processInfo.environment["PEAR_INSTALLED_WINE_ENGINES"] else {
            throw XCTSkip("Set PEAR_INSTALLED_WINE_ENGINES to an Engines folder.")
        }
        let engines = WineDistribution.ordered(try WineEngineStore(rootURL: URL(fileURLWithPath: path)).engines())
        XCTAssertFalse(engines.isEmpty)
        for engine in engines {
            XCTAssertNoThrow(try engine.validate(), engine.id)
            print("[engines] \(engine.id): \(engine.name) \(engine.version) (\(engine.distribution.rawValue))")
        }
        XCTAssertEqual(engines.first?.distribution, .metalSharp)
        XCTAssertEqual(engines.first?.name, "MetalSharp Wine")
    }
}
