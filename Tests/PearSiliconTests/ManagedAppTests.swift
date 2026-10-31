import Darwin
import Foundation
import XCTest
@testable import PearSilicon

final class ManagedAppTests: XCTestCase {
    func testMacImportCopiesBundleAndSigningBytesWithoutPreparingOrCreatingOtherPlatforms() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        let framework = source.appendingPathComponent("Contents/Frameworks/Fixture.framework")
        try fixture.write(Data("framework".utf8), to: framework.appendingPathComponent("Versions/A/Fixture"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Fixture").path, withDestinationPath: "Versions/Current/Fixture")
        let before = try fixture.snapshot(source)
        XCTAssertFalse(ManagedAppFiles.exists(fixture.library))

        let entry = try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library)

        XCTAssertEqual(entry.platform, .macOS)
        XCTAssertEqual(entry.manifest.id, "com.pearsilicon.fixture")
        XCTAssertEqual(entry.displayName, "Fixture App")
        XCTAssertEqual(entry.manifest.version, "2.3")
        XCTAssertEqual(entry.manifest.payloadPath, "Payload/Fixture.app")
        XCTAssertNil(entry.manifest.wineEngineID)
        XCTAssertNil(entry.manifest.runtimeRevision)
        XCTAssertFalse(entry.manifest.metalHUDEnabled)
        XCTAssertEqual(try fixture.snapshot(source), before)
        XCTAssertEqual(try fixture.snapshot(entry.payloadURL), before)
        XCTAssertTrue(ManagedAppFiles.exists(entry.dataURL.appendingPathComponent("tmp")))
        XCTAssertTrue(ManagedAppFiles.exists(entry.prefixURL))
        XCTAssertTrue(LibraryPath.isInside(entry.payloadURL, root: entry.directoryURL))
        XCTAssertEqual(try JSONDecoder().decode(LibraryManifest.self, from: Data(contentsOf: entry.manifestURL)), entry.manifest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path), [LibraryPlatform.macOS.rawValue])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: entry.directoryURL.deletingLastPathComponent().path), [entry.manifest.id])
    }

    func testMacCopyPreservesExtendedAttributesWithoutChangingSource() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        let attribute = "com.pearsilicon.portable-test"
        let expected = Data("preserve bundle metadata".utf8)
        let result = expected.withUnsafeBytes {
            setxattr(source.path, attribute, $0.baseAddress, $0.count, 0, 0)
        }
        guard result == 0 else { throw XCTSkip("Fixture filesystem does not support extended attributes") }
        func value(at url: URL) throws -> Data {
            let length = getxattr(url.path, attribute, nil, 0, 0, 0)
            guard length >= 0 else { throw ManagedAppFiles.posix(url) }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes {
                getxattr(url.path, attribute, $0.baseAddress, $0.count, 0, 0)
            }
            guard read == length else { throw ManagedAppFiles.posix(url) }
            return data
        }
        let entry = try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library)
        XCTAssertEqual(try value(at: entry.payloadURL), expected)
        XCTAssertEqual(try value(at: source), expected)
    }

    func testNonMacAndMalformedMainExecutablesFailBeforeCreatingLibrary() throws {
        for platform: UInt32 in [2, 6, 7, 11] {
            let fixture = try ManagedAppTestFixture()
            defer { fixture.remove() }
            let source = try fixture.macBundle(platform: platform)
            let before = try fixture.snapshot(source)
            XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library))
            XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
            XCTAssertEqual(try fixture.snapshot(source), before)
        }
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: source.appendingPathComponent("Contents/MacOS/Fixture"))
        XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library))
        XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
    }

    func testAllUniversalSlicesMustBeNativeMacExecutables() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        let binary = source.appendingPathComponent("Contents/MacOS/Fixture")
        try ManagedAppTestFixture.universal([
            ManagedAppTestFixture.machO(cpu: 0x0100000c), ManagedAppTestFixture.machO(cpu: 0x01000007)
        ]).write(to: binary)
        XCTAssertNoThrow(try ManagedExecutable.validateMacOS(binary))
        try ManagedAppTestFixture.universal([
            ManagedAppTestFixture.machO(), ManagedAppTestFixture.machO(platform: 2, cpu: 0x01000007)
        ]).write(to: binary)
        XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library))
        XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
    }

    func testUnsafeBundleAndExecutableIdentifiersAndIOSMetadataAreRejected() throws {
        let cases: [(String, Any)] = [
            ("CFBundleIdentifier", "../escape"), ("CFBundleIdentifier", "com..example"),
            ("CFBundleIdentifier", "com.example; command"), ("CFBundleExecutable", "../Fixture"),
            ("CFBundleExecutable", "/bin/sh"), ("CFBundleExecutable", "bad\\name"),
            ("LSRequiresIPhoneOS", true), ("CFBundleSupportedPlatforms", ["iPhoneOS"]),
            ("DTPlatformName", "iphonesimulator")
        ]
        for (key, value) in cases {
            let fixture = try ManagedAppTestFixture()
            defer { fixture.remove() }
            let source = try fixture.macBundle()
            try fixture.changePlist(in: source, key: key, value: value)
            XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library), key)
            XCTAssertFalse(ManagedAppFiles.exists(fixture.library), key)
        }
    }

    func testExistingEntryIsNeverOverwrittenIncludingItsData() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        let service = ManagedAppService()
        let entry = try service.importMacApp(from: source, libraryRoot: fixture.library)
        try Data("save".utf8).write(to: entry.dataURL.appendingPathComponent("save.bin"))
        let before = try fixture.snapshot(entry.directoryURL)

        XCTAssertThrowsError(try service.importMacApp(from: source, libraryRoot: fixture.library)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        XCTAssertEqual(try fixture.snapshot(entry.directoryURL), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: entry.directoryURL.deletingLastPathComponent().path), [entry.manifest.id])
    }

    func testExternalAbsoluteSymlinksAndHardlinksAreRejectedWithoutChangingTheirTargets() throws {
        for hardlink in [false, true] {
            let fixture = try ManagedAppTestFixture()
            defer { fixture.remove() }
            let source = try fixture.macBundle()
            let outside = fixture.root.appendingPathComponent("outside.bin")
            let sentinel = Data("untouched".utf8)
            try sentinel.write(to: outside)
            let link = source.appendingPathComponent("Contents/Resources/escape")
            if hardlink {
                try FileManager.default.linkItem(at: outside, to: link)
            } else {
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
            }
            XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library))
            XCTAssertEqual(try Data(contentsOf: outside), sentinel)
            XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
        }
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("Contents/Resources/absoluteInternal").path,
            withDestinationPath: source.appendingPathComponent("Contents/MacOS/Fixture").path
        )
        XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library))
    }

    func testSymlinkedLibraryOrPlatformCannotRedirectAnImport() throws {
        for linkRoot in [false, true] {
            let fixture = try ManagedAppTestFixture()
            defer { fixture.remove() }
            let source = try fixture.macBundle()
            let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
            try ManagedAppFiles.makeDirectory(outside)
            try Data("sentinel".utf8).write(to: outside.appendingPathComponent("sentinel"))
            if !linkRoot { try ManagedAppFiles.makeDirectory(fixture.library) }
            let link = linkRoot ? fixture.library : fixture.library.appendingPathComponent(LibraryPlatform.macOS.rawValue)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
            let before = try fixture.snapshot(outside)
            XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: fixture.library))
            XCTAssertEqual(try fixture.snapshot(outside), before)
        }
    }

    func testSymlinkInManagedRootAncestorsCannotRedirectAnImport() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try ManagedAppFiles.makeDirectory(outside)
        let pivot = fixture.root.appendingPathComponent("Pivot", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: pivot.path, withDestinationPath: outside.path)
        let destination = pivot.appendingPathComponent("Library", isDirectory: true)
        XCTAssertThrowsError(try ManagedAppService().importMacApp(from: source, libraryRoot: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testFailedTransactionRemovesStagingAndLazilyCreatedPlatform() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        enum Expected: Error { case failure }
        XCTAssertThrowsError(try ManagedAppFiles.install(root: fixture.library, folder: "mac-apps", id: "test") { stage, _ in
            try Data("partial".utf8).write(to: stage.appendingPathComponent("partial"))
            throw Expected.failure
        })
        XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
    }

    func testExclusiveCommitRejectsDestinationThatAppearsAfterPreflight() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let destination = fixture.library.appendingPathComponent("wine-apps/Game")
        XCTAssertThrowsError(try ManagedAppFiles.install(root: fixture.library, folder: "wine-apps", id: "Game") { stage, final in
            try Data("new".utf8).write(to: stage.appendingPathComponent("new"))
            try ManagedAppFiles.makeDirectory(final)
            try Data("concurrent owner's data".utf8).write(to: final.appendingPathComponent("save"))
        })
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("save"), encoding: .utf8), "concurrent owner's data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["Game"])
    }

    func testWindowsFolderCopiesDependenciesAndRelativeExecutableWithPrivateDataAndPrefix() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.windowsFolder()
        try fixture.write(Data("dll".utf8), to: source.appendingPathComponent("bin/support.dll"))
        try fixture.write(Data("assets".utf8), to: source.appendingPathComponent("assets/level.dat"))
        let before = try fixture.snapshot(source)
        let entry = try ManagedAppService().importWindowsFolder(
            from: source, executablePath: "bin/Game.exe", libraryRoot: fixture.library,
            engineID: "community-test", displayName: "My Game"
        )
        XCTAssertEqual(entry.platform, .wine)
        XCTAssertEqual(entry.displayName, "My Game")
        XCTAssertEqual(entry.manifest.payloadPath, "Payload/Program/bin/Game.exe")
        XCTAssertEqual(entry.manifest.wineEngineID, "community-test")
        XCTAssertEqual(try fixture.snapshot(entry.directoryURL.appendingPathComponent("Payload/Program")), before)
        XCTAssertEqual(try fixture.snapshot(source), before)
        XCTAssertTrue(LibraryPath.isInside(entry.prefixURL, root: entry.directoryURL))
        XCTAssertTrue(LibraryPath.isInside(entry.dataURL, root: entry.directoryURL))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.library.path), ["wine-apps"])
        XCTAssertEqual(try JSONDecoder().decode(LibraryManifest.self, from: Data(contentsOf: entry.manifestURL)), entry.manifest)
    }

    func testExecutableOnlyImportNeverCopiesAnUnselectedSiblingDirectory() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let folder = try fixture.windowsFolder()
        try fixture.write(Data("private sibling".utf8), to: folder.appendingPathComponent("bin/private.txt"))
        let entry = try ManagedAppService().importWindowsExecutable(
            from: folder.appendingPathComponent("bin/Game.exe"), libraryRoot: fixture.library, engineID: "test"
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: entry.payloadURL.deletingLastPathComponent().path), ["Game.exe"])
        XCTAssertTrue(ManagedAppService.windowsExecutableOnlyImportHint.contains("just this .exe"))
        XCTAssertTrue(ManagedAppService.windowsExecutableOnlyImportHint.contains("folder"))
    }

    func testPEAdmissionRejectsDisguisedFilesDLLsDriversAndTruncatedSections() throws {
        var truncatedSection = ManagedAppTestFixture.pe()
        ManagedAppTestFixture.put32(0xfffffff0, into: &truncatedSection, at: 392 + 20)
        var badSignature = ManagedAppTestFixture.pe()
        badSignature[128] = 0
        for data in [Data("not a program".utf8), ManagedAppTestFixture.pe(dll: true),
                     ManagedAppTestFixture.pe(subsystem: 1), truncatedSection, badSignature] {
            let fixture = try ManagedAppTestFixture()
            defer { fixture.remove() }
            let source = fixture.root.appendingPathComponent("Game.exe")
            try data.write(to: source)
            XCTAssertThrowsError(try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: fixture.library, engineID: "test"))
            XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
        }
    }

    func testWindowsExecutablePathMustBeSafeRelativeAndInsideSelectedFolder() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let source = try fixture.windowsFolder()
        for path in ["../Game.exe", "/bin/Game.exe", "bin/../bin/Game.exe", "C:\\Game.exe", "bin//Game.exe"] {
            XCTAssertThrowsError(try ManagedAppService().importWindowsFolder(
                from: source, executablePath: path, libraryRoot: fixture.library, engineID: "test"
            ))
        }
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("escape.exe").path,
            withDestinationPath: source.appendingPathComponent("bin/Game.exe").path
        )
        XCTAssertThrowsError(try ManagedAppService().importWindowsFolder(
            from: source, executablePath: "escape.exe", libraryRoot: fixture.library, engineID: "test"
        ))
        XCTAssertFalse(ManagedAppFiles.exists(fixture.library))
    }

    func testMacLaunchPlanUsesTheNativeExecutableWithPrivateHomeAndCleanEnvironment() throws {
        let fixture = try ManagedAppTestFixture(name: "quoted-\"-path")
        defer { fixture.remove() }
        let source = try fixture.macBundle()
        let service = ManagedAppService()
        let entry = try service.importMacApp(from: source, libraryRoot: fixture.library)
        let plan = try service.launchConfiguration(for: entry, metalHUDEnabled: true)
        XCTAssertEqual(
            plan.executableURL.path,
            entry.payloadURL.appendingPathComponent("Contents/MacOS/Fixture").path
        )
        XCTAssertEqual(plan.arguments, [])
        XCTAssertTrue(plan.sandboxProfile.isEmpty, "Mac apps run natively, without sandbox-exec")
        XCTAssertFalse(plan.executableURL.path.contains("sandbox-exec"))
        let environment = ManagedAppService.environment(for: entry, metalHUDEnabled: true, inherited: [
            "HOME": "/host", "TMPDIR": "/host-tmp", "PATH": "/untrusted", "LANG": "en_US.UTF-8",
            "DYLD_INSERT_LIBRARIES": "/inject", "DYLD_LIBRARY_PATH": "/inject",
            "PEAR_HOME_DIR": "/host", "PEAR_HOST_SOCKET": "/host/socket", "WINEPREFIX": "/shared",
            "MTL_HUD_ENABLED": "0", "SHELL": "/bin/sh"
        ])
        XCTAssertEqual(environment["HOME"], entry.dataURL.path)
        XCTAssertEqual(environment["CFFIXED_USER_HOME"], entry.dataURL.path)
        XCTAssertEqual(environment["TMPDIR"], entry.dataURL.appendingPathComponent("tmp").path + "/")
        XCTAssertEqual(environment["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(environment["WINEPREFIX"])
        XCTAssertNil(environment["SHELL"])
        XCTAssertFalse(environment.keys.contains { $0.hasPrefix("DYLD_") || $0.hasPrefix("PEAR_") })
    }

    func testLaunchPlanRejectsDataSymlinkAndHardlinkedLogWithoutChangingHostFile() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let entry = try ManagedAppService().importMacApp(from: fixture.macBundle(), libraryRoot: fixture.library)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: entry.dataURL.appendingPathComponent("launch.log"))
        XCTAssertThrowsError(try ManagedAppService().launchConfiguration(for: entry))
        XCTAssertThrowsError(try ManagedAppFiles.openPrivateLog(entry.dataURL.appendingPathComponent("launch.log")))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
        try FileManager.default.removeItem(at: entry.dataURL)
        try FileManager.default.createSymbolicLink(atPath: entry.dataURL.path, withDestinationPath: fixture.imports.path)
        let before = try fixture.snapshot(fixture.imports)
        XCTAssertThrowsError(try ManagedAppService().launchConfiguration(for: entry))
        XCTAssertEqual(try fixture.snapshot(fixture.imports), before)
    }

    func testPrefixSanitizerRemovesHostMappingsNotTheirTargetsAndPreservesInternalCDrive() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let entry = try ManagedAppService().importWindowsFolder(
            from: fixture.windowsFolder(), executablePath: "bin/Game.exe", libraryRoot: fixture.library, engineID: "test"
        )
        let devices = entry.prefixURL.appendingPathComponent("dosdevices")
        try ManagedAppFiles.makeDirectory(devices)
        try ManagedAppFiles.makeDirectory(entry.prefixURL.appendingPathComponent("drive_c"))
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("z:").path, withDestinationPath: "/")
        let outside = fixture.root.appendingPathComponent("private-sentinel")
        try Data("do not change".utf8).write(to: outside)
        let other = entry.prefixURL.appendingPathComponent("host-documents")
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: outside.path)
        XCTAssertThrowsError(try ManagedAppFiles.validateTree(entry.directoryURL))

        try ManagedAppService.sanitizeWinePrefix(for: entry)

        XCTAssertFalse(ManagedAppFiles.exists(devices.appendingPathComponent("z:")))
        XCTAssertFalse(ManagedAppFiles.exists(other))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: devices.appendingPathComponent("c:").path), "../drive_c")
        XCTAssertEqual(try Data(contentsOf: outside), Data("do not change".utf8))
        XCTAssertNoThrow(try ManagedAppFiles.validateTree(entry.directoryURL))
    }

    func testPrefixRootSymlinkAndNonLinkZMappingFailClosed() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let entry = try ManagedAppService().importWindowsFolder(
            from: fixture.windowsFolder(), executablePath: "bin/Game.exe", libraryRoot: fixture.library, engineID: "test"
        )
        let devices = entry.prefixURL.appendingPathComponent("dosdevices")
        try ManagedAppFiles.makeDirectory(devices)
        try Data("unknown data".utf8).write(to: devices.appendingPathComponent("z:"))
        XCTAssertThrowsError(try ManagedAppService.sanitizeWinePrefix(for: entry))
        XCTAssertEqual(try Data(contentsOf: devices.appendingPathComponent("z:")), Data("unknown data".utf8))
        try FileManager.default.removeItem(at: entry.prefixURL)
        try FileManager.default.createSymbolicLink(atPath: entry.prefixURL.path, withDestinationPath: fixture.imports.path)
        let before = try fixture.snapshot(fixture.imports)
        XCTAssertThrowsError(try ManagedAppService.sanitizeWinePrefix(for: entry))
        XCTAssertEqual(try fixture.snapshot(fixture.imports), before)
    }

    func testRecursiveFolderDestinationIsRejectedBeforeCreatingIt() throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let folder = try fixture.windowsFolder()
        let nested = folder.appendingPathComponent("Library")
        XCTAssertThrowsError(try ManagedAppService().importWindowsFolder(
            from: folder, executablePath: "bin/Game.exe", libraryRoot: nested, engineID: "test"
        ))
        XCTAssertFalse(ManagedAppFiles.exists(nested))
    }
}

