import Foundation
import XCTest
@testable import PearSilicon

final class CommunityWineServiceTests: XCTestCase {
    func testAcceptsRepositoryURLsAndIgnoresReleasePaths() throws {
        let service = CommunityWineService.self
        let expected = (owner: "Gcenx", repo: "macOS_Wine_builds")
        for input in [
            "https://github.com/Gcenx/macOS_Wine_builds",
            "https://github.com/Gcenx/macOS_Wine_builds.git",
            "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.21",
            "github.com/Gcenx/macOS_Wine_builds",
            "Gcenx/macOS_Wine_builds",
        ] {
            let parts = try service.repositoryParts(input)
            XCTAssertEqual(parts.owner, expected.owner, input)
            XCTAssertEqual(parts.repo, expected.repo, input)
        }
    }

    func testRejectsNonGitHubAndMalformedRepositories() {
        let service = CommunityWineService.self
        for input in [
            "", "https://gitlab.com/owner/repo", "http://github.com/owner/repo",
            "https://github.com/owner", "https://github.com/../repo",
            "https://github.com/owner/repo/../../etc", "ftp://github.com/owner/repo",
        ] {
            XCTAssertThrowsError(try service.repositoryParts(input), input)
        }
    }

    func testDownloadHostsAreLimitedToGitHub() {
        for host in ["github.com", "codeload.github.com", "release-assets.githubusercontent.com",
                     "objects.githubusercontent.com"] {
            XCTAssertTrue(CommunityWineService.isAllowedDownloadHost(host), host)
        }
        for host in ["evil.example", "github.com.evil.example", nil, "raw.githubusercontent.com"] as [String?] {
            XCTAssertFalse(CommunityWineService.isAllowedDownloadHost(host), host ?? "nil")
        }
    }

    /// Opt-in network check: resolves a real repository without downloading the
    /// archive. Set PEAR_COMMUNITY_INTEGRATION=1 to run it.
    func testResolvesRealGitHubRepository() async throws {
        guard ProcessInfo.processInfo.environment["PEAR_COMMUNITY_INTEGRATION"] == "1" else {
            throw XCTSkip("Set PEAR_COMMUNITY_INTEGRATION=1 to query GitHub")
        }
        let archive = try await CommunityWineService().resolve(input: "https://github.com/Gcenx/macOS_Wine_builds")
        XCTAssertTrue(archive.url.scheme == "https")
        XCTAssertTrue(CommunityWineService.isAllowedDownloadHost(archive.url.host))
        XCTAssertFalse(archive.assetName.isEmpty)
    }
}
