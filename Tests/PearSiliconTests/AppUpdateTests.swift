import CryptoKit
import Darwin
import Foundation
import XCTest
import zlib
@testable import PearSilicon

@MainActor
final class AppUpdateTests: XCTestCase {
    private let oldCommit = String(repeating: "a", count: 40)
    private let newCommit = String(repeating: "b", count: 40)

    func testGitHubModelsRoundTripAndSelectOnlyAppZIP() throws {
        let release = UpdateTestFixture.release()
        let decoded = try JSONDecoder().decode(UpdateRelease.self, from: JSONEncoder().encode(release))
        XCTAssertEqual(decoded, release)
        XCTAssertEqual(try AppUpdateService.selectAsset(in: decoded, channel: .developmentBeta).name, "PearSilicon.zip")
        XCTAssertEqual(decoded.targetCommitish, "main")
    }

    func testMovingBetaComparesCommitNotConstantVersionOrBranchName() throws {
        let release = UpdateTestFixture.release()
        let current = AppUpdateIdentity(version: "0.2.0", build: "10", commit: oldCommit)
        let result = try AppUpdateService.evaluate(
            release: release, asset: release.assets[0], commit: newCommit, current: current, channel: .developmentBeta
        )
        XCTAssertEqual(result.reason, .changedCommit)
        XCTAssertTrue(result.isUpdateAvailable)
        let identical = try AppUpdateService.evaluate(
            release: release, asset: release.assets[0], commit: oldCommit, current: current, channel: .developmentBeta
        )
        XCTAssertFalse(identical.isUpdateAvailable)
    }

    func testAssetDigestDetectsSameCommitRebuildAndOverridesCommit() throws {
        let release = UpdateTestFixture.release()
        let remoteDigest = try XCTUnwrap(release.assets[0].sha256)
        let rebuilt = AppUpdateIdentity(version: "0.2.0", commit: newCommit, assetSHA256: String(repeating: "1", count: 64))
        XCTAssertEqual(try AppUpdateService.evaluate(
            release: release, asset: release.assets[0], commit: newCommit, current: rebuilt, channel: .developmentBeta
        ).reason, .changedAsset)
        let identicalBytes = AppUpdateIdentity(version: "0.2.0", commit: oldCommit, assetSHA256: "sha256:" + remoteDigest)
        XCTAssertFalse(try AppUpdateService.evaluate(
            release: release, asset: release.assets[0], commit: newCommit, current: identicalBytes, channel: .developmentBeta
        ).isUpdateAvailable)
    }

    func testMissingOrAbbreviatedCurrentRevisionDoesNotClaimBetaIsCurrent() throws {
        let release = UpdateTestFixture.release()
        for commit in [nil, "main", "bbbbbbb"] as [String?] {
            XCTAssertEqual(try AppUpdateService.evaluate(
                release: release, asset: release.assets[0], commit: newCommit,
                current: AppUpdateIdentity(version: "0.2.0", commit: commit), channel: .developmentBeta
            ).reason, .unknownCurrentRevision)
        }
    }

    func testStableSelectionUsesNumericVersionAndDoesNotDowngrade() throws {
        let release = UpdateTestFixture.release(tag: "v0.10.0", prerelease: false)
        let asset = try AppUpdateService.selectAsset(in: release, channel: .stable)
        XCTAssertEqual(try AppUpdateService.evaluate(
            release: release, asset: asset, commit: newCommit,
            current: AppUpdateIdentity(version: "0.9.0", commit: oldCommit), channel: .stable
        ).reason, .newerVersion)
        XCTAssertFalse(try AppUpdateService.evaluate(
            release: release, asset: asset, commit: newCommit,
            current: AppUpdateIdentity(version: "1.0.0", commit: oldCommit), channel: .stable
        ).isUpdateAvailable)
        XCTAssertThrowsError(try AppUpdateService.selectAsset(in: UpdateTestFixture.release(), channel: .stable))
        XCTAssertThrowsError(try AppUpdateService.selectAsset(
            in: UpdateTestFixture.release(tag: "v1.0.0", prerelease: true), channel: .stable
        ))
    }

    func testMandatoryDigestAssetBoundsAndDraftAdmission() throws {
        for digest in [nil, "", "md5:" + String(repeating: "0", count: 32), "sha256:abc", String(repeating: "0", count: 64)] as [String?] {
            XCTAssertThrowsError(try AppUpdateService.selectAsset(
                in: UpdateTestFixture.release(digest: digest), channel: .developmentBeta
            ))
        }
        for size in [0, -1, 513 * 1024 * 1024] as [Int64] {
            XCTAssertThrowsError(try AppUpdateService.selectAsset(
                in: UpdateTestFixture.release(size: size), channel: .developmentBeta
            ))
        }
        XCTAssertThrowsError(try AppUpdateService.selectAsset(
            in: UpdateTestFixture.release(draft: true), channel: .developmentBeta
        ))
    }