/// All inputs are synthetic, non-runnable fixtures beneath one private temp
/// directory. Neither suite touches installed applications or starts a GUI app.
struct ManagedAppTestFixture {
    let root: URL
    let imports: URL
    let library: URL
    let enginesRoot: URL

    init(name: String = "fixture") throws {
        root = Self.canonical(FileManager.default.temporaryDirectory)
            .appendingPathComponent("pear-managed-\(name)-\(UUID().uuidString)", isDirectory: true)
        imports = root.appendingPathComponent("Imports", isDirectory: true)
        library = root.appendingPathComponent("Library", isDirectory: true)
        enginesRoot = root.appendingPathComponent("Engines", isDirectory: true)
        try ManagedAppFiles.makeDirectory(root)
        try ManagedAppFiles.makeDirectory(imports)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func macBundle(name: String = "Fixture.app", platform: UInt32 = 1) throws -> URL {
        let bundle = imports.appendingPathComponent(name, isDirectory: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.pearsilicon.fixture", "CFBundleExecutable": "Fixture",
            "CFBundleDisplayName": "Fixture App", "CFBundleShortVersionString": "2.3",
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["MacOSX"]
        ]
        try write(try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: bundle.appendingPathComponent("Contents/Info.plist"))
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
        try write(Self.machO(platform: platform), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try write(Data("synthetic signing metadata: do not rewrite".utf8), to: bundle.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        try write(Data("resource".utf8), to: bundle.appendingPathComponent("Contents/Resources/resource.dat"))
        return bundle
    }

    func changePlist(in bundle: URL, key: String, value: Any) throws {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
        plist[key] = value
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    func windowsFolder(name: String = "Game") throws -> URL {
        let folder = imports.appendingPathComponent(name, isDirectory: true)
        try write(Self.pe(), to: folder.appendingPathComponent("bin/Game.exe"))
        return folder
    }

    func engineFolder(name: String = "Engine Source") throws -> URL {
        let folder = imports.appendingPathComponent(name, isDirectory: true)
        let executable = folder.appendingPathComponent("bin/wine64")
        try write(Self.machO(), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try write(Data("runtime library".utf8), to: folder.appendingPathComponent("lib/runtime.dat"))
        return folder
    }

    static func canonical(_ url: URL) -> URL {
        // Foundation deliberately leaves /var unresolved; realpath matches what
        // directory enumeration and the managed services report.
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    func snapshot(_ directory: URL) throws -> [String: Data] {
        let directory = Self.canonical(directory)
        var result: [String: Data] = [:]
        try ManagedAppFiles.walk(directory) { url, status in
            let path = String(url.path.dropFirst(directory.path.count + 1))
            if status.st_mode & S_IFMT == S_IFLNK {
                result[path] = Data(("link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))).utf8)
            } else if status.st_mode & S_IFMT == S_IFREG {
                result[path] = try Data(contentsOf: url)
            } else {
                result[path] = Data("directory".utf8)
            }
        }
        return result
    }

    static func machO(platform: UInt32 = 1, cpu: UInt32 = 0x0100000c) -> Data {
        var data = Data(count: 56)
        put32(0xfeedfacf, into: &data, at: 0)
        put32(cpu, into: &data, at: 4)
        put32(2, into: &data, at: 12)
        put32(1, into: &data, at: 16)
        put32(24, into: &data, at: 20)
        put32(0x32, into: &data, at: 32)
        put32(24, into: &data, at: 36)
        put32(platform, into: &data, at: 40)
        put32(0x000f0000, into: &data, at: 44)
        put32(0x001a0000, into: &data, at: 48)
        return data
    }

    static func universal(_ slices: [Data]) -> Data {
        let tableSize = 8 + slices.count * 20
        var data = Data(count: tableSize)
        put32(0xcafebabe, into: &data, at: 0, little: false)
        put32(UInt32(slices.count), into: &data, at: 4, little: false)
        var offset = tableSize
        for (index, slice) in slices.enumerated() {
            put32(UInt32(offset), into: &data, at: 8 + index * 20 + 8, little: false)
            put32(UInt32(slice.count), into: &data, at: 8 + index * 20 + 12, little: false)
            data.append(slice)
            offset += slice.count
        }
        return data
    }

    static func pe(dll: Bool = false, subsystem: UInt16 = 2) -> Data {
        var data = Data(count: 1_024)
        data[0] = 0x4d; data[1] = 0x5a
        put32(128, into: &data, at: 60)
        data[128] = 0x50; data[129] = 0x45
        put16(0x8664, into: &data, at: 132)
        put16(1, into: &data, at: 134)
        put16(240, into: &data, at: 148)
        put16(dll ? 0x2002 : 0x0002, into: &data, at: 150)
        put16(0x20b, into: &data, at: 152)
        put32(0x2000, into: &data, at: 152 + 56)
        put32(512, into: &data, at: 152 + 60)
        put16(subsystem, into: &data, at: 152 + 68)
        put32(16, into: &data, at: 152 + 108)
        put32(512, into: &data, at: 392 + 16)
        put32(512, into: &data, at: 392 + 20)
        return data
    }

    static func put16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func put32(_ value: UInt32, into data: inout Data, at offset: Int, little: Bool = true) {
        for index in 0..<4 {
            let shift = (little ? index : 3 - index) * 8
            data[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }
}
