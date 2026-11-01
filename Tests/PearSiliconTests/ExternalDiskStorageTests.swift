import Foundation
import XCTest
@testable import PearSilicon

/// Opt-in integration test for a real external volume. It never touches the
/// user's library: the source root and UserDefaults suite are private fixtures,
/// and the destination is a uniquely named folder that is removed afterwards.
///
/// Run with:
///   PEAR_EXTERNAL_TEST_DIR=/Volumes/Untitled swift test --filter ExternalDiskStorageTests
final class ExternalDiskStorageTests: XCTestCase {

    func testMoveToARealExternalAPFSVolume() async throws {
        guard let external = ProcessInfo.processInfo.environment["PEAR_EXTERNAL_TEST_DIR"],
              !external.isEmpty else {
            throw XCTSkip("Set PEAR_EXTERNAL_TEST_DIR to opt in to the external-volume test")
        }
        let externalURL = URL(fileURLWithPath: external, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: externalURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("External test directory is not available: \(external)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-external-\(UUID().uuidString)", isDirectory: true)
        let suite = "pear-external-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = StorageLocationStore(
            defaults: defaults, leaseFileURL: root.appendingPathComponent("lease.lock")
        )
        let destination = externalURL.appendingPathComponent("PearSiliconSmoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
            defaults.removePersistentDomain(forName: suite)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Internal/PearSilicon", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try StorageLocationStore.writeMarker(at: source)
        defaults.set(source.path, forKey: StorageLocationStore.rootPathKey)

        let files = [
            "ios-apps/Game.app/Info.plist",
            "Games/com.example.game/Documents/save.dat",
            "Keychain/com.example.game/items.plist",
            "Keymaps/com.example.game.json",
            "ODR/com.example.game/pack.bin",
            "mac-apps/com.example.mac/pear-app.json",
            "wine-apps/com.example.wine/pear-app.json",
        ]
        for relative in files {
            let url = source.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("payload \(relative)".utf8).write(to: url)
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let migration = StorageMigration(locations: store, relocateBundle: { _, _, _ in })
        let result = try await migration.move(to: destination)

        XCTAssertEqual(result.rootURL.path, destination.appendingPathComponent("PearSilicon").path)
        XCTAssertEqual(store.rootURL.path, result.rootURL.path)
        XCTAssertTrue(StorageLocationStore.hasMarker(at: result.rootURL))
        for relative in files {
            let moved = result.rootURL.appendingPathComponent(relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "missing on external disk: \(relative)")
        }
        XCTAssertEqual(
            try String(contentsOf: result.rootURL.appendingPathComponent("Games/com.example.game/Documents/save.dat")),
            "payload Games/com.example.game/Documents/save.dat"
        )
        // The source remains as the rollback copy.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("ios-apps/Game.app/Info.plist").path
        ))
    }
}