    func testURLAllowlistRejectsNonHTTPSCredentialsHostConfusionAndTraversal() throws {
        let forbidden = [
            "http://github.com/denizomer10/PearSilicon/releases/download/development-beta/PearSilicon.zip",
            "https://github.com.evil.example/denizomer10/PearSilicon/releases/download/development-beta/PearSilicon.zip",
            "https://user:secret@github.com/denizomer10/PearSilicon/releases/download/development-beta/PearSilicon.zip",
            "https://github.com:444/denizomer10/PearSilicon/releases/download/development-beta/PearSilicon.zip",
            "https://github.com/another/project/releases/download/development-beta/PearSilicon.zip",
            "https://github.com/denizomer10/PearSilicon/releases/download/%2fetc/passwd",
            "https://release-assets.githubusercontent.com.evil.example/file",
            "https://raw.githubusercontent.com/denizomer10/PearSilicon/main/file.zip",
            "file:///tmp/PearSilicon.zip",
            "https://127.0.0.1/PearSilicon.zip"
        ]
        for string in forbidden {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertThrowsError(try UpdateURLPolicy.validate(url, api: false), string)
        }
        try UpdateURLPolicy.validate(
            XCTUnwrap(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/asset?token=fixture")), api: false
        )
        XCTAssertThrowsError(try UpdateURLPolicy.validate(
            XCTUnwrap(URL(string: "https://release-assets.githubusercontent.com/asset")), api: false, initialAsset: true
        ))
        XCTAssertThrowsError(try UpdateURLPolicy.validate(
            XCTUnwrap(URL(string: "https://api.github.com/repos/another/project/releases/latest")), api: true
        ))
    }

    func testCheckIsExplicitAndDereferencesAnnotatedTagNotTargetCommitish() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let release = UpdateTestFixture.release()
        let tagObject = String(repeating: "c", count: 40)
        let http = try UpdateHTTPFixture(release: release, archive: Data(), commit: newCommit, annotatedTag: tagObject)
        let service = AppUpdateService(
            current: AppUpdateIdentity(version: "0.2.0", commit: oldCommit), stagingRoot: fixture.stagingRoot, transport: http.transport
        )
        XCTAssertTrue(http.paths.isEmpty, "Initialization must not contact GitHub")
        let check = try await service.checkForUpdates()
        XCTAssertEqual(check.commit, newCommit)
        XCTAssertEqual(check.reason, .changedCommit)
        XCTAssertEqual(http.paths, [
            "/repos/denizomer10/PearSilicon/releases/tags/development-beta",
            "/repos/denizomer10/PearSilicon/git/ref/tags/development-beta",
            "/repos/denizomer10/PearSilicon/git/tags/" + tagObject
        ])
        XCTAssertFalse(http.paths.contains(where: { $0.contains("heads/main") }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingRoot.path), [])
    }

