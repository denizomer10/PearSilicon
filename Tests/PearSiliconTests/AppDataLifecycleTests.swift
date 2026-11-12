import Foundation
import XCTest
@testable import PearSilicon

final class AppDataLifecycleTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pear-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testResetRequiresMarkerAndDoesNotFollowSymlinks() throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("save")
        try Data("safe".utf8).write(to: sentinel)
        XCTAssertThrowsError(try AppDataLifecycle(root: root).validateForReset())
        XCTAssertThrowsError(try AppDataLifecycle(root: root).reset())
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        try Data("1\n".utf8).write(to: root.appendingPathComponent(StorageLocationStore.markerName))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try AppDataLifecycle(root: root).reset()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [StorageLocationStore.markerName])
    }

    func testNativeDownloadsMoveIntoPortableHomeAndConflictsAreRetained() throws {
        let root = try fixture(), source = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data("download".utf8).write(to: source.appendingPathComponent("Documents/assets"))
        try AppDataLifecycle(root: root).importNativeData(id: "game", source: source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Games/game/Documents/assets")), Data("download".utf8))
        XCTAssertFalse(fm.fileExists(atPath: source.appendingPathComponent("Documents").path))
        try fm.createDirectory(at: source.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: source.appendingPathComponent("Documents/assets"))
        try AppDataLifecycle(root: root).importNativeData(id: "game", source: source)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("NativeMigrationConflicts/game").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Games/game/Documents/assets")), Data("download".utf8))
    }

    func testIOSRemovalDoesNotDeleteAnotherAppsLogs() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for path in ["Games/com.game", "ODR/com.game", "Keychain/com.game", "Legacy32/Saves/com.game", "Logs"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for name in ["com.game.log", "com.game.legacy.1.log", "com.game.other.log"] {
            try Data().write(to: root.appendingPathComponent("Logs/" + name))
        }
        try AppDataLifecycle(root: root).removeIOSData(id: "com.game")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Games/com.game").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Logs").path), ["com.game.other.log"])
    }

    func testKeepAndReinstallManagedData() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("Game.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        let library = fixture.root.appendingPathComponent("Library")
        let service = ManagedAppService()
        let entry = try service.importWindowsExecutable(from: source, libraryRoot: library, engineID: "wine")
        try Data("progress".utf8).write(to: entry.dataURL.appendingPathComponent("save"))
        try Data("beside exe".utf8).write(to: entry.payloadURL.deletingLastPathComponent().appendingPathComponent("slot.sav"))
        try AppDataLifecycle(root: library).removeManaged(entry, keepData: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directoryURL.path))
        let restored = try service.importWindowsExecutable(from: source, libraryRoot: library, engineID: "wine")
        XCTAssertEqual(try Data(contentsOf: restored.dataURL.appendingPathComponent("save")), Data("progress".utf8))
        XCTAssertEqual(try Data(contentsOf: restored.payloadURL.deletingLastPathComponent().appendingPathComponent("slot.sav")), Data("beside exe".utf8))
        try AppDataLifecycle(root: library).removeManaged(restored, keepData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("SavedData/wine-apps/Game").path))
    }
}
