import Foundation

/// Prepares supported, unencrypted ARM64 iOS images for Mac Catalyst without
/// moving section contents. Signatures must be refreshed by the caller.
/// Encryption metadata and CPU subtypes are never rewritten.
enum BinaryPatcher {

    enum MachO {
        static let magic64: UInt32 = 0xFEEDFACF
        static let headerSize = 32
        static let fatMagic: UInt32 = 0xCAFEBABE
        static let fatMagic64: UInt32 = 0xCAFEBABF
        static let fatArchSize = 20
        static let fatArchSize64 = 32
        static let cpuTypeARM64: UInt32 = 0x0100_000C
    }

    enum Platform {
        static let macOS: UInt32 = 1
        static let iOS: UInt32 = 2
        static let macCatalyst: UInt32 = 6
    }

    enum LoadCommand {
        static let segment64: UInt32 = 0x19
        static let symtab: UInt32 = 0x2
        static let loadDylib: UInt32 = 0x0C
        static let loadWeakDylib: UInt32 = 0x8000_0018
        static let reexportDylib: UInt32 = 0x8000_001F
        static let rpath: UInt32 = 0x8000_001C
        static let versionMinMacOSX: UInt32 = 0x24
        static let versionMinIPhoneOS: UInt32 = 0x25
        static let encryptionInfo: UInt32 = 0x21
        static let encryptionInfo64: UInt32 = 0x2C
        static let buildVersion: UInt32 = 0x32
        static let chainedFixups: UInt32 = 0x8000_0034
    }

    private static let dependencyCommands: Set<UInt32> = [0x0C, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]
    private static let linkeditCommands: Set<UInt32> = [
        0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x8000_0033, 0x8000_0034
    ]
    private static let unavailableSystemSymbols: Set<Data> = [
        Data("_OBJC_CLASS_$_PHAssetCurationUtilities".utf8)
    ]

    private struct Slice {
        let offset: Int
        let size: Int
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let littleEndian64: Bool
        var end: Int { offset + size }
        var range: Range<Int> { offset..<end }
        var isPortableARM64: Bool {
            cpuType == MachO.cpuTypeARM64 && littleEndian64
                && (cpuSubtype == 0 || cpuSubtype == 1) // ARM64_ALL / ARM64_V8, no capability bits
        }
    }

    private struct Command {
        let kind: UInt32
        let offset: Int
        let size: Int
        var end: Int { offset + size }
    }

    private struct Image {
        let slice: Slice
        let commands: [Command]
        let commandsEnd: Int
        let paddingEnd: Int
        let name: String
    }

    private static func invalid(_ name: String, _ detail: String) -> PearError {
        .invalidPackage("\(name): \(detail)")
    }

    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    // MARK: - Detection and preflight

    /// A cheap magic check, not a promise that the image is valid or supported.
    static func isMachO64(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return readU32(data, 0) == MachO.magic64
            || readBeU32(data, 0) == MachO.fatMagic
            || readBeU32(data, 0) == MachO.fatMagic64
    }

    static func fileIsMachO64(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return isMachO64(head)
    }

    /// Reads but never modifies the file. Selects ARM64_ALL (or ARM64_V8), not
    /// ARM64e, and requires iOS/Catalyst or legacy iPhoneOS platform metadata.
    /// Zippered MH_DYLIB images may declare both macOS and Catalyst.
    /// Malformed, unsupported or encrypted selected images throw invalidPackage;
    /// file I/O errors propagate. Unselected slices are structurally checked but
    /// their platform/encryption metadata does not affect preparation.
    static func validateForPreparation(at url: URL) throws {
        _ = try preparationImage(Data(contentsOf: url), name: url.lastPathComponent)
    }

    /// Compatibility name for the old warning predicate. These are encryption
    /// commands, not generic guards; a nonzero cryptid must never be cleared.
    static func hasLegacyGuardMarkers(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let image = try? selectedImage(data, name: url.lastPathComponent) else { return false }
        return image.commands.contains {
            ($0.kind == LoadCommand.encryptionInfo || $0.kind == LoadCommand.encryptionInfo64)
                && readU32(data, $0.offset + 16) != 0
        }
    }

    /// Offset of the selected portable ARM64 slice (zero or one result).
    /// Malformed containers and unsupported CPUs/ABIs produce an empty result.
    static func machO64Offsets(_ data: Data) -> [Int] {
        guard let image = try? selectedImage(Data(data), name: "Mach-O image") else { return [] }
        return [image.slice.offset]
    }

