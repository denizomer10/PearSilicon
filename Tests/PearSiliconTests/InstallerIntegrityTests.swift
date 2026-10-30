import Darwin
import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class InstallerIntegrityTests: XCTestCase {
    func testReadOnlyPreflightInspectsAllNestedCodeLocations() throws {
        let paths = [
            "Frameworks/Telemetry.framework/Telemetry",
            "PlugIns/Extension.appex/Frameworks/Telemetry.framework/Telemetry",
            "Resources/Embedded.bundle/Telemetry",
            "Resources/.hidden/code",
            "Other/libEmbedded.dylib"
        ]
        for path in paths {
            let fixture = try IntegrityFixture()
            defer { fixture.remove() }
            try fixture.addImage(at: path, data: IntegrityFixture.image(cryptid: 1))
            let before = try fixture.snapshot(fixture.source)
            XCTAssertThrowsError(try fixture.installer().validateBundleForPreparation(at: fixture.source)) {
                XCTAssertTrue($0.localizedDescription.contains(path), $0.localizedDescription)
                XCTAssertTrue($0.localizedDescription.contains("cryptid 1"), $0.localizedDescription)
            }
            XCTAssertEqual(try fixture.snapshot(fixture.source), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path))
        }
    }

    func testPreflightFailureDoesNotPartiallyPrepareAnyMode() throws {
        for mode in [PreparationMode.compatibility, .compatibilityEnvironment, .nativeContainer] {
            let fixture = try IntegrityFixture()
            defer { fixture.remove() }
            try fixture.addImage(at: "Frameworks/Telemetry.framework/Telemetry", data: IntegrityFixture.image(cryptid: 1))
            let before = try fixture.snapshot(fixture.source)
            XCTAssertThrowsError(try fixture.installer().prepareForMacOS(at: fixture.source, mode: mode))
            XCTAssertEqual(try fixture.snapshot(fixture.source), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path))
        }
    }

    func testPreflightRejectsMalformedSimulatorAnd32BitEmbeddedCode() throws {
        var thirtyTwoBit = Data(count: 28)
        thirtyTwoBit.replaceSubrange(0..<4, with: [0xCE, 0xFA, 0xED, 0xFE])
        let inputs = [
            Data([0xCF, 0xFA, 0xED, 0xFE]),
            IntegrityFixture.image(platform: 7),
            thirtyTwoBit
        ]
        for data in inputs {
            let fixture = try IntegrityFixture()
            defer { fixture.remove() }
            let path = "Resources/Embedded.bundle/Code"
            try fixture.addImage(at: path, data: data)
            let before = try fixture.snapshot(fixture.source)
            XCTAssertThrowsError(try fixture.installer().validateBundleForPreparation(at: fixture.source)) {
                XCTAssertTrue($0.localizedDescription.contains(path), $0.localizedDescription)
            }
            XCTAssertEqual(try fixture.snapshot(fixture.source), before)
        }
    }

    func testPreflightAllowsInternalFrameworkSymlinksWithoutWriting() throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        let framework = fixture.source.appendingPathComponent("Frameworks/Telemetry.framework")
        try fixture.addImage(at: "Frameworks/Telemetry.framework/Versions/A/Telemetry", data: IntegrityFixture.image(type: 6))
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A"
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Telemetry").path,
            withDestinationPath: "Versions/Current/Telemetry"
        )
        let before = try fixture.snapshot(fixture.source)
        try fixture.installer().validateBundleForPreparation(at: fixture.source)
        XCTAssertEqual(try fixture.snapshot(fixture.source), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path))
    }

    func testPreflightRejectsExternalSymlinksWithoutChangingTheirTarget() throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("Outside")
        let data = IntegrityFixture.image()
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.source.appendingPathComponent("ExternalCode").path, withDestinationPath: outside.path
        )
        let before = try fixture.snapshot(fixture.source)
        XCTAssertThrowsError(try fixture.installer().prepareForMacOS(at: fixture.source)) {
            XCTAssertTrue($0.localizedDescription.contains("ExternalCode"))
        }
        XCTAssertEqual(try fixture.snapshot(fixture.source), before)
        XCTAssertEqual(try Data(contentsOf: outside), data)
    }

    func testFreshInstallUsesFinalPathsAndDoesNotChangeSourceInAllModes() async throws {
        for mode in [PreparationMode.compatibility, .compatibilityEnvironment, .nativeContainer] {
            let fixture = try IntegrityFixture()
            defer { fixture.remove() }
            let before = try fixture.snapshot(fixture.source)
            let installed = try await fixture.installer().installBundle(at: fixture.source, mode: mode)
            XCTAssertEqual(installed.bundleURL, fixture.destination)
            XCTAssertEqual(try fixture.snapshot(fixture.source), before)
            let data = try Data(contentsOf: installed.executableURL)
            XCTAssertEqual(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 192, as: UInt32.self) }, 6)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(".pear-install-"))
            XCTAssertEqual(BinaryPatcher.hasLoadDylib(at: installed.executableURL, containing: "libPearRuntime"), mode == .compatibility)
            if mode == .compatibility {
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(
                    fixture.destination.appendingPathComponent("Frameworks/libPearRuntime.dylib").path
                ))
            }
            try fixture.assertNoTransactions()
        }
    }

    func testRealCatalystBundlePreparesAndVerifiesWithoutLaunching() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        let mainSource = fixture.root.appendingPathComponent("main.c")
        let runtimeSource = fixture.root.appendingPathComponent("runtime.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: mainSource)
        try Data("int pear_runtime_probe(void) { return 0; }\n".utf8).write(to: runtimeSource)
        let common = ["--sdk", "macosx", "clang", "-target", "arm64-apple-ios15.0-macabi", "-Wl,-headerpad,0x4000"]
        _ = try Shell.run("/usr/bin/xcrun", common + [mainSource.path, "-o", fixture.source.appendingPathComponent("Game").path])
        _ = try Shell.run("/usr/bin/xcrun", common + [
            "-dynamiclib", "-install_name", "@rpath/libPearRuntime.dylib",
            runtimeSource.path, "-o", fixture.runtime.path
        ])
        let before = try fixture.snapshot(fixture.source)
        var tools = fixture.tools()
        tools.run = { try Shell.run($0, $1) }
        let installed = try await PackageInstaller(libraryURL: fixture.library, preparationTools: tools)
            .installBundle(at: fixture.source)
        _ = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.bundleURL.path])
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: installed.executableURL, containing: "libPearRuntime"))
        XCTAssertEqual(try fixture.snapshot(fixture.source), before)
        try fixture.assertNoTransactions()
    }

    func testEncryptedReinstallPreservesInstalledBundleAndSaves() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        _ = try await fixture.installer().installBundle(at: fixture.source)
        let saved = try fixture.createSave()
        let installedBefore = try fixture.snapshot(fixture.destination)
        try fixture.addImage(at: "Frameworks/Telemetry.framework/Telemetry", data: IntegrityFixture.image(cryptid: 1))
        let sourceBefore = try fixture.snapshot(fixture.source)
        do {
            _ = try await fixture.installer().installBundle(at: fixture.source)
            XCTFail("Encrypted reinstall succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Frameworks/Telemetry.framework/Telemetry"))
        }
        XCTAssertEqual(try fixture.snapshot(fixture.destination), installedBefore)
        XCTAssertEqual(try fixture.snapshot(fixture.source), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
        try fixture.assertNoTransactions()
    }

    func testSigningAndVerificationFailuresPreserveExistingBundleAndSource() async throws {
        for failure in [IntegrityFailure.signing, .verification] {
            let fixture = try IntegrityFixture()
            defer { fixture.remove() }
            _ = try await fixture.installer().installBundle(at: fixture.source)
            let before = try fixture.snapshot(fixture.destination)
            let sourceBefore = try fixture.snapshot(fixture.source)
            do {
                _ = try await fixture.installer(failure: failure).installBundle(at: fixture.source)
                XCTFail("Failed signing/verification committed an installation")
            } catch {
                XCTAssertEqual(error as? IntegrityFailure, failure)
            }
            XCTAssertEqual(try fixture.snapshot(fixture.destination), before)
            XCTAssertEqual(try fixture.snapshot(fixture.source), sourceBefore)
            try fixture.assertNoTransactions()
        }
    }

    func testFailedFreshInstallLeavesNoInstalledBundleOrODR() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        let before = try fixture.snapshot(fixture.source)
        do {
            _ = try await fixture.installer(failure: .signing).installBundle(at: fixture.source)
            XCTFail("Failed fresh installation succeeded")
        } catch { XCTAssertEqual(error as? IntegrityFailure, .signing) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.appendingPathComponent("ODR").path))
        XCTAssertEqual(try fixture.snapshot(fixture.source), before)
        try fixture.assertNoTransactions()
    }

    func testStoppedCheckIsRepeatedImmediatelyBeforeCommit() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        var tools = fixture.tools()
        var checks = 0
        tools.requireStopped = { _ in
            checks += 1
            if checks == 2 { throw IntegrityFailure.running }
        }
        let before = try fixture.snapshot(fixture.source)
        do {
            _ = try await PackageInstaller(libraryURL: fixture.library, preparationTools: tools)
                .installBundle(at: fixture.source)
            XCTFail("Installation committed after the stopped-state check failed")
        } catch { XCTAssertEqual(error as? IntegrityFailure, .running) }
        XCTAssertEqual(checks, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try fixture.snapshot(fixture.source), before)
        try fixture.assertNoTransactions()
    }

    func testPreparationRejectsRunningAppBeforeStagingAndReleasesLease() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        let app = try await fixture.installer().installBundle(at: fixture.source)
        let before = try fixture.snapshot(fixture.destination)
        var tools = fixture.tools()
        var checks = 0
        var commands = 0
        let run = tools.run
        tools.run = { tool, arguments in
            commands += 1
            return try run(tool, arguments)
        }
        tools.requireStopped = { _ in
            checks += 1
            XCTAssertThrowsError(try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library))
            throw IntegrityFailure.running
        }
        let installer = PackageInstaller(libraryURL: fixture.library, preparationTools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: app)) {
            XCTAssertEqual($0 as? IntegrityFailure, .running)
        }

        XCTAssertEqual(checks, 1)
        XCTAssertEqual(commands, 0)
        XCTAssertTrue(try fixture.snapshot(fixture.destination) == before, "Running app bundle changed")
        try fixture.assertNoTransactions()
        let next = try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library)
        next.release()
    }

    func testPreparationRechecksStoppedStateImmediatelyBeforeExchange() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        let app = try await fixture.installer().installBundle(at: fixture.source)
        let before = try fixture.snapshot(fixture.destination)
        var tools = fixture.tools()
        var checks = 0
        tools.requireStopped = { _ in
            checks += 1
            if checks == 2 { throw IntegrityFailure.running }
        }
        let installer = PackageInstaller(libraryURL: fixture.library, preparationTools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: app)) {
            XCTAssertEqual($0 as? IntegrityFailure, .running)
        }

        XCTAssertEqual(checks, 2)
        XCTAssertTrue(try fixture.snapshot(fixture.destination) == before, "Stopped-state failure replaced the bundle")
        try fixture.assertNoTransactions()
        let next = try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library)
        next.release()
    }

    func testUninstallRejectsRunningAppAndReleasesLease() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        let app = try await fixture.installer().installBundle(at: fixture.source)
        let saved = try fixture.createSave()
        let before = try fixture.snapshot(fixture.destination)
        var tools = fixture.tools()
        var checks = 0
        tools.requireStopped = { _ in
            checks += 1
            XCTAssertThrowsError(try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library))
            throw IntegrityFailure.running
        }
        let installer = PackageInstaller(libraryURL: fixture.library, preparationTools: tools)

        XCTAssertThrowsError(try installer.uninstall(app)) {
            XCTAssertEqual($0 as? IntegrityFailure, .running)
        }

        XCTAssertEqual(checks, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        if FileManager.default.fileExists(atPath: fixture.destination.path) {
            XCTAssertTrue(try fixture.snapshot(fixture.destination) == before, "Running app was partially removed")
        }
        XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
        let next = try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library)
        next.release()
    }

    func testPreparationExchangeIOFailurePreservesBundleAndReleasesLease() async throws {
        let fixture = try IntegrityFixture()
        defer {
            chflags(fixture.destination.path, 0)
            fixture.remove()
        }
        let app = try await fixture.installer().installBundle(at: fixture.source)
        let saved = try fixture.createSave()
        let before = try fixture.snapshot(fixture.destination)
        let sourceBefore = try fixture.snapshot(fixture.source)
        var tools = fixture.tools()
        var protected = false
        tools.run = { tool, arguments in
            if tool == "/usr/bin/codesign" {
                if arguments.contains("--verify") {
                    guard chflags(fixture.destination.path, UInt32(UF_IMMUTABLE)) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    protected = true
                }
                return ""
            }
            return try Shell.run(tool, arguments)
        }
        let installer = PackageInstaller(libraryURL: fixture.library, preparationTools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: app)) {
            XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual(($0 as NSError).code, Int(EPERM))
        }

        XCTAssertTrue(protected, "Must reach the real atomic exchange, not fail during preparation")
        XCTAssertEqual(chflags(fixture.destination.path, 0), 0)
        XCTAssertEqual(try fixture.snapshot(fixture.destination), before)
        XCTAssertEqual(try fixture.snapshot(fixture.source), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
        try fixture.assertNoTransactions()
        let next = try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library)
        next.release()
    }

    func testUninstallIOFailurePreservesBundleAndReleasesLease() async throws {
        let fixture = try IntegrityFixture()
        defer {
            chflags(fixture.destination.path, 0)
            fixture.remove()
        }
        let app = try await fixture.installer().installBundle(at: fixture.source)
        let saved = try fixture.createSave()
        let before = try fixture.snapshot(fixture.destination)
        XCTAssertEqual(chflags(fixture.destination.path, UInt32(UF_IMMUTABLE)), 0)

        XCTAssertThrowsError(try fixture.installer().uninstall(app))

        XCTAssertEqual(chflags(fixture.destination.path, 0), 0)
        XCTAssertEqual(try fixture.snapshot(fixture.destination), before)
        XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
        try fixture.assertNoTransactions()
        let next = try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library)
        next.release()
    }

    func testUninstallImmutableDescendantFailurePreservesBundleAndSaveAndReleasesLease() async throws {
        let fixture = try IntegrityFixture()
        let locked = fixture.destination.appendingPathComponent("Resources/locked.asset")
        defer {
            chflags(locked.path, 0)
            fixture.remove()
        }
        let app = try await fixture.installer().installBundle(at: fixture.source)
        let saved = try fixture.createSave()
        try FileManager.default.createDirectory(at: locked.deletingLastPathComponent(), withIntermediateDirectories: true)
        let asset = Data("protected asset".utf8)
        try asset.write(to: locked)
        XCTAssertEqual(chflags(locked.path, UInt32(UF_IMMUTABLE)), 0)
        let installer = fixture.installer()

        let before = try fixture.snapshot(fixture.destination)

        XCTAssertThrowsError(try installer.uninstall(app)) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, CocoaError.fileWriteNoPermission.rawValue)
        }

        XCTAssertEqual(try fixture.snapshot(fixture.destination), before)
        XCTAssertEqual(try Data(contentsOf: locked), asset)
        XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
        try fixture.assertNoTransactions()
        let next = try AppLaunchLease.acquire(appID: app.id, libraryURL: fixture.library)
        next.release()
    }

    func testArchiveInstallSwitchReinstallAndUninstallPreserveSourceAndSaves() async throws {
        for mode in [PreparationMode.compatibility, .compatibilityEnvironment, .nativeContainer] {
            let fixture = try IntegrityFixture()
            defer { fixture.remove() }
            let archive = try fixture.package()
            let archiveBefore = try Data(contentsOf: archive)
            let sourceBefore = try fixture.snapshot(fixture.source)
            let installer = fixture.installer()
            let installed = try await installer.install(packageAt: archive, mode: mode)
            XCTAssertEqual(installer.currentPreparationMode(for: installed), mode)
            let saved = try fixture.createSave()

            let switched: PreparationMode = mode == .compatibilityEnvironment ? .compatibility : .compatibilityEnvironment
            try installer.setPreparationMode(switched, for: installed)
            XCTAssertEqual(installer.currentPreparationMode(for: installed), switched)
            let reinstalled = try await installer.install(packageAt: archive, mode: mode)
            XCTAssertEqual(installer.currentPreparationMode(for: reinstalled), mode)
            XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
            try installer.uninstall(reinstalled)

            XCTAssertTrue(try installer.scanLibrary().isEmpty)
            XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
            XCTAssertEqual(try fixture.snapshot(fixture.source), sourceBefore)
            XCTAssertEqual(try Data(contentsOf: archive), archiveBefore)
            try fixture.assertNoTransactions()
            try fixture.assertNoTemporaryWork()
        }
    }

    func testTraversalAndSymlinkArchivesCannotOverwriteOutsideFilesOrInstalledBundle() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("Python 3 is required to construct adversarial ZIP entries")
        }
        for attack in ["traversal", "symlink-parent"] {
            let fixture = try IntegrityFixture()
            defer { fixture.remove() }
            _ = try await fixture.installer().installBundle(at: fixture.source)
            let before = try fixture.snapshot(fixture.destination)
            let sourceBefore = try fixture.snapshot(fixture.source)
            let saved = try fixture.createSave()
            let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let sentinel = outside.appendingPathComponent("sentinel")
            let original = Data("outside-data".utf8)
            try original.write(to: sentinel)
            let archive = fixture.root.appendingPathComponent("\(attack).ipa")
            _ = try Shell.run(python, ["-c", """
                import pathlib, sys, zipfile
                archive, source, outside, attack = sys.argv[1:]
                with zipfile.ZipFile(archive, 'w') as z:
                    z.write(pathlib.Path(source) / 'Info.plist', 'Payload/Source.app/Info.plist')
                    z.write(pathlib.Path(source) / 'Game', 'Payload/Source.app/Game')
                    if attack == 'traversal':
                        z.writestr('../../../outside/sentinel', b'overwritten')
                    else:
                        link = zipfile.ZipInfo('Payload/Source.app/Resources')
                        link.create_system = 3
                        link.external_attr = 0o120777 << 16
                        z.writestr(link, outside.encode())
                        z.writestr('Payload/Source.app/Resources/sentinel', b'overwritten')
                """, archive.path, fixture.source.path, outside.path, attack])
            var tools = fixture.tools()
            let run = tools.run
            var beganPreparation = false
            tools.run = { tool, arguments in
                if tool == "/usr/bin/ditto" || tool == "/usr/bin/codesign" { beganPreparation = true }
                return try run(tool, arguments)
            }
            let installer = PackageInstaller(libraryURL: fixture.library, preparationTools: tools)

            do {
                _ = try await installer.install(packageAt: archive)
                XCTFail("Accepted \(attack) archive")
            } catch {
                switch error {
                case PearError.commandFailed, PearError.invalidPackage: break
                default: XCTFail("Unexpected admission error: \(error)")
                }
            }

            XCTAssertFalse(beganPreparation, "Unsafe archive reached bundle preparation")
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
            XCTAssertEqual(try Data(contentsOf: saved), Data("save-data".utf8))
            XCTAssertEqual(try fixture.snapshot(fixture.destination), before)
            XCTAssertEqual(try fixture.snapshot(fixture.source), sourceBefore)
            try fixture.assertNoTransactions()
            try fixture.assertNoTemporaryWork()
        }
    }

    func testCRCFailureIsRejectedBeforeReplacingAnInstalledApp() async throws {
        let fixture = try IntegrityFixture()
        defer { fixture.remove() }
        _ = try await fixture.installer().installBundle(at: fixture.source)
        let before = try fixture.snapshot(fixture.destination)
        let archive = fixture.root.appendingPathComponent("BadCRC.ipa")
        try IntegrityFixture.badCRCArchive().write(to: archive)
        do {
            _ = try await fixture.installer().install(packageAt: archive)
            XCTFail("CRC-damaged archive was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("CRC check failed"), error.localizedDescription)
        }
        XCTAssertEqual(try fixture.snapshot(fixture.destination), before)
        try fixture.assertNoTransactions()
    }
}

