import Foundation

/// Rewrites Mach-O binaries in place so an iOS app can be loaded as a Mac
/// Catalyst binary by macOS.
///
/// This is a pure-Swift, in-place patcher: it only overwrites 4-byte fields
/// inside existing load commands, so no command size changes are needed. The
/// code signature is invalidated by design and is refreshed afterwards.
///
/// What it does, per 64-bit Mach-O image:
///   - `LC_BUILD_VERSION`            : platform  iOS (2) → Mac Catalyst (6)
///   - `LC_VERSION_MIN_IPHONEOS`     : command  → `LC_VERSION_MIN_MACOSX`
///   - legacy load commands          : guard field → 0 during preparation
///
/// Universal (fat) binaries are handled too: macOS can only execute the arm64
/// slice, so that slice is what gets patched. A 32-bit armv7 slice is ignored
/// (and cannot run on arm64 anyway). Missing this was why some apps came
/// back `Killed: 9`: their platform was never rewritten, so the kernel refused
/// to launch an "iOS" image.
enum BinaryPatcher {

    // MARK: - Constants

    enum MachO {
        static let magic64: UInt32 = 0xFEEDFACF
        static let headerSize = 32

        // Fat (universal) headers are big-endian.
        static let fatMagic: UInt32 = 0xCAFEBABE
        static let fatMagic64: UInt32 = 0xCAFEBABF
        static let fatArchSize: Int = 20
        static let fatArchSize64: Int = 32
        static let cpuTypeARM64: UInt32 = 0x0100_000C
    }

    enum Platform {
        static let macOS: UInt32 = 1
        static let iOS: UInt32 = 2
        static let macCatalyst: UInt32 = 6
    }

    enum LoadCommand {
        static let segment64: UInt32 = 0x19
        static let loadDylib: UInt32 = 0x0C
        static let loadWeakDylib: UInt32 = 0x8000_0018
        static let reexportDylib: UInt32 = 0x8000_001F
        static let rpath: UInt32 = 0x8000_001C
        static let versionMinMacOSX: UInt32 = 0x24
        static let versionMinIPhoneOS: UInt32 = 0x25
        static let legacyGuard32: UInt32 = 0x21
        static let legacyGuard64: UInt32 = 0x2C
        static let buildVersion: UInt32 = 0x32
    }

    // MARK: - Detection

    /// True if `data` is a Mach-O image this patcher can rewrite: either a thin
    /// 64-bit image or a universal (fat) container that may hold one.
    static func isMachO64(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        if readU32(data, 0) == MachO.magic64 { return true }
        let magic = readBeU32(data, 0)
        return magic == MachO.fatMagic || magic == MachO.fatMagic64
    }

    /// True if the file at `url` looks patchable. Reads only the first 4 bytes,
    /// so it is cheap for large trees.
    static func fileIsMachO64(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        if readU32(head, 0) == MachO.magic64 { return true }
        let magic = readBeU32(head, 0)
        return magic == MachO.fatMagic || magic == MachO.fatMagic64
    }

    /// True if the image at `url` still carries a legacy guard field.
    ///
    /// Such an image was not prepared for this platform and can fault on
    /// execution. It is reported so a launch failure is not mistaken for a
    /// shim problem.
    static func hasLegacyGuardMarkers(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        for base in machO64Offsets(data) {
            let ncmds = Int(readU32(data, base + 16))
            var offset = base + MachO.headerSize
            for _ in 0..<ncmds {
                guard offset + 8 <= data.count else { break }
                let cmd = readU32(data, offset)
                let cmdsize = Int(readU32(data, offset + 4))
                guard cmdsize >= 8, offset + cmdsize <= data.count else { break }
                if cmd == LoadCommand.legacyGuard64, cmdsize >= 24,
                   readU32(data, offset + 16) != 0 { return true }
                if cmd == LoadCommand.legacyGuard32, cmdsize >= 20,
                   readU32(data, offset + 16) != 0 { return true }
                offset += cmdsize
            }
        }
        return false
    }

