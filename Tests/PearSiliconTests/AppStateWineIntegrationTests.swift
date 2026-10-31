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
        // launch log, which only the game's MoltenVK path produces.
        var rendered = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            let size = logSize()
            if size > before,
               let text = try? String(contentsOf: logURL, encoding: .utf8),
               text.contains("mvk-info") || text.contains("MoltenVK") {
                rendered = true
                break
            }
        }
        XCTAssertTrue(rendered, "Wine did not initialize the game's renderer; see \(logURL.path)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entry.prefixURL.appendingPathComponent("system.reg").path),
            "Wine prefix was not initialized"
        )
        XCTAssertTrue(state.isRunning(entry), "The game process exited: \(state.statusMessage)")
        state.stop(entry)
        try await Task.sleep(for: .seconds(1))
    }
}