private enum IntegrityFailure: Error { case signing, verification, running }

private final class IntegrityFixture {
    let root: URL
    let source: URL
    let runtime: URL
    let support: URL
    var library: URL { support.appendingPathComponent("Applications") }
    var destination: URL { library.appendingPathComponent("com.example.integrity.app") }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("pear-integrity-\(UUID().uuidString)")
        source = root.appendingPathComponent("Input/Source.app")
        runtime = root.appendingPathComponent("Runtime/libPearRuntime.dylib")
        support = root.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.integrity", "CFBundleExecutable": "Game",
            "CFBundleName": "Integrity", "CFBundleSupportedPlatforms": ["iPhoneOS"]
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: source.appendingPathComponent("Info.plist"))
        try Self.image().write(to: source.appendingPathComponent("Game"))
        try Self.image(platform: 6, type: 6).write(to: runtime)
        let signature = source.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: false)
        try Data("original-signature".utf8).write(to: signature.appendingPathComponent("CodeResources"))
    }

    func package() throws -> URL {
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: source, to: payload.appendingPathComponent("Source.app"))
        let archive = root.appendingPathComponent("Source.ipa")
        _ = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, archive.path])
        return archive
    }

    func addImage(at relative: String, data: Data) throws {
        let url = source.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func tools(failure: IntegrityFailure? = nil) -> PackageInstaller.PreparationTools {
        var tools = PackageInstaller.PreparationTools()
        tools.runtimeLibraryURL = { [runtime] in runtime }
        tools.requireStopped = { _ in }
        tools.run = { tool, arguments in
            if tool == "/usr/bin/codesign" {
                if failure == .verification && arguments.contains("--verify") { throw IntegrityFailure.verification }
                if failure == .signing && !arguments.contains("--verify") { throw IntegrityFailure.signing }
                return ""
            }
            return try Shell.run(tool, arguments)
        }
        return tools
    }

    func installer(failure: IntegrityFailure? = nil) -> PackageInstaller {
        PackageInstaller(libraryURL: library, preparationTools: tools(failure: failure))
    }

    struct Entry: Equatable {
        let kind: FileAttributeType
        let inode: UInt64
        let modified: Date?
        let permissions: UInt16
        let bytes: Data?
        let link: String?
    }

    func snapshot(_ directory: URL) throws -> [String: Entry] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var entries: [String: Entry] = [:]
        for url in [directory] + enumerator.compactMap({ $0 as? URL }) {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let kind = try XCTUnwrap(attrs[.type] as? FileAttributeType)
            entries[String(url.path.dropFirst(directory.path.count))] = Entry(
                kind: kind, inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                modified: attrs[.modificationDate] as? Date,
                permissions: (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                bytes: kind == .typeRegular ? try Data(contentsOf: url) : nil,
                link: kind == .typeSymbolicLink ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            )
        }
        return entries
    }

    func assertNoTransactions(file: StaticString = #filePath, line: UInt = #line) throws {
        guard FileManager.default.fileExists(atPath: library.path) else { return }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.path).contains {
            $0.hasPrefix(".pear-install-") || $0.hasPrefix(".pear-preparation-")
        }, file: file, line: line)
    }

    /// `Work` intentionally keeps the empty/debug entitlement plists used for
    /// signing. A failed transaction must leave no per-install UUID directory.
    func assertNoTemporaryWork(file: StaticString = #filePath, line: UInt = #line) throws {
        let work = support.appendingPathComponent("Work")
        guard FileManager.default.fileExists(atPath: work.path) else { return }
        let allowed: Set<String> = [
            "entitlements.plist", "native-entitlements.plist", "debug-entitlements.plist"
        ]
        let unexpected = try FileManager.default.contentsOfDirectory(atPath: work.path)
            .filter { !allowed.contains($0) }
        XCTAssertTrue(unexpected.isEmpty, "Temporary work entries remain: \(unexpected)", file: file, line: line)
    }

    func createSave() throws -> URL {
        let url = support.appendingPathComponent("Games/com.example.integrity/Documents/save")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save-data".utf8).write(to: url)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func image(platform: UInt32 = 2, type: UInt32 = 2, cryptid: UInt32? = nil) -> Data {
        var data = Data()
        func u32(_ value: UInt32) { data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func u64(_ value: UInt64) { data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func name(_ value: String) { data.append(Data(value.utf8)); data.append(Data(count: 16 - value.utf8.count)) }
        u32(0xFEEDFACF); u32(0x0100_000C); u32(0); u32(type)
        u32(cryptid == nil ? 2 : 3); u32(176 + (cryptid == nil ? 0 : 24)); u32(0); u32(0)
        u32(0x19); u32(152); name("__TEXT")
        u64(0x1_0000_0000); u64(8192); u64(0); u64(8192)
        u32(7); u32(5); u32(1); u32(0)
        name("__text"); name("__TEXT"); u64(0x1_0000_1000); u64(8)
        u32(4096); u32(2); u32(0); u32(0); u32(0x8000_0400); u32(0); u32(0); u32(0)
        u32(0x32); u32(24); u32(platform); u32(0x000F_0000); u32(0x001A_0100); u32(0)
        if let cryptid { u32(0x2C); u32(24); u32(4096); u32(8); u32(cryptid); u32(0) }
        data.append(Data(count: 8192 - data.count))
        data.replaceSubrange(4096..<4104, with: [0xC0, 0x03, 0x5F, 0xD6, 0xC0, 0x03, 0x5F, 0xD6])
        return data
    }

    static func badCRCArchive() -> Data {
        let filename = Data("Payload/Source.app/Game".utf8)
        let payload = Data("CRC-damaged-content".utf8)
        var data = Data()
        func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
        func u32(_ value: UInt32) { data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        u32(0x0403_4B50); u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(0); u32(UInt32(payload.count)); u32(UInt32(payload.count)); u16(UInt16(filename.count)); u16(0)
        data.append(filename); data.append(payload)
        let start = data.count
        u32(0x0201_4B50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(0); u32(UInt32(payload.count)); u32(UInt32(payload.count)); u16(UInt16(filename.count))
        u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); data.append(filename)
        let size = data.count - start
        u32(0x0605_4B50); u16(0); u16(0); u16(1); u16(1); u32(UInt32(size)); u32(UInt32(start)); u16(0)
        return data
    }
}
