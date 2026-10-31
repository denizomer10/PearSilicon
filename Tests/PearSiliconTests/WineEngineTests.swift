import CryptoKit
import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class WineEngineTests: XCTestCase {
    func testReadingAnUncreatedStoreDoesNotCreateIt() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        XCTAssertEqual(try WineEngineStore(rootURL: fixture.enginesRoot).engines(), [])
        XCTAssertFalse(ManagedAppFiles.exists(fixture.enginesRoot))
    }

    func testRegistrationCopiesSelfContainedEngineAndPersistsRelativeExecutableWithoutExecutingIt() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.engineFolder()
        let before = try fixture.snapshot(source)
        let store = WineEngineStore(rootURL: fixture.enginesRoot)
        let engine = try store.registerLocalEngine(
            from: source, id: "community-test", name: "Community Wine", version: "test-version",
            executablePath: "bin/wine64", licenseConfirmed: true
        )
        XCTAssertEqual(engine.distribution, .community)
        XCTAssertEqual(engine.version, "test-version")
        XCTAssertEqual(engine.executablePath, "Runtime/bin/wine64")
        XCTAssertEqual(engine.rootURL, ManagedAppTestFixture.canonical(fixture.enginesRoot.appendingPathComponent("community-test", isDirectory: true)))
        XCTAssertEqual(engine.executableURL.path, engine.rootURL.appendingPathComponent("Runtime/bin/wine64").path)
        XCTAssertTrue(LibraryPath.isInside(engine.executableURL, root: engine.rootURL))
        XCTAssertEqual(try fixture.snapshot(engine.rootURL.appendingPathComponent("Runtime")), before)
        XCTAssertEqual(try fixture.snapshot(source), before)
        XCTAssertEqual(try store.engines(), [engine])
        XCTAssertEqual(try store.engine(id: engine.id), engine)
        XCTAssertEqual(try JSONDecoder().decode(WineEngine.self, from: JSONEncoder().encode(engine)), engine)
        // These are only Mach-O headers, not runnable binaries. Successful
        // registration therefore also proves no version-probe was executed.
        XCTAssertNoThrow(try engine.validate())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: engine.rootURL.path).sorted(), ["Runtime", WineEngine.manifestFilename].sorted())
    }

    func testLocalOpenSourceEngineRequiresExplicitLicenseConfirmation() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.engineFolder()
        let store = WineEngineStore(rootURL: fixture.enginesRoot)
        XCTAssertThrowsError(try store.registerLocalEngine(
            from: source, id: "local-test", name: "Local Wine", version: "user-supplied",
            executablePath: "bin/wine64", distribution: .community, licenseConfirmed: false
        ))
        XCTAssertFalse(ManagedAppFiles.exists(fixture.enginesRoot))
        let engine = try store.registerLocalEngine(
            from: source, id: "local-test", name: "Local Wine", version: "user-supplied",
            executablePath: "bin/wine64", distribution: .community, licenseConfirmed: true
        )
        XCTAssertEqual(engine.distribution, .community)
        XCTAssertEqual(engine.version, "user-supplied")
        XCTAssertTrue(WineEngineStore.openSourceNotice.contains("LGPL"))
        XCTAssertTrue(WineEngineStore.openSourceNotice.contains("Gcenx"))
    }

    func testLoadsARealInstalledEngineWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["PEAR_REAL_ENGINE_ROOT"], !path.isEmpty else {
            throw XCTSkip("Set PEAR_REAL_ENGINE_ROOT to an Engines directory")
        }
        let store = WineEngineStore(rootURL: URL(fileURLWithPath: path, isDirectory: true))
        let engines = try store.engines()
        XCTAssertFalse(engines.isEmpty)
        for engine in engines { try engine.validate() }
    }

    func testMovedEngineStoreRebasesPersistedRootAndExecutablePaths() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let original = try WineEngineStore(rootURL: fixture.enginesRoot).registerLocalEngine(
            from: fixture.engineFolder(), id: "move-test", name: "Move Test", version: "1",
            executablePath: "bin/wine64", licenseConfirmed: true
        )
        let moved = fixture.root.appendingPathComponent("Moved Engines", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.enginesRoot, to: moved)
        let reloaded = try XCTUnwrap(WineEngineStore(rootURL: moved).engine(id: original.id))
        XCTAssertEqual(reloaded.rootURL, ManagedAppTestFixture.canonical(moved.appendingPathComponent(original.id, isDirectory: true)))
        XCTAssertEqual(reloaded.executablePath, original.executablePath)
        XCTAssertTrue(ManagedAppFiles.exists(reloaded.executableURL))
        XCTAssertFalse(ManagedAppFiles.exists(original.executableURL))
    }

    func testUnsafeEngineIDsAndExecutablePathsFailBeforeWritingStore() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.engineFolder()
        let store = WineEngineStore(rootURL: fixture.enginesRoot)
        for id in ["../outside", "a/b", "a\\b", "bad:id", ".hidden", "Downloads", "downloads", ""] {
            XCTAssertThrowsError(try store.registerLocalEngine(
                from: source, id: id, name: "Engine", version: "1", executablePath: "bin/wine64", licenseConfirmed: true
            ), id)
        }
        for path in ["/bin/wine64", "../wine64", "bin/../bin/wine64", "bin//wine64", "C:\\wine.exe"] {
            XCTAssertThrowsError(try store.registerLocalEngine(
                from: source, id: "engine", name: "Engine", version: "1", executablePath: path, licenseConfirmed: true
            ), path)
        }
        XCTAssertFalse(ManagedAppFiles.exists(fixture.enginesRoot))
    }

    func testShellWrappersNonMacBinariesAndMissingExecuteBitCannotBeRegistered() throws {
        for kind in 0..<3 {
            let fixture = try ManagedAppTestFixture()
            defer { fixture.remove() }
            let source = try fixture.engineFolder()
            let binary = source.appendingPathComponent("bin/wine64")
            switch kind {
            case 0: try Data("#!/bin/sh\ntouch should-never-exist\n".utf8).write(to: binary)
            case 1: try ManagedAppTestFixture.machO(platform: 2).write(to: binary)
            default: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
            }
            XCTAssertThrowsError(try WineEngineStore(rootURL: fixture.enginesRoot).registerLocalEngine(
                from: source, id: "engine", name: "Engine", version: "1", executablePath: "bin/wine64", licenseConfirmed: true
            ))
            XCTAssertFalse(ManagedAppFiles.exists(fixture.enginesRoot))
            XCTAssertFalse(ManagedAppFiles.exists(fixture.root.appendingPathComponent("should-never-exist")))
        }
    }

    func testEngineLinkEscapesAreRejectedAndExistingRegistrationIsNeverReplaced() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.engineFolder()
        let store = WineEngineStore(rootURL: fixture.enginesRoot)
        let engine = try store.registerLocalEngine(
            from: source, id: "engine", name: "Engine", version: "1", executablePath: "bin/wine64", licenseConfirmed: true
        )
        let before = try fixture.snapshot(engine.rootURL)
        XCTAssertThrowsError(try store.registerLocalEngine(
            from: source, id: "engine", name: "Replacement", version: "2", executablePath: "bin/wine64", licenseConfirmed: true
        ))
        XCTAssertEqual(try fixture.snapshot(engine.rootURL), before)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("not runtime data".utf8).write(to: outside)
        let escape = source.appendingPathComponent("lib/escape")
        try FileManager.default.createSymbolicLink(atPath: escape.path, withDestinationPath: outside.path)
        XCTAssertThrowsError(try store.registerLocalEngine(
            from: source, id: "other", name: "Other", version: "1", executablePath: "bin/wine64", licenseConfirmed: true
        ))
        try FileManager.default.removeItem(at: escape)
        try FileManager.default.linkItem(at: outside, to: escape)
        XCTAssertThrowsError(try store.registerLocalEngine(
            from: source, id: "other", name: "Other", version: "1", executablePath: "bin/wine64", licenseConfirmed: true
        ))
        XCTAssertEqual(try Data(contentsOf: outside), Data("not runtime data".utf8))
        XCTAssertEqual(try fixture.snapshot(engine.rootURL), before)
    }

    func testWineLaunchPlanUsesExplicitEngineAndPerGamePrefixWithNoInjectedEnvironment() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let engine = try WineEngineStore(rootURL: fixture.enginesRoot).registerLocalEngine(
            from: fixture.engineFolder(), id: "engine", name: "Engine", version: "1",
            executablePath: "bin/wine64", licenseConfirmed: true
        )
        let service = ManagedAppService()
        let first = try service.importWindowsFolder(
            from: fixture.windowsFolder(name: "Game One"), executablePath: "bin/Game.exe", libraryRoot: fixture.library, engineID: engine.id
        )
        let second = try service.importWindowsFolder(
            from: fixture.windowsFolder(name: "Game Two"), executablePath: "bin/Game.exe", libraryRoot: fixture.library, engineID: engine.id
        )
        let plan = try service.launchConfiguration(for: first, engine: engine, metalHUDEnabled: true)
        XCTAssertEqual(plan.executableURL, engine.executableURL)
        XCTAssertEqual(plan.arguments, [first.payloadURL.path])
        XCTAssertTrue(plan.sandboxProfile.isEmpty, "Wine now launches directly for Rosetta/wineserver compatibility")
        XCTAssertEqual(plan.workingDirectoryURL, first.payloadURL.deletingLastPathComponent())
        XCTAssertEqual(plan.environment["WINEPREFIX"], first.prefixURL.path)
        XCTAssertEqual(plan.environment["HOME"], first.dataURL.path)
        XCTAssertEqual(plan.environment["CFFIXED_USER_HOME"], first.dataURL.path)
        XCTAssertEqual(plan.environment["MTL_HUD_ENABLED"], "1")
        XCTAssertNotEqual(plan.environment["WINEPREFIX"], try service.launchConfiguration(for: second, engine: engine).environment["WINEPREFIX"])
        XCTAssertFalse(ManagedAppFiles.exists(first.prefixURL.appendingPathComponent("system.reg")), "Planning must not bootstrap or execute Wine")
        let environment = ManagedAppService.environment(for: first, engine: engine, inherited: [
            "DYLD_INSERT_LIBRARIES": "/host/inject", "PEAR_HOME_DIR": "/host/home", "WINEPREFIX": "/shared",
            "WINESERVER": "/host/server", "WINELOADER": "/host/loader", "PATH": "/host/bin"
        ])
        XCTAssertEqual(environment["WINESERVER"], engine.executableURL.deletingLastPathComponent().appendingPathComponent("wineserver").path)
        XCTAssertEqual(environment["WINELOADER"], engine.executableURL.path)
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertFalse(environment.keys.contains { $0.hasPrefix("PEAR_") })
        XCTAssertEqual(environment["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        XCTAssertEqual(environment["WINEDLLPATH"], engine.rootURL.appendingPathComponent("Runtime/lib/wine").path)
        XCTAssertNil(environment["VK_ICD_FILENAMES"])
    }

    func testMissingMismatchedAndEscapingEngineDescriptorsCannotProduceLaunchPlan() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let engine = try WineEngineStore(rootURL: fixture.enginesRoot).registerLocalEngine(
            from: fixture.engineFolder(), id: "engine", name: "Engine", version: "1",
            executablePath: "bin/wine64", licenseConfirmed: true
        )
        let entry = try ManagedAppService().importWindowsFolder(
            from: fixture.windowsFolder(), executablePath: "bin/Game.exe", libraryRoot: fixture.library, engineID: engine.id
        )
        XCTAssertThrowsError(try ManagedAppService().launchConfiguration(for: entry))
        var wrong = engine
        wrong.id = "different"
        XCTAssertThrowsError(try ManagedAppService().launchConfiguration(for: entry, engine: wrong))
        wrong = engine
        wrong.executablePath = "../../outside"
        XCTAssertThrowsError(try ManagedAppService().launchConfiguration(for: entry, engine: wrong))
        wrong.executablePath = "/bin/sh"
        XCTAssertThrowsError(try ManagedAppService().launchConfiguration(for: entry, engine: wrong))
    }

    func testCommunityDownloadVerifiesHashWithoutExtractingExecutingOrRegistering() async throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let payload = Data("opaque archive fixture, never extracted".utf8)
        let url = URL(string: "https://engines.example.invalid/community.zip")!
        let probe = EngineDownloadProbe(payload: payload)
        let store = WineEngineStore(rootURL: fixture.enginesRoot, download: { url, destination, maximum in
            try await probe.write(url, to: destination, maximum: maximum)
        })
        let result = try await store.downloadCommunityArchive(
            from: url, sha256: Self.sha256(payload).uppercased(), licenseConfirmed: true, maximumBytes: 1_024
        )
        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(result.lastPathComponent, Self.sha256(payload) + ".archive")
        XCTAssertEqual(result.deletingLastPathComponent(), fixture.enginesRoot.appendingPathComponent("Downloads", isDirectory: true))
        XCTAssertTrue(LibraryPath.isInside(result, root: fixture.enginesRoot))
        XCTAssertEqual(try store.engines(), [])
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, url)
        XCTAssertEqual(requests.first?.1, 1_024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.enginesRoot.path), ["Downloads"])
        do {
            _ = try await store.downloadCommunityArchive(from: url, sha256: Self.sha256(payload), licenseConfirmed: true, maximumBytes: 1_024)
            XCTFail("A verified artifact must not overwrite an existing destination")
        } catch {
            XCTAssertEqual(try Data(contentsOf: result), payload)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.deletingLastPathComponent().path), [result.lastPathComponent])
    }

    func testDownloadRequiresHTTPSHashLicenseAndBoundBeforeCallingTransport() async throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let payload = Data("archive".utf8)
        let probe = EngineDownloadProbe(payload: payload)
        let store = WineEngineStore(rootURL: fixture.enginesRoot, download: { url, destination, maximum in
            try await probe.write(url, to: destination, maximum: maximum)
        })
        let good = URL(string: "https://engines.example.invalid/engine.zip")!
        let cases: [(URL, String, Bool, Int64)] = [
            (good, Self.sha256(payload), false, 100),
            (URL(string: "http://engines.example.invalid/engine.zip")!, Self.sha256(payload), true, 100),
            (URL(string: "file:///tmp/engine.zip")!, Self.sha256(payload), true, 100),
            (URL(string: "https://user:password@engines.example.invalid/engine.zip")!, Self.sha256(payload), true, 100),
            (URL(string: "https://engines.example.invalid/engine.zip#fragment")!, Self.sha256(payload), true, 100),
            (good, "short", true, 100), (good, String(repeating: "g", count: 64), true, 100),
            (good, Self.sha256(payload), true, 0),
            (good, Self.sha256(payload), true, WineEngineStore.maximumAllowedDownloadBytes + 1)
        ]
        for (url, hash, license, maximum) in cases {
            do {
                _ = try await store.downloadCommunityArchive(from: url, sha256: hash, licenseConfirmed: license, maximumBytes: maximum)
                XCTFail("Invalid download request was admitted")
            } catch { }
        }
        let requests = await probe.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(ManagedAppFiles.exists(fixture.enginesRoot))
    }

    func testWrongHashEmptyAndOversizedDownloadsLeaveNoArtifacts() async throws {
        for kind in 0..<3 {
            let fixture = try ManagedAppTestFixture()
            defer { fixture.remove() }
            let payload = kind == 1 ? Data() : Data("download fixture".utf8)
            // This deliberately ignores the transport bound to test independent
            // postflight admission as well as the real transport's streaming cap.
            let store = WineEngineStore(rootURL: fixture.enginesRoot, download: { _, destination, _ in
                try payload.write(to: destination)
            })
            do {
                _ = try await store.downloadCommunityArchive(
                    from: URL(string: "https://engines.example.invalid/archive")!,
                    sha256: kind == 0 ? String(repeating: "0", count: 64) : Self.sha256(payload),
                    licenseConfirmed: true, maximumBytes: kind == 2 ? 1 : 1_024
                )
                XCTFail("Invalid download was committed")
            } catch { }
            XCTAssertFalse(ManagedAppFiles.exists(fixture.enginesRoot))
        }
    }

    func testCancelledDownloadCleansPartialFileAndNeverCreatesPlatformFolders() async throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let store = WineEngineStore(rootURL: fixture.enginesRoot, download: { _, destination, _ in
            try Data("partial".utf8).write(to: destination)
            throw CancellationError()
        })
        do {
            _ = try await store.downloadCommunityArchive(
                from: URL(string: "https://engines.example.invalid/archive")!,
                sha256: String(repeating: "0", count: 64), licenseConfirmed: true
            )
            XCTFail("Cancelled download was committed")
        } catch is CancellationError { }
        XCTAssertFalse(ManagedAppFiles.exists(fixture.enginesRoot))
        XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor EngineDownloadProbe {
    let payload: Data
    var requests: [(URL, Int64)] = []

    init(payload: Data) { self.payload = payload }

    func write(_ url: URL, to destination: URL, maximum: Int64) throws {
        requests.append((url, maximum))
        try payload.write(to: destination)
    }
}
