import Foundation
import XCTest
@testable import PearSilicon

final class WineSteamCompatibilityTests: XCTestCase {
    private func installedSteam(_ f: ManagedAppTestFixture) throws -> LibraryEntry {
        let source = f.root.appendingPathComponent("SteamSetup.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        var entry = try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: f.library, engineID: "pearwine-1.0.1")
        entry.manifest.wineLaunchPath = "Prefix/drive_c/Program Files (x86)/Steam/Steam.exe"
        for path in ["Steam.exe", "steamclient64.dll", "bin/cef/cef.win64/steamwebhelper.exe"] {
            let file = entry.prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/" + path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ManagedAppTestFixture.pe().write(to: file)
        }
        // Persist the selected launch path like the app does, so the on-disk
        // manifest matches the entry that sanitizeWinePrefix re-reads.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry.manifest).write(to: entry.manifestURL, options: .atomic)
        return entry
    }
    private func engine(_ f: ManagedAppTestFixture, known: Bool = true) -> WineEngine {
        WineEngine(id: known ? "pearwine-1.0.1" : "custom", name: "Wine", version: "1", rootURL: f.enginesRoot,
                   executablePath: "Runtime/MetalSharp-Wine.app/Contents/MacOS/wine", distribution: known ? .pearWine : .community)
    }
    func testAliasIsIdempotentPortableAndLeavesClientAndRegistryUntouched() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try installedSteam(f)
        let exe = try WineInstallation.validatedLaunchURL(entry)
        let original = try Data(contentsOf: exe)
        let registry = entry.prefixURL.appendingPathComponent("user.reg")
        let registryBytes = Data("Existing client paths and settings".utf8)
        try registryBytes.write(to: registry)
        let selectedPath = entry.manifest.wineLaunchPath
        for _ in 0..<2 { XCTAssertEqual(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)), "S:\\Steam.exe") }
        let alias = entry.prefixURL.appendingPathComponent("dosdevices/s:")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)
        XCTAssertEqual(target, "../drive_c/Program Files (x86)/Steam")
        XCTAssertEqual(try Data(contentsOf: exe), original)
        XCTAssertEqual(try Data(contentsOf: registry), registryBytes)
        XCTAssertEqual(entry.manifest.wineLaunchPath, selectedPath)
        XCTAssertNoThrow(try ManagedAppService.sanitizeWinePrefix(for: entry))
        let moved = f.root.appendingPathComponent("MovedEntry")
        try FileManager.default.copyItem(at: entry.directoryURL, to: moved)
        let movedAlias = moved.appendingPathComponent("Prefix/dosdevices/s:/Steam.exe")
        XCTAssertTrue(LibraryPath.isInside(movedAlias, root: moved))
        XCTAssertEqual(try Data(contentsOf: movedAlias), original)
    }
    func testUnknownEngineAndInstallerDoNotReceiveTheWorkaround() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        var entry = try installedSteam(f)
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f, known: false)))
        entry.manifest.wineLaunchPath = nil
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertFalse(ManagedAppFiles.exists(entry.prefixURL.appendingPathComponent("dosdevices/s:")))
    }
    func testSteamNameWithoutInstalledClientMarkersKeepsNormalPath() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try installedSteam(f)
        try FileManager.default.removeItem(at: entry.prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamclient64.dll"))
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertTrue(try ManagedAppService.prepareWineGameDrive(for: entry).hasPrefix("C:\\"))
    }
    func testConflictingDriveIsNotOverwrittenAndEscapingMarkerIsRejected() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try installedSteam(f)
        let devices = entry.prefixURL.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let link = devices.appendingPathComponent("s:")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../drive_c")
        XCTAssertThrowsError(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../drive_c")
        try FileManager.default.removeItem(at: link)
        let marker = entry.prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamclient64.dll")
        try FileManager.default.removeItem(at: marker)
        let outside = f.root.appendingPathComponent("outside.dll")
        try ManagedAppTestFixture.pe().write(to: outside)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
        XCTAssertThrowsError(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertFalse(ManagedAppFiles.exists(link))
    }
}
