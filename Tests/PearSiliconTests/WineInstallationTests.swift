import Foundation
import XCTest
@testable import PearSilicon

final class WineInstallationTests: XCTestCase {
    func testDetectsSteamSetupAndRenamedInstallerWithoutTreatingSteamAsSetup() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("download.exe")
        try (ManagedAppTestFixture.pe() + Data("Inno Setup Setup Data".utf8)).write(to: file)
        XCTAssertTrue(WineInstallation.isInstaller(source: file, name: "download.exe"))
        try ManagedAppTestFixture.pe().write(to: file)
        XCTAssertTrue(WineInstallation.isInstaller(source: file, name: "SteamSetup.exe"))
        XCTAssertFalse(WineInstallation.isInstaller(source: file, name: "steam.exe"))
        XCTAssertFalse(WineInstallation.isInstaller(source: file, name: "uninstall.exe"))
    }

    func testInstalledProgramDiscoveryAndCDriveLaunchArePortable() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("SteamSetup.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        var entry = try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: fixture.library, engineID: "wine")
        XCTAssertEqual(entry.manifest.wineInstaller, true)
        XCTAssertEqual(entry.manifest.wineEngineGraphics, true)
        entry.manifest.wineInstallBaseline = WineInstallation.installedExecutables(entry)
        for path in ["Program Files (x86)/Steam/steam.exe", "Program Files (x86)/Steam/uninstall.exe", "windows/system32/notepad.exe"] {
            let file = entry.prefixURL.appendingPathComponent("drive_c/" + path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ManagedAppTestFixture.pe().write(to: file)
        }
        let choices = WineInstallation.candidates(entry, changedOnly: true)
        XCTAssertEqual(choices.map(\.path), ["Prefix/drive_c/Program Files (x86)/Steam/steam.exe"])
        entry.manifest.wineLaunchPath = choices[0].path
        XCTAssertEqual(try WineInstallation.validatedLaunchURL(entry).lastPathComponent, "steam.exe")
        XCTAssertEqual(try ManagedAppService.prepareWineGameDrive(for: entry), "C:\\Program Files (x86)\\Steam\\steam.exe")
        entry.manifest.wineInstallBaseline = WineInstallation.installedExecutables(entry)
        XCTAssertTrue(WineInstallation.candidates(entry, changedOnly: true).isEmpty)
        XCTAssertEqual(WineInstallation.candidates(entry).count, 1)
        entry.manifest.wineLaunchPath = "Prefix/drive_c/../../escape.exe"
        XCTAssertThrowsError(try WineInstallation.validatedLaunchURL(entry))
    }

    func testRejectsPrefixLinkToHostAndDoesNotRecommendHelpers() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("setup.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        var entry = try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: fixture.library, engineID: "wine")
        let drive = entry.prefixURL.appendingPathComponent("drive_c")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("escape.exe"), withDestinationURL: source)
        entry.manifest.wineLaunchPath = "Prefix/drive_c/escape.exe"
        XCTAssertThrowsError(try WineInstallation.validatedLaunchURL(entry))
        XCTAssertTrue(WineInstallation.candidates(entry).isEmpty)
    }
}
