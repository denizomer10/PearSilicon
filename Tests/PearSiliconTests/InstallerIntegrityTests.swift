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
