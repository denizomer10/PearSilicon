import Foundation
import XCTest
@testable import PearSilicon

final class StorageLocationStoreTests: XCTestCase {

    func testDefaultRootAndMarkerAdoption() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(rootPath: nil)
        XCTAssertEqual(store.rootURL, StorageLocationStore.defaultSupportRoot)
        XCTAssertFalse(store.usesCustomRoot)
        // A custom folder is never adopted without the marker.
        let foreign = fixture.root.appendingPathComponent("Foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("somebody else's files".utf8).write(to: foreign.appendingPathComponent("data.bin"))
        let foreignStore = fixture.store(rootPath: foreign.path)
        XCTAssertThrowsError(try foreignStore.requireAvailableRoot()) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a PearSilicon folder"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("data.bin").path))
    }

    func testCustomRootRequiresMarkerAndMissingDiskErrorsWithoutFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("GamesDisk/PearSilicon")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StorageLocationStore.writeMarker(at: root)
        let store = fixture.store(rootPath: root.path)
        XCTAssertEqual(try store.requireAvailableRoot(), root.standardizedFileURL)
        XCTAssertTrue(store.usesCustomRoot)

        // An unmounted external disk must error, not silently use the Mac root.
        let missing = fixture.root.appendingPathComponent("Unmounted/PearSilicon")
        let missingStore = fixture.store(rootPath: missing.path)
        XCTAssertThrowsError(try missingStore.requireAvailableRoot()) { error in
            XCTAssertTrue(error.localizedDescription.contains("not available"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNotEqual(missingStore.rootURL, StorageLocationStore.defaultSupportRoot)
    }

    func testDestinationRootNamingAndCommitPreviousCopyLifecycle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("ExternalDisk")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(
            StorageLocationStore.destinationRoot(in: folder).path,
            folder.appendingPathComponent("PearSilicon").path
        )
        let named = folder.appendingPathComponent("PearSilicon")
        XCTAssertEqual(StorageLocationStore.destinationRoot(in: named).path, named.path)

        let store = fixture.store(rootPath: nil)
        let newRoot = named
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try StorageLocationStore.writeMarker(at: newRoot)
        let old = fixture.root.appendingPathComponent("Old/PearSilicon")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try StorageLocationStore.writeMarker(at: old)

        try store.commit(rootURL: newRoot, previousRootURL: old)
        XCTAssertEqual(store.rootURL.path, newRoot.standardizedFileURL.path)
        XCTAssertEqual(store.previousRootURL?.path, old.standardizedFileURL.path)

        // Refusing to remove an unrelated folder keeps it intact.
        let unmarked = fixture.root.appendingPathComponent("Unmarked")
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: true)
        fixture.set(previousRootPath: unmarked.path)
        XCTAssertThrowsError(try store.removePreviousCopy())
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.path))

        fixture.set(previousRootPath: old.path)
        try store.removePreviousCopy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertNil(store.previousRootURL)
    }

    func testCommitRefusesFolderWithoutMarker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(rootPath: nil)
        let foreign = fixture.root.appendingPathComponent("NotARoot")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.commit(rootURL: foreign, previousRootURL: nil))
        XCTAssertEqual(store.rootURL.path, StorageLocationStore.defaultSupportRoot.standardizedFileURL.path)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        private let defaults: UserDefaults
        private let suiteName: String

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("pear-storage-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suiteName = "pear-storage-test-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }

        func store(rootPath: String?) -> StorageLocationStore {
            if let rootPath { set(rootPath: rootPath) }
            return StorageLocationStore(
                defaults: defaults,
                leaseFileURL: root.appendingPathComponent("lease.lock")
            )
        }

        func set(rootPath: String? = nil, previousRootPath: String? = nil) {
            if let rootPath { defaults.set(rootPath, forKey: StorageLocationStore.rootPathKey) }
            if let previousRootPath { defaults.set(previousRootPath, forKey: StorageLocationStore.previousRootPathKey) }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}