    /// File offsets of every 64-bit Mach-O image inside `data`.
    ///
    /// For a thin image that is just `[0]`. For a fat container it is the offset
    /// of each 64-bit slice (the 32-bit armv7 slices are skipped).
    static func machO64Offsets(_ data: Data) -> [Int] {
        guard data.count >= 4 else { return [] }
        if readU32(data, 0) == MachO.magic64 { return [0] }

        let magic = readBeU32(data, 0)
        guard magic == MachO.fatMagic || magic == MachO.fatMagic64 else { return [] }
        guard data.count >= 8 else { return [] }

        let count = Int(readBeU32(data, 4))
        let stride = magic == MachO.fatMagic64 ? MachO.fatArchSize64 : MachO.fatArchSize

        var offsets: [Int] = []
        var entry = 8
        for _ in 0..<count {
            guard entry + stride <= data.count else { break }
            let cpuType = readBeU32(data, entry)
            let offset = Int(readBeU32(data, entry + 8))
            let size = Int(readBeU32(data, entry + 12))
            if cpuType == MachO.cpuTypeARM64,
               offset >= 0, size > 0,
               offset + 4 <= data.count,
               offset + size <= data.count,
               readU32(data, offset) == MachO.magic64 {
                offsets.append(offset)
            }
            entry += stride
        }
        return offsets
    }

    // MARK: - Patching

    /// Patches every 64-bit Mach-O image in `data` in place.
    /// - Returns: `true` if anything was changed.
    @discardableResult
    static func patch(
        _ data: inout Data,
        platform: UInt32 = Platform.macCatalyst
    ) throws -> Bool {
        var changed = false
        for base in machO64Offsets(data) {
            if try patch(&data, base: base, platform: platform) {
                changed = true
            }
        }
        return changed
    }

