import XCTest
@testable import PearSilicon

final class BinaryPatcherTests: XCTestCase {

    /// Builds a minimal thin 64-bit Mach-O image with a single
    /// `LC_BUILD_VERSION` load command.
    private func makeMachO(platform: UInt32) -> Data {
        var data = Data()

        func append(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }

        // mach_header_64
        append(0xFEEDFACF)  // magic
        append(0)           // cputype
        append(0)           // cpusubtype
        append(0)           // filetype
        append(1)           // ncmds
        append(24)          // sizeofcmds
        append(0)           // flags
        append(0)           // reserved

        // build_version_command
        append(0x32)        // cmd = LC_BUILD_VERSION
        append(24)          // cmdsize
        append(platform)    // platform
        append(0x000F0000)  // minos
        append(0x001A0100)  // sdk
        append(0)           // ntools

        return data
    }

    func testPatchesBuildVersionPlatformToMacCatalyst() throws {
        var data = makeMachO(platform: 2) // iOS

        let changed = try BinaryPatcher.patch(&data, platform: 6) // Mac Catalyst
        XCTAssertTrue(changed)

        let platform = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(platform, 6)
    }

    func testLeavesUnknownFilesUntouched() throws {
        var data = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let changed = try BinaryPatcher.patch(&data)
        XCTAssertFalse(changed)
    }

    func testAcceptsDetectionOnValidImage() {
        let data = makeMachO(platform: 2)
        XCTAssertTrue(BinaryPatcher.isMachO64(data))
    }

    func testAddLoadDylibAddsCommand() throws {
        // header + one LC_SEGMENT_64 with no sections, padded with slack.
        var data = Data()
        func u32(_ v: UInt32) {
            data.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                     UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }
        u32(0xFEEDFACF); u32(0); u32(0); u32(0)   // magic, cputype, cpusubtype, filetype
        u32(1)                                     // ncmds
        u32(72)                                    // sizeofcmds (one segment)
        u32(0); u32(0)                             // flags, reserved
        // LC_SEGMENT_64 (72 bytes), nsects = 0
        u32(0x19); u32(72)
        data.append(Data(count: 16))               // segname
        data.append(Data(count: 8 * 4))            // vmaddr, vmsize, fileoff, filesize
        u32(7); u32(5)                             // maxprot, initprot
        u32(0); u32(0)                             // nsects = 0, flags
        data.append(Data(count: 4096 - data.count)) // slack

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pear-runtime-test.bin")
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(try BinaryPatcher.addLoadDylib(at: url, path: "@executable_path/Frameworks/libPearRuntime.dylib"))

        let result = try Data(contentsOf: url)
        let ncmds = result.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        XCTAssertEqual(ncmds, 2)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("libPearRuntime.dylib"))

        // idempotent
        XCTAssertFalse(try BinaryPatcher.addLoadDylib(at: url, path: "@executable_path/Frameworks/libPearRuntime.dylib"))
    }

    /// Validates the patcher against the real extracted binary when available.
    /// Skipped otherwise so the suite stays green on clean checkouts.
    /// Works in memory to avoid file-coordination issues in the test runner.
    func testPatchesRealExtractedBinaryIfPresent() throws {
        let source = URL(fileURLWithPath: "/tmp/pearsilicon/extracted-binary")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no extracted binary present")
        }

        var data = try Data(contentsOf: source)
        XCTAssertTrue(BinaryPatcher.isMachO64(data))
        XCTAssertTrue(try BinaryPatcher.patch(&data), "first patch should change the image")

        // Idempotent: the image is Mac Catalyst now, so a second pass is a no-op.
        XCTAssertFalse(try BinaryPatcher.patch(&data), "second patch should be a no-op")
    }

    // MARK: - Legacy version command

    /// Thin Mach-O whose only version command is the legacy
    /// `LC_VERSION_MIN_IPHONEOS`, with slack for a new load command.
    private func makeMachOWithVersionMin() -> Data {
        var data = Data()
        func u32(_ value: UInt32) {
            data.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
                                     UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
        }
        u32(0xFEEDFACF); u32(0); u32(0); u32(0)  // magic, cputype, cpusubtype, filetype
        u32(1)                                   // ncmds
        u32(16)                                  // sizeofcmds
        u32(0); u32(0)                           // flags, reserved
        u32(0x25); u32(16); u32(0x000B0100); u32(0x000B0100) // LC_VERSION_MIN_IPHONEOS
        data.append(Data(count: 4096 - data.count))
        return data
    }

    func testReplacesVersionMinWithBuildVersion() throws {
        var data = makeMachOWithVersionMin()
        XCTAssertTrue(try BinaryPatcher.patch(&data, platform: 6))

        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        }

        XCTAssertEqual(u32(16), 1, "one command remains")
        XCTAssertEqual(u32(32), 0x32, "it is LC_BUILD_VERSION")
        XCTAssertEqual(u32(40), 6, "platform is Mac Catalyst")

        // The legacy min-version command must not survive.
        let count = Int(u32(16))
        var offset = 32
        for _ in 0..<count {
            let cmd = u32(offset)
            XCTAssertNotEqual(cmd, 0x25)
            XCTAssertNotEqual(cmd, 0x24)
            offset += Int(u32(offset + 4))
        }
    }

    // MARK: - Universal (fat) binaries

    private func makeSlice(magic: UInt32) -> Data {
        var data = Data()
        func u32(_ value: UInt32) {
            data.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
                                     UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
        }
        u32(magic); u32(0); u32(0); u32(0); u32(0); u32(0); u32(0); u32(0)
        data.append(Data(count: 1024 - data.count))
        return data
    }

    /// Fat container holding an armv7 slice (4096) and an arm64 slice (8192).
    private func makeFat() -> Data {
        let armv7 = makeSlice(magic: 0xFEEDFACE)
        let arm64 = makeSlice(magic: 0xFEEDFACF)

        var data = Data()
        func be(_ value: UInt32) {
            data.append(contentsOf: [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                                     UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
        }
        be(0xCAFEBABE); be(2)
        be(12); be(0); be(4096); be(UInt32(armv7.count)); be(12)          // armv7
        be(0x0100_000C); be(0); be(8192); be(UInt32(arm64.count)); be(12) // arm64
        data.append(Data(count: 4096 - data.count))
        data.append(armv7)
        data.append(Data(count: 8192 - data.count))
        data.append(arm64)
        return data
    }

    func testDetectsAndThinsFatBinary() throws {
        let data = makeFat()
        XCTAssertEqual(BinaryPatcher.machO64Offsets(data), [8192])
        XCTAssertTrue(BinaryPatcher.isMachO64(data))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pear-fat-test.bin")
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(try BinaryPatcher.thinToARM64(at: url))
        let thin = try Data(contentsOf: url)
        XCTAssertEqual(thin.count, 1024)
        XCTAssertEqual(thin.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }, 0xFEEDFACF)

        // Already thin: no further change.
        XCTAssertFalse(try BinaryPatcher.thinToARM64(at: url))
    }
}
