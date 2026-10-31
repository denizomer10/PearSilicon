import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class PortableLibraryAppStateTests: XCTestCase {

    func testStateScansAllPlatformsWithoutCreatingEmptyFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeIOSBundle(at: fixture.root.appendingPathComponent("ios-apps/Game.app"), id: "com.example.ios")
        try fixture.writeManifest(.macOS, id: "com.example.mac", at: fixture.root.appendingPathComponent("mac-apps/com.example.mac"))
        try fixture.writeManifest(.wine, id: "example-game", at: fixture.root.appendingPathComponent("wine-apps/example-game"))

        let state = fixture.state()
        try await state.refreshLibrary()

        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.ios"])
        XCTAssertEqual(state.managedEntries.map(\.manifest.id).sorted(), ["com.example.mac", "example-game"])
        XCTAssertTrue(state.platformEntries.isEmpty)
        state.platform = .macOS
        XCTAssertEqual(state.platformEntries.map(\.manifest.id), ["com.example.mac"])
        state.platform = .wine
        XCTAssertEqual(state.platformEntries.map(\.manifest.id), ["example-game"])
    }

    func testIOSBackupAndRestoreRoundTripBundleAndSaves() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeIOSBundle(at: fixture.root.appendingPathComponent("ios-apps/Game.app"), id: "com.example.game")
        try fixture.write("save", to: fixture.root.appendingPathComponent("Games/com.example.game/Documents/save.dat"))
        try fixture.write("key", to: fixture.root.appendingPathComponent("Keychain/com.example.game/items.plist"))

        let state = fixture.state()
        try await state.refreshLibrary()
        let app = try XCTUnwrap(state.installedApps.first)
        let backup = fixture.root.appendingPathComponent("Game.pearbackup")

        await state.backup(app, to: backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), state.statusMessage)
        XCTAssertFalse(state.statusMessage.lowercased().contains("error"), state.statusMessage)

        try FileManager.default.removeItem(at: app.bundleURL)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Games/com.example.game"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Keychain/com.example.game"))
        try await state.refreshLibrary()
        XCTAssertTrue(state.installedApps.isEmpty)

        await state.restoreBackup(from: backup, replacing: false)
        XCTAssertFalse(state.statusMessage.lowercased().contains("error"), state.statusMessage)
        XCTAssertEqual(state.installedApps.map(\.id), ["com.example.game"], state.statusMessage)
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("Games/com.example.game/Documents/save.dat")),
            "save"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Keychain/com.example.game/items.plist").path
        ))
        XCTAssertTrue(state.installedApps.first.map { FileManager.default.fileExists(atPath: $0.bundleURL.path) } ?? false)
    }

    func testManagedBackupAndRestoreKeepsEntryData() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("mac-apps/com.example.mac")
        let payload = directory.appendingPathComponent("Payload/Example.app")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try fixture.write("binary", to: payload.appendingPathComponent("Contents/MacOS/Example"))
        try fixture.write("settings", to: directory.appendingPathComponent("Data/Library/settings.plist"))
        let manifest = LibraryManifest(
            id: "com.example.mac", platform: .macOS, displayName: "Example Mac",
            version: "1.0", payloadPath: "Payload/Example.app"
        )
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(LibraryManifest.filename))

        let state = fixture.state()
        try await state.refreshLibrary()
        let entry = try XCTUnwrap(state.managedEntries.first)
        let backup = fixture.root.appendingPathComponent("Mac.pearbackup")
        await state.backup(entry, to: backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), state.statusMessage)

        try FileManager.default.removeItem(at: directory)
        try await state.refreshLibrary()
        XCTAssertTrue(state.managedEntries.isEmpty)

        await state.restoreBackup(from: backup, replacing: false)
        XCTAssertFalse(state.statusMessage.lowercased().contains("error"), state.statusMessage)
        XCTAssertEqual(state.managedEntries.map(\.manifest.id), ["com.example.mac"])
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("mac-apps/com.example.mac/Data/Library/settings.plist")),
            "settings"
        )
    }

    func testRestoreRefusesToOverwriteWithoutReplace() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeIOSBundle(at: fixture.root.appendingPathComponent("ios-apps/Game.app"), id: "com.example.game")
        let state = fixture.state()
        try await state.refreshLibrary()
        let app = try XCTUnwrap(state.installedApps.first)
        let backup = fixture.root.appendingPathComponent("Game.pearbackup")
        await state.backup(app, to: backup)

        await state.restoreBackup(from: backup, replacing: false)
        XCTAssertTrue(state.statusMessage.lowercased().contains("error"), state.statusMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.bundleURL.path))

        await state.restoreBackup(from: backup, replacing: true)
        XCTAssertFalse(state.statusMessage.lowercased().contains("error"), state.statusMessage)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: try Self.realPath(FileManager.default.temporaryDirectory))
                .appendingPathComponent("pear-appstate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("ios-apps"), withIntermediateDirectories: true
            )
        }

        func state() -> AppState {
            AppState(
                storageRootURL: root,
                packageImports: PackageImportOperations(
                    installArchive: { _ in throw PearError.invalidPackage("not used") },
                    installBundle: { _ in throw PearError.invalidPackage("not used") }
                ),
                observesWorkspace: false
            )
        }

        func writeIOSBundle(at url: URL, id: String) throws {
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

        func writeManifest(_ platform: LibraryPlatform, id: String, at directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = LibraryManifest(
                id: id, platform: platform, displayName: id, version: "1.0",
                payloadPath: "Payload/\(id).app"
            )
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(LibraryManifest.filename))
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func realPath(_ url: URL) throws -> String {
            guard let pointer = realpath(url.path, nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { free(pointer) }
            return String(cString: pointer)
        }
    }
}
