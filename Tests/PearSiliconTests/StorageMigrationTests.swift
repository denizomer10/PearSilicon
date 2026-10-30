import Foundation
import XCTest
@testable import PearSilicon

final class StorageMigrationTests: XCTestCase {

    func testMovesEveryKindOfDataAndKeepsThePreviousCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSourceRoot()
        try fixture.populate(source)

        let targetFolder = fixture.root.appendingPathComponent("ExternalDisk")
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let migration = StorageMigration(
            locations: fixture.store,
            relocateBundle: { _, _, _ in }
        )
        let result = try await migration.move(to: targetFolder)

        XCTAssertEqual(result.rootURL.path, targetFolder.appendingPathComponent("PearSilicon").standardizedFileURL.path)
        XCTAssertEqual(result.previousRootURL?.path, source.standardizedFileURL.path)
        XCTAssertEqual(fixture.store.rootURL.path, result.rootURL.path)
        XCTAssertEqual(fixture.store.previousRootURL?.path, source.standardizedFileURL.path)

        // Everything moved together: app, game data, keymap, ODR, keychain, log,
        // work files and unknown future entries.
        for relative in fixture.expectedFiles {
            let moved = result.rootURL.appendingPathComponent(relative)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: moved.path),
                "missing after move: \(relative)"
            )
        }
        XCTAssertTrue(StorageLocationStore.hasMarker(at: result.rootURL))
        // The source is untouched and serves as the rollback copy.
        for relative in fixture.expectedFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent(relative).path))
        }

        try await migration.removePreviousCopy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNil(fixture.store.previousRootURL)
    }

    func testOccupiedOrNestedTargetsAreRejectedWithoutTouchingData() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSourceRoot()
        try fixture.populate(source)
        let before = try fixture.inventory(of: source)

        let occupied = fixture.root.appendingPathComponent("Occupied/PearSilicon")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: occupied.appendingPathComponent("foreign.bin"))
        let migration = StorageMigration(locations: fixture.store, relocateBundle: { _, _, _ in })

        do {
            _ = try await migration.move(to: occupied.deletingLastPathComponent())
            XCTFail("An occupied target must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already contains data"))
        }
        do {
            _ = try await migration.move(to: source.appendingPathComponent("Nested"))
            XCTFail("A nested target must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("inside the current storage"))
        }
        XCTAssertEqual(try fixture.inventory(of: source), before)
        XCTAssertEqual(fixture.store.rootURL, source.standardizedFileURL)
        XCTAssertNil(fixture.store.previousRootURL)
    }

    func testRelocationFailureRollsBackAndLeavesSourceAsActiveRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSourceRoot()
        try fixture.populate(source)
        let before = try fixture.inventory(of: source)

        struct RelocationFailed: Error {}
        let migration = StorageMigration(locations: fixture.store) { _, _, _ in throw RelocationFailed() }
        let targetFolder = fixture.root.appendingPathComponent("BrokenDisk")
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        do {
            _ = try await migration.move(to: targetFolder)
            XCTFail("A failed relocation must not commit a new root")
        } catch {
            XCTAssertTrue(error is RelocationFailed)
        }
        XCTAssertEqual(try fixture.inventory(of: source), before)
        XCTAssertEqual(fixture.store.rootURL.path, source.standardizedFileURL.path)
        XCTAssertNil(fixture.store.previousRootURL)
        let contents = try FileManager.default.contentsOfDirectory(atPath: targetFolder.path)
        XCTAssertTrue(contents.isEmpty, "no staging may remain: \(contents)")
    }

    func testUnavailableDestinationErrorsInsteadOfFallingBack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSourceRoot()
        try fixture.populate(source)
        let migration = StorageMigration(locations: fixture.store, relocateBundle: { _, _, _ in })
        let missing = fixture.root.appendingPathComponent("UnmountedDisk/PearSilicon")
        do {
            _ = try await migration.move(to: missing.deletingLastPathComponent())
            XCTFail("An unavailable volume must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not available"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(fixture.store.rootURL.path, source.standardizedFileURL.path)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let store: StorageLocationStore
        private let defaults: UserDefaults
        private let suiteName: String
        let expectedFiles = [
            "Applications/com.example.game.app/Info.plist",
            "Games/com.example.game/Documents/save.dat",
            "Games/com.example.game/Library/Cloud/key-values.plist",
            "Games/com.example.game/Library/Caches/blob.bin",
            "Keymaps/com.example.game.json",
            "ODR/com.example.game/pack0.bundle",
            "Keychain/com.example.game/items.plist",
            "Logs/com.example.game.log",
            "Work/scratch.tmp",
            "future-entry/unknown.bin",
        ]

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("pear-storage-move-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suiteName = "pear-storage-move-test-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            store = StorageLocationStore(
                defaults: defaults, leaseFileURL: root.appendingPathComponent("lease.lock")
            )
        }

        func makeSourceRoot() throws -> URL {
            let source = root.appendingPathComponent("Internal/PearSilicon")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try StorageLocationStore.writeMarker(at: source)
            defaults.set(source.path, forKey: StorageLocationStore.rootPathKey)
            return source
        }

        func populate(_ source: URL) throws {
            for relative in expectedFiles {
                let url = source.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data("payload \(relative)".utf8).write(to: url)
            }
        }

        func inventory(of root: URL) throws -> [String: Int64] {
            var result: [String: Int64] = [:]
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            )
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.fileSizeKey])
                result[String(item.path.dropFirst(root.path.count + 1))] = Int64(values.fileSize ?? 0)
            }
            return result
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}