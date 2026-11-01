import Foundation
import XCTest
@testable import PearSilicon

/// Opt-in end-to-end check through the same AppState path the GUI uses.
/// It uses the real installed library but only launches/stops DELTARUNE.
@MainActor
final class AppStateWineIntegrationTests: XCTestCase {

    func testLaunchesInstalledDeltaruneThroughAppState() async throws {
        guard let root = ProcessInfo.processInfo.environment["PEAR_REAL_SUPPORT_ROOT"], !root.isEmpty else {
            throw XCTSkip("Set PEAR_REAL_SUPPORT_ROOT to the real PearSilicon support root")
        }
        let state = AppState(
            storageRootURL: URL(fileURLWithPath: root, isDirectory: true),
            observesWorkspace: false
        )
        try await state.refreshLibrary()
        XCTAssertFalse(state.wineEngines.isEmpty, "The repaired Wine engine must be visible to the GUI")
        let entry = try XCTUnwrap(state.managedEntries.first { $0.manifest.id == "DELTARUNE" })
        XCTAssertEqual(entry.manifest.wineEngineID, "wine-staging-11-21")

        let logURL = entry.dataURL.appendingPathComponent("launch.log")
        func logSize() -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        }
        let before = logSize()

        await state.launch(entry)
        XCTAssertFalse(
            state.statusMessage.lowercased().contains("error") || state.statusMessage.lowercased().contains("failed"),
            state.statusMessage
        )

        // A process that stays alive is not proof that the game started: Wine
        // can keep an error dialog open. Require fresh renderer output in the
        // launch log, which only the game entering its main loop produces.
        var rendered = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            let size = logSize()
            if size > before,
               let text = try? String(contentsOf: logURL, encoding: .utf8),
               text.contains("Entering main loop") || text.contains("Resizing win") {
                rendered = true
                break
            }
        }
        XCTAssertTrue(rendered, "Wine did not reach the game's main loop; see \(logURL.path)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entry.prefixURL.appendingPathComponent("system.reg").path),
            "Wine prefix was not initialized"
        )
        XCTAssertTrue(state.isRunning(entry), "The game process exited: \(state.statusMessage)")
        state.stop(entry)
        try await Task.sleep(for: .seconds(1))
    }

    /// Opt-in proof that the app's own launch path selects the installed DXVK
    /// component for a MoltenVK entry, mirrors it into the private prefix, and
    /// reaches the game loop. Black-screen prevention itself was confirmed
    /// visually; a test cannot inspect a window's pixels without a screenshot.
    func testLaunchesInstalledDeltaruneWithDXVK() async throws {
        guard let root = ProcessInfo.processInfo.environment["PEAR_REAL_SUPPORT_ROOT"], !root.isEmpty,
              ProcessInfo.processInfo.environment["PEAR_DXVK_E2E"] == "1" else {
            throw XCTSkip("Set PEAR_REAL_SUPPORT_ROOT and PEAR_DXVK_E2E=1")
        }
        let state = AppState(
            storageRootURL: URL(fileURLWithPath: root, isDirectory: true),
            observesWorkspace: false
        )
        try await state.refreshLibrary()
        let entry = try XCTUnwrap(state.managedEntries.first { $0.manifest.id == "DELTARUNE" })
        let engine = try XCTUnwrap(state.wineEngines.first { $0.id == entry.manifest.wineEngineID })
        XCTAssertEqual(state.graphicsBackend(for: entry), .moltenVK)
        XCTAssertTrue(
            GraphicsComponentService.isDXVKInstalled(in: engine.rootURL),
            "Install the DXVK component into the engine before running this test"
        )

        let logURL = entry.dataURL.appendingPathComponent("launch.log")
        func logSize() -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        }
        let before = logSize()

        await state.launch(entry)
        XCTAssertFalse(
            state.statusMessage.lowercased().contains("error") || state.statusMessage.lowercased().contains("failed"),
            state.statusMessage
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entry.prefixURL.appendingPathComponent("drive_c/windows/system32/d3d11.dll").path),
            "The DXVK component was not mirrored into the prefix"
        )

        var usedDXVK = false
        var enteredMainLoop = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(35))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            guard logSize() > before,
                  let text = try? String(contentsOf: logURL, encoding: .utf8) else { continue }
            if text.contains("DXVK: v1.10.3") { usedDXVK = true }
            if text.contains("Entering main loop") || text.contains("Resizing win") { enteredMainLoop = true }
            if usedDXVK && enteredMainLoop { break }
        }
        XCTAssertTrue(usedDXVK, "The launch did not use the DXVK component; see \(logURL.path)")
        XCTAssertTrue(enteredMainLoop, "The game did not reach its main loop; see \(logURL.path)")
        XCTAssertTrue(state.isRunning(entry), "The game process exited: \(state.statusMessage)")
        state.stop(entry)
        try await Task.sleep(for: .seconds(1))
    }
}
