import Foundation
import XCTest
@testable import PearSilicon

final class BinaryPatcherTests: XCTestCase {
    private let unavailableClass = "_OBJC_CLASS_$_PHAssetCurationUtilities"

    // MARK: - Basic preparation and encryption

    func testPatchesBuildVersionPlatformToMacCatalyst() throws {
        var data = makeMachO(platform: 2)
        let original = data
        XCTAssertTrue(try BinaryPatcher.patch(&data, platform: 6))
        XCTAssertEqual(u32(data, 40), 6)
        var expected = original
        put(6, at: 40, in: &expected)
        XCTAssertEqual(data, expected, "only the platform word changes")
        XCTAssertFalse(try BinaryPatcher.patch(&data))
    }

    func testLeavesUnknownFilesUntouched() throws {
        for original in [Data(), Data([1, 2, 3]), Data([1, 2, 3, 4, 5, 6, 7, 8])] {
            var data = original
            XCTAssertFalse(try BinaryPatcher.patch(&data))
            XCTAssertEqual(data, original)
        }
    }

    func testAcceptsDetectionOnValidImage() {
        XCTAssertTrue(BinaryPatcher.isMachO64(makeMachO(platform: 2)))
    }

    func testPreflightAcceptsSupportedPlainMetadataWithoutWriting() throws {
        let images = [makeMachO(platform: 2), makeMachO(platform: 6), makeMachOWithVersionMin()]
        for data in images {
            let url = try writeTemporary(data)
            defer { try? FileManager.default.removeItem(at: url) }
            try BinaryPatcher.validateForPreparation(at: url)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testRejectsBothEncryptionCommandsWithoutAnyMutation() throws {
        for kind in [UInt32(0x21), 0x2C] {
            let command = encryption(kind: kind, offset: 4096, size: 64, id: 1)
            let data = sectionedImage(extraCommands: [command])
            try assertUnpreparable(data, containing: ["encrypted", "0x1000", "0x1040", "cryptid 1"])
        }
    }

    func testPlainEncryptionCommandsAndReferencedBytesArePreserved() throws {
        for kind in [UInt32(0x21), 0x2C] {
            let command = encryption(kind: kind, offset: 4096, size: 64, id: 0)
            var data = sectionedImage(extraCommands: [command])
            let original = data
            let url = try writeTemporary(data)
            defer { try? FileManager.default.removeItem(at: url) }
            try BinaryPatcher.validateForPreparation(at: url)
            XCTAssertFalse(BinaryPatcher.hasLegacyGuardMarkers(at: url))
            XCTAssertTrue(try BinaryPatcher.patch(&data))
            let at = try commandOffset(0x32, in: data)
            var expected = original
            put(6, at: at + 8, in: &expected)
            XCTAssertEqual(data, expected)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testNonzeroCryptidIsRejectedEvenForAnEmptyRange() throws {
        let data = sectionedImage(extraCommands: [encryption(kind: 0x2C, offset: 0, size: 0, id: 7)])
        try assertUnpreparable(data, containing: ["encrypted", "cryptid 7", "0x0"])
    }

    func testRejectsInvalidEncryptionRangesWithoutAnyMutation() throws {
        let ranges: [(UInt32, UInt32)] = [(4096, 65), (UInt32.max, 16), (32, 16), (4161, 0)]
        for (offset, size) in ranges {
            let data = sectionedImage(extraCommands: [encryption(kind: 0x2C, offset: offset, size: size, id: 0)])
            try assertUnpreparable(data, containing: ["encryption range"])
        }
    }

    func testRejectsTruncatedEncryptionCommands() throws {
        for kind in [UInt32(0x21), 0x2C] {
            let data = sectionedImage(extraCommands: [words(kind, 16, 0, 0)])
            try assertUnpreparable(data, containing: ["truncated load command"])
        }
    }

    func testRejectsUnpadded20ByteEncryptionInfoInARM64() throws {
        for id in [UInt32(0), 1] {
            let unpadded = words(0x21, 20, 4096, 64, id)
            try assertUnpreparable(sectionedImage(extraCommands: [unpadded]), containing: ["load-command size"])
        }
    }

    func testEncryptionWarningPredicateDoesNotClearCryptid() throws {
        let data = sectionedImage(extraCommands: [encryption(kind: 0x2C, offset: 4096, size: 64, id: 3)])
        let url = try writeTemporary(data)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(BinaryPatcher.hasLegacyGuardMarkers(at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    // MARK: - CPU, platform and bounded load commands

    func testRejectsUnsupportedExplicitPlatformsAndCPUs() throws {
        for platform in [UInt32(1), 3, 4, 7, 99] {
            try assertUnpreparable(makeMachO(platform: platform), containing: ["unsupported", "platform"])
        }
        for cpu in [UInt32(0), 0x0100_0007, 12] {
            var data = makeMachO(platform: 2)
            put(cpu, at: 4, in: &data)
            try assertUnpreparable(data, containing: ["unsupported", "CPU"])
        }
        for subtype in [UInt32(2), 0x8000_0002, 0x8000_0000, 3] {
            let data = makeMachO(platform: 2, subtype: subtype)
            try assertUnpreparable(data, containing: ["unsupported", subtype & 0x00FF_FFFF == 2 ? "ARM64e" : "subtype"])
        }
    }

    func testRejectsUnsupportedLegacyAndMissingOrDuplicatePlatformMetadata() throws {
        for kind in [UInt32(0x24), 0x2F, 0x30] {
            try assertUnpreparable(machO(commands: [words(kind, 16, 0x000F0000, 0x001A0100)]), containing: ["unsupported legacy"])
        }
        try assertUnpreparable(machO(commands: []), containing: ["missing or ambiguous"])
        try assertUnpreparable(machO(commands: [buildVersion(2), buildVersion(6)]), containing: ["ambiguous"])
        var unsupportedType = makeMachO(platform: 2)
        put(0, at: 12, in: &unsupportedType)
        try assertUnpreparable(unsupportedType, containing: ["file type"])
    }

    func testZipperedDylibPreservesBothBuildVersionsInEitherOrder() throws {
        let macOS = words(0x32, 32, 1, 0x000B0000, 0x001B0200, 1, 3, 0x00050000)
        let catalyst = words(0x32, 32, 6, 0x000D0100, 0x001A0100, 1, 3, 0x00060000)
        for commands in [[macOS, catalyst], [catalyst, macOS]] {
            let original = machO(commands: commands, fileType: 6)
            var data = original
            let url = try writeTemporary(original)
            defer { try? FileManager.default.removeItem(at: url) }
            try BinaryPatcher.validateForPreparation(at: url)
            XCTAssertFalse(try BinaryPatcher.patch(&data))
            XCTAssertEqual(data, original)
            XCTAssertFalse(try BinaryPatcher.patchFile(at: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
            assertInvalid({ _ = try BinaryPatcher.patch(&data, platform: 2) }, containing: ["zippered"])
            XCTAssertEqual(data, original)

            let fatURL = try writeTemporary(makeFat([armv7Slice(), original], fat64: true))
            defer { try? FileManager.default.removeItem(at: fatURL) }
            XCTAssertTrue(try BinaryPatcher.patchFile(at: fatURL))
            XCTAssertEqual(try Data(contentsOf: fatURL), original, "thinning must preserve both commands and tool/version fields")
        }
    }

    func testRejectsOtherMultiPlatformCombinationsAndZipperedExecutables() throws {
        let combinations: [[UInt32]] = [[1, 6], [6, 1], [2, 6], [1, 2], [6, 6], [1, 1], [1, 6, 2]]
        for fileType in [UInt32(2), 6, 8] {
            for platforms in combinations {
                if fileType == 6, platforms == [1, 6] || platforms == [6, 1] { continue }
                let commands = platforms.map { buildVersion($0) }
                try assertUnpreparable(machO(commands: commands, fileType: fileType))
            }
        }
        let pair = [buildVersion(1), buildVersion(6)]
        try assertUnpreparable(machO(commands: pair + [words(0x25, 16, 0x000B0100, 0x001A0100)], fileType: 6))
        let encrypted = encryption(kind: 0x2C, offset: 0, size: 0, id: 1)
        try assertUnpreparable(machO(commands: pair + [encrypted], fileType: 6), containing: ["encrypted"])
    }

    func testUnsupportedTargetDoesNotPartiallyPatchData() throws {
        var data = makeMachO(platform: 2)
        let original = data
        assertInvalid({ _ = try BinaryPatcher.patch(&data, platform: 7) }, containing: ["target platform"])
        XCTAssertEqual(data, original)
    }

    func testRejectsTruncatedHeadersAndMalformedCommandBounds() throws {
        try assertUnpreparable(words(0xFEEDFACF), containing: ["truncated"])
        var cases: [Data] = []
        let original = sectionedImage()
        var data = original
        put(UInt32.max, at: 20, in: &data)
        cases.append(data)
        data = original
        put(UInt32.max, at: 16, in: &data)
        cases.append(data)
        data = original
        put(1, at: 16, in: &data)
        cases.append(data)
        for size in [UInt32(0), 10, 20, UInt32.max] {
            data = original
            put(size, at: 36, in: &data)
            cases.append(data)
        }
        data = original
        let build = try commandOffset(0x32, in: data)
        put(1, at: build + 20, in: &data)
        cases.append(data)
        // This command would previously be read beyond sizeofcmds, in payload bytes.
        data = original
        put(152, at: 20, in: &data)
        cases.append(data)
        for malformed in cases { try assertUnpreparable(malformed) }
    }

    func testRejectsSectionsOutsideTheirCommandOrSlice() throws {
        let original = sectionedImage()
        var cases: [Data] = []
        var data = original
        put(2, at: 32 + 64, in: &data)
        cases.append(data)
        data = original
        put(UInt32.max, at: 32 + 72 + 48, in: &data)
        cases.append(data)
        data = original
        put64(UInt64.max, at: 32 + 72 + 40, in: &data)
        cases.append(data)
        data = original
        put(64, at: 32 + 72 + 48, in: &data)
        cases.append(data)
        for malformed in cases { try assertUnpreparable(malformed) }
    }

    func testRejectsMalformedPathCommandsBeforePlatformMutation() throws {
        let invalidOffset = words(0x0C, 24, 24, 0, 0, 0)
        var unterminated = words(0x0C, 32, 24, 0, 0, 0)
        unterminated.append(Data(repeating: 0x41, count: 8))
        for command in [invalidOffset, unterminated] {
            try assertUnpreparable(sectionedImage(extraCommands: [command]))
        }
    }

    // MARK: - Legacy conversion and payload preservation

    func testReplacesVersionMinWithBuildVersion() throws {
        var data = makeMachOWithVersionMin()
        XCTAssertTrue(try BinaryPatcher.patch(&data))
        XCTAssertEqual(u32(data, 16), 1)
        XCTAssertEqual(u32(data, 32), 0x32)
        XCTAssertEqual(u32(data, 40), 6)
        XCTAssertEqual(u32(data, 44), 0x000B0100)
        XCTAssertEqual(u32(data, 48), 0x001A0100)
        XCTAssertFalse(try BinaryPatcher.patch(&data))
    }

    func testLegacyConversionPreservesVersionsInitializersAndPayload() throws {
        var routines = words(0x1A, 72)
        append64(0x1_0000_1000, to: &routines)
        append64(0, to: &routines)
        routines.append(Data(count: 48))
        var data = sectionedImage(legacy: true, extraCommands: [routines])
        let original = data
        XCTAssertTrue(try BinaryPatcher.patch(&data))
        let version = try commandOffset(0x32, in: data)
        XCTAssertEqual(u32(data, version + 12), 0x000B0100)
        XCTAssertEqual(u32(data, version + 16), 0x001A0100)
        XCTAssertEqual(u32(data, 16), u32(original, 16))
        XCTAssertEqual(u32(data, 20), u32(original, 20) + 8)
        let newRoutines = try commandOffset(0x1A, in: data)
        XCTAssertEqual(data.subdata(in: newRoutines..<(newRoutines + 72)), routines)
        XCTAssertEqual(data.subdata(in: 4096..<data.count), original.subdata(in: 4096..<original.count))
        XCTAssertEqual(data.count, original.count)
        XCTAssertFalse(try BinaryPatcher.patch(&data))
    }

    func testLegacyNoSlackFailsWithoutInoutOrFileMutation() throws {
        let original = sectionedImage(legacy: true, headerPadding: false)
        var data = original
        assertInvalid({ _ = try BinaryPatcher.patch(&data) }, containing: ["padding"])
        XCTAssertEqual(data, original)
        let url = try writeTemporary(original)
        defer { try? FileManager.default.removeItem(at: url) }
        // Preflight validates the input; replacement capacity is checked by the mutation.
        try BinaryPatcher.validateForPreparation(at: url)
        assertInvalid({ _ = try BinaryPatcher.patchFile(at: url) }, containing: ["padding", url.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLegacyFailureDoesNotThinTheOriginalFatFile() throws {
        let data = makeFat([armv7Slice(), sectionedImage(legacy: true, headerPadding: false)], fat64: true)
        let url = try writeTemporary(data)
        defer { try? FileManager.default.removeItem(at: url) }
        assertInvalid({ _ = try BinaryPatcher.patchFile(at: url) }, containing: ["padding"])
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testExistingBuildVersionRemovesRedundantLegacyWithoutChangingVersions() throws {
        var data = machO(commands: [buildVersion(2), words(0x25, 16, 0x000B0100, 0x000C0000)])
        XCTAssertTrue(try BinaryPatcher.patch(&data))
        XCTAssertEqual(u32(data, 16), 1)
        XCTAssertEqual(u32(data, 44), 0x000F0000)
        XCTAssertEqual(u32(data, 48), 0x001A0100)
        XCTAssertEqual(u32(data, 20), 24)
    }

    func testNonzeroUnknownPaddingIsNotOverwritten() throws {
        var original = makeMachOWithVersionMin()
        original[48] = 0xA5
        var data = original
        assertInvalid({ _ = try BinaryPatcher.patch(&data) }, containing: ["padding"])
        XCTAssertEqual(data, original)
    }

    func testAddLoadDylibAddsCommand() throws {
        let original = sectionedImage(platform: 6)
        let url = try writeTemporary(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let path = "@executable_path/Frameworks/libPearRuntime.dylib"
        XCTAssertTrue(try BinaryPatcher.addLoadDylib(at: url, path: path))
        let result = try Data(contentsOf: url)
        XCTAssertEqual(u32(result, 16), u32(original, 16) + 1)
        XCTAssertTrue(BinaryPatcher.hasLoadDylib(at: url, containing: "libPearRuntime"))
        XCTAssertEqual(result.subdata(in: 4096..<result.count), original.subdata(in: 4096..<original.count))
        XCTAssertFalse(try BinaryPatcher.addLoadDylib(at: url, path: path))
    }

    func testRPathInsertionAndRemovalStayInsideCommandArea() throws {
        let original = sectionedImage(platform: 6)
        let url = try writeTemporary(original)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try BinaryPatcher.addLoadDylib(at: url, path: "/tmp/libPearRuntime.dylib"))
        XCTAssertTrue(try BinaryPatcher.addRPath(at: url, path: "@executable_path/Frameworks"))
        let result = try Data(contentsOf: url)
        XCTAssertLessThan(try commandOffset(0x8000_001C, in: result), try commandOffset(0x0C, in: result))
        XCTAssertEqual(result.subdata(in: 4096..<result.count), original.subdata(in: 4096..<original.count))
        XCTAssertFalse(try BinaryPatcher.addRPath(at: url, path: "@executable_path/Frameworks"))
        XCTAssertTrue(try BinaryPatcher.removeLoadDylib(at: url, containing: "libPearRuntime"))
        let removed = try Data(contentsOf: url)
        XCTAssertFalse(BinaryPatcher.hasLoadDylib(at: url, containing: "libPearRuntime"))
        XCTAssertEqual(removed.subdata(in: 4096..<removed.count), original.subdata(in: 4096..<original.count))
    }

    func testCommandInsertionFailureDoesNotThinFatOrOverwriteSectionlessContent() throws {
        let noSlack = makeFat([armv7Slice(), sectionedImage(platform: 6, headerPadding: false)])
        let sectionless = machO(commands: [segment(fileSize: 512), buildVersion(6)], size: 512)
        for original in [noSlack, sectionless] {
            let url = try writeTemporary(original)
            defer { try? FileManager.default.removeItem(at: url) }
            assertInvalid({ _ = try BinaryPatcher.addLoadDylib(at: url, path: "/tmp/Test.dylib") }, containing: ["padding"])
            XCTAssertEqual(try Data(contentsOf: url), original)
            assertInvalid({ _ = try BinaryPatcher.addRPath(at: url, path: "/tmp") }, containing: ["padding"])
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    // MARK: - FAT32 / FAT64 and slice selection

    func testDetectsAndThinsFatBinary() throws {
        for fat64 in [false, true] {
            let arm64 = makeMachO(platform: 2, size: 1024)
            let data = makeFat([armv7Slice(), arm64], fat64: fat64)
            XCTAssertEqual(BinaryPatcher.machO64Offsets(data), [8192])
            XCTAssertTrue(BinaryPatcher.isMachO64(data))
            let url = try writeTemporary(data)
            defer { try? FileManager.default.removeItem(at: url) }
            try BinaryPatcher.validateForPreparation(at: url)
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertTrue(try BinaryPatcher.thinToARM64(at: url))
            XCTAssertEqual(try Data(contentsOf: url), arm64)
            XCTAssertFalse(try BinaryPatcher.thinToARM64(at: url))
        }
    }

    func testPrefersPlainARM64RegardlessOfARM64eOrder() throws {
        let arm64 = makeMachO(platform: 2, size: 1024)
        let arm64e = makeMachO(platform: 2, subtype: 0x8000_0002, size: 1024)
        for fat64 in [false, true] {
            for images in [[arm64e, arm64], [arm64, arm64e]] {
                let data = makeFat(images, fat64: fat64)
                XCTAssertEqual(BinaryPatcher.machO64Offsets(data), [images[0] == arm64 ? 4096 : 8192])
                let url = try writeTemporary(data)
                defer { try? FileManager.default.removeItem(at: url) }
                XCTAssertTrue(try BinaryPatcher.thinToARM64(at: url))
                XCTAssertEqual(try Data(contentsOf: url), arm64)
            }
        }
        try assertUnpreparable(makeFat([arm64e], fat64: true), containing: ["ARM64e ABI"])
    }

    func testPrefersARM64AllOverV8AndPreservesSubtype() throws {
        let all = makeMachO(platform: 2, size: 1024)
        let v8 = makeMachO(platform: 2, subtype: 1, size: 1024)
        XCTAssertEqual(BinaryPatcher.machO64Offsets(makeFat([v8, all])), [8192])
        var data = v8
        XCTAssertTrue(try BinaryPatcher.patch(&data))
        XCTAssertEqual(u32(data, 8), 1)
    }

    func testEncryptedSelectedFatSliceDoesNotFallBackOrWrite() throws {
        let encrypted = sectionedImage(extraCommands: [encryption(kind: 0x2C, offset: 4096, size: 64, id: 1)])
        let arm64e = makeMachO(platform: 2, subtype: 2, size: 1024)
        let v8 = makeMachO(platform: 2, subtype: 1, size: 1024)
        for fat64 in [false, true] {
            try assertUnpreparable(makeFat([arm64e, v8, encrypted], fat64: fat64), containing: ["encrypted", "0x1000", "0x1040"])
        }
    }

    func testUnselectedEncryptedARM64eDoesNotBlockPortableSlice() throws {
        var arm64e = sectionedImage(extraCommands: [encryption(kind: 0x2C, offset: 4096, size: 64, id: 1)])
        put(2, at: 8, in: &arm64e)
        let plain = makeMachO(platform: 2, size: 1024)
        let data = makeFat([arm64e, plain], fat64: true)
        let url = try writeTemporary(data)
        defer { try? FileManager.default.removeItem(at: url) }
        try BinaryPatcher.validateForPreparation(at: url)
        XCTAssertTrue(try BinaryPatcher.thinToARM64(at: url))
        XCTAssertEqual(try Data(contentsOf: url), plain)
    }

    func testInMemoryFatPatchOnlyChangesSelectedSlice() throws {
        let arm64e = makeMachO(platform: 2, subtype: 2, size: 1024)
        let plain = makeMachO(platform: 2, size: 1024)
        var data = makeFat([arm64e, plain], fat64: true)
        var expected = data
        put(6, at: 8192 + 40, in: &expected)
        XCTAssertTrue(try BinaryPatcher.patch(&data))
        XCTAssertEqual(data, expected)
    }

    func testRejectsMalformedFatTablesRangesAndCPUDisagreements() throws {
        for fat64 in [false, true] {
            let original = makeFat([armv7Slice(), makeMachO(platform: 2, size: 1024)], fat64: fat64)
            let stride = fat64 ? 32 : 20
            var cases: [Data] = [Data(original.prefix(8 + stride))]
            var data = original
            putBE(3, at: 4, in: &data)
            cases.append(data)
            data = original
            putBE(1, at: 8 + stride + 4, in: &data)
            cases.append(data)
            data = original
            putBE(0x0100_0007, at: 8 + stride, in: &data)
            cases.append(data)
            data = original
            put(0, at: 4096, in: &data) // Even an unselected slice must have a valid header.
            cases.append(data)
            data = original
            if fat64 { putBE64(16, at: 8 + stride + 16, in: &data) }
            else { putBE(16, at: 8 + stride + 12, in: &data) }
            cases.append(data)
            data = original
            putBE(64, at: 8 + stride + (fat64 ? 24 : 16), in: &data)
            cases.append(data)
            data = original
            if fat64 { putBE64(UInt64.max, at: 8 + stride + 8, in: &data) }
            else { putBE(UInt32.max, at: 8 + stride + 8, in: &data) }
            cases.append(data)
            data = original
            if fat64 { putBE64(UInt64.max, at: 8 + stride + 16, in: &data) }
            else { putBE(UInt32.max, at: 8 + stride + 12, in: &data) }
            cases.append(data)
            // Make the first slice extend across the second without changing either header.
            data = original
            let overlappingSize = data.count - 4096
            if fat64 { putBE64(UInt64(overlappingSize), at: 8 + 16, in: &data) }
            else { putBE(UInt32(overlappingSize), at: 8 + 12, in: &data) }
            cases.append(data)
            for malformed in cases {
                XCTAssertEqual(BinaryPatcher.machO64Offsets(malformed), [])
                try assertUnpreparable(malformed)
            }
        }
        try assertUnpreparable(makeFat([makeMachO(platform: 2), makeMachO(platform: 6)]), containing: ["duplicate"])
    }

    func testCommandBoundsCannotEscapeSelectedSliceIntoSibling() throws {
        var plain = makeMachO(platform: 2, size: 1024)
        put(2048, at: 20, in: &plain)
        let arm64e = makeMachO(platform: 2, subtype: 2, size: 1024)
        try assertUnpreparable(makeFat([plain, arm64e], fat64: true), containing: ["slice"])
    }

    func testContainsSymbolUsesSliceRelativeTablesInFat32AndFat64() throws {
        let symbol = "_SyntheticMarker"
        let strings = Data(("\0" + symbol + "\0").utf8)
        var thin = machO(commands: [buildVersion(2), words(0x2, 24, 512, 1, 528, UInt32(strings.count))], size: 1024)
        put(1, at: 512, in: &thin)
        thin[516] = 1 // N_UNDF | N_EXT
        thin.replaceSubrange(528..<(528 + strings.count), with: strings)
        for fat64 in [false, true] {
            let data = makeFat([armv7Slice(), thin], fat64: fat64)
            let url = try writeTemporary(data)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(BinaryPatcher.containsSymbol(at: url, named: symbol))
            XCTAssertTrue(BinaryPatcher.containsSymbol(at: url, withPrefix: "_Synthetic"))
            XCTAssertFalse(BinaryPatcher.containsSymbol(at: url, named: "_Missing"))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    // MARK: - Chained fixups and format-specific imports

    func testClampsChainedFixupSegmentCount() throws {
        let blob = chainedFixupsBlob(segCount: 5, offsets: [0, 24, 56, 0, 0])
        let url = try writeTemporary(makeMachO(segments: 4, fixups: blob))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try BinaryPatcher.patchFile(at: url))
        let result = try Data(contentsOf: url)
        XCTAssertEqual(u32(result, 4096 + 28), 4)
        XCTAssertFalse(try BinaryPatcher.patchFile(at: url))
    }

    func testDoesNotClampWhenExtraEntryCarriesFixups() throws {
        let blob = chainedFixupsBlob(segCount: 5, offsets: [0, 24, 56, 0, 12])
        let data = makeMachO(segments: 4, fixups: blob)
        let url = try writeTemporary(data)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try BinaryPatcher.patchFile(at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testMarksUnavailableClassImportWeak() throws {
        try assertImportWeakening(format: 1)
    }

    func testFormat2PreservesOrdinalNameAndAddend() throws {
        try assertImportWeakening(format: 2)
    }

    func testFormat3UsesBit16AndUpperWordNameWithoutChangingOrdinalOrAddend() throws {
        try assertImportWeakening(format: 3)
    }

    func testNonUTF8UnrelatedChainedImportsPreserveEveryOtherByte() throws {
        for format in [UInt32(1), 2, 3] {
            try assertImportWeakening(format: format, nonUTF8Unrelated: true)
        }
    }

    func testNlistFiltersTypesBeforeNamesAndAcceptsNonUTF8UnrelatedImports() throws {
        var names = Data([0, 0xFF, 0x80, 0])
        names.append(Data((unavailableClass + "\0").utf8))
        let original = symbolTableImage(names: names, entries: [
            (UInt32.max, 0x03, 0x0520), // N_ABS | N_EXT: its name is irrelevant to import weakening.
            (UInt32.max, 0xE0, 0x0130), // Debug entry: do not interpret its name as an import.
            (1, 0x01, 0x0200),          // Unrelated N_UNDF with arbitrary non-UTF8 bytes.
            (4, 0x01, 0x0300),          // Target N_UNDF; preserve the ordinal while setting N_WEAK_REF.
            (4, 0x03, 0x0400)           // The same target name is defined here and must not change.
        ])
        var expected = original
        expected[512 + 3 * 16 + 6] |= 0x40
        let url = try writeTemporary(original)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try BinaryPatcher.patchFile(at: url))
        XCTAssertEqual(try Data(contentsOf: url), expected, "only the undefined target's weak-reference bit changes")
        XCTAssertFalse(try BinaryPatcher.patchFile(at: url))
    }

    func testSymbolLookupByteComparesPastNonUTF8DefinedNames() throws {
        let marker = "_SyntheticMarker"
        var names = Data([0, 0xFF, 0x80, 0])
        names.append(Data((marker + "\0").utf8))
        let original = symbolTableImage(names: names, entries: [(1, 0x03, 0), (4, 0x03, 0)])
        let url = try writeTemporary(original)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(BinaryPatcher.containsSymbol(at: url, named: marker))
        XCTAssertTrue(BinaryPatcher.containsSymbol(at: url, withPrefix: "_Synthetic"))
        XCTAssertFalse(BinaryPatcher.containsSymbol(at: url, named: "_Missing"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUndefinedSymbolNameBoundsAndTerminationStillRejectWithoutWriting() throws {
        let badOffset = symbolTableImage(names: Data([0]), entries: [(UInt32.max, 0x01, 0)], platform: 2)
        let unterminated = symbolTableImage(names: Data([0, 0xFF, 0x80]), entries: [(1, 0x01, 0)], platform: 2)
        try assertFilePatchRejected(badOffset, containing: ["symbol name"])
        try assertFilePatchRejected(unterminated, containing: ["unterminated"])
    }

    func testUnsupportedSymbolsFormatRejectsPatchBeforeFatFileWrite() throws {
        var blob = importBlob(format: 3)
        put(1, at: 24, in: &blob)
        let thin = makeMachO(segments: 1, fixups: blob, platform: 2)
        for data in [thin, makeFat([armv7Slice(), thin], fat64: true)] {
            try assertFilePatchRejected(data, containing: ["symbols_format 1"])
        }
    }

    func testUnusedSymbolsFormatDoesNotRequireDecoding() throws {
        var blob = chainedFixupsBlob(segCount: 1, offsets: [0])
        put(1, at: 24, in: &blob)
        let data = makeMachO(segments: 1, fixups: blob)
        let url = try writeTemporary(data)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try BinaryPatcher.patchFile(at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testMalformedImportBoundsAndStringsDoNotCommitEarlierPlatformChanges() throws {
        let original = importBlob(format: 3)
        var cases: [Data] = []
        var blob = original
        put(UInt32.max, at: 16, in: &blob)
        cases.append(blob)
        blob = original
        put(UInt32.max, at: 64 + 16 + 4, in: &blob)
        cases.append(blob)
        blob = original
        blob[blob.count - 1] = 0x41
        cases.append(blob)
        blob = original
        put(99, at: 20, in: &blob)
        cases.append(blob)
        blob = original
        put(UInt32.max, at: 28, in: &blob)
        cases.append(blob)
        for malformed in cases {
            try assertFilePatchRejected(makeMachO(segments: 1, fixups: malformed, platform: 2))
        }
    }

    /// Optional legacy smoke coverage; synthetic regressions do not depend on it.
    func testPatchesRealExtractedBinaryIfPresent() throws {
        let source = URL(fileURLWithPath: "/tmp/pearsilicon/extracted-binary")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("no extracted binary present") }
        var data = try Data(contentsOf: source)
        XCTAssertTrue(BinaryPatcher.isMachO64(data))
        XCTAssertTrue(try BinaryPatcher.patch(&data))
        XCTAssertFalse(try BinaryPatcher.patch(&data))
    }

    // MARK: - Assertions

    private func assertInvalid(
        _ operation: () throws -> Void, containing fragments: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("expected PearError.invalidPackage", file: file, line: line)
        } catch {
            guard case PearError.invalidPackage(let message) = error else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            for fragment in fragments {
                XCTAssertTrue(message.contains(fragment), "missing '\(fragment)' in '\(message)'", file: file, line: line)
            }
        }
    }

    private func assertUnpreparable(
        _ original: Data, containing fragments: [String] = [], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var data = original
        assertInvalid({ _ = try BinaryPatcher.patch(&data) }, containing: fragments, file: file, line: line)
        XCTAssertEqual(data, original, file: file, line: line)
        let url = try writeTemporary(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let fileFragments = [url.lastPathComponent] + fragments
        assertInvalid({ try BinaryPatcher.validateForPreparation(at: url) }, containing: fileFragments, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), original, file: file, line: line)
        let operations: [(URL) throws -> Bool] = [
            { try BinaryPatcher.patchFile(at: $0) },
            { try BinaryPatcher.thinToARM64(at: $0) },
            { try BinaryPatcher.addLoadDylib(at: $0, path: "/tmp/Test.dylib") },
            { try BinaryPatcher.addRPath(at: $0, path: "/tmp") },
            { try BinaryPatcher.removeLoadDylib(at: $0, containing: "Test") }
        ]
        for operation in operations {
            assertInvalid({ _ = try operation(url) }, containing: fileFragments, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: url), original, file: file, line: line)
        }
    }

    private func assertFilePatchRejected(_ data: Data, containing fragments: [String] = []) throws {
        let url = try writeTemporary(data)
        defer { try? FileManager.default.removeItem(at: url) }
        assertInvalid({ _ = try BinaryPatcher.patchFile(at: url) }, containing: [url.lastPathComponent] + fragments)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    private func assertImportWeakening(format: UInt32, nonUTF8Unrelated: Bool = false) throws {
        let blob = importBlob(format: format, nonUTF8Unrelated: nonUTF8Unrelated)
        let original = makeMachO(segments: 1, fixups: blob)
        let url = try writeTemporary(original)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try BinaryPatcher.patchFile(at: url))
        let result = try Data(contentsOf: url)
        let stride = format == 3 ? 16 : (format == 2 ? 8 : 4)
        let entry = 4096 + 64 + stride
        var expected = original
        let weakened = u32(expected, entry) | (format == 3 ? 0x1_0000 : 0x100)
        put(weakened, at: entry, in: &expected)
        XCTAssertEqual(result, expected, "only the target import's weak bit may change")
        if format == 3 {
            XCTAssertEqual(u32(result, entry) & 0xFFFF, 0x135, "bit 8 belongs to the ordinal, not weak_import")
            XCTAssertEqual(u32(result, entry + 4), u32(original, entry + 4))
            XCTAssertEqual(u64(result, entry + 8), u64(original, entry + 8))
        }
        XCTAssertFalse(try BinaryPatcher.patchFile(at: url))
    }

    // MARK: - Synthetic fixtures (never executed)

    private func makeMachO(platform: UInt32, subtype: UInt32 = 0, size: Int? = nil) -> Data {
        machO(commands: [buildVersion(platform)], subtype: subtype, size: size)
    }

    private func makeMachOWithVersionMin() -> Data {
        machO(commands: [words(0x25, 16, 0x000B0100, 0x001A0100)], size: 4096)
    }

    private func buildVersion(_ platform: UInt32) -> Data {
        words(0x32, 24, platform, 0x000F0000, 0x001A0100, 0)
    }

    private func encryption(kind: UInt32, offset: UInt32, size: UInt32, id: UInt32) -> Data {
        // ARM64 load commands include padding even for the 20-byte LC_ENCRYPTION_INFO structure.
        words(kind, 24, offset, size, id, 0)
    }

    private func machO(commands: [Data], subtype: UInt32 = 0, fileType: UInt32 = 2, size: Int? = nil) -> Data {
        let count = commands.reduce(0) { $0 + $1.count }
        var data = words(0xFEEDFACF, 0x0100_000C, subtype, fileType, UInt32(commands.count), UInt32(count), 0, 0)
        commands.forEach { data.append($0) }
        if let size { data.append(Data(count: max(0, size - data.count))) }
        return data
    }

    private func sectionedImage(
        platform: UInt32 = 2, legacy: Bool = false, extraCommands: [Data] = [], headerPadding: Bool = true
    ) -> Data {
        let version = legacy ? words(0x25, 16, 0x000B0100, 0x001A0100) : buildVersion(platform)
        let end = 32 + 152 + version.count + extraCommands.reduce(0) { $0 + $1.count }
        let textOffset = headerPadding ? 4096 : end
        let payload = Data((0..<64).map { UInt8($0 ^ 0xA5) })
        let textSegment = segment(sectionOffset: textOffset, fileSize: UInt64(textOffset + payload.count))
        var data = machO(commands: [textSegment, version] + extraCommands, size: textOffset)
        data.append(payload)
        return data
    }

    private func segment(sectionOffset: Int? = nil, fileSize: UInt64 = 0) -> Data {
        var data = words(0x19, sectionOffset == nil ? 72 : 152)
        appendName("__TEXT", to: &data)
        append64(0x1_0000_0000, to: &data)
        append64(fileSize, to: &data)
        append64(0, to: &data)
        append64(fileSize, to: &data)
        for value in [UInt32(7), 5, sectionOffset == nil ? 0 : 1, 0] { append(value, to: &data) }
        if let sectionOffset {
            appendName("__text", to: &data)
            appendName("__TEXT", to: &data)
            append64(0x1_0000_0000 + UInt64(sectionOffset), to: &data)
            append64(64, to: &data)
            for value in [UInt32(sectionOffset), 2, 0, 0, 0x8000_0400, 0, 0, 0] { append(value, to: &data) }
        }
        return data
    }

    private func armv7Slice() -> Data {
        var data = words(0xFEEDFACE, 12, 9, 2, 0, 0, 0)
        data.append(Data(count: 1024 - data.count))
        return data
    }

    private func makeFat(_ images: [Data], fat64: Bool = false) -> Data {
        var offsets: [Int] = []
        var end = 4096
        for image in images {
            offsets.append(end)
            end = ((end + image.count + 4095) / 4096) * 4096
        }
        var data = Data()
        appendBE(fat64 ? 0xCAFEBABF : 0xCAFEBABE, to: &data)
        appendBE(UInt32(images.count), to: &data)
        for (index, image) in images.enumerated() {
            appendBE(u32(image, 4), to: &data)
            appendBE(u32(image, 8), to: &data)
            if fat64 {
                appendBE64(UInt64(offsets[index]), to: &data)
                appendBE64(UInt64(image.count), to: &data)
                appendBE(12, to: &data)
                appendBE(0, to: &data)
            } else {
                appendBE(UInt32(offsets[index]), to: &data)
                appendBE(UInt32(image.count), to: &data)
                appendBE(12, to: &data)
            }
        }
        for (index, image) in images.enumerated() {
            data.append(Data(count: offsets[index] - data.count))
            data.append(image)
        }
        return data
    }

    private func makeMachO(segments: Int, fixups blob: Data, platform: UInt32 = 6) -> Data {
        let commands = (0..<segments).map { _ in segment() }
            + [words(0x8000_0034, 16, 4096, UInt32(blob.count)), buildVersion(platform)]
        var data = machO(commands: commands, size: 4096)
        data.append(blob)
        return data
    }

    private func symbolTableImage(
        names: Data, entries: [(nameOffset: UInt32, type: UInt8, desc: UInt16)], platform: UInt32 = 6
    ) -> Data {
        let stringsOffset = 512 + entries.count * 16
        var data = machO(commands: [
            buildVersion(platform), words(0x2, 24, 512, UInt32(entries.count), UInt32(stringsOffset), UInt32(names.count))
        ], size: max(1024, stringsOffset + names.count))
        for (index, entry) in entries.enumerated() {
            let at = 512 + index * 16
            put(entry.nameOffset, at: at, in: &data)
            data[at + 4] = entry.type
            data[at + 6] = UInt8(truncatingIfNeeded: entry.desc)
            data[at + 7] = UInt8(truncatingIfNeeded: entry.desc >> 8)
        }
        data.replaceSubrange(stringsOffset..<(stringsOffset + names.count), with: names)
        return data
    }

    private func chainedFixupsBlob(segCount: UInt32, offsets: [UInt32]) -> Data {
        var data = words(0, 28, 0, 0, 0, 1, 0, segCount)
        offsets.forEach { append($0, to: &data) }
        data.append(Data(count: 64))
        return data
    }

    private func importBlob(format: UInt32, nonUTF8Unrelated: Bool = false) -> Data {
        let stride = format == 3 ? 16 : (format == 2 ? 8 : 4)
        let prefix = nonUTF8Unrelated ? Data([0, 0xFF, 0x80, 0]) : Data("\0_Unrelated\0".utf8)
        var names = prefix
        names.append(Data((unavailableClass + "\0").utf8))
        var data = words(0, 28, 64, UInt32(64 + 3 * stride), 3, format, 0, 1, 0)
        data.append(Data(count: 64 - data.count))
        for index in 0..<3 {
            let nameOffset = UInt32(index == 0 ? 1 : prefix.count)
            let ordinal: UInt32 = index == 1 ? 0x135 : 3
            if format == 3 {
                append(ordinal | (index == 2 ? 0x1_0000 : 0), to: &data)
                append(nameOffset, to: &data)
                append64(0xFEDC_BA98_7654_3210 + UInt64(index), to: &data)
            } else {
                append((nameOffset << 9) | (ordinal & 0xFF) | (index == 2 ? 0x100 : 0), to: &data)
                if format == 2 { append(0xFFFF_FFF0 + UInt32(index), to: &data) }
            }
        }
        data.append(names)
        return data
    }

    private func writeTemporary(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pear-macho-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    private func commandOffset(_ kind: UInt32, in data: Data) throws -> Int {
        var offset = 32
        for _ in 0..<Int(u32(data, 16)) {
            if u32(data, offset) == kind { return offset }
            offset += Int(u32(data, offset + 4))
        }
        return try XCTUnwrap(nil as Int?, "missing command \(kind)")
    }

    private func words(_ values: UInt32...) -> Data {
        var data = Data()
        values.forEach { append($0, to: &data) }
        return data
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func append64(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func appendBE(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) })
    }

    private func appendBE64(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> ((7 - $0) * 8)) })
    }

    private func appendName(_ value: String, to data: inout Data) {
        data.append(Data(value.utf8))
        data.append(Data(count: 16 - value.utf8.count))
    }

    private func put(_ value: UInt32, at offset: Int, in data: inout Data) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func put64(_ value: UInt64, at offset: Int, in data: inout Data) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func putBE(_ value: UInt32, at offset: Int, in data: inout Data) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((3 - index) * 8)) }
    }

    private func putBE64(_ value: UInt64, at offset: Int, in data: inout Data) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((7 - index) * 8)) }
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private func u64(_ data: Data, _ offset: Int) -> UInt64 {
        data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