    /// Patches a single Mach-O image located at `base` in `data`.
    private static func patch(
        _ data: inout Data,
        base: Int,
        platform: UInt32
    ) throws -> Bool {
        guard base + MachO.headerSize <= data.count else {
            throw PearError.invalidPackage("truncated Mach-O header")
        }

        let ncmds = Int(readU32(data, base + 16))
        var offset = base + MachO.headerSize
        var changed = false
        var buildVersionOffset: Int? = nil
        var versionMin: (offset: Int, size: Int)? = nil

        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = readU32(data, offset)
            let cmdsize = Int(readU32(data, offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= data.count else { break }

            switch cmd {
            case LoadCommand.buildVersion where cmdsize >= 24:
                buildVersionOffset = offset

            case LoadCommand.legacyGuard64 where cmdsize >= 24:
                // cmd, cmdsize, dataoff, datasize, guard, pad
                if readU32(data, offset + 16) != 0 {
                    writeU32(&data, offset + 16, 0)
                    changed = true
                }

            case LoadCommand.legacyGuard32 where cmdsize >= 20:
                if readU32(data, offset + 16) != 0 {
                    writeU32(&data, offset + 16, 0)
                    changed = true
                }

            case LoadCommand.versionMinIPhoneOS where cmdsize >= 16:
                if versionMin == nil { versionMin = (offset, cmdsize) }

            default:
                break
            }

            offset += cmdsize
        }

        if let buildVersionOffset {
            if readU32(data, buildVersionOffset + 8) != platform {
                writeU32(&data, buildVersionOffset + 8, platform)
                changed = true
            }
        } else {
            // Older binaries only carry `LC_VERSION_MIN_IPHONEOS`, which the
            // system still reads to decide the platform — and having it present
            // makes AMFI reject the process ("Security policy would not allow
            // process"). Simply renaming it to `LC_VERSION_MIN_MACOSX` is not
            // enough either. Drop it entirely and add a real `LC_BUILD_VERSION`
            // with platform 6 (Mac Catalyst), which is what actually loads.
            if let versionMin {
                removeLoadCommand(&data, base: base, at: versionMin.offset, size: versionMin.size)
                changed = true
            }
            if addBuildVersion(&data, base: base, platform: platform) {
                changed = true
            }
        }

        return changed
    }

    /// Removes a load command from the command area by sliding the following
    /// commands down. Only the command bytes move; section data keeps its
    /// absolute offsets, so nothing else has to be adjusted.
    private static func removeLoadCommand(_ data: inout Data, base: Int, at offset: Int, size: Int) {
        let ncmds = Int(readU32(data, base + 16))
        let sizeofcmds = Int(readU32(data, base + 20))
        let commandsEnd = base + MachO.headerSize + sizeofcmds

        let from = offset + size
        let count = commandsEnd - from
        if count > 0 {
            let tail = Array(data[from..<from + count])
            for (i, byte) in tail.enumerated() { data[offset + i] = byte }
        }

        writeU32(&data, base + 16, UInt32(ncmds - 1))
        writeU32(&data, base + 20, UInt32(sizeofcmds - size))
    }

    /// Appends a fresh `LC_BUILD_VERSION` command in the header padding.
    private static func addBuildVersion(_ data: inout Data, base: Int, platform: UInt32) -> Bool {
        guard let at = reserveLoadCommand(&data, base: base, size: 24) else { return false }

        let version: UInt32 = 0x000D_0000 // 13.0
        writeU32(&data, at + 0, LoadCommand.buildVersion)
        writeU32(&data, at + 4, 24)
        writeU32(&data, at + 8, platform)
        writeU32(&data, at + 12, version) // minos
        writeU32(&data, at + 16, version) // sdk
        writeU32(&data, at + 20, 0)       // ntools
        return true
    }

    /// Reserves `size` bytes of trailing header padding for a new load command.
    /// Updates the command count/size and returns the offset to write at, or
    /// `nil` when the padding is too small (the image is left untouched).
    private static func reserveLoadCommand(_ data: inout Data, base: Int, size: Int) -> Int? {
        let ncmds = Int(readU32(data, base + 16))
        let sizeofcmds = Int(readU32(data, base + 20))
        let endCommands = base + MachO.headerSize + sizeofcmds

        let firstSection = firstSectionOffset(data, base: base, ncmds: ncmds)
        guard endCommands + size <= firstSection else { return nil }

        writeU32(&data, base + 16, UInt32(ncmds + 1))
        writeU32(&data, base + 20, UInt32(sizeofcmds + size))
        return endCommands
    }

    /// Inserts a load command before the first library dependency. Dyld resolves
    /// an `@rpath/...` dependency while walking the commands, so an `LC_RPATH`
    /// appended after it is seen too late. The platform linker emits run paths
    /// before the dylib commands; this reproduces that order without changing
    /// section offsets.
    private static func insertLoadCommandBeforeDependencies(_ data: inout Data,
                                                              base: Int,
                                                              size: Int) -> Int? {
        let ncmds = Int(readU32(data, base + 16))
        let sizeofcmds = Int(readU32(data, base + 20))
        let endCommands = base + MachO.headerSize + sizeofcmds
        let firstSection = firstSectionOffset(data, base: base, ncmds: ncmds)
        guard endCommands + size <= firstSection else { return nil }

        var offset = base + MachO.headerSize
        var insertion = endCommands
        for _ in 0..<ncmds {
            guard offset + 8 <= endCommands else { break }
            let cmd = readU32(data, offset)
            let cmdsize = Int(readU32(data, offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= endCommands else { break }
            if cmd == LoadCommand.loadDylib
                || cmd == LoadCommand.loadWeakDylib
                || cmd == LoadCommand.reexportDylib {
                insertion = offset
                break
            }
            offset += cmdsize
        }

        let tailCount = endCommands - insertion
        if tailCount > 0 {
            var i = tailCount - 1
            while i >= 0 {
                data[insertion + size + i] = data[insertion + i]
                i -= 1
            }
        }

        writeU32(&data, base + 16, UInt32(ncmds + 1))
        writeU32(&data, base + 20, UInt32(sizeofcmds + size))
        return insertion
    }

    /// Patches the Mach-O file at `url` in place, preserving file permissions.
    /// Universal binaries are first reduced to their arm64 slice.
    /// - Returns: `true` if the file was changed.
    @discardableResult
    static func patchFile(at url: URL) throws -> Bool {
        var changed = try thinToARM64(at: url)

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber

        var data = try Data(contentsOf: url)
        guard isMachO64(data) else { return changed }

        if try patch(&data) {
            try data.write(to: url)
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            changed = true
        }
        return changed
    }

    /// Rewrites a universal (fat) binary as a thin arm64 one, preserving file
    /// permissions. Returns `true` if the file was fat.
    ///
    /// macOS will not launch one of these apps while a 32-bit armv7 slice is
    /// present: the Mac scene wrapper never gets a main scene identifier and the
    /// app aborts. The
    /// armv7 slice cannot execute on arm64 anyway, so dropping it is
    /// harmless.
    @discardableResult
    static func thinToARM64(at url: URL) throws -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber

        let data = try Data(contentsOf: url)
        guard data.count >= 8 else { return false }
        let magic = readBeU32(data, 0)
        guard magic == MachO.fatMagic || magic == MachO.fatMagic64 else { return false }

        // Find the arm64 slice's file range.
        let count = Int(readBeU32(data, 4))
        let stride = magic == MachO.fatMagic64 ? MachO.fatArchSize64 : MachO.fatArchSize
        var sliceOffset: Int? = nil
        var sliceSize = 0
        var entry = 8
        for _ in 0..<count {
            guard entry + stride <= data.count else { break }
            let cpuType = readBeU32(data, entry)
            if cpuType == MachO.cpuTypeARM64 {
                sliceOffset = Int(readBeU32(data, entry + 8))
                sliceSize = Int(readBeU32(data, entry + 12))
                break
            }
            entry += stride
        }

        guard let offset = sliceOffset, sliceSize > 0, offset + sliceSize <= data.count else {
            return false
        }

        let slice = data.subdata(in: offset..<(offset + sliceSize))
        try slice.write(to: url)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return true
    }

    // MARK: - Load command addition

    /// Adds an `LC_LOAD_DYLIB` command to each 64-bit Mach-O image in the file,
    /// writing it into the header padding so no section data has to move. This
    /// is how the runtime library is loaded: the older environment-variable
    /// loading path is refused for these processes, but a real load command is
    /// honored.
    ///
    /// - Returns: `true` if the command was added (false if already present or
    ///   the file holds no 64-bit Mach-O image).
    @discardableResult
    static func addLoadDylib(at url: URL, path dylibPath: String) throws -> Bool {
        let fileManager = FileManager.default
        _ = try thinToARM64(at: url)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber

        var data = try Data(contentsOf: url)
        let bases = machO64Offsets(data)
        guard !bases.isEmpty else { return false }

        var changed = false
        for base in bases {
            if addLoadDylib(&data, base: base, path: dylibPath) {
                changed = true
            }
        }
        guard changed else { return false }

        try data.write(to: url)
        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return true
    }

    private static func addLoadDylib(_ data: inout Data, base: Int, path dylibPath: String) -> Bool {
        let ncmds = Int(readU32(data, base + 16))
        if containsLoadDylib(data, base: base, ncmds: ncmds, path: dylibPath) { return false }

        let pathBytes = Array(dylibPath.utf8) + [0]
        var cmdsize = 24 + pathBytes.count
        cmdsize = (cmdsize + 7) & ~7

        guard let at = reserveLoadCommand(&data, base: base, size: cmdsize) else { return false }

        writeU32(&data, at + 0, LoadCommand.loadDylib)
        writeU32(&data, at + 4, UInt32(cmdsize))
        writeU32(&data, at + 8, 24)   // dylib.name offset
        writeU32(&data, at + 12, 0)   // timestamp
        writeU32(&data, at + 16, 0)   // current_version
        writeU32(&data, at + 20, 0)   // compatibility_version
        for (i, byte) in pathBytes.enumerated() { data[at + 24 + i] = byte }
        return true
    }

    /// Adds an `LC_RPATH` command to every 64-bit Mach-O image in the file.
    ///
    /// A package prepared from a store build often has dependencies written as
    /// `@rpath/Foo.framework/Foo` but no matching run-path command. The
    /// dynamic linker then searches only the system fallback and fails with
    /// "Library not loaded" before the app's main function runs. Adding the
    /// bundle's own Frameworks directory restores the layout the build
    /// expected.
    @discardableResult
    static func addRPath(at url: URL, path rpath: String) throws -> Bool {
        let fileManager = FileManager.default
        _ = try thinToARM64(at: url)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber

        var data = try Data(contentsOf: url)
        let bases = machO64Offsets(data)
        guard !bases.isEmpty else { return false }

        var changed = false
        for base in bases {
            if addRPath(&data, base: base, path: rpath) {
                changed = true
            }
        }
        guard changed else { return false }

        try data.write(to: url)
        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return true
    }

    private static func addRPath(_ data: inout Data, base: Int, path rpath: String) -> Bool {
        let ncmds = Int(readU32(data, base + 16))
        if containsCommandPath(data, base: base, ncmds: ncmds,
                              command: LoadCommand.rpath, path: rpath) {
            return false
        }

        let pathBytes = Array(rpath.utf8) + [0]
        var cmdsize = 12 + pathBytes.count
        cmdsize = (cmdsize + 7) & ~7

        guard let at = insertLoadCommandBeforeDependencies(&data, base: base, size: cmdsize) else {
            return false
        }

        writeU32(&data, at + 0, LoadCommand.rpath)
        writeU32(&data, at + 4, UInt32(cmdsize))
        writeU32(&data, at + 8, 12) // path offset
        for (i, byte) in pathBytes.enumerated() { data[at + 12 + i] = byte }
        return true
    }

    private static func containsLoadDylib(_ data: Data, base: Int, ncmds: Int, path: String) -> Bool {
        containsCommandPath(data, base: base, ncmds: ncmds,
                            command: LoadCommand.loadDylib, path: path)
    }

    private static func containsCommandPath(_ data: Data, base: Int, ncmds: Int,
                                            command: UInt32, path: String) -> Bool {
        var offset = base + MachO.headerSize
        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = readU32(data, offset)
            let cmdsize = Int(readU32(data, offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= data.count else { break }

            if cmd == command {
                let nameOffset = Int(readU32(data, offset + 8))
                guard nameOffset >= 8, nameOffset < cmdsize else {
                    offset += cmdsize
                    continue
                }
                var name = ""
                var i = offset + nameOffset
                while i < offset + cmdsize, data[i] != 0 {
                    name.append(Character(UnicodeScalar(data[i])))
                    i += 1
                }
                if name == path { return true }
            }
            offset += cmdsize
        }
        return false
    }

    /// Smallest file offset among all sections — the first byte of real content.
    /// Returns an absolute file offset (relative to the start of `data`), so it
    /// can be compared directly against `base + headerSize + sizeofcmds`.
    private static func firstSectionOffset(_ data: Data, base: Int, ncmds: Int) -> Int {
        var minimum = Int.max
        var offset = base + MachO.headerSize
        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = readU32(data, offset)
            let cmdsize = Int(readU32(data, offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= data.count else { break }

            if cmd == LoadCommand.segment64, offset + 72 <= data.count {
                let sections = Int(readU32(data, offset + 64))
                var sectionOffset = offset + 72
                for _ in 0..<sections where sectionOffset + 52 <= data.count {
                    let fileOffset = Int(readU32(data, sectionOffset + 48))
                    if fileOffset > 0, fileOffset < minimum { minimum = fileOffset }
                    sectionOffset += 80
                }
            }
            offset += cmdsize
        }
        // Section offsets are relative to the slice; map back to the file.
        return minimum == Int.max ? data.count : base + minimum
    }

    // MARK: - Little-endian access

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    private static func readBeU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }

    private static func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xFF)
        data[base + 1] = UInt8((value >> 8) & 0xFF)
        data[base + 2] = UInt8((value >> 16) & 0xFF)
        data[base + 3] = UInt8((value >> 24) & 0xFF)
    }
}
