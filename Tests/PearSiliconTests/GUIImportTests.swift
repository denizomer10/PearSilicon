import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class GUIImportTests: XCTestCase {
    func testAcceptedAppBundleDoesNotGoThroughArchiveInstaller() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        var archives: [URL] = []
        var bundles: [URL] = []
        let operations = PackageImportOperations(
            installArchive: { archives.append($0); return fixture.app(named: "Archive") },
            installBundle: { bundles.append($0); return fixture.app(named: "Bundle") }
        )
        let state = fixture.state(imports: operations)
        let archive = fixture.root.appendingPathComponent("Example.IPA")
        let bundle = fixture.root.appendingPathComponent("Example.APP")

        await state.install(packageURLs: [archive, bundle])

        XCTAssertEqual(archives, [archive])
        XCTAssertEqual(bundles, [bundle])
        XCTAssertFalse(state.isBusy)
    }

    func testOverlappingImportsStayFIFOAndBusyUntilTheLastRequestFinishes() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        let firstGate = GUIImportGate()
        let secondGate = GUIImportGate()
        defer { firstGate.open(); secondGate.open() }
        let firstStarted = expectation(description: "first package started")
        let secondSubmitted = expectation(description: "second request submitted")
        let secondStarted = expectation(description: "second package started")
        var started: [String] = []
        var active = 0
        var maximumActive = 0
        let operations = PackageImportOperations(
            installArchive: { url in
                started.append(url.lastPathComponent)
                active += 1
                maximumActive = max(maximumActive, active)
                defer { active -= 1 }
                if url.lastPathComponent == "First.ipa" {
                    firstStarted.fulfill()
                    await firstGate.wait()
                } else {
                    secondStarted.fulfill()
                    await secondGate.wait()
                }
                return fixture.app()
            },
            installBundle: { _ in throw GUIImportFailure.unexpectedBundle }
        )
        let state = fixture.state(imports: operations)
        let first = Task { await state.install(packageURLs: [fixture.root.appendingPathComponent("First.ipa")]) }
        await completed(firstStarted)
        let second = Task {
            secondSubmitted.fulfill()
            await state.install(packageURLs: [fixture.root.appendingPathComponent("Second.ipa")])
        }
        await completed(secondSubmitted)
        XCTAssertEqual(started, ["First.ipa"], "the second request must wait, not run concurrently")

        firstGate.open()
        await first.value
        await completed(secondStarted)
        XCTAssertTrue(state.isBusy, "finishing the first request must not unlock storage while the second is active")
        XCTAssertEqual(maximumActive, 1)
        secondGate.open()
        await second.value
        XCTAssertEqual(started, ["First.ipa", "Second.ipa"])
        XCTAssertFalse(state.isBusy)
    }

    func testCancellationStopsTheRestOfABatchAndReleasesBusyState() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        let gate = GUIImportGate()
        defer { gate.open() }
        let started = expectation(description: "first package started")
        var imported: [String] = []
        let state = fixture.state(imports: PackageImportOperations(
            installArchive: { url in
                imported.append(url.lastPathComponent)
                if imported.count == 1 {
                    started.fulfill()
                    await gate.wait()
                }
                return fixture.app()
            },
            installBundle: { _ in throw GUIImportFailure.unexpectedBundle }
        ))
        let task = Task {
            await state.install(packageURLs: ["First.ipa", "MustNotStart.ipa"].map {
                fixture.root.appendingPathComponent($0)
            })
        }
        await completed(started)
        task.cancel()
        gate.open()
        await task.value

        XCTAssertEqual(imported, ["First.ipa"])
        XCTAssertFalse(state.isBusy)
    }

    func testCancellingAQueuedRequestDoesNotCancelItsPredecessorOrSuccessor() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        let gate = GUIImportGate()
        defer { gate.open() }
        let started = expectation(description: "active package started")
        let queued = expectation(description: "cancelled request submitted")
        var imported: [String] = []
        let state = fixture.state(imports: PackageImportOperations(
            installArchive: { url in
                imported.append(url.lastPathComponent)
                if url.lastPathComponent == "Active.ipa" {
                    started.fulfill()
                    await gate.wait()
                }
                return fixture.app()
            },
            installBundle: { _ in throw GUIImportFailure.unexpectedBundle }
        ))
        let active = Task { await state.install(packageURLs: [fixture.root.appendingPathComponent("Active.ipa")]) }
        await completed(started)
        let cancelled = Task {
            queued.fulfill()
            await state.install(packageURLs: [fixture.root.appendingPathComponent("Cancelled.ipa")])
        }
        await completed(queued)
        cancelled.cancel()
        let successor = Task { await state.install(packageURLs: [fixture.root.appendingPathComponent("Next.ipa")]) }
        gate.open()
        await active.value
        await cancelled.value
        await successor.value

        XCTAssertEqual(imported, ["Active.ipa", "Next.ipa"])
        XCTAssertFalse(state.isBusy)
    }

    func testImportBlocksUninstallAndLaunchBeforeTheyTouchTheLibrary() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        let gate = GUIImportGate()
        defer { gate.open() }
        let started = expectation(description: "import started")
        let state = fixture.state(imports: PackageImportOperations(
            installArchive: { _ in
                started.fulfill()
                await gate.wait()
                return fixture.app()
            },
            installBundle: { _ in throw GUIImportFailure.unexpectedBundle }
        ))
        let existing = fixture.app(named: "Existing")
        try FileManager.default.createDirectory(at: existing.bundleURL, withIntermediateDirectories: true)
        let sentinel = existing.bundleURL.appendingPathComponent("sentinel")
        try Data("keep this bundle".utf8).write(to: sentinel)
        let task = Task { await state.install(packageURLs: [fixture.root.appendingPathComponent("Import.ipa")]) }
        await completed(started)
        let progress = state.statusMessage

        state.uninstall(existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(state.statusMessage, progress)
        // This bundle does not exist and has no executable, so even the old
        // unguarded path cannot launch anything during the regression check.
        await state.launch(fixture.app(named: "Missing"))
        XCTAssertEqual(state.statusMessage, progress)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Runtime").path))

        gate.open()
        await task.value
        XCTAssertFalse(state.isBusy)
    }

    private func completed(_ expectation: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed)
    }
}