    func testStableCheckUsesLatestEndpoint() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let release = UpdateTestFixture.release(tag: "v1.0.0", prerelease: false)
        let http = try UpdateHTTPFixture(release: release, archive: Data(), commit: newCommit)
        let service = AppUpdateService(current: AppUpdateIdentity(version: "0.2.0"), stagingRoot: fixture.stagingRoot, transport: http.transport)
        let check = try await service.checkForUpdates(channel: .stable)
        XCTAssertEqual(check.reason, .newerVersion)
        XCTAssertEqual(http.paths.first, "/repos/denizomer10/PearSilicon/releases/latest")
    }

    func testStageHashMismatchCleansWorkspaceBeforeAnyExtraction() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let bytes = Data("not a real archive".utf8)
        let release = UpdateTestFixture.release(size: Int64(bytes.count))
        let http = try UpdateHTTPFixture(release: release, archive: bytes, commit: newCommit)
        let service = AppUpdateService(stagingRoot: fixture.stagingRoot, transport: http.transport)
        let check = try await service.checkForUpdates()
        do {
            _ = try await service.stage(check)
            XCTFail("A digest mismatch was staged")
        } catch AppUpdateError.integrity(let message) {
            XCTAssertTrue(message.contains("SHA-256"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingRoot.path), [])
    }

    func testChangedReleaseIsNotStaged() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let release = UpdateTestFixture.release()
        let http = try UpdateHTTPFixture(release: release, archive: Data(), commit: newCommit)
        let service = AppUpdateService(stagingRoot: fixture.stagingRoot, transport: http.transport)
        let check = try await service.checkForUpdates()
        http.override(path: "/repos/denizomer10/PearSilicon/git/ref/tags/development-beta", with: Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(oldCommit)\"}}".utf8))
        do {
            _ = try await service.stage(check)
            XCTFail("A moved tag was accepted")
        } catch AppUpdateError.staleRelease { }
        XCTAssertFalse(http.paths.contains(where: { $0.contains("/releases/download/") }))
    }

    func testReleaseMovedDuringDownloadIsRejectedBeforeExtraction() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let bytes = Data("small fixture, not executable code".utf8)
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let release = UpdateTestFixture.release(size: Int64(bytes.count), digest: digest)
        let http = try UpdateHTTPFixture(release: release, archive: bytes, commit: newCommit)
        let base = http.transport
        let movedReference = Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(oldCommit)\"}}".utf8)
        let transport = AppUpdateService.Transport { request, destination, limit, timeout in
            let response = try await base.fetch(request, destination, limit, timeout)
            if request.url?.host == "github.com" {
                http.override(path: "/repos/denizomer10/PearSilicon/git/ref/tags/development-beta", with: movedReference)
            }
            return response
        }
        let service = AppUpdateService(stagingRoot: fixture.stagingRoot, transport: transport)
        let check = try await service.checkForUpdates()
        do {
            _ = try await service.stage(check)
            XCTFail("A release that moved during download was staged")
        } catch AppUpdateError.staleRelease { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingRoot.path), [])
    }

    func testInjectedTransportCannotBypassFinalURLOrSizeAdmission() async throws {
        for wrongURL in [false, true] {
            let fixture = try UpdateTestFixture()
            defer { fixture.remove() }
            let release = UpdateTestFixture.release()
            let http = try UpdateHTTPFixture(release: release, archive: Data(), commit: newCommit)
            let base = http.transport
            let transport = AppUpdateService.Transport { request, destination, limit, timeout in
                guard request.url?.host == "github.com" else { return try await base.fetch(request, destination, limit, timeout) }
                try Data(repeating: 0, count: 11).write(to: destination)
                let url = wrongURL ? URL(string: "https://example.com/untrusted.zip")! : request.url!
                return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            }
            let service = AppUpdateService(stagingRoot: fixture.stagingRoot, transport: transport)
            let check = try await service.checkForUpdates()
            do {
                _ = try await service.stage(check)
                XCTFail("Transport bypassed service admission")
            } catch AppUpdateError.unsafeURL where wrongURL { }
            catch AppUpdateError.integrity where !wrongURL { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingRoot.path), [])
        }
    }

    func testInvalidTimeLimitAndSymlinkStagingRootFailWithoutNetworking() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let http = try UpdateHTTPFixture(release: UpdateTestFixture.release(), archive: Data(), commit: newCommit)
        var limits = AppUpdateService.Limits()
        limits.requestTimeout = .infinity
        let invalidLimits = AppUpdateService(stagingRoot: fixture.stagingRoot, limits: limits, transport: http.transport)
        do {
            _ = try await invalidLimits.checkForUpdates()
            XCTFail("An infinite timeout was accepted")
        } catch AppUpdateError.invalidMetadata { }
        try FileManager.default.createSymbolicLink(at: fixture.stagingRoot, withDestinationURL: fixture.root)
        let symlinkRoot = AppUpdateService(stagingRoot: fixture.stagingRoot, transport: http.transport)
        do {
            _ = try await symlinkRoot.checkForUpdates()
            XCTFail("A symlink became a staging root")
        } catch AppUpdateError.operation { }
        XCTAssertTrue(http.paths.isEmpty)
    }

    func testIdentityReadsInjectedBundleBuildCommit() throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        try fixture.makeBundle(at: fixture.source, marker: "fixture", commit: newCommit)
        let bundle = try XCTUnwrap(Bundle(url: fixture.source))
        let identity = AppUpdateIdentity(bundle: bundle)
        XCTAssertEqual(identity.version, "0.2.0")
        XCTAssertEqual(identity.build, "10")
        XCTAssertEqual(identity.commit, newCommit)
        XCTAssertNil(identity.assetSHA256)
    }

    func testRealAdHocBundleStagesWithoutChangingSourceOrInstalledApp() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        try fixture.makeBundle(at: fixture.source, marker: "new", commit: newCommit, internalLinks: true)
        try fixture.makeBundle(at: fixture.destination, marker: "old", commit: oldCommit)
        let sourceHash = try RuntimeRevision.sha256(of: fixture.marker(in: fixture.source))
        let oldHash = try RuntimeRevision.sha256(of: fixture.marker(in: fixture.destination))
        let (service, staged) = try await fixture.stage(commit: newCommit)
        XCTAssertEqual(staged.identity.commit, newCommit)
        XCTAssertEqual(staged.identity.version, "0.2.0")
        XCTAssertGreaterThan(getxattr(staged.bundleURL.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)
        XCTAssertGreaterThan(getxattr(staged.archiveURL.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)
        XCTAssertTrue(staged.bundleURL.path.hasPrefix(fixture.stagingRoot.resolvingSymlinksInPath().path + "/"))
        XCTAssertEqual(try RuntimeRevision.sha256(of: fixture.marker(in: fixture.source)), sourceHash)
        XCTAssertEqual(try RuntimeRevision.sha256(of: fixture.marker(in: fixture.destination)), oldHash)
        _ = try UpdateTestFixture.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.bundleURL.path])
        try await service.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directoryURL.path))
    }

    func testBundleIdentifierAndCodeSignatureAreVerifiedAfterExtraction() async throws {
        for wrongIdentifier in [false, true] {
            let fixture = try UpdateTestFixture()
            defer { fixture.remove() }
            try fixture.makeBundle(at: fixture.source, marker: "new", commit: newCommit, identifier: wrongIdentifier ? "com.example.wrong" : "com.pearsilicon.app")
            if !wrongIdentifier { try Data("tampered".utf8).write(to: fixture.marker(in: fixture.source)) }
            do {
                _ = try await fixture.stage(commit: newCommit)
                XCTFail("An invalid bundle was staged")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(wrongIdentifier ? "com.pearsilicon.app" : "codesign"), error.localizedDescription)
            }
        }
    }

    func testX86OnlyUpdateIsRejectedEvenWhenAdHocSignatureIsValid() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        try fixture.makeBundle(at: fixture.source, marker: "new", commit: newCommit)
        let executable = fixture.source.appendingPathComponent("Contents/MacOS/PearSilicon")
        let archs = try UpdateTestFixture.run("/usr/bin/lipo", ["-archs", executable.path])
        guard archs.contains("x86_64") else { throw XCTSkip("The tiny system fixture has no x86_64 slice") }
        let thinned = fixture.root.appendingPathComponent("thin")
        _ = try UpdateTestFixture.run("/usr/bin/lipo", [executable.path, "-thin", "x86_64", "-output", thinned.path])
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.moveItem(at: thinned, to: executable)
        _ = try UpdateTestFixture.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", fixture.source.path])
        do {
            _ = try await fixture.stage(commit: newCommit)
            XCTFail("An Intel-only update was accepted")
        } catch AppUpdateError.invalidBundle(let message) {
            XCTAssertTrue(message.contains("Apple silicon"))
        }
    }

    func testTransactionalReplacementRetainsRollbackAndMatchingReceipt() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        try fixture.makeBundle(at: fixture.source, marker: "new", commit: newCommit)
        try fixture.makeBundle(at: fixture.destination, marker: "old", commit: oldCommit)
        let (service, staged) = try await fixture.stage(commit: newCommit)
        // Finder edits to a staged copy must never become installed payload.
        try Data("edited staging copy".utf8).write(to: fixture.marker(in: staged.bundleURL))
        let installed = try await service.replaceNonrunningApp(staged, at: fixture.destination, protecting: [], requireStopped: {})
        XCTAssertEqual(try String(contentsOf: fixture.marker(in: fixture.destination), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: fixture.marker(in: installed.rollbackBundleURL), encoding: .utf8), "old")
        let identity = try AppUpdateService.identity(of: installed.installedBundleURL, matching: installed.receiptURL)
        XCTAssertEqual(identity.assetSHA256, staged.update.asset.sha256)
        XCTAssertEqual(identity.commit, newCommit)
        try await service.rollback(installed, protecting: [], requireStopped: {})
        XCTAssertEqual(try String(contentsOf: fixture.marker(in: fixture.destination), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: fixture.marker(in: installed.rollbackBundleURL), encoding: .utf8), "new")
        XCTAssertThrowsError(try AppUpdateService.identity(of: fixture.destination, matching: installed.receiptURL))
    }

    func testReplacementGuardIsRepeatedAndFailurePreservesOriginal() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        try fixture.makeBundle(at: fixture.source, marker: "new", commit: newCommit)
        try fixture.makeBundle(at: fixture.destination, marker: "old", commit: oldCommit)
        let (service, staged) = try await fixture.stage(commit: newCommit)
        let probe = UpdateStoppedProbe()
        do {
            _ = try await service.replaceNonrunningApp(staged, at: fixture.destination, protecting: [], requireStopped: { try probe.check() })
            XCTFail("The second stopped-app guard was ignored")
        } catch UpdateFixtureError.becameRunning { }
        XCTAssertEqual(probe.count, 2)
        XCTAssertEqual(try String(contentsOf: fixture.marker(in: fixture.destination), encoding: .utf8), "old")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains(where: { $0.hasPrefix(".pear-update-") }))
    }

    func testReplacementRejectsRunningDestinationAndProtectedGame() async throws {
        for protectGame in [false, true] {
            let fixture = try UpdateTestFixture()
            defer { fixture.remove() }
            try fixture.makeBundle(at: fixture.source, marker: "new", commit: newCommit)
            try fixture.makeBundle(at: fixture.destination, marker: "old", commit: oldCommit, executableSource: "/bin/sleep")
            let runningBundle = protectGame ? fixture.root.appendingPathComponent("Game.app") : fixture.destination
            if protectGame { try fixture.makeBundle(at: runningBundle, marker: "game", commit: oldCommit, executableSource: "/bin/sleep") }
            let process = Process()
            process.executableURL = runningBundle.appendingPathComponent("Contents/MacOS/PearSilicon")
            process.arguments = ["30"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
            let (service, staged) = try await fixture.stage(commit: newCommit)
            do {
                _ = try await service.replaceNonrunningApp(staged, at: fixture.destination, protecting: protectGame ? [runningBundle] : [], requireStopped: {})
                XCTFail("A running app was replaced")
            } catch AppUpdateError.runningApplication { }
            XCTAssertEqual(try String(contentsOf: fixture.marker(in: fixture.destination), encoding: .utf8), "old")
        }
    }

    func testTamperedArchiveCannotBeInstalledAndRollbackCannotOverwriteEditedApp() async throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        try fixture.makeBundle(at: fixture.source, marker: "new", commit: newCommit)
        try fixture.makeBundle(at: fixture.destination, marker: "old", commit: oldCommit)
        let (service, staged) = try await fixture.stage(commit: newCommit)
        let bytes = try Data(contentsOf: staged.archiveURL)
        var corrupt = bytes
        corrupt[0] ^= 1
        try corrupt.write(to: staged.archiveURL)
        do {
            _ = try await service.replaceNonrunningApp(staged, at: fixture.destination, protecting: [], requireStopped: {})
            XCTFail("An edited staged ZIP was installed")
        } catch AppUpdateError.integrity { }
        XCTAssertEqual(try String(contentsOf: fixture.marker(in: fixture.destination), encoding: .utf8), "old")
        try bytes.write(to: staged.archiveURL)
        let installed = try await service.replaceNonrunningApp(staged, at: fixture.destination, protecting: [], requireStopped: {})
        try Data("user changes".utf8).write(to: fixture.marker(in: fixture.destination))
        do {
            try await service.rollback(installed, protecting: [], requireStopped: {})
            XCTFail("Rollback overwrote an edited app")
        } catch AppUpdateError.operation { }
        XCTAssertEqual(try String(contentsOf: fixture.marker(in: fixture.destination), encoding: .utf8), "user changes")
    }

    func testZIPPathAdmissionBeforeExtraction() throws {
        let unsafe = ["../outside", "/tmp/outside", "PearSilicon.app/../outside", "PearSilicon.app//file", "PearSilicon.app/./file", "C:/outside", "PearSilicon.app\\outside", "PearSilicon.app/file\nname", "PearSilicon.app/file\0name"]
        for path in unsafe {
            try assertInvalidZIP([.init(path, "value")])
        }
        try assertInvalidZIP([.init("PearSilicon.app/File", "one"), .init("PearSilicon.app/file", "two")])
        try assertInvalidZIP([.init("PearSilicon.app/caf\u{e9}", "one"), .init("PearSilicon.app/cafe\u{301}", "two")])
        try assertInvalidZIP([.init("PearSilicon.app/file", "one"), .init("Other.app/file", "two")])
    }

    func testZIPAllowsInternalFrameworkStyleSymlinksButRejectsEscapeCyclesAndLinkParents() throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let valid: [UpdateZIPFixture.Entry] = [
            .init("PearSilicon.app/Versions/A/value", "payload"),
            .link("PearSilicon.app/Versions/Current", "A"),
            .link("PearSilicon.app/value", "Versions/Current/value")
        ]
        let zip = fixture.root.appendingPathComponent("valid.zip")
        try UpdateZIPFixture.make(valid).write(to: zip)
        XCTAssertEqual(try UpdateZIPArchive.validate(at: zip).bundleName, "PearSilicon.app")
        for target in ["/tmp/outside", "../../outside", "Versions/../../../outside", "missing", "C:\\outside"] {
            try assertInvalidZIP([.init("PearSilicon.app/value", "data"), .link("PearSilicon.app/link", target)])
        }
        try assertInvalidZIP([.link("PearSilicon.app/a", "b"), .link("PearSilicon.app/b", "a")])
        try assertInvalidZIP([
            .init("PearSilicon.app/real/value", "data"), .link("PearSilicon.app/alias", "real"), .init("PearSilicon.app/alias/injected", "data")
        ])
        try assertInvalidZIP([.init("PearSilicon.app/file", "data", mode: 0o010644)])
        try assertInvalidZIP([.init("PearSilicon.app/file", "data", mode: 0o104755)])
    }

    func testZIPRejectsAlternatePathsLocalNameMismatchCRCAndExpansionBomb() throws {
        var alternatePath = Data()
        alternatePath.appendLE(UInt16(0x7075)); alternatePath.appendLE(UInt16(0))
        try assertInvalidZIP([.init("PearSilicon.app/file", "data", extra: alternatePath)])
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let zip = fixture.root.appendingPathComponent("invalid.zip")
        var mismatched = UpdateZIPFixture.make([.init("PearSilicon.app/file", "data")])
        mismatched[30] = Character("X").asciiValue!
        try mismatched.write(to: zip)
        XCTAssertThrowsError(try UpdateZIPArchive.validate(at: zip))
        var badCRC = UpdateZIPFixture.make([.init("PearSilicon.app/file", "data")])
        badCRC[30 + "PearSilicon.app/file".utf8.count] ^= 1
        try badCRC.write(to: zip)
        XCTAssertThrowsError(try UpdateZIPArchive.validate(at: zip))
        let payload = Data(repeating: 0, count: 200_000)
        let deflated = try UpdateZIPFixture.deflated(payload)
        let bomb = UpdateZIPFixture.Entry("PearSilicon.app/file", payload: payload, compressed: deflated, declaredSize: 1)
        try UpdateZIPFixture.make([bomb]).write(to: zip)
        XCTAssertThrowsError(try UpdateZIPArchive.validate(at: zip))
    }

    func testZIPEnforcesEntryAndExpandedLimitsAndAcceptsRealDeflate() throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let zip = fixture.root.appendingPathComponent("limited.zip")
        let payload = Data(repeating: 0x61, count: 200_000)
        let entry = UpdateZIPFixture.Entry("PearSilicon.app/file", payload: payload, compressed: try UpdateZIPFixture.deflated(payload))
        try UpdateZIPFixture.make([entry]).write(to: zip)
        XCTAssertEqual(try UpdateZIPArchive.validate(at: zip).expandedBytes, 200_000)
        var limits = AppUpdateService.Limits()
        limits.maximumExpandedBytes = 199_999
        XCTAssertThrowsError(try UpdateZIPArchive.validate(at: zip, limits: limits))
        try UpdateZIPFixture.make([.init("PearSilicon.app/a", "a"), .init("PearSilicon.app/b", "b")]).write(to: zip)
        limits.maximumExpandedBytes = 100
        limits.maximumArchiveEntries = 1
        XCTAssertThrowsError(try UpdateZIPArchive.validate(at: zip, limits: limits))
    }

    func testRuntimeHashIsStreamingAndContentBasedIncludingOptionalCompatibilityLibraries() throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        XCTAssertNil(try RuntimeRevision.fingerprint(in: fixture.root))
        let runtime = fixture.root.appendingPathComponent("libPearRuntime.dylib")
        try Data("abc".utf8).write(to: runtime)
        XCTAssertEqual(try RuntimeRevision.sha256(of: runtime), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let first = try XCTUnwrap(RuntimeRevision.fingerprint(in: fixture.root))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: runtime.path)
        XCTAssertEqual(try RuntimeRevision.fingerprint(in: fixture.root), first)
        let compat = fixture.root.appendingPathComponent("libcxxcompat.dylib")
        let large = Data(repeating: 0x42, count: 3 * 1024 * 1024 + 17)
        try large.write(to: compat)
        XCTAssertEqual(try RuntimeRevision.sha256(of: compat), SHA256.hash(data: large).map { String(format: "%02x", $0) }.joined())
        let withCompat = try XCTUnwrap(RuntimeRevision.fingerprint(in: fixture.root))
        XCTAssertNotEqual(withCompat, first)
        try FileManager.default.removeItem(at: compat)
        XCTAssertEqual(try RuntimeRevision.fingerprint(in: fixture.root), first)
        try Data("abd".utf8).write(to: runtime)
        XCTAssertNotEqual(try RuntimeRevision.fingerprint(in: fixture.root), first)
    }

    func testRuntimeFingerprintIncludesFrameworkContentAndRejectsExternalLinks() throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        try Data("runtime".utf8).write(to: fixture.root.appendingPathComponent("libPearRuntime.dylib"))
        let framework = fixture.root.appendingPathComponent("MarketplaceKit.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let binary = version.appendingPathComponent("MarketplaceKit")
        try Data("first".utf8).write(to: binary)
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("MarketplaceKit").path, withDestinationPath: "Versions/Current/MarketplaceKit")
        let first = try RuntimeRevision.fingerprint(in: fixture.root)
        try Data("other".utf8).write(to: binary)
        XCTAssertNotEqual(try RuntimeRevision.fingerprint(in: fixture.root), first)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: framework.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try RuntimeRevision.fingerprint(in: fixture.root))
    }

    private func assertInvalidZIP(_ entries: [UpdateZIPFixture.Entry], file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try UpdateTestFixture()
        defer { fixture.remove() }
        let zip = fixture.root.appendingPathComponent("unsafe.zip")
        try UpdateZIPFixture.make(entries).write(to: zip)
        XCTAssertThrowsError(try UpdateZIPArchive.validate(at: zip), file: file, line: line)
    }
}

