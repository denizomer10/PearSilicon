import Foundation
import XCTest
@testable import PearSilicon

/// Regression tests for the Updates pane offering an old beta (0.6.0) after a
/// newer stable release (0.7.0), and for old builds reaching new releases.
final class AppUpdateChannelTests: XCTestCase {
    private func release(_ tag: String, prerelease: Bool, id: Int64) -> UpdateRelease {
        let url = URL(string: "https://github.com/denizomer10/PearSilicon/releases/download/\(tag)/pearsilicon-macos-arm64.zip")!
        let asset = UpdateAsset(id: id, name: "pearsilicon-macos-arm64.zip", size: 1_000, browserDownloadURL: url,
                                digest: "sha256:" + String(repeating: "a", count: 64), state: "uploaded")
        return UpdateRelease(id: id, tagName: tag, name: tag, body: nil, draft: false, prerelease: prerelease,
                             targetCommitish: nil, htmlURL: nil, publishedAt: nil, assets: [asset])
    }

    /// GitHub lists releases newest first. The first *prerelease* in that list
    /// is v0.6.0, which the old development channel offered over v0.7.0.
    private var publishedOrder: [UpdateRelease] {
        [release("v0.7.0", prerelease: false, id: 9), release("v0.6.0", prerelease: true, id: 8),
         release("v0.5.0", prerelease: true, id: 7), release("v0.4.9", prerelease: true, id: 6)]
    }

    func testDevelopmentChannelPicksNewestVersionIncludingStable() {
        XCTAssertEqual(AppUpdateService.selectRelease(in: publishedOrder, channel: .developmentBeta)?.tagName, "v0.7.0")
    }

    func testCompanionBetaTagRanksWithItsVersionAndStableWinsTie() {
        let releases = [release("v0.8.0-beta", prerelease: true, id: 11), release("v0.8.0", prerelease: false, id: 10)]
            + publishedOrder
        XCTAssertEqual(AppUpdateService.selectRelease(in: releases, channel: .developmentBeta)?.tagName, "v0.8.0")
        XCTAssertEqual(AppUpdateService.selectRelease(in: releases, channel: .stable)?.tagName, "v0.8.0")
    }

    func testStableReleaseIsAcceptedOnTheDevelopmentChannel() throws {
        let asset = try AppUpdateService.selectAsset(in: release("v0.8.0", prerelease: false, id: 10), channel: .developmentBeta)
        XCTAssertEqual(asset.name, "pearsilicon-macos-arm64.zip")
    }

    func testOlderReleaseIsNeverOfferedAsAnUpdate() throws {
        let old = release("v0.6.0", prerelease: true, id: 7)
        let check = try AppUpdateService.evaluate(
            release: old, asset: old.assets[0], commit: String(repeating: "b", count: 40),
            current: AppUpdateIdentity(version: "0.7.0", commit: String(repeating: "c", count: 40)),
            channel: .developmentBeta
        )
        XCTAssertFalse(check.isUpdateAvailable)
    }

    func testNewerVersionIsOfferedOnTheDevelopmentChannel() throws {
        let new = release("v0.8.0", prerelease: false, id: 10)
        let check = try AppUpdateService.evaluate(
            release: new, asset: new.assets[0], commit: String(repeating: "b", count: 40),
            current: AppUpdateIdentity(version: "0.7.0", assetSHA256: String(repeating: "a", count: 64)),
            channel: .developmentBeta
        )
        XCTAssertTrue(check.isUpdateAvailable)
        XCTAssertEqual(check.reason, .newerVersion)
    }

    func testVersionParsingToleratesSuffixes() {
        XCTAssertEqual(UpdateVersion.numericPrefix("v0.8.0-beta"), UpdateVersion("0.8.0"))
        XCTAssertNil(UpdateVersion.numericPrefix("development-beta"))
        XCTAssertTrue(UpdateVersion.numericPrefix("v0.10.0")! > UpdateVersion.numericPrefix("v0.9.9")!)
    }
}