    private static func looksLikeMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return [UInt32(0xFEEDFACE), 0xCEFAEDFE, 0xFEEDFACF, 0xCFFAEDFE,
                0xBEBAFECA, 0xBFBAFECA, 0xCAFEBABE, 0xCAFEBABF].contains(readU32(data, 0))
    }

    /// The sole thin/fat parser. Every record is bounded and checked against
    /// its own Mach-O header, even when that architecture will be discarded.
    private static func slices(_ data: Data, name: String) throws -> [Slice] {
        guard data.count >= 4 else { throw invalid(name, "truncated Mach-O header") }
        let magic = readBeU32(data, 0)
        guard magic == MachO.fatMagic || magic == MachO.fatMagic64 else {
            return [try slice(data, offset: 0, size: data.count, name: name)]
        }
        guard data.count >= 8 else { throw invalid(name, "truncated fat header") }
        let count = Int(readBeU32(data, 4))
        let isFat64 = magic == MachO.fatMagic64
        let stride = isFat64 ? MachO.fatArchSize64 : MachO.fatArchSize
        guard count > 0, count <= (data.count - 8) / stride else {
            throw invalid(name, "invalid or truncated fat architecture table")
        }
        let tableEnd = 8 + count * stride
        var result: [Slice] = []
        for index in 0..<count {
            let entry = 8 + index * stride
            let offset = isFat64 ? readBeU64(data, entry + 8) : UInt64(readBeU32(data, entry + 8))
            let size = isFat64 ? readBeU64(data, entry + 16) : UInt64(readBeU32(data, entry + 12))
            let alignment = readBeU32(data, entry + (isFat64 ? 24 : 16))
            guard offset >= UInt64(tableEnd), size > 0,
                  offset <= UInt64(data.count), size <= UInt64(data.count) - offset,
                  alignment <= (isFat64 ? 63 : 31) else {
                throw invalid(name, "fat slice \(index) has an invalid range or alignment")
            }
            let mask = (UInt64(1) << alignment) - 1
            guard offset & mask == 0,
                  !isFat64 || readBeU32(data, entry + 28) == 0 else {
                throw invalid(name, "fat slice \(index) has invalid alignment or reserved bits")
            }
            let parsed = try slice(data, offset: Int(offset), size: Int(size), name: name)
            guard parsed.cpuType == readBeU32(data, entry),
                  parsed.cpuSubtype == readBeU32(data, entry + 4) else {
                throw invalid(name, "fat slice \(index) CPU/subtype disagrees with its Mach-O header")
            }
            guard !result.contains(where: { $0.cpuType == parsed.cpuType && $0.cpuSubtype == parsed.cpuSubtype }) else {
                throw invalid(name, "duplicate fat CPU/subtype records")
            }
            result.append(parsed)
        }
        let ordered = result.sorted { $0.offset < $1.offset }
        for index in 1..<ordered.count where ordered[index].offset < ordered[index - 1].end {
            throw invalid(name, "overlapping fat slices")
        }
        return result
    }

    private static func slice(_ data: Data, offset: Int, size: Int, name: String) throws -> Slice {
        guard size >= 4 else { throw invalid(name, "truncated slice header") }
        let magic = readU32(data, offset)
        let is64 = magic == MachO.magic64 || magic == 0xCFFAEDFE
        let isLittleEndian = magic == MachO.magic64 || magic == 0xFEEDFACE
        guard is64 || magic == 0xFEEDFACE || magic == 0xCEFAEDFE else {
            throw invalid(name, "invalid or unsupported Mach-O slice magic")
        }
        guard size >= (is64 ? 32 : 28) else { throw invalid(name, "truncated Mach-O slice header") }
        let cpu = isLittleEndian ? readU32(data, offset + 4) : readBeU32(data, offset + 4)
        let subtype = isLittleEndian ? readU32(data, offset + 8) : readBeU32(data, offset + 8)
        guard cpu != MachO.cpuTypeARM64 || (is64 && isLittleEndian) else {
            throw invalid(name, "ARM64 slice requires a little-endian 64-bit Mach-O header")
        }
        return Slice(offset: offset, size: size, cpuType: cpu, cpuSubtype: subtype,
                     littleEndian64: is64 && isLittleEndian)
    }

    private static func selectedImage(_ data: Data, name: String) throws -> Image {
        let candidates = try slices(data, name: name)
        // Prefer ARM64_ALL even if ARM64_V8 or ARM64e appears earlier in the FAT table.
        let selected = candidates.first { $0.isPortableARM64 && $0.cpuSubtype == 0 }
            ?? candidates.first { $0.isPortableARM64 }
        guard let selected else {
            if candidates.contains(where: { $0.cpuType == MachO.cpuTypeARM64 && $0.cpuSubtype & 0x00FF_FFFF == 2 }) {
                throw invalid(name, "unsupported ARM64e ABI; a plain ARM64 slice is required")
            }
            throw invalid(name, "unsupported CPU/subtype; a plain ARM64_ALL or ARM64_V8 slice without capability bits is required")
        }
        return try image(data, slice: selected, name: name)
    }

    /// Bounds are slice-relative on input and absolute in the returned range.
    private static func payloadRange(offset: UInt64, size: UInt64, slice: Slice, name: String) throws -> Range<Int> {
        guard offset <= UInt64(slice.size), size <= UInt64(slice.size) - offset else {
            throw invalid(name, "payload range \(hex(offset)) + \(hex(size)) exceeds the Mach-O slice")
        }
        let start = slice.offset + Int(offset)
        return start..<(start + Int(size))
    }

    private static func image(_ data: Data, slice: Slice, name: String) throws -> Image {
        let base = slice.offset
        guard [UInt32(2), 6, 8].contains(readU32(data, base + 12)) else {
            throw invalid(name, "unsupported Mach-O file type (expected executable, dylib or bundle)")
        }
        let count = Int(readU32(data, base + 16))
        let byteCount = Int(readU32(data, base + 20))
        guard byteCount <= slice.size - MachO.headerSize, count <= byteCount / 8 else {
            throw invalid(name, "load commands exceed the Mach-O slice")
        }
        let end = base + MachO.headerSize + byteCount
        var commands: [Command] = []
        var offset = base + MachO.headerSize
        var paddingEnd = slice.end
        var sectionlessContent = false
        func protect(_ fileOffset: UInt64, _ size: UInt64) throws {
            let range = try payloadRange(offset: fileOffset, size: size, slice: slice, name: name)
            if !range.isEmpty {
                guard range.lowerBound >= end else { throw invalid(name, "payload overlaps load commands") }
                paddingEnd = min(paddingEnd, range.lowerBound)
            }
        }
        for _ in 0..<count {
            guard offset <= end - 8 else { throw invalid(name, "truncated load command") }
            let kind = readU32(data, offset)
            let size = Int(readU32(data, offset + 4))
            guard size >= 8, size % 8 == 0, size <= end - offset else {
                throw invalid(name, "invalid load-command size")
            }
            let command = Command(kind: kind, offset: offset, size: size)
            func require(_ minimum: Int) throws {
                guard size >= minimum else { throw invalid(name, "truncated load command \(hex(UInt64(kind)))") }
            }
            switch kind {
            case LoadCommand.segment64:
                try require(72)
                let fileOffset = readU64(data, offset + 40)
                let fileSize = readU64(data, offset + 48)
                _ = try payloadRange(offset: fileOffset, size: fileSize, slice: slice, name: name)
                if fileOffset > 0 { try protect(fileOffset, fileSize) }
                let sections = Int(readU32(data, offset + 64))
                guard sections <= (size - 72) / 80 else { throw invalid(name, "sections exceed their segment command") }
                var fileBackedSections = 0
                for index in 0..<sections {
                    let section = offset + 72 + index * 80
                    let type = readU32(data, section + 64) & 0xFF
                    if ![UInt32(1), 0x0C, 0x12].contains(type) {
                        let sectionSize = readU64(data, section + 40)
                        try protect(UInt64(readU32(data, section + 48)), sectionSize)
                        if sectionSize > 0 { fileBackedSections += 1 }
                    }
                    try protect(UInt64(readU32(data, section + 56)), UInt64(readU32(data, section + 60)) * 8)
                }
                // A sectionless file-backed segment at offset zero gives us no
                // evidence that any bytes after the commands are spare padding.
                if fileOffset == 0, fileSize > UInt64(MachO.headerSize + byteCount), fileBackedSections == 0 {
                    sectionlessContent = true
                }
            case LoadCommand.buildVersion:
                try require(24)
                guard Int(readU32(data, offset + 20)) <= (size - 24) / 8 else {
                    throw invalid(name, "build-version tools exceed their load command")
                }
            case LoadCommand.versionMinIPhoneOS, LoadCommand.versionMinMacOSX, 0x2F, 0x30:
                try require(16)
            case LoadCommand.encryptionInfo, LoadCommand.encryptionInfo64:
                try require(kind == LoadCommand.encryptionInfo64 ? 24 : 20)
                let cryptoff = UInt64(readU32(data, offset + 8))
                let cryptsize = UInt64(readU32(data, offset + 12))
                guard cryptoff <= UInt64(slice.size), cryptsize <= UInt64(slice.size) - cryptoff else {
                    throw invalid(name, "invalid encryption range [\(hex(cryptoff)), \(hex(cryptoff + cryptsize))) in slice at \(hex(UInt64(base)))")
                }
                guard cryptsize == 0 || cryptoff >= UInt64(MachO.headerSize + byteCount) else {
                    throw invalid(name, "invalid encryption range [\(hex(cryptoff)), \(hex(cryptoff + cryptsize))) overlaps load commands")
                }
                try protect(cryptoff, cryptsize)
            case LoadCommand.symtab:
                try require(24)
                try protect(UInt64(readU32(data, offset + 8)), UInt64(readU32(data, offset + 12)) * 16)
                try protect(UInt64(readU32(data, offset + 16)), UInt64(readU32(data, offset + 20)))
            case 0x22, 0x8000_0022: // LC_DYLD_INFO / LC_DYLD_INFO_ONLY
                try require(48)
                for field in stride(from: 8, through: 40, by: 8) {
                    try protect(UInt64(readU32(data, offset + field)), UInt64(readU32(data, offset + field + 4)))
                }
            case 0x31: // LC_NOTE
                try require(40)
                try protect(readU64(data, offset + 24), readU64(data, offset + 32))
            case 0x1A: // LC_ROUTINES_64 (initializer address is preserved)
                try require(72)
            default:
                if linkeditCommands.contains(kind) {
                    try require(16)
                    try protect(UInt64(readU32(data, offset + 8)), UInt64(readU32(data, offset + 12)))
                } else if dependencyCommands.contains(kind) || kind == 0x0D || kind == LoadCommand.rpath {
                    let minimum = kind == LoadCommand.rpath ? 12 : 24
                    try require(minimum)
                    let nameOffset = Int(readU32(data, offset + 8))
                    guard nameOffset >= minimum, nameOffset < size else { throw invalid(name, "invalid load-command path offset") }
                    _ = try string(data, in: (offset + nameOffset)..<command.end, name: name)
                }
            }
            commands.append(command)
            offset += size
        }
        guard offset == end else { throw invalid(name, "load-command count does not match sizeofcmds") }
        return Image(slice: slice, commands: commands, commandsEnd: end,
                     paddingEnd: sectionlessContent ? end : paddingEnd, name: name)
    }

    private static func preparationImage(_ data: Data, name: String) throws -> Image {
        let parsed = try selectedImage(data, name: name)
        let builds = parsed.commands.filter { $0.kind == LoadCommand.buildVersion }
        var legacyVersions = 0
        for command in parsed.commands {
            switch command.kind {
            case LoadCommand.encryptionInfo, LoadCommand.encryptionInfo64:
                let cryptid = readU32(data, command.offset + 16)
                if cryptid != 0 {
                    let start = UInt64(readU32(data, command.offset + 8))
                    let end = start + UInt64(readU32(data, command.offset + 12))
                    throw invalid(name, "encrypted ARM64 range [\(hex(start)), \(hex(end))) (cryptid \(cryptid), slice at \(hex(UInt64(parsed.slice.offset)))); encrypted images cannot be prepared")
                }
            case LoadCommand.versionMinIPhoneOS:
                legacyVersions += 1
            case LoadCommand.versionMinMacOSX, 0x2F, 0x30:
                throw invalid(name, "unsupported legacy Mach-O platform command \(hex(UInt64(command.kind)))")
            default: break
            }
        }
        if isZipperedCatalystDylib(data, image: parsed), legacyVersions == 0 {
            return parsed
        }
        for build in builds {
            let platform = readU32(data, build.offset + 8)
            guard platform == Platform.iOS || platform == Platform.macCatalyst else {
                throw invalid(name, "unsupported Mach-O platform \(platform); expected iOS (2) or Mac Catalyst (6), or a zippered macOS/Catalyst dylib")
            }
        }
        guard builds.count <= 1, legacyVersions <= 1, builds.count + legacyVersions > 0 else {
            throw invalid(name, "missing or ambiguous iOS/Mac Catalyst platform metadata")
        }
        return parsed
    }

    private static func isZipperedCatalystDylib(_ data: Data, image: Image) -> Bool {
        guard readU32(data, image.slice.offset + 12) == 6 else { return false } // MH_DYLIB
        let builds = image.commands.filter { $0.kind == LoadCommand.buildVersion }
        guard builds.count == 2 else { return false }
        let first = readU32(data, builds[0].offset + 8)
        let second = readU32(data, builds[1].offset + 8)
        return (first == Platform.macOS && second == Platform.macCatalyst)
            || (first == Platform.macCatalyst && second == Platform.macOS)
    }

    // MARK: - Transactional mutations

    /// Unknown non-Mach-O data remains a no-op. Recognized but malformed,
    /// unsupported or encrypted images throw without changing the inout value.
    /// In a fat container only the selected portable ARM64 slice is patched.
    @discardableResult
    static func patch(_ data: inout Data, platform: UInt32 = Platform.macCatalyst) throws -> Bool {
        let original = Data(data)
        guard looksLikeMachO(original) else { return false }
        let parsed = try preparationImage(original, name: "Mach-O image")
        var candidate = original
        let changed = try patchPlatform(&candidate, image: parsed, platform: platform)
        if changed {
            _ = try preparationImage(candidate, name: parsed.name)
            data = candidate
        }
        return changed
    }

    private static func patchPlatform(_ data: inout Data, image: Image, platform: UInt32) throws -> Bool {
        guard platform == Platform.iOS || platform == Platform.macCatalyst else {
            throw invalid(image.name, "unsupported target platform \(platform)")
        }
        if isZipperedCatalystDylib(data, image: image) {
            guard platform == Platform.macCatalyst else {
                throw invalid(image.name, "zippered macOS/Catalyst dylibs cannot be retargeted to iOS")
            }
            return false
        }
        let build = image.commands.first { $0.kind == LoadCommand.buildVersion }
        let legacy = image.commands.first { $0.kind == LoadCommand.versionMinIPhoneOS }
        if let build {
            let changed = readU32(data, build.offset + 8) != platform
            writeU32(&data, build.offset + 8, platform)
            if let legacy { removeLoadCommand(&data, image: image, command: legacy) }
            return changed || legacy != nil
        }
        guard let legacy else { throw invalid(image.name, "missing platform metadata") }
        let growth = max(0, 24 - legacy.size)
        guard hasPadding(data, image: image, size: growth) else {
            throw invalid(image.name, "insufficient zero-filled header padding for legacy build-version replacement")
        }
        let minos = readU32(data, legacy.offset + 8)
        let sdk = readU32(data, legacy.offset + 12)
        let delta = 24 - legacy.size
        let newEnd = image.commandsEnd + delta
        let tail = Array(data[legacy.end..<image.commandsEnd])
        let at = legacy.offset
        data.replaceSubrange((at + 24)..<newEnd, with: tail)
        data.replaceSubrange(at..<(at + 24), with: repeatElement(UInt8(0), count: 24))
        if delta < 0 {
            data.replaceSubrange(newEnd..<image.commandsEnd, with: repeatElement(UInt8(0), count: -delta))
        }
        writeU32(&data, image.slice.offset + 20, UInt32(newEnd - image.slice.offset - MachO.headerSize))
        writeU32(&data, at, LoadCommand.buildVersion)
        writeU32(&data, at + 4, 24)
        writeU32(&data, at + 8, platform)
        writeU32(&data, at + 12, minos)
        writeU32(&data, at + 16, sdk)
        writeU32(&data, at + 20, 0)
        return true
    }

    /// Thinning, platform edits and linkedit edits are committed together.
    @discardableResult
    static func patchFile(at url: URL) throws -> Bool {
        try mutateFile(at: url, thin: true) { data, parsed in
            var changed = try patchPlatform(&data, image: parsed, platform: Platform.macCatalyst)
            let updated = try image(data, slice: parsed.slice, name: parsed.name)
            if try repairChainedFixups(&data, image: updated) { changed = true }
            if try weakenUnavailableImports(&data, image: updated) { changed = true }
            return changed
        }
    }

    @discardableResult
    static func thinToARM64(at url: URL) throws -> Bool {
        try mutateFile(at: url, thin: true) { _, _ in false }
    }

    private static func mutateFile(
        at url: URL, thin: Bool, mutation: (inout Data, Image) throws -> Bool
    ) throws -> Bool {
        let original = try Data(contentsOf: url)
        guard looksLikeMachO(original) else { return false }
        let parsed = try preparationImage(original, name: url.lastPathComponent)
        let thinned = thin && (parsed.slice.offset != 0 || parsed.slice.size != original.count)
        var candidate = thinned ? original.subdata(in: parsed.slice.range) : original
        let workingImage: Image
        if thinned {
            workingImage = try preparationImage(candidate, name: parsed.name)
        } else {
            workingImage = parsed
        }
        let changed = try mutation(&candidate, workingImage)
        guard thinned || changed else { return false }
        _ = try preparationImage(candidate, name: parsed.name)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        try candidate.write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return true
    }

    // MARK: - Chained fixups and imports

    private static func fixupsRange(_ data: Data, image: Image) throws -> Range<Int>? {
        guard let command = image.commands.first(where: { $0.kind == LoadCommand.chainedFixups }) else { return nil }
        let range = try payloadRange(offset: UInt64(readU32(data, command.offset + 8)),
                                     size: UInt64(readU32(data, command.offset + 12)), slice: image.slice, name: image.name)
        guard range.count >= 28 else { throw invalid(image.name, "truncated chained-fixups header") }
        guard readU32(data, range.lowerBound) == 0 else { throw invalid(image.name, "unsupported chained-fixups version") }
        return range
    }

    /// Only drops trailing empty entries; retained pointer chains are not moved
    /// or re-encoded. This is not a validator/emulator for every pointer format.
    private static func repairChainedFixups(_ data: inout Data, image: Image) throws -> Bool {
        guard let range = try fixupsRange(data, image: image) else { return false }
        let segments = image.commands.filter { $0.kind == LoadCommand.segment64 }.count
        let relative = Int(readU32(data, range.lowerBound + 4))
        guard relative >= 28, relative <= range.count - 4 else { throw invalid(image.name, "invalid chained-fixups starts offset") }
        let starts = range.lowerBound + relative
        let count = Int(readU32(data, starts))
        guard count <= (range.upperBound - starts - 4) / 4 else { throw invalid(image.name, "chained-fixups starts table exceeds its blob") }
        guard segments > 0, count > segments else { return false }
        for index in segments..<count where readU32(data, starts + 4 + index * 4) != 0 { return false }
        writeU32(&data, starts, UInt32(segments))
        return true
    }

    private static func weakenUnavailableImports(_ data: inout Data, image: Image) throws -> Bool {
        var changed = false
        if let range = try fixupsRange(data, image: image) {
            let start = range.lowerBound
            let count = Int(readU32(data, start + 16))
            if count > 0 {
                let format = readU32(data, start + 20)
                let stride: Int
                switch format {
                case 1: stride = 4
                case 2: stride = 8
                case 3: stride = 16
                default: throw invalid(image.name, "unsupported chained-import format \(format)")
                }
                let symbolsFormat = readU32(data, start + 24)
                guard symbolsFormat == 0 else {
                    throw invalid(image.name, "unsupported chained-fixups symbols_format \(symbolsFormat)")
                }
                let imports = Int(readU32(data, start + 8))
                let symbols = Int(readU32(data, start + 12))
                guard imports >= 28, imports <= range.count, count <= (range.count - imports) / stride,
                      symbols >= imports + count * stride, symbols < range.count else {
                    throw invalid(image.name, "invalid chained-import or symbol-pool bounds")
                }
                for index in 0..<count {
                    let entry = start + imports + index * stride
                    let raw = readU32(data, entry)
                    let weakBit: UInt32 = format == 3 ? 0x1_0000 : 0x100
                    let nameOffset = Int(format == 3 ? readU32(data, entry + 4) : raw >> 9)
                    guard nameOffset < range.count - symbols else { throw invalid(image.name, "chained-import name exceeds symbol pool") }
                    let name = try symbolNameBytes(data, in: (start + symbols + nameOffset)..<range.upperBound, name: image.name)
                    if raw & weakBit == 0, unavailableSystemSymbols.contains(name) {
                        // In ADDEND64 the name is the upper word and the addend
                        // is the next 64 bits. Neither is part of this write.
                        writeU32(&data, entry, raw | weakBit)
                        changed = true
                    }
                }
            }
        }
        if let command = image.commands.first(where: { $0.kind == LoadCommand.symtab }) {
            let symbols = image.slice.offset + Int(readU32(data, command.offset + 8))
            let count = Int(readU32(data, command.offset + 12))
            let strings = image.slice.offset + Int(readU32(data, command.offset + 16))
            let stringSize = Int(readU32(data, command.offset + 20))
            for index in 0..<count {
                let entry = symbols + index * 16
                let type = data[entry + 4]
                guard type & 0xEE == 0 else { continue } // Only non-debug N_UNDF entries are imports.
                let nameOffset = Int(readU32(data, entry))
                guard nameOffset < stringSize else { throw invalid(image.name, "symbol name exceeds string table") }
                let name = try symbolNameBytes(data, in: (strings + nameOffset)..<(strings + stringSize), name: image.name)
                guard unavailableSystemSymbols.contains(name) else { continue }
                let desc = readU16(data, entry + 6)
                if desc & 0x0040 == 0 {
                    writeU16(&data, entry + 6, desc | 0x0040)
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: - Read-only symbol and dependency inspection

    static func containsSymbol(at url: URL, named symbol: String) -> Bool {
        let bytes = Data(symbol.utf8)
        return containsSymbol(at: url) { $0 == bytes }
    }

    static func containsSymbol(at url: URL, withPrefix prefix: String) -> Bool {
        let bytes = Data(prefix.utf8)
        return containsSymbol(at: url) { $0.starts(with: bytes) }
    }

    private static func containsSymbol(at url: URL, matching predicate: (Data) -> Bool) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? selectedImage(data, name: url.lastPathComponent),
              let command = parsed.commands.first(where: { $0.kind == LoadCommand.symtab }) else { return false }
        let symbols = parsed.slice.offset + Int(readU32(data, command.offset + 8))
        let strings = parsed.slice.offset + Int(readU32(data, command.offset + 16))
        let stringSize = Int(readU32(data, command.offset + 20))
        for index in 0..<Int(readU32(data, command.offset + 12)) {
            let nameOffset = Int(readU32(data, symbols + index * 16))
            guard nameOffset < stringSize,
                  let name = try? symbolNameBytes(data, in: (strings + nameOffset)..<(strings + stringSize), name: parsed.name) else { return false }
            if predicate(name) { return true }
        }
        return false
    }

    static func hasLoadDylib(at url: URL, containing token: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? selectedImage(data, name: url.lastPathComponent) else { return false }
        return parsed.commands.contains { command in
            guard command.kind == LoadCommand.loadDylib || command.kind == LoadCommand.loadWeakDylib,
                  let path = try? commandPath(data, command: command, name: parsed.name) else { return false }
            return path.contains(token)
        }
    }

    // MARK: - Load command edits

    @discardableResult
    static func addLoadDylib(at url: URL, path dylibPath: String) throws -> Bool {
        try mutateFile(at: url, thin: true) { data, parsed in
            if try parsed.commands.contains(where: { command in
                guard command.kind == LoadCommand.loadDylib else { return false }
                return try commandPath(data, command: command, name: parsed.name) == dylibPath
            }) { return false }
            let bytes = try pathBytes(dylibPath, name: parsed.name)
            let size = (24 + bytes.count + 7) & ~7
            guard let at = reserveLoadCommand(&data, image: parsed, size: size) else {
                throw invalid(parsed.name, "insufficient zero-filled header padding for LC_LOAD_DYLIB")
            }
            writeU32(&data, at, LoadCommand.loadDylib)
            writeU32(&data, at + 4, UInt32(size))
            writeU32(&data, at + 8, 24)
            for (index, byte) in bytes.enumerated() { data[at + 24 + index] = byte }
            return true
        }
    }

    @discardableResult
    static func addRPath(at url: URL, path rpath: String) throws -> Bool {
        try mutateFile(at: url, thin: true) { data, parsed in
            if try parsed.commands.contains(where: { command in
                guard command.kind == LoadCommand.rpath else { return false }
                return try commandPath(data, command: command, name: parsed.name) == rpath
            }) { return false }
            let bytes = try pathBytes(rpath, name: parsed.name)
            let size = (12 + bytes.count + 7) & ~7
            guard let end = reserveLoadCommand(&data, image: parsed, size: size) else {
                throw invalid(parsed.name, "insufficient zero-filled header padding for LC_RPATH")
            }
            let at = parsed.commands.first { dependencyCommands.contains($0.kind) }?.offset ?? end
            if at < end {
                let tail = Array(data[at..<end])
                data.replaceSubrange((at + size)..<(end + size), with: tail)
            }
            data.replaceSubrange(at..<(at + size), with: repeatElement(UInt8(0), count: size))
            writeU32(&data, at, LoadCommand.rpath)
            writeU32(&data, at + 4, UInt32(size))
            writeU32(&data, at + 8, 12)
            for (index, byte) in bytes.enumerated() { data[at + 12 + index] = byte }
            return true
        }
    }

    /// Does not remap bind/import ordinals. Callers must only remove dependencies
    /// for which removal is safe; general dependency-ordinal rewriting is outside
    /// this patcher's preparation validation.
    @discardableResult
    static func removeLoadDylib(at url: URL, containing token: String) throws -> Bool {
        try mutateFile(at: url, thin: false) { data, parsed in
            let matches = try parsed.commands.filter { command in
                guard command.kind == LoadCommand.loadDylib || command.kind == LoadCommand.loadWeakDylib else { return false }
                return try commandPath(data, command: command, name: parsed.name).contains(token)
            }
            for command in matches.reversed() { removeLoadCommand(&data, image: parsed, command: command) }
            return !matches.isEmpty
        }
    }

    private static func hasPadding(_ data: Data, image: Image, size: Int) -> Bool {
        guard size >= 0, size <= image.paddingEnd - image.commandsEnd,
              size <= Int(UInt32.max) - (image.commandsEnd - image.slice.offset - MachO.headerSize) else { return false }
        return data[image.commandsEnd..<(image.commandsEnd + size)].allSatisfy { $0 == 0 }
    }

    private static func reserveLoadCommand(_ data: inout Data, image: Image, size: Int) -> Int? {
        guard hasPadding(data, image: image, size: size) else { return nil }
        let base = image.slice.offset
        let count = readU32(data, base + 16)
        let bytes = readU32(data, base + 20)
        writeU32(&data, base + 16, count + 1)
        writeU32(&data, base + 20, bytes + UInt32(size))
        return image.commandsEnd
    }

    private static func removeLoadCommand(_ data: inout Data, image: Image, command: Command) {
        let base = image.slice.offset
        let end = base + MachO.headerSize + Int(readU32(data, base + 20))
        let tail = Array(data[command.end..<end])
        data.replaceSubrange(command.offset..<(end - command.size), with: tail)
        data.replaceSubrange((end - command.size)..<end, with: repeatElement(UInt8(0), count: command.size))
        let count = readU32(data, base + 16)
        let bytes = readU32(data, base + 20)
        writeU32(&data, base + 16, count - 1)
        writeU32(&data, base + 20, bytes - UInt32(command.size))
    }

    private static func commandPath(_ data: Data, command: Command, name: String) throws -> String {
        let start = command.offset + Int(readU32(data, command.offset + 8))
        return try string(data, in: start..<command.end, name: name)
    }

    private static func pathBytes(_ path: String, name: String) throws -> [UInt8] {
        guard !path.isEmpty, !path.utf8.contains(0), path.utf8.count <= Int(UInt32.max) - 32 else {
            throw invalid(name, "invalid load-command path")
        }
        return Array(path.utf8) + [0]
    }

    /// Symbol names are arbitrary NUL-terminated bytes, not UTF-8 strings.
    private static func symbolNameBytes(_ data: Data, in range: Range<Int>, name: String) throws -> Data {
        guard let end = data[range].firstIndex(of: 0) else {
            throw invalid(name, "unterminated Mach-O symbol name")
        }
        return data[range.lowerBound..<end]
    }

    private static func string(_ data: Data, in range: Range<Int>, name: String) throws -> String {
        guard let end = data[range].firstIndex(of: 0),
              let value = String(data: data[range.lowerBound..<end], encoding: .utf8) else {
            throw invalid(name, "unterminated or invalid Mach-O string")
        }
        return value
    }

    // MARK: - Bounded callers provide byte access ranges

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) | UInt32(data[start + 1]) << 8
            | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readU32(data, offset)) | UInt64(readU32(data, offset + 4)) << 32
    }

    private static func readBeU32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) << 24 | UInt32(data[start + 1]) << 16
            | UInt32(data[start + 2]) << 8 | UInt32(data[start + 3])
    }

    private static func readBeU64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readBeU32(data, offset)) << 32 | UInt64(readBeU32(data, offset + 4))
    }

    private static func writeU16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        for index in 0..<2 { data[data.startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private static func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { data[data.startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