private enum UpdateFixtureError: Error { case unexpectedRequest(String), commandFailed(String), becameRunning }

private final class UpdateStoppedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func check() throws {
        try lock.withLock {
            calls += 1
            if calls == 2 { throw UpdateFixtureError.becameRunning }
        }
    }
}

private struct UpdateTestFixture: Sendable {
    let root: URL
    var source: URL { root.appendingPathComponent("Source/PearSilicon.app") }
    var destination: URL { root.appendingPathComponent("PearSilicon.app") }
    var stagingRoot: URL { root.appendingPathComponent("Updates") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PearSilicon-update-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func marker(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Resources/marker.txt") }

    func makeBundle(
        at url: URL, marker: String, commit: String, internalLinks: Bool = false,
        identifier: String = "com.pearsilicon.app", executableSource: String = "/usr/bin/true"
    ) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: executableSource), to: url.appendingPathComponent("Contents/MacOS/PearSilicon"))
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "PearSilicon", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "10", "PearBuildCommit": commit
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: self.marker(in: url))
        if internalLinks {
            let resources = url.appendingPathComponent("Contents/Resources")
            let version = resources.appendingPathComponent("Versions/A")
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            try Data("linked".utf8).write(to: version.appendingPathComponent("value"))
            try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
            try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("alias").path, withDestinationPath: "Versions/Current/value")
        }
        _ = try Self.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", url.path])
    }

    func stage(commit: String) async throws -> (AppUpdateService, StagedAppUpdate) {
        let archive = root.appendingPathComponent("fixture.zip")
        _ = try Self.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path])
        let bytes = try Data(contentsOf: archive)
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let release = Self.release(size: Int64(bytes.count), digest: digest)
        let http = try UpdateHTTPFixture(release: release, archive: bytes, commit: commit)
        let service = AppUpdateService(stagingRoot: stagingRoot, transport: http.transport)
        let check = try await service.checkForUpdates()
        return (service, try await service.stage(check))
    }

    static func release(
        tag: String = "development-beta", prerelease: Bool = true, draft: Bool = false,
        size: Int64 = 10, digest: String? = "sha256:" + String(repeating: "0", count: 64)
    ) -> UpdateRelease {
        UpdateRelease(
            id: 100, tagName: tag, name: "Fixture release", body: "Ad-hoc test fixture", draft: draft, prerelease: prerelease,
            targetCommitish: "main", htmlURL: URL(string: "https://github.com/denizomer10/PearSilicon/releases/tag/" + tag),
            publishedAt: "2026-10-31T00:00:00Z", assets: [UpdateAsset(
                id: 200, name: "PearSilicon.zip", size: size,
                browserDownloadURL: URL(string: "https://github.com/denizomer10/PearSilicon/releases/download/\(tag)/PearSilicon.zip")!,
                digest: digest, state: "uploaded"
            )]
        )
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UpdateFixtureError.commandFailed(tool + ": " + text) }
        return text
    }
}

