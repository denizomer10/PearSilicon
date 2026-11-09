import Foundation
import Testing

@testable import PearSilicon

/// Installing a 32-bit bundle must skip every macOS/Catalyst admission and
/// preparation step: the engine executes the bundle exactly as shipped.
@MainActor
struct LegacyInstallTests {
    private final class Fixture {
        let root: URL
        let libraryURL: URL
        let bundleURL: URL
        var executableURL: URL { bundleURL.appendingPathComponent("Synthetic") }

        init(magic: [UInt8]) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("pear-legacy-install-\(UUID().uuidString)")
            libraryURL = root.appendingPathComponent("Library")
            bundleURL = libraryURL.appendingPathComponent("com.example.legacy.app")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.example.legacy",
                "CFBundleExecutable": "Synthetic",
                "CFBundleName": "Legacy Synthetic",
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
                "MinimumOSVersion": "3.2"
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: bundleURL.appendingPathComponent("Info.plist"))
            // Header magic plus padding, so a Mach-O reader can walk the header.
            var image = magic
            image += Array(repeating: 0, count: 60)
            try Data(image).write(to: executableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        }
    }

    private static let thin32: [UInt8] = [0xCE, 0xFA, 0xED, 0xFE]
    private static let thin64: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]

    /// Prep must not run for 32-bit bundles, so a runtime stand-in that reports
    /// every invocation keeps the assertion honest.
    private final class PrepSpy {
        var runTools: [String] = []
        var requireStoppedCalls = 0
    }

    private func tools(_ spy: PrepSpy) -> PackageInstaller.PreparationTools {
        var tools = PackageInstaller.PreparationTools()
        tools.runtimeLibraryURL = { nil }
        tools.requireStopped = { _ in spy.requireStoppedCalls += 1 }
        tools.run = { tool, arguments in
            spy.runTools.append(([tool] + arguments).joined(separator: " "))
            return try Shell.run(tool, arguments)
        }
        return tools
    }

    @Test func thirtyTwoBitBundleInstallsWithoutPreparation() async throws {
        let fixture = try Fixture(magic: Self.thin32)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let spy = PrepSpy()
        let installer = PackageInstaller(libraryURL: fixture.libraryURL, preparationTools: tools(spy))

        let originalImage = try Data(contentsOf: fixture.executableURL)
        let installed = try await installer.installBundle(at: fixture.bundleURL)

        #expect(installed.isLegacy32Bit)
        #expect(installed.id == "com.example.legacy")
        // The executable is byte-identical: no LC_LOAD_DYLIB was injected.
        let installedImage = try Data(
            contentsOf: installed.bundleURL.appendingPathComponent("Synthetic")
        )
        #expect(installedImage == originalImage)
        // No Frameworks/libPearRuntime.dylib, and no codesign/ditto ran.
        #expect(!FileManager.default.fileExists(
            atPath: installed.bundleURL.appendingPathComponent("Frameworks/libPearRuntime.dylib").path
        ))
        // The only external tool is the staging clone; signing and Metal/Catalyst
        // preparation never ran.
        #expect(!spy.runTools.contains { $0.contains("codesign") })
        #expect(!spy.runTools.contains { $0.contains("install_name_tool") })
    }

    @Test func thirtyTwoBitIPAInstallsFromTheArchiveAlone() async throws {
        let fixture = try Fixture(magic: Self.thin32)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Archive a real Payload/*.app so the full IPA path runs: extraction,
        // Payload discovery, then the legacy install.
        let payload = fixture.root.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let stagedBundle = payload.appendingPathComponent("com.example.legacy.app", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.bundleURL, to: stagedBundle)
        try FileManager.default.removeItem(at: fixture.bundleURL)

        let ipa = fixture.root.appendingPathComponent("legacy.ipa")
        _ = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, ipa.path])

        let installer = PackageInstaller(
            libraryURL: fixture.libraryURL, preparationTools: tools(PrepSpy())
        )
        let installed = try await installer.install(packageAt: ipa)

        #expect(installed.id == "com.example.legacy")
        #expect(installed.isLegacy32Bit)
        #expect(FileManager.default.fileExists(atPath: installed.executableURL.path))
    }

    @Test func sixtyFourBitBundleStillUsesThePreparedPath() async throws {
        let fixture = try Fixture(magic: Self.thin64)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let spy = PrepSpy()
        let installer = PackageInstaller(libraryURL: fixture.libraryURL, preparationTools: tools(spy))

        // The arm64 admission check must reject this Apple-platform bundle, which
        // is exactly the path a 32-bit bundle now bypasses.
        await #expect(throws: (any Error).self) {
            _ = try await installer.installBundle(at: fixture.bundleURL)
        }
    }
}
