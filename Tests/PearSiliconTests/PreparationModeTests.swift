import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class PreparationModeTests: XCTestCase {
    func testEnvironmentRepairsMixedMarkerAndLoadCommandEvenWhenAlreadySelected() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try Data("environment\n".utf8).write(to: fixture.markerURL)
        let installer = fixture.installer()
        let app = try fixture.app(using: installer)
        XCTAssertEqual(installer.currentPreparationMode(for: app), .compatibilityEnvironment)

        try installer.setPreparationMode(.compatibilityEnvironment, for: app)

        XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: fixture.executableURL, containing: "libPearRuntime"))
        XCTAssertEqual(try Data(contentsOf: fixture.markerURL), Data("environment\n".utf8))
        try fixture.assertFinalPaths(runtimeLoad: false)
        try fixture.assertUserChangesPreserved()
        try fixture.assertNoStagingRemains()
    }

    func testLoadCommandAndNativeSwitchesPreserveUnrelatedBundleFiles() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibilityEnvironment)
        let installer = fixture.installer()
        let app = try fixture.app(using: installer)

        try installer.setPreparationMode(.compatibility, for: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        try fixture.assertFinalPaths(runtimeLoad: true)
        try fixture.assertUserChangesPreserved()

        try installer.setPreparationMode(.nativeContainer, for: app)
        XCTAssertEqual(installer.currentPreparationMode(for: app), .nativeContainer)
        for name in ["libPearRuntime.dylib", "libswiftUIKit.dylib", "libcxxcompat.dylib", ".pear-injection"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.frameworksURL.appendingPathComponent(name).path))
        }
        XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: fixture.executableURL, containing: "libPearRuntime"))
        try fixture.assertUserChangesPreserved()
        try fixture.assertNoStagingRemains()
    }

    func testMissingRuntimeRollsBackAllPreparationChanges() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try fixture.addSignatureSidecar()
        let before = try fixture.snapshot()
        var tools = fixture.tools()
        tools.runtimeLibraryURL = { nil }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            guard case PearError.missingRuntimeComponent("libPearRuntime.dylib") = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testFailedLoadCommandRemovalPropagatesAndRollsBack() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try fixture.addSignatureSidecar()
        let before = try fixture.snapshot()
        var tools = fixture.tools()
        tools.removeLoadDylib = { _, token in
            XCTAssertEqual(token, "libPearRuntime")
            throw PreparationTestError.removal
        }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            XCTAssertEqual($0 as? PreparationTestError, .removal)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testIneffectiveRemovalCannotCommitMixedEnvironmentState() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        let before = try fixture.snapshot()
        var tools = fixture.tools()
        tools.removeLoadDylib = { _, _ in false }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            guard case PearError.invalidPackage(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(reason.contains("invariants"))
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testMarkerWriteFailureRollsBackRemovedLoadCommandAndSignatureSidecars() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try fixture.addSignatureSidecar()
        // A directory makes atomic marker writing fail independently of user privileges.
        try FileManager.default.createDirectory(at: fixture.markerURL, withIntermediateDirectories: false)
        let before = try fixture.snapshot()
        let installer = fixture.installer()

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer)))
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: fixture.executableURL, containing: "libPearRuntime"))
        try fixture.assertNoStagingRemains()
    }

    func testSigningFailureOnlyMutatesDiscardedStagingCopy() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try fixture.addSignatureSidecar()
        let before = try fixture.snapshot()
        var signedStagingCopy = false
        var tools = fixture.tools()
        tools.run = { tool, arguments in
            if tool == "/usr/bin/codesign" {
                let nestedObject = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
                XCTAssertTrue(nestedObject.path.contains(".pear-preparation-"))
                try Data("partially signed".utf8).write(to: nestedObject)
                signedStagingCopy = true
                throw PreparationTestError.signing
            }
            return try Shell.run(tool, arguments)
        }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            XCTAssertEqual($0 as? PreparationTestError, .signing)
        }
        XCTAssertTrue(signedStagingCopy)
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testSignatureVerificationFailureRollsBackAfterSigning() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try fixture.addSignatureSidecar()
        let before = try fixture.snapshot()
        var verifiedStagingCopy = false
        var tools = fixture.tools()
        tools.run = { tool, arguments in
            if tool == "/usr/bin/codesign" {
                if arguments.contains("--verify") {
                    let staged = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
                    XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: staged.appendingPathComponent("Synthetic"), containing: "libPearRuntime"))
                    verifiedStagingCopy = true
                    throw PreparationTestError.verification
                }
                return ""
            }
            return try Shell.run(tool, arguments)
        }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            XCTAssertEqual($0 as? PreparationTestError, .verification)
        }
        XCTAssertTrue(verifiedStagingCopy)
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testDamagedSyntheticRuntimeIsRejectedBeforeCodesignAndLeavesOriginalUntouched() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try fixture.addSignatureSidecar()
        // The copied runtime must pass admission before signing. The installed
        // runtime remains valid; only the replacement source is damaged.
        let header: [UInt32] = [0xfeedfacf, 0x0100_000c, 0, 6, 1, 24, 0, 0]
        let damaged = header.flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        try Data(damaged).write(to: fixture.runtimeURL)
        let before = try fixture.snapshot()
        var tools = fixture.tools()
        var attemptedSignature = false
        tools.run = { tool, arguments in
            if tool == "/usr/bin/codesign" {
                attemptedSignature = true
                return ""
            }
            return try Shell.run(tool, arguments)
        }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            guard case PearError.invalidPackage(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(reason.contains("Frameworks/libPearRuntime.dylib"))
        }
        XCTAssertFalse(attemptedSignature)
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testDanglingMarkerCannotBypassCompatibilityInvariant() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        try FileManager.default.createSymbolicLink(atPath: fixture.markerURL.path, withDestinationPath: "missing-marker")
        let installer = fixture.installer()

        try installer.setPreparationMode(.compatibility, for: fixture.app(using: installer))

        XCTAssertThrowsError(try FileManager.default.attributesOfItem(atPath: fixture.markerURL.path))
        try fixture.assertFinalPaths(runtimeLoad: true)
        try fixture.assertNoStagingRemains()
    }

    func testModeInvariantsAreCheckedAgainAfterSigning() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibility)
        let before = try fixture.snapshot()
        var tools = fixture.tools()
        tools.run = { tool, arguments in
            if tool == "/usr/bin/codesign" {
                if arguments.contains("--verify") {
                    let staged = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
                    try BinaryPatcher.addLoadDylib(
                        at: staged.appendingPathComponent("Synthetic"),
                        path: fixture.frameworksURL.appendingPathComponent("libPearRuntime.dylib").path
                    )
                }
                return ""
            }
            return try Shell.run(tool, arguments)
        }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            guard case PearError.invalidPackage(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(reason.contains("invariants"))
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testCxxDependencyRewriteFailureRollsBack() throws {
        let fixture = try PreparationFixture(needsCxx: true)
        defer { fixture.remove() }
        let before = try fixture.snapshot()
        var tools = fixture.tools()
        tools.run = { tool, arguments in
            if tool == "/usr/bin/install_name_tool" { throw PreparationTestError.dependencyRewrite }
            if tool == "/usr/bin/codesign" { return "" }
            return try Shell.run(tool, arguments)
        }
        let installer = fixture.installer(tools: tools)

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            XCTAssertEqual($0 as? PreparationTestError, .dependencyRewrite)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testMissingHeaderSpaceRejectsInsertionInsteadOfCommitting() throws {
        let fixture = try PreparationFixture(headerPadding: false)
        defer { fixture.remove() }
        let before = try fixture.snapshot()
        let installer = fixture.installer()

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            guard case PearError.invalidPackage(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(reason.contains("padding"))
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testCxxDependencyAndRPathReferToFinalBundleNotStaging() throws {
        let fixture = try PreparationFixture(needsCxx: true)
        defer { fixture.remove() }
        let installer = fixture.installer()
        let app = try fixture.app(using: installer)

        try installer.setPreparationMode(.compatibilityEnvironment, for: app)

        let paths = try fixture.paths()
        XCTAssertTrue(paths.dependencies.contains(fixture.frameworksURL.appendingPathComponent("libcxxcompat.dylib").path))
        XCTAssertFalse(paths.dependencies.contains("/usr/lib/libc++.1.dylib"))
        try fixture.assertFinalPaths(runtimeLoad: false)
        try fixture.assertNoStagingRemains()
    }

    func testNewInstallPreparationDefaultsToItsOwnFinalDestination() throws {
        for mode in [PreparationMode.compatibility, .compatibilityEnvironment] {
            let fixture = try PreparationFixture(needsCxx: true)
            defer { fixture.remove() }
            try fixture.prepare(mode)
            try fixture.assertFinalPaths(runtimeLoad: mode == .compatibility)
            let paths = try fixture.paths()
            XCTAssertTrue(paths.dependencies.contains(fixture.frameworksURL.appendingPathComponent("libcxxcompat.dylib").path))
        }
    }

    func testValidSameModeDoesNotNeedExternalRuntimeOrResigning() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        try fixture.prepare(.compatibilityEnvironment)
        let before = try fixture.snapshot()
        var tools = fixture.tools()
        tools.runtimeLibraryURL = { nil }
        tools.run = { _, _ in throw PreparationTestError.unexpectedCommand }
        let installer = fixture.installer(tools: tools)

        try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))

        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }

    func testEncryptedOrMalformedNestedImageCannotBypassAnyAlreadySelectedMode() throws {
        let path = "Resources/Embedded.bundle/Telemetry"
        for mode in [PreparationMode.compatibility, .compatibilityEnvironment, .nativeContainer] {
            for encrypted in [true, false] {
                let fixture = try PreparationFixture()
                defer { fixture.remove() }
                try fixture.prepare(mode)
                try fixture.addSignatureSidecar()
                try fixture.addInvalidImage(at: path, encrypted: encrypted)
                let before = try fixture.snapshot()
                var tools = fixture.tools()
                tools.run = { _, _ in throw PreparationTestError.unexpectedCommand }
                let installer = fixture.installer(tools: tools)
                let app = try fixture.app(using: installer)
                XCTAssertEqual(installer.currentPreparationMode(for: app), mode)

                XCTAssertThrowsError(try installer.setPreparationMode(mode, for: app)) {
                    guard case PearError.invalidPackage(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
                    XCTAssertTrue(reason.contains(path))
                }
                XCTAssertEqual(try fixture.snapshot(), before)
                try fixture.assertNoStagingRemains()
            }
        }
    }

    func testExternalSymlinkCannotWriteThroughToOriginalDuringPreparation() throws {
        let fixture = try PreparationFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        let original = Data("not part of the bundle".utf8)
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.bundleURL.appendingPathComponent("external"), withDestinationURL: outside
        )
        let before = try fixture.snapshot()
        let installer = fixture.installer()

        XCTAssertThrowsError(try installer.setPreparationMode(.compatibilityEnvironment, for: fixture.app(using: installer))) {
            guard case PearError.invalidPackage(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(reason.contains("external symlink"))
        }
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertEqual(try fixture.snapshot(), before)
        try fixture.assertNoStagingRemains()
    }
}

private enum PreparationTestError: Error, Equatable {
    case removal, signing, verification, dependencyRewrite, unexpectedCommand
}

/// All bundles, runtime stand-ins, signature sidecars and work files live under
/// a fresh temporary root. Successful transaction tests stub only codesign;
/// ditto, Mach-O edits, install_name_tool and the atomic exchange are real.
private final class PreparationFixture {
    let root: URL
    let libraryURL: URL
    let bundleURL: URL
    let runtimeURL: URL
    var executableURL: URL { bundleURL.appendingPathComponent("Synthetic") }
    var frameworksURL: URL { bundleURL.appendingPathComponent("Frameworks") }
    var markerURL: URL { PackageInstaller.injectionMarkerURL(in: bundleURL) }
    private let userData = Data("third-party resource\n".utf8)
    private let thirdPartyBinary: Data

    init(headerPadding: Bool = true, needsCxx: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("pear-preparation-\(UUID().uuidString)")
        libraryURL = root.appendingPathComponent("Library")
        bundleURL = libraryURL.appendingPathComponent("com.example.synthetic.app")
        runtimeURL = root.appendingPathComponent("Runtime/libPearRuntime.dylib")
        thirdPartyBinary = Self.machO(platform: 6)
        try FileManager.default.createDirectory(at: frameworksURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.synthetic", "CFBundleExecutable": "Synthetic",
            "CFBundleName": "Synthetic", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UserCustomKey": "preserved"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        try Self.machO(platform: 2, headerPadding: headerPadding, needsCxx: needsCxx).write(to: executableURL)
        try Self.machO(platform: 6).write(to: runtimeURL)
        if needsCxx {
            try Self.machO(platform: 6).write(to: runtimeURL.deletingLastPathComponent().appendingPathComponent("libcxxcompat.dylib"))
            try BinaryPatcher.addLoadDylib(at: executableURL, path: "/usr/lib/libc++.1.dylib")
        }
        try thirdPartyBinary.write(to: frameworksURL.appendingPathComponent("ThirdParty.dylib"))
        try userData.write(to: bundleURL.appendingPathComponent("UserResource"))
        try FileManager.default.createSymbolicLink(
            atPath: bundleURL.appendingPathComponent("UserResourceLink").path, withDestinationPath: "UserResource"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    func tools() -> PackageInstaller.PreparationTools {
        var tools = PackageInstaller.PreparationTools()
        tools.runtimeLibraryURL = { [runtimeURL] in runtimeURL }
        tools.requireStopped = { _ in }
        tools.run = { tool, arguments in
            if tool == "/usr/bin/codesign" { return "" }
            return try Shell.run(tool, arguments)
        }
        return tools
    }

    func installer(tools: PackageInstaller.PreparationTools? = nil) -> PackageInstaller {
        PackageInstaller(libraryURL: libraryURL, preparationTools: tools ?? self.tools())
    }

    func app(using installer: PackageInstaller) throws -> InstalledApp {
        try installer.makeInstalledApp(fromBundleAt: bundleURL)
    }

    func prepare(_ mode: PreparationMode) throws {
        try installer().prepareForMacOS(at: bundleURL, mode: mode)
    }

    func addInvalidImage(at relativePath: String, encrypted: Bool) throws {
        let file = bundleURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = encrypted ? Self.machO(platform: 2, cryptid: 1) : Data([0xCF, 0xFA, 0xED, 0xFE])
        try data.write(to: file)
    }

    func addSignatureSidecar() throws {
        let directory = bundleURL.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("original signature sidecar".utf8).write(to: directory.appendingPathComponent("CodeResources"))
    }

    func assertUserChangesPreserved(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: bundleURL.appendingPathComponent("UserResource")), userData, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: frameworksURL.appendingPathComponent("ThirdParty.dylib")), thirdPartyBinary, file: file, line: line)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bundleURL.appendingPathComponent("UserResourceLink").path), "UserResource", file: file, line: line)
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundleURL.appendingPathComponent("Info.plist")), format: nil
        ) as? [String: Any]
        XCTAssertEqual(info?["UserCustomKey"] as? String, "preserved", file: file, line: line)
    }

    func assertFinalPaths(runtimeLoad: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let paths = try paths()
        let runtimeLoads = paths.dependencies.filter { $0.contains("libPearRuntime") }
        XCTAssertEqual(runtimeLoads, runtimeLoad ? [frameworksURL.appendingPathComponent("libPearRuntime.dylib").path] : [], file: file, line: line)
        XCTAssertTrue(paths.rpaths.contains(frameworksURL.path), file: file, line: line)
        XCTAssertFalse((paths.dependencies + paths.rpaths).contains { $0.contains(".pear-preparation-") }, file: file, line: line)
    }

    func assertNoStagingRemains(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: libraryURL.path), [bundleURL.lastPathComponent], file: file, line: line)
    }

    struct Entry: Equatable {
        let kind: FileAttributeType
        let permissions: UInt16
        let modified: Date?
        let inode: UInt64
        let contents: Data?
        let symlink: String?
    }

    func snapshot() throws -> [String: Entry] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil))
        var urls = [bundleURL]
        for case let url as URL in enumerator { urls.append(url) }
        var result: [String: Entry] = [:]
        for url in urls {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let kind = try XCTUnwrap(attributes[.type] as? FileAttributeType)
            result[String(url.path.dropFirst(bundleURL.path.count))] = Entry(
                kind: kind,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                modified: attributes[.modificationDate] as? Date,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                contents: kind == .typeRegular ? try Data(contentsOf: url) : nil,
                symlink: kind == .typeSymbolicLink ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            )
        }
        return result
    }

    func paths() throws -> (dependencies: [String], rpaths: [String]) {
        let data = try Data(contentsOf: executableURL)
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        var dependencies: [String] = []
        var rpaths: [String] = []
        var offset = 32
        for _ in 0..<u32(16) {
            let command = u32(offset)
            let size = Int(u32(offset + 4))
            if command == 0x0c || command == 0x8000_001c {
                let start = offset + Int(u32(offset + 8))
                let end = try XCTUnwrap(data[start..<(offset + size)].firstIndex(of: 0))
                let path = String(decoding: data[start..<end], as: UTF8.self)
                if command == 0x0c { dependencies.append(path) } else { rpaths.append(path) }
            }
            offset += size
        }
        return (dependencies, rpaths)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func machO(platform: UInt32, headerPadding: Bool = true, needsCxx: Bool = false, cryptid: UInt32? = nil) -> Data {
        var data = Data()
        func u32(_ value: UInt32) {
            data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func u64(_ value: UInt64) {
            data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func name(_ value: String) {
            data.append(Data(value.utf8)); data.append(Data(count: 16 - value.utf8.count))
        }
        let symbol = Data("\0__ZNSt3__119piecewise_constructE\0".utf8)
        let imageSize = needsCxx ? 8208 + symbol.count : 12288
        let commandBytes = 152 + 24 + (needsCxx ? 24 : 0) + (cryptid == nil ? 0 : 24)
        let sectionOffset = headerPadding ? 4096 : 32 + commandBytes
        u32(0xfeedfacf); u32(0x0100_000c); u32(0); u32(2)
        u32(UInt32(2 + (needsCxx ? 1 : 0) + (cryptid == nil ? 0 : 1)))
        u32(UInt32(commandBytes)); u32(0); u32(0)
        // __TEXT and one section make the header padding boundary explicit.
        u32(0x19); u32(152); name("__TEXT")
        u64(0x1_0000_0000); u64(0x3000); u64(0); u64(UInt64(imageSize))
        u32(7); u32(5); u32(1); u32(0)
        name("__text"); name("__TEXT")
        u64(0x1_0000_0000 + UInt64(sectionOffset)); u64(8)
        u32(UInt32(sectionOffset)); u32(2); u32(0); u32(0)
        u32(0x8000_0400); u32(0); u32(0); u32(0)
        u32(0x32); u32(24); u32(platform); u32(0x000f_0000); u32(0x001a_0100); u32(0)
        if needsCxx {
            u32(2); u32(24); u32(8192); u32(1); u32(8208); u32(UInt32(symbol.count))
        }
        if let cryptid {
            u32(0x2C); u32(24); u32(UInt32(sectionOffset)); u32(8); u32(cryptid); u32(0)
        }
        data.append(Data(count: imageSize - data.count))
        if needsCxx {
            var symbols = Data([1, 0, 0, 0, 1, 0, 0, 0])
            symbols.append(Data(count: 8))
            data.replaceSubrange(8192..<8208, with: symbols)
            data.replaceSubrange(8208..<(8208 + symbol.count), with: symbol)
        }
        return data
    }
}