private final class UpdateHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: Data]
    private var requests: [String] = []
    var paths: [String] { lock.withLock { requests } }

    init(release: UpdateRelease, archive: Data, commit: String, annotatedTag: String? = nil) throws {
        let releaseData = try JSONEncoder().encode(release)
        let prefix = "/repos/denizomer10/PearSilicon/"
        let object = annotatedTag ?? commit
        let type = annotatedTag == nil ? "commit" : "tag"
        bodies = [
            prefix + "releases/tags/" + release.tagName: releaseData,
            prefix + "releases/latest": releaseData,
            prefix + "releases/\(release.id)": releaseData,
            prefix + "git/ref/tags/" + release.tagName: Data("{\"object\":{\"type\":\"\(type)\",\"sha\":\"\(object)\"}}".utf8),
            release.assets[0].browserDownloadURL.path: archive
        ]
        if let annotatedTag {
            bodies[prefix + "git/tags/" + annotatedTag] = Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commit)\"}}".utf8)
        }
    }

    func override(path: String, with body: Data) { lock.withLock { bodies[path] = body } }

    var transport: AppUpdateService.Transport {
        AppUpdateService.Transport { [self] request, destination, maximumBytes, timeout in
            let url = try XCTUnwrap(request.url)
            let data = try lock.withLock {
                requests.append(url.path)
                guard let data = bodies[url.path] else { throw UpdateFixtureError.unexpectedRequest(url.absoluteString) }
                return data
            }
            guard Int64(data.count) <= maximumBytes, timeout.isFinite, timeout > 0 else { throw UpdateFixtureError.unexpectedRequest("Invalid fixture transfer limits") }
            try data.write(to: destination, options: .withoutOverwriting)
            return try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)]))
        }
    }
}

