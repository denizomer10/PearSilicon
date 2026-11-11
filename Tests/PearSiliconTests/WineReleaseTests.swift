import Foundation
import XCTest
@testable import PearSilicon

final class WineReleaseTests: XCTestCase {

    func testZipRejectsEscapingSymlinkBeforeExtraction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wine-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path,
                                                   withDestinationPath: "/tmp")
        let zip = root.appendingPathComponent("unsafe.zip")
        _ = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, zip.path])
        XCTAssertThrowsError(try WineReleaseService.validateZipListing(zip))
        try FileManager.default.removeItem(at: source.appendingPathComponent("escape"))
        try Data("safe".utf8).write(to: source.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path,
                                                   withDestinationPath: "file")
        let safe = root.appendingPathComponent("safe.zip")
        _ = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, safe.path])
        XCTAssertNoThrow(try WineReleaseService.validateZipListing(safe))
    }

    func testLatestSelectsTheNewestMatchingAssetAndReadsGitHubDigest() async throws {
        let hash = String(repeating: "a", count: 64)
        let json = """
        [
          {
            "tag_name": "11.21", "name": "11.21", "draft": false, "prerelease": false,
            "html_url": "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.21",
            "assets": [
              {"name": "wine-devel-11.21-osx64.tar.xz", "size": 225000000,
               "digest": "sha256:\(hash)",
               "browser_download_url": "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-devel-11.21-osx64.tar.xz"},
              {"name": "wine-staging-11.21-osx64.tar.xz", "size": 228000000,
               "digest": "sha256:\(String(repeating: "b", count: 64))",
               "browser_download_url": "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-staging-11.21-osx64.tar.xz"}
            ]
          }
        ]
        """
        let service = WineReleaseService(
            listReleases: { _ in Data(json.utf8) },
            download: { _, _ in throw WineReleaseError.invalid("not used") }
        )
        let check = try await service.latest(channel: .devel)
        XCTAssertEqual(check.tag, "11.21")
        XCTAssertEqual(check.assetName, "wine-devel-11.21-osx64.tar.xz")
        XCTAssertEqual(check.sha256, hash)
        XCTAssertEqual(check.assetURL.host, "github.com")
        XCTAssertEqual(check.size, 225_000_000)
    }

    func testPrereleasesDraftsAndWrongChannelsAreIgnored() async throws {
        let json = """
        [
          {"tag_name": "draft", "name": "Draft", "draft": true, "prerelease": false,
           "assets": [{"name": "wine-devel-9-osx64.tar.xz", "size": 1,
             "digest": "sha256:\(String(repeating: "1", count: 64))",
             "browser_download_url": "https://github.com/x/y/releases/download/draft/a.tar.xz"}]},
          {"tag_name": "pre", "name": "Pre", "draft": false, "prerelease": true,
           "assets": [{"name": "wine-stable-8-osx64.tar.xz", "size": 1,
             "digest": "sha256:\(String(repeating: "2", count: 64))",
             "browser_download_url": "https://github.com/x/y/releases/download/pre/a.tar.xz"}]},
          {"tag_name": "7", "name": "7", "draft": false, "prerelease": false,
           "assets": [{"name": "wine-devel-7-osx64.tar.xz", "size": 1,
             "digest": "sha256:\(String(repeating: "3", count: 64))",
             "browser_download_url": "https://github.com/x/y/releases/download/7/a.tar.xz"}]}
        ]
        """
        let service = WineReleaseService(
            listReleases: { _ in Data(json.utf8) },
            download: { _, _ in throw WineReleaseError.invalid("not used") }
        )
        let check = try await service.latest(channel: .devel)
        XCTAssertEqual(check.tag, "7")
        do {
            _ = try await service.latest(channel: .stable)
            XCTFail("Only a prerelease contains a stable asset")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No verified"))
        }
    }

    func testEngineIdentifiersAreSafeAndDeterministic() {
        XCTAssertEqual(
            WineReleaseService.engineID(channel: .staging, tag: "11.21"),
            "wine-staging-11-21"
        )
        XCTAssertEqual(WineReleaseService.normalizedHash("sha256:" + String(repeating: "A", count: 64)),
                       String(repeating: "a", count: 64))
        XCTAssertNil(WineReleaseService.normalizedHash("not-a-hash"))
    }

    func testAtomFeedAndAssetPageParsingDoNotNeedTheRateLimitedAPI() {
        let atom = """
        <feed><entry><title>9.0</title><link href="https://github.com/x/releases/tag/9.0"/></entry>
        <entry><title>11.21</title><link href="https://github.com/x/releases/tag/11.21"/></entry></feed>
        """
        XCTAssertEqual(WineReleaseService.tags(inAtom: atom), ["9.0", "11.21"])

        let hash = String(repeating: "c", count: 64)
        let html = """
        <a href="/x/releases/download/11.21/wine-staging-11.21-osx64.tar.xz">
        <span>wine-staging-11.21-osx64.tar.xz</span>
        <span>sha256:\(hash)</span>
        """
        XCTAssertEqual(
            WineReleaseService.assetName(channel: .staging, inAssetsHTML: html),
            "wine-staging-11.21-osx64.tar.xz"
        )
        XCTAssertEqual(
            WineReleaseService.hash(for: "wine-staging-11.21-osx64.tar.xz", inAssetsHTML: html),
            hash
        )
        XCTAssertNil(WineReleaseService.assetName(channel: .stable, inAssetsHTML: html))
    }
}
