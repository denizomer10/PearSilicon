import Foundation
import XCTest
@testable import PearSilicon

/// The top-bar location picker: Internal Storage is always offered; a marked
/// library on a connected disk adds a second option that disappears when the
/// disk is ejected. Ejecting falls back to Internal Storage without deleting
/// anything, and reconnecting brings the option back.
@MainActor
final class StorageLocationSwitchTests: XCTestCase {

    func testExternalLocationsUseDiskNameAndSkipSystemAndInternalRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let systemVolume = fixture.root.appendingPathComponent("System")
        let systemRoot = systemVolume.appendingPathComponent("PearSilicon")
        try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)
        try StorageLocationStore.writeMarker(at: systemRoot)

        let twoLibraries = fixture.root.appendingPathComponent("Two")
        for name in ["PearSilicon", "Backup"] {
            let root = twoLibraries.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try StorageLocationStore.writeMarker(at: root)
        }

        let options = StorageLocationStore.externalLocations(
            on: [systemVolume, fixture.diskVolume, twoLibraries, fixture.internalRoot],
            internalRoot: fixture.internalRoot,
            isSystemVolume: { $0 == systemVolume }
        )
        XCTAssertEqual(options.map(\.name), ["GameDisk", "Two — Backup", "Two — PearSilicon"])
        XCTAssertTrue(options.allSatisfy { $0.kind == .external })
        XCTAssertFalse(options.contains { $0.rootURL == fixture.internalRoot.standardizedFileURL })
    }

    func testPickerShowsInternalFirstAndDiskOnlyWhileConnected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let connected = StorageLocationStore.locationOptions(
            internalRoot: fixture.internalRoot,
            selectedRoot: fixture.internalRoot,
            external: fixture.external()
        )
        XCTAssertEqual(connected.map(\.name), ["Internal Storage", "GameDisk"])
        XCTAssertEqual(connected.first?.kind, .internal)

        try fixture.eject()
        let ejected = StorageLocationStore.locationOptions(
            internalRoot: fixture.internalRoot,
            selectedRoot: fixture.internalRoot,
            external: fixture.external()
        )
        XCTAssertEqual(ejected.map(\.name), ["Internal Storage"])
    }

    func testSelectKeepsRollbackCopyAndRefusesUnmarkedFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let previous = fixture.root.appendingPathComponent("Old/PearSilicon")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try StorageLocationStore.writeMarker(at: previous)
        try store.commit(rootURL: fixture.diskRoot, previousRootURL: previous)

        try store.select(rootURL: fixture.internalRoot)
        XCTAssertEqual(store.rootURL, fixture.internalRoot.standardizedFileURL)
        XCTAssertFalse(store.usesCustomRoot)
        XCTAssertTrue(StorageLocationStore.hasMarker(at: fixture.internalRoot))
        XCTAssertEqual(store.previousRootURL, previous.standardizedFileURL)

        try store.select(rootURL: fixture.diskRoot)
        XCTAssertEqual(store.rootURL, fixture.diskRoot.standardizedFileURL)
        XCTAssertEqual(store.previousRootURL, previous.standardizedFileURL)

        let foreign = fixture.root.appendingPathComponent("Foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.select(rootURL: foreign))
        XCTAssertEqual(store.rootURL, fixture.diskRoot.standardizedFileURL)
    }

    func testEjectFallsBackToInternalAndReconnectRestoresOption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeIOSBundle(in: fixture.internalRoot, id: "com.example.internal")
        try fixture.writeIOSBundle(in: fixture.diskRoot, id: "com.example.disk")
        let store = fixture.store()
        try store.select(rootURL: fixture.diskRoot)
        let state = fixture.state(store: store)

        // Disk connected and selected: two options, the disk's games.
        await state.applyStorageSnapshot(externalLocations: fixture.external())
        XCTAssertEqual(state.storageLocations.map(\.name), ["Internal Storage", "GameDisk"])
        XCTAssertEqual(state.storageRootURL.standardizedFileURL, fixture.diskRoot.standardizedFileURL)
        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.disk"])
        XCTAssertTrue(state.storageConnected)

        // Ejected: the option goes away and the internal library is shown.
        try fixture.eject()
        await state.applyStorageSnapshot(externalLocations: fixture.external())
        XCTAssertEqual(state.storageLocations.map(\.name), ["Internal Storage"])
        XCTAssertEqual(state.storageRootURL.standardizedFileURL, fixture.internalRoot.standardizedFileURL)
        XCTAssertEqual(store.rootURL, fixture.internalRoot.standardizedFileURL)
        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.internal"])
        XCTAssertTrue(state.storageConnected)
        XCTAssertTrue(state.statusMessage.contains("GameDisk was disconnected"), state.statusMessage)
        // Nothing on the disk was deleted.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.ejectedRoot.appendingPathComponent("ios-apps/com.example.disk.app/Info.plist").path
        ))

        // Reconnected: the option returns; Internal Storage stays selected.
        try fixture.reconnect()
        await state.applyStorageSnapshot(externalLocations: fixture.external())
        XCTAssertEqual(state.storageLocations.map(\.name), ["Internal Storage", "GameDisk"])
        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.internal"])

        // Picking the disk shows its games again.
        let disk = try XCTUnwrap(state.storageLocations.last)
        await state.selectStorageLocation(disk)
        XCTAssertEqual(state.storageRootURL.standardizedFileURL, fixture.diskRoot.standardizedFileURL)
        XCTAssertEqual(store.rootURL, fixture.diskRoot.standardizedFileURL)
        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.disk"])

        // And back to Internal Storage.
        let internalOption = try XCTUnwrap(state.storageLocations.first)
        await state.selectStorageLocation(internalOption)
        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.internal"])
        XCTAssertEqual(state.storageLocations.count, 2)
    }

    func testSelectingAnEjectedDiskFailsSafelyAndDropsTheOption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeIOSBundle(in: fixture.internalRoot, id: "com.example.internal")
        let store = fixture.store()
        let state = fixture.state(store: store)
        await state.applyStorageSnapshot(externalLocations: fixture.external())
        let disk = try XCTUnwrap(state.storageLocations.last)
        XCTAssertEqual(disk.kind, .external)

        try fixture.eject() // gone before the mount notification arrived
        await state.selectStorageLocation(disk)
        XCTAssertEqual(state.storageRootURL.standardizedFileURL, fixture.internalRoot.standardizedFileURL)
        XCTAssertEqual(state.storageLocations.map(\.name), ["Internal Storage"])
        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.internal"])
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let root: URL
        let internalRoot: URL
        let diskVolume: URL
        let diskRoot: URL
        let ejectedRoot: URL
        private let defaults: UserDefaults
        private let suiteName: String

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("pear-storage-switch-\(UUID().uuidString)", isDirectory: true)
            internalRoot = root.appendingPathComponent("Internal/PearSilicon", isDirectory: true)
            diskVolume = root.appendingPathComponent("GameDisk", isDirectory: true)
            diskRoot = diskVolume.appendingPathComponent("PearSilicon", isDirectory: true)
            ejectedRoot = root.appendingPathComponent("Ejected/PearSilicon", isDirectory: true)
            try FileManager.default.createDirectory(at: internalRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: diskRoot, withIntermediateDirectories: true)
            try StorageLocationStore.writeMarker(at: diskRoot)
            suiteName = "pear-storage-switch-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }

        func store() -> StorageLocationStore {
            StorageLocationStore(
                defaults: defaults,
                leaseFileURL: root.appendingPathComponent("lease.lock"),
                internalRootURL: internalRoot
            )
        }

        func state(store: StorageLocationStore) -> AppState {
            AppState(
                storageStore: store,
                packageImports: PackageImportOperations(
                    installArchive: { _ in throw PearError.invalidPackage("not used") },
                    installBundle: { _ in throw PearError.invalidPackage("not used") }
                ),
                observesWorkspace: false
            )
        }

        /// What mount discovery reports right now (the disk is the only volume).
        func external() -> [StorageLocationOption] {
            StorageLocationStore.externalLocations(
                on: FileManager.default.fileExists(atPath: diskVolume.path) ? [diskVolume] : [],
                internalRoot: internalRoot,
                isSystemVolume: { _ in false }
            )
        }

        /// Simulates an unmount: the library leaves its path (a copy keeps the
        /// disk's contents so the test can check nothing was deleted). Copying
        /// rather than moving keeps the bookmark from following the folder.
        func eject() throws {
            try FileManager.default.createDirectory(
                at: ejectedRoot.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: diskRoot, to: ejectedRoot)
            try FileManager.default.removeItem(at: diskVolume)
        }

        func reconnect() throws {
            try FileManager.default.createDirectory(at: diskVolume, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: ejectedRoot, to: diskRoot)
            try FileManager.default.removeItem(at: ejectedRoot)
        }

        func writeIOSBundle(in library: URL, id: String) throws {
            let url = library.appendingPathComponent("ios-apps/\(id).app", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": id,
                "CFBundleExecutable": "App",
                "CFBundleName": id,
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "MinimumOSVersion": "15.0",
                "LSRequiresIPhoneOS": true,
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Info.plist"))
            try Data("binary".utf8).write(to: url.appendingPathComponent("App"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