@MainActor
final class GUIImportRoutingTests: XCTestCase {
    func testSecurityScopeIsHeldUntilTheAsyncImportReturns() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        let gate = GUIImportGate()
        defer { gate.open() }
        let started = expectation(description: "installer entered")
        var events: [String] = []
        let operations = PackageImportOperations(
            installArchive: { _ in
                events.append("install")
                started.fulfill()
                await gate.wait()
                return fixture.app()
            },
            installBundle: { _ in throw GUIImportFailure.unexpectedBundle },
            startAccessing: { _ in events.append("start"); return true },
            stopAccessing: { _ in events.append("stop") }
        )
        let task = Task { try await operations.install(at: fixture.root.appendingPathComponent("Example.ipa")) }
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events, ["start", "install"])
        gate.open()
        _ = try await task.value
        XCTAssertEqual(events, ["start", "install", "stop"])
    }

    func testFailedBundleImportReleasesSecurityScope() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        var events: [String] = []
        let operations = PackageImportOperations(
            installArchive: { _ in events.append("archive"); throw GUIImportFailure.installer },
            installBundle: { _ in events.append("bundle"); throw GUIImportFailure.installer },
            startAccessing: { _ in events.append("start"); return true },
            stopAccessing: { _ in events.append("stop") }
        )
        do {
            _ = try await operations.install(at: fixture.root.appendingPathComponent("Broken.app"))
            XCTFail("the install must fail")
        } catch {
            XCTAssertEqual(error as? GUIImportFailure, .installer)
        }
        XCTAssertEqual(events, ["start", "bundle", "stop"])
    }

    func testOrdinaryLocalURLDoesNotRequireASecurityScopeGrant() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        var imports = 0
        var stops = 0
        let operations = PackageImportOperations(
            installArchive: { _ in imports += 1; return fixture.app() },
            installBundle: { _ in throw GUIImportFailure.unexpectedBundle },
            startAccessing: { _ in false },
            stopAccessing: { _ in stops += 1 }
        )
        _ = try await operations.install(at: fixture.root.appendingPathComponent("Example.ipa"))
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(stops, 0)
    }

    func testUnsupportedAndNonlocalURLsNeverReachTheInstaller() async throws {
        let fixture = try GUIImportFixture()
        defer { fixture.remove() }
        var imports = 0
        var accesses = 0
        let operations = PackageImportOperations(
            installArchive: { _ in imports += 1; return fixture.app() },
            installBundle: { _ in imports += 1; return fixture.app() },
            startAccessing: { _ in accesses += 1; return false }
        )
        let urls = [
            fixture.root.appendingPathComponent("Notes.txt"),
            try XCTUnwrap(URL(string: "https://example.invalid/Example.ipa")),
            try XCTUnwrap(URL(string: "file://example.invalid/Example.app"))
        ]
        for url in urls {
            do {
                _ = try await operations.install(at: url)
                XCTFail("unsupported input reached the installer: \(url)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("local .ipa"), error.localizedDescription)
            }
        }
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(accesses, 0)
    }
}

private enum GUIImportFailure: Error {
    case unexpectedBundle
    case installer
}

@MainActor
private final class GUIImportGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private struct GUIImportFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-gui-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func state(imports: PackageImportOperations) -> AppState {
        AppState(storageRootURL: root, packageImports: imports, observesWorkspace: false)
    }

    func app(named name: String = "Imported") -> InstalledApp {
        InstalledApp(
            id: "com.pearsilicon.gui-test.\(name.lowercased())", displayName: name,
            bundleName: name, shortVersion: "1.0", bundleVersion: "1", minimumOSVersion: nil,
            bundleURL: root.appendingPathComponent("Applications/\(name).app"),
            executableName: "NoExecutable", iconURL: nil, installedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
