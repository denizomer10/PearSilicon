import Foundation
import XCTest
@testable import PearSilicon

/// Opt-in end-to-end download of a real open-source WineHQ build. It writes only
/// under a unique temporary root on the supplied disk and removes it afterwards.
///
///   PEAR_WINE_INTEGRATION_DIR=/Volumes/ExternalDisk \
///     swift test --filter WineReleaseIntegrationTests
///
/// This proves download, SHA-256, tar admission, extraction, executable discovery
/// and engine registration. It does not prove that a particular Windows game runs.
final class WineReleaseIntegrationTests: XCTestCase {

    func testLatestReleaseFeedWorksWhenTheGitHubAPIQuotaIsExhausted() async throws {
        guard ProcessInfo.processInfo.environment["PEAR_WINE_LATEST_TEST"] == "1" else {
            throw XCTSkip("Set PEAR_WINE_LATEST_TEST=1 to check the live release feed")
        }
        let check = try await WineReleaseService().latest(channel: .devel)
        XCTAssertFalse(check.tag.isEmpty)
        XCTAssertTrue(check.assetName.hasPrefix("wine-devel-"))
        XCTAssertEqual(check.sha256.count, 64)
        print("Latest devel Wine: \(check.tag) \(check.assetName) \(check.sha256)")
    }

    func testDownloadsVerifiesExtractsAndRegistersARealWineBuild() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PEAR_WINE_INTEGRATION_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("Set PEAR_WINE_INTEGRATION_DIR to opt in to the real Wine download")
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("PearSiliconWineTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // A known published open-source build. The hash comes from GitHub's asset
        // metadata and is mandatory; update this fixture deliberately if the
        // upstream release is removed.
        let check = WineReleaseCheck(
            channel: .devel,
            tag: "11.21",
            releaseName: "11.21",
            assetName: "wine-devel-11.21-osx64.tar.xz",
            assetURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-devel-11.21-osx64.tar.xz")!,
            sha256: "9909b486657e10ab66c7279371ae1f990345b596b3b1b3a0cf21f28af24fa0ce",
            size: 225_000_000,
            releasePage: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.21")
        )

        let store = WineEngineStore(rootURL: base.appendingPathComponent("Engines", isDirectory: true))
        let engine = try await WineReleaseService().install(check, store: store)
        XCTAssertEqual(engine.distribution, .wineHQ)
        XCTAssertEqual(engine.version, "11.21")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: engine.executableURL.path))
        XCTAssertNoThrow(try engine.validate())
        XCTAssertEqual(try store.engines().map(\.id), [engine.id])
        let archs = try Shell.run("/usr/bin/lipo", ["-archs", engine.executableURL.path])
        print("Wine executable architectures: \(archs)")
    }
}
