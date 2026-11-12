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
        // The real Steam installer leaves its folder group-writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o775],
            ofItemAtPath: entry.prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam").path)
        // Persist the selected launch path like the app does, so the on-disk
        // manifest matches the entry that sanitizeWinePrefix re-reads.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry.manifest).write(to: entry.manifestURL, options: .atomic)
        return entry
    }
    private func engine(_ f: ManagedAppTestFixture, known: Bool = true) -> WineEngine {
        WineEngine(id: known ? "pearwine-1.0.1" : "custom", name: "Wine", version: "1", rootURL: f.enginesRoot,
                   executablePath: "Runtime/MetalSharp-Wine.app/Contents/MacOS/wine", distribution: known ? .metalSharp : .community)
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
        for _ in 0..<2 { XCTAssertEqual(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)), "C:\\PearSiliconSteam\\Steam.exe") }
        let alias = entry.prefixURL.appendingPathComponent("drive_c/PearSiliconSteam")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)
        XCTAssertEqual(target, "Program Files (x86)/Steam")
        // No drive letter: Steam must not record a drive root as its install folder.
        XCTAssertFalse(ManagedAppFiles.exists(entry.prefixURL.appendingPathComponent("dosdevices/s:")))
        XCTAssertEqual(try Data(contentsOf: exe), original)
        XCTAssertEqual(try Data(contentsOf: registry), registryBytes)
        XCTAssertEqual(entry.manifest.wineLaunchPath, selectedPath)
        XCTAssertNoThrow(try ManagedAppService.sanitizeWinePrefix(for: entry))
        let moved = f.root.appendingPathComponent("MovedEntry")
        try FileManager.default.copyItem(at: entry.directoryURL, to: moved)
        let movedAlias = moved.appendingPathComponent("Prefix/drive_c/PearSiliconSteam/Steam.exe")
        XCTAssertTrue(LibraryPath.isInside(movedAlias, root: moved))
        XCTAssertEqual(try Data(contentsOf: movedAlias), original)
    }
    func testOnlyMetalSharpReceivesTheWorkaround() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try installedSteam(f)
        let hq = WineEngine(id: "wine-staging-11.21", name: "WineHQ", version: "11.21", rootURL: f.enginesRoot,
                            executablePath: "Runtime/bin/wine", distribution: .wineHQ)
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: hq))
        XCTAssertFalse(ManagedAppFiles.exists(entry.prefixURL.appendingPathComponent("drive_c/PearSiliconSteam")))
        XCTAssertEqual(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)), "C:\\PearSiliconSteam\\Steam.exe")
    }
    func testUnknownEngineAndInstallerDoNotReceiveTheWorkaround() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        var entry = try installedSteam(f)
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f, known: false)))
        entry.manifest.wineLaunchPath = nil
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertFalse(ManagedAppFiles.exists(entry.prefixURL.appendingPathComponent("drive_c/PearSiliconSteam")))
    }
    func testSteamNameWithoutInstalledClientMarkersKeepsNormalPath() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try installedSteam(f)
        try FileManager.default.removeItem(at: entry.prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamclient64.dll"))
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertTrue(try ManagedAppService.prepareWineGameDrive(for: entry).hasPrefix("C:\\"))
    }
    func testConflictingAliasNameIsNotOverwrittenAndEscapingMarkerIsRejected() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try installedSteam(f)
        let link = entry.prefixURL.appendingPathComponent("drive_c/PearSiliconSteam")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "windows")
        XCTAssertThrowsError(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "windows")
        try FileManager.default.removeItem(at: link)
        // A real folder with that name is not replaced either.
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        XCTAssertThrowsError(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        try FileManager.default.removeItem(at: link)
        let marker = entry.prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamclient64.dll")
        try FileManager.default.removeItem(at: marker)
        let outside = f.root.appendingPathComponent("outside.dll")
        try ManagedAppTestFixture.pe().write(to: outside)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
        // A marker outside the client means the quirk does not apply: the
        // normal launch path is used and no alias is created.
        XCTAssertNil(try WineSteamCompatibility.prepareLaunchPath(for: entry, engine: engine(f)))
        XCTAssertFalse(ManagedAppFiles.exists(link))
    }
}