private enum UpdateZIPFixture {
    struct Entry {
        let name: String
        let payload: Data
        let compressed: Data?
        let declaredSize: UInt32?
        let mode: UInt16
        let extra: Data

        init(_ name: String, _ text: String, mode: UInt16 = 0o100644, extra: Data = Data()) {
            self.init(name, payload: Data(text.utf8), mode: mode, extra: extra)
        }
        init(_ name: String, payload: Data, compressed: Data? = nil, declaredSize: UInt32? = nil, mode: UInt16 = 0o100644, extra: Data = Data()) {
            self.name = name; self.payload = payload; self.compressed = compressed
            self.declaredSize = declaredSize; self.mode = mode; self.extra = extra
        }
        static func link(_ name: String, _ target: String) -> Entry { Entry(name, target, mode: 0o120777) }
    }

    static func make(_ entries: [Entry]) -> Data {
        var result = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let payload = entry.compressed ?? entry.payload
            let method: UInt16 = entry.compressed == nil ? 0 : 8
            let size = entry.declaredSize ?? UInt32(entry.payload.count)
            let crc = entry.payload.withUnsafeBytes { UInt32(truncatingIfNeeded: crc32(0, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt($0.count))) }
            let offset = UInt32(result.count)
            result.appendLE(UInt32(0x04034b50)); result.appendLE(UInt16(20)); result.appendLE(UInt16(0x0800)); result.appendLE(method)
            result.appendLE(UInt16(0)); result.appendLE(UInt16(0)); result.appendLE(crc)
            result.appendLE(UInt32(payload.count)); result.appendLE(size); result.appendLE(UInt16(name.count)); result.appendLE(UInt16(entry.extra.count))
            result.append(name); result.append(entry.extra); result.append(payload)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0x0800)); central.appendLE(method)
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(crc)
            central.appendLE(UInt32(payload.count)); central.appendLE(size); central.appendLE(UInt16(name.count)); central.appendLE(UInt16(entry.extra.count))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt32(entry.mode) << 16); central.appendLE(offset); central.append(name); central.append(entry.extra)
        }
        let centralOffset = UInt32(result.count)
        result.append(central)
        result.appendLE(UInt32(0x06054b50)); result.appendLE(UInt16(0)); result.appendLE(UInt16(0))
        result.appendLE(UInt16(entries.count)); result.appendLE(UInt16(entries.count)); result.appendLE(UInt32(central.count)); result.appendLE(centralOffset); result.appendLE(UInt16(0))
        return result
    }

    static func deflated(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw UpdateFixtureError.commandFailed("deflateInit")
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let capacity = output.count
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(capacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw UpdateFixtureError.commandFailed("deflate") }
        output.count = Int(stream.total_out)
        return output
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
