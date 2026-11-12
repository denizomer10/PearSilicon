import Foundation
import XCTest
@testable import PearSilicon

/// Opt-in installation of the signed MetalSharp Wine release from a cached ZIP.
/// The destination is explicit and retained so the imported game can be launched.
final class SignedWineIntegrationTests: XCTestCase {
    func testInstallsSignedBundleAndImportsGame() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let archive = env["PEAR_SIGNED_WINE_ZIP"],
              let destination = env["PEAR_SIGNED_WINE_DESTINATION"],
              let game = env["PEAR_WINDOWS_GAME_FOLDER"] else {
            throw XCTSkip("Set PEAR_SIGNED_WINE_ZIP, PEAR_SIGNED_WINE_DESTINATION and PEAR_WINDOWS_GAME_FOLDER")
        }
        let root = URL(fileURLWithPath: destination)
        let service = WineReleaseService(listReleases: { _ in Data() }, download: { url, target in
            try FileManager.default.copyItem(at: URL(fileURLWithPath: archive), to: target)
            return URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        })
        let engine = try await service.installArchive(
            from: URL(string: "https://github.com/metalsharp/MetalSharp-Wine/releases/download/v6.0/MetalSharp-Wine-6.0-arm64.zip")!,
            assetName: "MetalSharp-Wine-6.0-arm64.zip",
            sha256: "25f7dff91000c03c835b800980878acb12c1f952a4b7853f77de7f21fb87046f",
            engineID: "metalsharp-6.0", name: "MetalSharp Wine", version: "6.0",
            distribution: .metalSharp, store: WineEngineStore(rootURL: root.appendingPathComponent("Engines")),
            progress: { print("[signed-wine]", $0) }
        )
        try engine.validate()
        XCTAssertTrue(engine.isAppBundleRuntime)
        let app = engine.wineHome.deletingLastPathComponent()
        _ = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let entry = try ManagedAppService().importWindowsFolder(
            from: URL(fileURLWithPath: game), executablePath: "gta-vc.exe",
            libraryRoot: root, engineID: engine.id)
        let config = try ManagedAppService().launchConfiguration(for: entry, engine: engine)
        XCTAssertEqual(config.environment["WINEDLLPATH"], engine.wineHome.appendingPathComponent("lib/wine").path)
        XCTAssertEqual(config.environment["WINEMSYNC"], "1")
        print("[signed-wine] engine: \(engine.rootURL.path) entry: \(entry.directoryURL.path)")
    }
}
