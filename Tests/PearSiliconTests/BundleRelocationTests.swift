import Foundation
import XCTest
@testable import PearSilicon

/// Relocation rewrites the absolute compatibility paths an installed app
/// received at install time, so moving storage does not leave its runtime and
/// support dylibs pointing at the old disk.
final class BundleRelocationTests: XCTestCase {

    func testAbsoluteLoadAndRPathReferencesFollowTheNewRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer()

        try installer.relocateInstalledBundle(
            at: fixture.stagedBundle, from: fixture.originalBundle, to: fixture.targetBundle
        )

        let paths = try fixture.paths(of: fixture.stagedExecutable)
        XCTAssertEqual(
            paths.dependencies,
            [fixture.targetFrameworks.appendingPathComponent("libPearRuntime.dylib").path]
        )
        XCTAssertEqual(paths.rpaths, [fixture.targetFrameworks.path])
        for path in paths.dependencies + paths.rpaths {
            XCTAssertFalse(path.hasPrefix(fixture.oldRoot.path + "/"), "still points at old root: \(path)")
            XCTAssertFalse(path.contains(".relocation-staging-"), "left a staging path: \(path)")
        }
        // The installed copy is never modified by a move.
        XCTAssertEqual(try Data(contentsOf: fixture.originalExecutable), fixture.originalBytes)
    }

    func testLongerDestinationFallsBackToInstallNameToolAndStillRebases() throws {
        let fixture = try Fixture(oldRootName: "a", newRootName: "much-longer-external-volume")
        defer { fixture.remove() }
        let installer = fixture.installer()

        try installer.relocateInstalledBundle(
            at: fixture.stagedBundle, from: fixture.originalBundle, to: fixture.targetBundle
        )

        let paths = try fixture.paths(of: fixture.stagedExecutable)
        XCTAssertEqual(
            paths.dependencies.map { $0.hasPrefix(fixture.newRoot.path) },
            [true]
        )
        XCTAssertTrue(paths.rpaths.allSatisfy { $0.hasPrefix(fixture.newRoot.path) })
    }

    func testUnrelatedSystemAndRPathsArePreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try BinaryPatcher.addRPath(at: fixture.stagedExecutable, path: "@executable_path/Frameworks")
        let installer = fixture.installer()

        try installer.relocateInstalledBundle(
            at: fixture.stagedBundle, from: fixture.originalBundle, to: fixture.targetBundle
        )

        let paths = try fixture.paths(of: fixture.stagedExecutable)
        XCTAssertTrue(paths.rpaths.contains("@executable_path/Frameworks"))
        XCTAssertEqual(paths.rpaths.filter { $0.hasPrefix(fixture.oldRoot.path) }, [])
    }

    func testRelocationRejectsAStagedBundleStillPointingAtTheOldRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // No rebase target: rewriting against an unrelated root must fail the
        // final invariant rather than commit a broken copy.
        XCTAssertThrowsError(
            try fixture.installer().relocateInstalledBundle(
                at: fixture.stagedBundle,
                from: fixture.root.appendingPathComponent("Elsewhere/com.example.game.app"),
                to: fixture.targetBundle
            )
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let oldRoot: URL
        let newRoot: URL
        let originalBundle: URL
        let stagedBundle: URL
        let targetBundle: URL
        var originalExecutable: URL { originalBundle.appendingPathComponent("Synthetic") }
        var stagedExecutable: URL { stagedBundle.appendingPathComponent("Synthetic") }
        var targetFrameworks: URL { targetBundle.appendingPathComponent("Frameworks") }
        var oldFrameworks: URL { originalBundle.appendingPathComponent("Frameworks") }
        var originalBytes: Data { (try? Data(contentsOf: originalExecutable)) ?? Data() }

        init(oldRootName: String = "OldDisk", newRootName: String = "NewDisk") throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("pear-relocation-\(UUID().uuidString)")
            oldRoot = root.appendingPathComponent(oldRootName)
            newRoot = root.appendingPathComponent(newRootName)
            originalBundle = oldRoot.appendingPathComponent("Applications/com.example.game.app")
            targetBundle = newRoot.appendingPathComponent("Applications/com.example.game.app")
            stagedBundle = root.appendingPathComponent(
                ".relocation-staging-\(UUID().uuidString)/Applications/com.example.game.app"
            )
            try FileManager.default.createDirectory(
                at: stagedBundle.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            for bundle in [originalBundle] {
                try FileManager.default.createDirectory(
                    at: bundle.appendingPathComponent("Frameworks"), withIntermediateDirectories: true
                )
            }
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.example.game", "CFBundleExecutable": "Synthetic",
                "CFBundleName": "Synthetic", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: originalBundle.appendingPathComponent("Info.plist"))
            let executable = Self.machO()
            try executable.write(to: originalExecutable)
            try executable.write(
                to: originalBundle.appendingPathComponent("Frameworks/libPearRuntime.dylib")
            )
            let frameworks = originalBundle.appendingPathComponent("Frameworks")
            try BinaryPatcher.addLoadDylib(
                at: originalExecutable,
                path: frameworks.appendingPathComponent("libPearRuntime.dylib").path
            )
            try BinaryPatcher.addRPath(at: originalExecutable, path: frameworks.path)

            // The migration copies the installed app as-is, so the staged copy
            // starts with the OLD absolute paths and must be rebased.
            try FileManager.default.copyItem(
                at: originalBundle, to: stagedBundle.deletingLastPathComponent()
                    .appendingPathComponent(originalBundle.lastPathComponent)
            )
        }

        func installer() -> PackageInstaller {
            var tools = PackageInstaller.PreparationTools()
            tools.run = { tool, arguments in
                if tool == "/usr/bin/codesign" { return "" }
                return try Shell.run(tool, arguments)
            }
            return PackageInstaller(libraryURL: stagedBundle, preparationTools: tools)
        }

        func paths(of executable: URL) throws -> (dependencies: [String], rpaths: [String]) {
            let data = try Data(contentsOf: executable)
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

        /// Minimal 64-bit arm64 image with header padding, so load commands can
        /// be added and rewritten exactly like a prepared app binary.
        private static func machO() -> Data {
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
            let imageSize = 12288
            let commandBytes = 152 + 24
            let sectionOffset = 4096
            u32(0xfeedfacf); u32(0x0100_000c); u32(0); u32(2)
            u32(2); u32(UInt32(commandBytes)); u32(0); u32(0)
            u32(0x19); u32(152); name("__TEXT")
            u64(0x1_0000_0000); u64(0x3000); u64(0); u64(UInt64(imageSize))
            u32(7); u32(5); u32(1); u32(0)
            name("__text"); name("__TEXT")
            u64(0x1_0000_0000 + UInt64(sectionOffset)); u64(8)
            u32(UInt32(sectionOffset)); u32(2); u32(0); u32(0)
            u32(0x8000_0400); u32(0); u32(0); u32(0)
            u32(0x32); u32(24); u32(2); u32(0x000f_0000); u32(0x001a_0100); u32(0)
            data.append(Data(count: imageSize - data.count))
            return data
        }
    }
}