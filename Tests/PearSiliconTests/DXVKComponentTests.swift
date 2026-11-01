import Foundation
import XCTest
@testable import PearSilicon

/// The pinned DXVK component and the per-prefix mirroring are pure file
/// operations; these tests never download anything and never run Wine.
final class DXVKComponentTests: XCTestCase {

    func testPinnedDXVKComponentIsTheTestedMacOSBuild() async throws {
        let service = GraphicsComponentService()
        let asset = try await service.latestDXVK()
        XCTAssertEqual(asset.tag, GraphicsComponentService.dxvkVersion)
        XCTAssertEqual(asset.name, GraphicsComponentService.dxvkAssetName)
        XCTAssertEqual(asset.sha256, GraphicsComponentService.dxvkArchiveSHA256)
        XCTAssertEqual(
            asset.url.absoluteString,
            "https://github.com/Gcenx/DXVK-macOS/releases/download/\(GraphicsComponentService.dxvkVersion)/"
                + GraphicsComponentService.dxvkAssetName
        )
        for hash in [
            GraphicsComponentService.dxvkArchiveSHA256,
            GraphicsComponentService.dxvkD3D11SHA256,
            GraphicsComponentService.dxvkD3D10CoreSHA256
        ] {
            XCTAssertEqual(hash.count, 64)
            XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
        }
    }

    func testDXVKIsMirroredIntoThePrefixAndRestoredWhenTheBackendChanges() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let engine = try WineEngineStore(rootURL: fixture.enginesRoot).registerLocalEngine(
            from: fixture.engineFolder(), id: "engine", name: "Engine", version: "1",
            executablePath: "bin/wine64", licenseConfirmed: true
        )
        let entry = try ManagedAppService().importWindowsFolder(
            from: fixture.windowsFolder(), executablePath: "bin/Game.exe",
            libraryRoot: fixture.library, engineID: engine.id
        )
        let (system32, originals) = try makePrefixFixtures(for: entry)
        let dxvk = try installComponentFixture(in: engine.rootURL)
        XCTAssertTrue(GraphicsComponentService.isDXVKInstalled(in: engine.rootURL))

        try ManagedAppService.synchronizeDXVK(for: entry, engine: engine)
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("d3d11.dll")), dxvk["d3d11.dll"])
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("d3d10core.dll")), dxvk["d3d10core.dll"])
        let backup = entry.prefixURL.appendingPathComponent(ManagedAppService.dxvkBackupDirectory, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("d3d11.dll")), originals["d3d11.dll"])
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("d3d10core.dll")), originals["d3d10core.dll"])
        XCTAssertTrue(ManagedAppFiles.exists(
            entry.prefixURL.appendingPathComponent(ManagedAppService.dxvkMarkerFilename)
        ))
        XCTAssertEqual(
            ManagedAppService.environment(for: entry, engine: engine)["WINEDLLOVERRIDES"],
            "d3d11,d3d10core=n;winemenubuilder.exe=d"
        )

        var other = entry
        other.manifest.graphicsBackend = .dxmt
        try ManagedAppService.synchronizeDXVK(for: other, engine: engine)
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("d3d11.dll")), originals["d3d11.dll"])
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("d3d10core.dll")), originals["d3d10core.dll"])
        XCTAssertFalse(ManagedAppFiles.exists(
            entry.prefixURL.appendingPathComponent(ManagedAppService.dxvkMarkerFilename)
        ))
        XCTAssertEqual(
            ManagedAppService.environment(for: other, engine: engine)["WINEDLLOVERRIDES"],
            "d3d11,dxgi,d3d10core,winemetal=n,b;winemenubuilder.exe=d"
        )
    }

    func testRestoreLeavesAFileThatNoLongerMatchesTheMarker() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let engine = try WineEngineStore(rootURL: fixture.enginesRoot).registerLocalEngine(
            from: fixture.engineFolder(), id: "engine", name: "Engine", version: "1",
            executablePath: "bin/wine64", licenseConfirmed: true
        )
        let entry = try ManagedAppService().importWindowsFolder(
            from: fixture.windowsFolder(), executablePath: "bin/Game.exe",
            libraryRoot: fixture.library, engineID: engine.id
        )
        let (system32, _) = try makePrefixFixtures(for: entry)
        _ = try installComponentFixture(in: engine.rootURL)
        try ManagedAppService.synchronizeDXVK(for: entry, engine: engine)

        let foreign = Data("replaced by the game or Wine".utf8)
        try foreign.write(to: system32.appendingPathComponent("d3d11.dll"))
        var other = entry
        other.manifest.graphicsBackend = .dxmt
        try ManagedAppService.synchronizeDXVK(for: other, engine: engine)
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("d3d11.dll")), foreign)
        XCTAssertEqual(
            try Data(contentsOf: system32.appendingPathComponent("d3d10core.dll")),
            Data("wine builtin d3d10core".utf8)
        )
        XCTAssertFalse(ManagedAppFiles.exists(
            entry.prefixURL.appendingPathComponent(ManagedAppService.dxvkMarkerFilename)
        ))
    }

    func testPrefixIsNotTouchedWhenNoComponentIsInstalled() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let engine = try WineEngineStore(rootURL: fixture.enginesRoot).registerLocalEngine(
            from: fixture.engineFolder(), id: "engine", name: "Engine", version: "1",
            executablePath: "bin/wine64", licenseConfirmed: true
        )
        let entry = try ManagedAppService().importWindowsFolder(
            from: fixture.windowsFolder(), executablePath: "bin/Game.exe",
            libraryRoot: fixture.library, engineID: engine.id
        )
        let (system32, originals) = try makePrefixFixtures(for: entry)
        try ManagedAppService.synchronizeDXVK(for: entry, engine: engine)
        XCTAssertEqual(try Data(contentsOf: system32.appendingPathComponent("d3d11.dll")), originals["d3d11.dll"])
        XCTAssertFalse(ManagedAppFiles.exists(
            entry.prefixURL.appendingPathComponent(ManagedAppService.dxvkMarkerFilename)
        ))
        XCTAssertEqual(
            ManagedAppService.environment(for: entry, engine: engine)["WINEDLLOVERRIDES"],
            "winemenubuilder.exe=d"
        )
    }

    // MARK: - Fixtures

    private func makePrefixFixtures(for entry: LibraryEntry) throws -> (URL, [String: Data]) {
        let system32 = entry.prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        let originals = [
            "d3d11.dll": Data("wine builtin d3d11".utf8),
            "d3d10core.dll": Data("wine builtin d3d10core".utf8),
        ]
        for (name, data) in originals {
            try data.write(to: system32.appendingPathComponent(name))
        }
        return (system32, originals)
    }

    private func installComponentFixture(in engineRoot: URL) throws -> [String: Data] {
        let root = engineRoot.appendingPathComponent("Graphics/DXVK/x64", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = [
            "d3d11.dll": Data("dxvk d3d11".utf8),
            "d3d10core.dll": Data("dxvk d3d10core".utf8),
        ]
        for (name, data) in files {
            try data.write(to: root.appendingPathComponent(name))
        }
        return files
    }
}
