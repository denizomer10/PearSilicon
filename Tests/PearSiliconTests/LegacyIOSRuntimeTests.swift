import Foundation
import Testing

@testable import PearSilicon

struct LegacyIOSBinaryTests {
    /// Writes a Mach-O header with the given magic and, for fat files, arch table.
    private func writeImage(
        magic: [UInt8], archs: [(cpu: UInt32, subtype: UInt32)] = [], to directory: URL
    ) throws -> URL {
        var data = magic
        if !archs.isEmpty {
            func be(_ value: UInt32) -> [UInt8] {
                [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            }
            data += be(UInt32(archs.count))
            for arch in archs {
                data += be(arch.cpu) + be(arch.subtype)
                data += be(0)  // offset
                data += be(0)  // size
                data += be(0)  // align
            }
        } else {
            data += Array(repeating: 0, count: 28)
        }
        let url = directory.appendingPathComponent("image-\(UUID().uuidString)")
        try Data(data).write(to: url)
        return url
    }

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-binary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private static let arm: UInt32 = 12
    private static let arm64: UInt32 = 0x0100_000C

    @Test func thin32BitIsLegacy() throws {
        try withTemporaryDirectory { directory in
            let url = try writeImage(magic: [0xCE, 0xFA, 0xED, 0xFE], to: directory)
            #expect(LegacyIOSBinary.isLegacy32Bit(executableAt: url))
        }
    }

    @Test func thin64BitIsNotLegacy() throws {
        try withTemporaryDirectory { directory in
            let url = try writeImage(magic: [0xCF, 0xFA, 0xED, 0xFE], to: directory)
            #expect(!LegacyIOSBinary.isLegacy32Bit(executableAt: url))
        }
    }

    @Test func fatWithOnlyArmIsLegacy() throws {
        try withTemporaryDirectory { directory in
            let url = try writeImage(
                magic: [0xCA, 0xFE, 0xBA, 0xBE],
                archs: [(Self.arm, 9), (Self.arm, 6)],
                to: directory
            )
            #expect(LegacyIOSBinary.isLegacy32Bit(executableAt: url))
        }
    }

    @Test func fatWithArmAndArm64IsNotLegacy() throws {
        try withTemporaryDirectory { directory in
            let url = try writeImage(
                magic: [0xCA, 0xFE, 0xBA, 0xBE],
                archs: [(Self.arm, 9), (Self.arm64, 0)],
                to: directory
            )
            #expect(!LegacyIOSBinary.isLegacy32Bit(executableAt: url))
        }
    }

    @Test func fat64WithOnlyArm64IsNotLegacy() throws {
        try withTemporaryDirectory { directory in
            var data: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBF]
            func be(_ value: UInt32) -> [UInt8] {
                [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            }
            func be64(_ value: UInt64) -> [UInt8] {
                be(UInt32(value >> 32 & 0xFFFF_FFFF)) + be(UInt32(value & 0xFFFF_FFFF))
            }
            data += be(1)
            data += be(Self.arm64) + be(0) + be64(0) + be64(0) + be(0) + be(0)
            let url = directory.appendingPathComponent("fat64")
            try Data(data).write(to: url)
            #expect(!LegacyIOSBinary.isLegacy32Bit(executableAt: url))
        }
    }

    @Test func missingOrTruncatedFileIsNotLegacy() throws {
        try withTemporaryDirectory { directory in
            #expect(!LegacyIOSBinary.isLegacy32Bit(executableAt: directory.appendingPathComponent("absent")))
            let truncated = directory.appendingPathComponent("truncated")
            try Data([0xCA, 0xFE]).write(to: truncated)
            #expect(!LegacyIOSBinary.isLegacy32Bit(executableAt: truncated))
        }
    }
}

struct LegacyRuntimeTests {
    private static func locate(
        environment: [String: String] = [:], supportRoot: URL, home: URL
    ) -> LegacyRuntime? {
        LegacyRuntime.locate(
            environment: environment,
            supportRoot: supportRoot,
            currentDirectory: home.deletingLastPathComponent(),
            resourceRoot: nil,
            homeDirectory: home
        )
    }

    @Test func missingEngineReportsNil() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-engine-\(UUID().uuidString)", isDirectory: true)
        #expect(Self.locate(supportRoot: root, home: root) == nil)
    }

    @Test func engineWithoutAngleIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-no-angle-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PearLegacyEngine", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = home.appendingPathComponent("touchHLE")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(Self.locate(supportRoot: root, home: root) == nil)
    }

    @Test func engineWithAngleIsFound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PearLegacyEngine", isDirectory: true)
        let angle = home.appendingPathComponent("touchHLE_dylibs/angle", isDirectory: true)
        try FileManager.default.createDirectory(at: angle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = home.appendingPathComponent("touchHLE")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data().write(to: angle.appendingPathComponent("libEGL.dylib"))

        let runtime = try #require(Self.locate(supportRoot: root, home: root))
        #expect(runtime.executableURL.lastPathComponent == "touchHLE")
        #expect(runtime.angleLibraryURL.resolvingSymlinksInPath().path.hasSuffix("touchHLE_dylibs/angle"))
    }

    @Test func environmentOverrideWins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-override-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("custom-engine", isDirectory: true)
        let angle = home.appendingPathComponent("touchHLE_dylibs/angle", isDirectory: true)
        try FileManager.default.createDirectory(at: angle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = home.appendingPathComponent("touchHLE")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data().write(to: angle.appendingPathComponent("libEGL.dylib"))

        let runtime = try #require(
            Self.locate(
                environment: [LegacyRuntime.environmentOverride: home.path],
                supportRoot: root,
                home: root
            )
        )
        #expect(runtime.homeURL.path == home.resolvingSymlinksInPath().path)
    }
}
