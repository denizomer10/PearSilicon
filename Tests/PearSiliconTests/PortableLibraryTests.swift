import Foundation
import XCTest
@testable import PearSilicon

final class PortableLibraryTests: XCTestCase {

    func testScanReadsNewFoldersLegacyApplicationsAndDeduplicates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeIOSBundle(at: fixture.root.appendingPathComponent("ios-apps/New.app"), id: "com.example.new")
        try fixture.writeIOSBundle(at: fixture.root.appendingPathComponent("Applications/Legacy.app"), id: "com.example.legacy")
        // The same identifier in the new folder must win over the legacy copy.
        try fixture.writeIOSBundle(at: fixture.root.appendingPathComponent("Applications/New.app"), id: "com.example.new")
        try fixture.writeManifest(
            platform: .macOS, id: "com.example.mac",
            at: fixture.root.appendingPathComponent("mac-apps/com.example.mac")
        )
        try fixture.writeManifest(
            platform: .wine, id: "example-game",
            at: fixture.root.appendingPathComponent("wine-apps/example-game")
        )
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("wine-apps/broken"),
            withIntermediateDirectories: true
        )

        let snapshot = PortableLibrary(rootURL: fixture.root).scan()

        XCTAssertEqual(snapshot.iosApps.map(\.id).sorted(), ["com.example.legacy", "com.example.new"])
        XCTAssertEqual(snapshot.macEntries.map(\.manifest.id), ["com.example.mac"])
        XCTAssertEqual(snapshot.wineEntries.map(\.manifest.id), ["example-game"])
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].contains("broken"))
    }

    func testScanDoesNotCreatePlatformFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = PortableLibrary(rootURL: fixture.root).scan()
        for folder in ["ios-apps", "mac-apps", "wine-apps"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(folder).path))
        }
    }

    func testClassifiesMacAndIOSBundles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mac = fixture.root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let macInfo: [String: Any] = [
            "CFBundleIdentifier": "com.example.mac", "CFBundleExecutable": "Example",
            "DTPlatformName": "macosx", "CFBundleSupportedPlatforms": ["MacOSX"],
        ]
        try PropertyListSerialization.data(fromPropertyList: macInfo, format: .xml, options: 0)
            .write(to: mac.appendingPathComponent("Contents/Info.plist"))

        let ios = fixture.root.appendingPathComponent("ExampleIOS.app")
        try fixture.writeIOSBundle(at: ios, id: "com.example.ios")

        XCTAssertEqual(try PortableLibrary.classify(mac), .macOS)
        XCTAssertEqual(try PortableLibrary.classify(ios), .iOS)
    }

    func testIOSSnapshotIncludesBundleSavesKeychainODRAndKeymap() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundle = fixture.root.appendingPathComponent("ios-apps/Game.app")
        try fixture.writeIOSBundle(at: bundle, id: "com.example.game")
        try fixture.write("save", to: fixture.root.appendingPathComponent("Games/com.example.game/Documents/save.dat"))
        try fixture.write("token", to: fixture.root.appendingPathComponent("Keychain/com.example.game/items.plist"))
        try fixture.write("odr", to: fixture.root.appendingPathComponent("ODR/com.example.game/pack.bin"))
        try fixture.write("{}", to: fixture.root.appendingPathComponent("Keymaps/com.example.game.json"))

        let library = PortableLibrary(rootURL: fixture.root)
        let app = try XCTUnwrap(library.scan().iosApps.first)
        let work = fixture.root.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let snapshot = try library.makeIOSSnapshot(for: app, in: work)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Payload/Game.app/Info.plist").path))
        XCTAssertEqual(
            try String(contentsOf: snapshot.appendingPathComponent("Data/Documents/save.dat")),
            "save"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Keychain/items.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("ODR/pack.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Keymap.json").path))
        let manifest = try JSONDecoder().decode(
            LibraryManifest.self,
            from: Data(contentsOf: snapshot.appendingPathComponent(LibraryManifest.filename))
        )
        XCTAssertEqual(manifest.platform, .iOS)
        XCTAssertEqual(manifest.id, "com.example.game")
    }

    func testRestoredIOSEntryReturnsToFlatLibraryAndDataFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let entryDirectory = fixture.root.appendingPathComponent("ios-apps/com.example.restored")
        let payload = entryDirectory.appendingPathComponent("Payload/Game.app")
        try fixture.writeIOSBundle(at: payload, id: "com.example.restored")
        try fixture.write("save", to: entryDirectory.appendingPathComponent("Data/Documents/save.dat"))
        try fixture.write("key", to: entryDirectory.appendingPathComponent("Keychain/items.plist"))
        let manifest = LibraryManifest(
            id: "com.example.restored", platform: .iOS, displayName: "Restored",
            version: "1.0", payloadPath: "Payload/Game.app"
        )
        try JSONEncoder().encode(manifest).write(
            to: entryDirectory.appendingPathComponent(LibraryManifest.filename)
        )
        let entry = LibraryEntry(manifest: manifest, directoryURL: entryDirectory)

        let library = PortableLibrary(rootURL: fixture.root)
        let app = try library.installRestoredIOSEntry(
            entry, replacing: false,
            rollbackRoot: fixture.root.appendingPathComponent("Work/RestoreRollback")
        )

        XCTAssertEqual(app.id, "com.example.restored")
        XCTAssertEqual(app.bundleURL.lastPathComponent, "com.example.restored.app")
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("Games/com.example.restored/Documents/save.dat")),
            "save"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Keychain/com.example.restored/items.plist").path
        ))
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: try Self.realPath(FileManager.default.temporaryDirectory))
                .appendingPathComponent("pear-portable-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func writeIOSBundle(at url: URL, id: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": id,
                "CFBundleExecutable": "App",
                "CFBundleName": id,
                "CFBundleDisplayName": id,
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

        func writeManifest(platform: LibraryPlatform, id: String, at directory: URL) throws {
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
