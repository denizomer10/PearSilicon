import Darwin
import Foundation

/// How an app is prepared to run on macOS.
///
/// `.compatibility` loads the in-process compatibility runtime through an
/// `LC_LOAD_DYLIB` entry. Runtime hooks adapt selected API behavior.
///
/// `.nativeContainer` removes PearSilicon's runtime artifacts. Despite the name,
/// this preparation mode does not itself add App Sandbox entitlements or
/// establish secure per-app isolation.
 enum PreparationMode: String, Sendable {
    case compatibility
    /// Same in-process runtime, but loaded by the launcher through
    /// `DYLD_INSERT_LIBRARIES` instead of an `LC_LOAD_DYLIB` in the app binary.
    /// Experimental launcher loading with a local KV/static-device-profile host.
    case compatibilityEnvironment
    case nativeContainer
}

/// Installs app package files into the library, prepares them to run on macOS,
/// scans the library and removes apps.
///
/// Installation pipeline:
///   1. unzip the package (it is a zip) into a temporary directory
///   2. locate `Payload/*.app` and read its `Info.plist`
///   3. move a copy into the app library
///   4. *prepare for macOS*: rewrite Info.plist, remove stale signature sidecars and
///      patch every Mach-O platform (iOS → Mac Catalyst)
///   5. adhoc re-sign with the entitlements the loader needs
///
/// Steps 4–5 are what allows an arm64 iOS binary to be loaded by macOS via the
/// `/System/iOSSupport` runtime. This is interoperability work only: it adapts
/// the binary's declared platform and leaves all application logic untouched.
final class PackageInstaller: @unchecked Sendable {

    /// Injectable operations keep mode-switch failure tests on synthetic bundles.
    struct PreparationTools {
        var runtimeLibraryURL: () -> URL? = { AppLauncher.runtimeLibraryURL() }
        var removeLoadDylib: (URL, String) throws -> Bool = {
            try BinaryPatcher.removeLoadDylib(at: $0, containing: $1)
        }
        var run: (String, [String]) throws -> String = { try Shell.run($0, $1) }
    }

    private let fileManager = FileManager.default
    private let libraryURL: URL
    private let workRoot: URL
    private let preparationTools: PreparationTools

    /// Files that still carried a legacy guard field at the last install. Such
    /// a file was not prepared for this platform and its app may not launch;
    /// surface this to the user instead of failing silently.
    private(set) var unpreparedBinaries: [String] = []

    /// Files whose ZIP entry failed its CRC check at the last install. `unzip`
    /// still extracts them, but the bytes are damaged; the app may crash when
    /// it reads one. Reported instead of aborting the whole install.
    private(set) var corruptedFiles: [String] = []

    init(libraryURL: URL, preparationTools: PreparationTools = PreparationTools()) {
        self.libraryURL = libraryURL
        self.preparationTools = preparationTools
        self.workRoot = libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent("Work", isDirectory: true)
    }

    // MARK: - Scanning

    func scanLibrary() throws -> [InstalledApp] {
        guard fileManager.fileExists(atPath: libraryURL.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { $0.pathExtension == "app" }
            .compactMap { try? makeInstalledApp(fromBundleAt: $0) }
    }

    // MARK: - Install

    func install(packageAt url: URL, mode: PreparationMode = .compatibility) async throws -> InstalledApp {
        guard fileManager.fileExists(atPath: url.path) else {
            throw PearError.packageNotFound(url.lastPathComponent)
        }

        let tempDir = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // 1) unzip
        //
        // `unzip` exits 2 when an entry fails its CRC check, but it still
        // extracts every other entry. Aborting here would reject an otherwise
        // usable app package because of one damaged asset, so keep the extracted tree
        // and report the damaged files instead.
        corruptedFiles = []
        let unzip = try Shell.runAllowingFailure(
            "/usr/bin/unzip", ["-o", "-q", url.path, "-d", tempDir.path]
        )
        if unzip.status != 0 {
            let badCRC = unzip.output
                .split(separator: "\n")
                .filter { $0.contains("bad CRC") }
            corruptedFiles = badCRC.map { line in
                var text = String(line)
                if let range = text.range(of: "  bad CRC") {
                    text = String(text[..<range.lowerBound])
                }
                text = text.trimmingCharacters(in: .whitespaces)
                // Show the path inside the app, not the temporary work dir.
                if let range = text.range(of: ".app/") {
                    text = String(text[range.upperBound...])
                }
                return text
            }
            if corruptedFiles.isEmpty {
                throw PearError.commandFailed(
                    tool: "unzip", status: unzip.status, output: unzip.output
                )
            }
        }

        // 2) find Payload/*.app
        let payload = tempDir.appendingPathComponent("Payload", isDirectory: true)
        guard let app = try fileManager.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" }) else {
            throw PearError.invalidPackage("no .app inside Payload")
        }

        let probe = try makeInstalledApp(fromBundleAt: app)

        // 3) move into library
        let destination = libraryURL.appendingPathComponent("\(probe.id).app", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: app, to: destination)

        // 4) prepare for macOS and 5) sign
        do {
            try finalizeInstall(at: destination, mode: mode)
        } catch {
            // Never leave a half-prepared bundle in the library: it would show
            // up as installable but fail at launch.
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return try makeInstalledApp(fromBundleAt: destination)
    }

    /// Installs an already-built `.app` bundle (for example the product of a
    /// toolchain build) instead of a package. The bundle is copied as-is (ditto, so
    /// symlinks and extended attributes survive), then prepared and signed the
    /// same way an app package is.
    ///
    /// Simulator builds are rejected: their binaries target the simulator
    /// runtime and cannot be turned into Mac Catalyst binaries.
    func installBundle(at sourceURL: URL, mode: PreparationMode = .compatibility) async throws -> InstalledApp {
        // A bundle install never goes through `unzip`, so clear any result
        // left over from a previous app package install; otherwise the caller would
        // report that app package's damaged files against this bundle.
        corruptedFiles = []
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PearError.packageNotFound(sourceURL.lastPathComponent)
        }
        if isSimulatorBuild(at: sourceURL) {
            throw PearError.invalidPackage(
                "\(sourceURL.lastPathComponent) is a simulator build. "
                + "Build for a device (destination generic/platform=iOS) or run \"pearsilicon build\" instead."
            )
        }

        let probe = try makeInstalledApp(fromBundleAt: sourceURL)
        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)

        let destination = libraryURL.appendingPathComponent("\(probe.id).app", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try Shell.run("/usr/bin/ditto", [sourceURL.path, destination.path])

        do {
            try finalizeInstall(at: destination, mode: mode)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return try makeInstalledApp(fromBundleAt: destination)
    }

    /// Prepares a bundle that is already in the library and signs it.
    private func finalizeInstall(at destination: URL, mode: PreparationMode) throws {
        try prepareForMacOS(at: destination, mode: mode)
        try signBundle(at: destination, mode: mode)

        // Give the user a place to drop ODR packs that the app package does
        // not carry. The runtime merges this directory into its local resource
        // view at launch. Derived from this installer's library root so the
        // packs follow a relocated storage folder.
        let bundleID = destination.deletingPathExtension().lastPathComponent
        let odrRoot = libraryURL.deletingLastPathComponent()
            .appendingPathComponent("ODR", isDirectory: true)
        try? fileManager.createDirectory(
            at: odrRoot.appendingPathComponent(bundleID, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// True when the bundle declares itself as an iOS Simulator build.
    private func isSimulatorBuild(at bundleURL: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
            as? [String: Any] else { return false }
        if let platform = info["DTPlatformName"] as? String,
           platform.lowercased().contains("simulator") {
            return true
        }
        if let platforms = info["CFBundleSupportedPlatforms"] as? [String],
           platforms.contains(where: { $0.lowercased().contains("simulator") }) {
            return true
        }
        return false
    }

    // MARK: - Removal

    func uninstall(_ app: InstalledApp) throws {
        try fileManager.removeItem(at: app.bundleURL)
    }

    // MARK: - Relocation

    /// Rebases a copied app bundle from one storage root to another and signs
    /// the copy. The original bundle is never modified.
    ///
    /// The installer hard-codes absolute paths for the runtime and compatibility
    /// dylibs (some binaries reject `@` expansion), so a plain file move would
    /// leave every load command pointing at the old disk. This rewrites those
    /// commands inside the staged copy, then re-signs it with the same
    /// preparation mode it already had.
    func relocateInstalledBundle(
        at stagedBundleURL: URL, from originalBundleURL: URL, to targetBundleURL: URL
    ) throws {
        let oldRoot = originalBundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.path
        let newRoot = targetBundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.path
        guard oldRoot != newRoot else { return }
        try validateStagingIsolation(at: stagedBundleURL)

        let app = try makeInstalledApp(fromBundleAt: stagedBundleURL)
        var targets = Set<URL>([app.executableURL])
        targets.formUnion(codeObjects(in: stagedBundleURL))
        for file in targets {
            try relocateLoadPaths(at: file, oldRoot: oldRoot, newRoot: newRoot)
        }

        // Preserve the mode the copy already has; relocation must not update or
        // replace its runtime, only point its absolute paths at the new root.
        let mode: PreparationMode
        if fileManager.fileExists(atPath: Self.injectionMarkerURL(in: stagedBundleURL).path) {
            mode = .compatibilityEnvironment
        } else if BinaryPatcher.hasLoadDylib(at: app.executableURL, containing: "libPearRuntime") {
            mode = .compatibility
        } else {
            mode = .nativeContainer
        }
        try signBundle(at: stagedBundleURL, mode: mode)
        _ = try preparationTools.run(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedBundleURL.path]
        )
        guard !loadPaths(at: stagedBundleURL).contains(where: { $0.hasPrefix(oldRoot + "/") }) else {
            throw PearError.invalidPackage(
                "Relocation left a path pointing at the previous location in \(stagedBundleURL.lastPathComponent)"
            )
        }
    }

    private func loadPaths(at bundleURL: URL) -> [String] {
        let app = try? makeInstalledApp(fromBundleAt: bundleURL)
        var urls = Set<URL>()
        if let app { urls.insert(app.executableURL) }
        urls.formUnion(codeObjects(in: bundleURL))
        return urls.flatMap { (try? preparationLoadPaths(at: $0))?.flatMap {
            $0.dependencies.map(\.path) + $0.rpaths
        } ?? [] }
    }

    /// Rewrites load commands whose path starts at `oldRoot`. Strings that fit
    /// are rewritten in place; longer replacements fall back to
    /// `install_name_tool`, which can grow a load command when header space
    /// allows. Any failure propagates so the migration can roll back.
    private func relocateLoadPaths(at url: URL, oldRoot: String, newRoot: String) throws {
        let data = try Data(contentsOf: url)
        guard !BinaryPatcher.machO64Offsets(data).isEmpty else { return }
        var rewritten = data
        var changed = false
        var fallback: [(command: UInt32, old: String, new: String)] = []

        for base in BinaryPatcher.machO64Offsets(data) {
            let count = Int(readU32(data, base + 16))
            let end = base + 32 + Int(readU32(data, base + 20))
            guard end <= data.count, count <= (end - base - 32) / 8 else {
                throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
            }
            var offset = base + 32
            for _ in 0..<count {
                guard offset + 8 <= end else {
                    throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
                }
                let command = readU32(data, offset)
                let size = Int(readU32(data, offset + 4))
                guard size >= 8, offset + size <= end else {
                    throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
                }
                if isPathCommand(command) {
                    let nameOffset = Int(readU32(data, offset + 8))
                    let minimum = command == Self.rpathCommand ? 12 : 24
                    guard nameOffset >= minimum, nameOffset < size,
                          let terminator = data[(offset + nameOffset)..<(offset + size)].firstIndex(of: 0) else {
                        throw PearError.invalidPackage("Invalid Mach-O path command: \(url.lastPathComponent)")
                    }
                    let path = String(decoding: data[(offset + nameOffset)..<terminator], as: UTF8.self)
                    if path == oldRoot || path.hasPrefix(oldRoot + "/") {
                        let replacement = newRoot + path.dropFirst(oldRoot.count)
                        let bytes = Array(replacement.utf8) + [0]
                        if bytes.count <= terminator + 1 - (offset + nameOffset) {
                            rewritten.replaceSubrange(
                                (offset + nameOffset)..<(offset + nameOffset + bytes.count), with: bytes
                            )
                            changed = true
                        } else {
                            fallback.append((command, path, replacement))
                        }
                    }
                }
                offset += size
            }
            guard offset == end else {
                throw PearError.invalidPackage("Invalid Mach-O load commands: \(url.lastPathComponent)")
            }
        }

        if changed {
            let permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
            try rewritten.write(to: url, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes(
                    [.posixPermissions: permissions], ofItemAtPath: url.path
                )
            }
        }
        for entry in fallback {
            if entry.command == Self.rpathCommand {
                _ = try preparationTools.run(
                    "/usr/bin/install_name_tool", ["-rpath", entry.old, entry.new, url.path]
                )
            } else if entry.command == Self.idDylibCommand {
                _ = try preparationTools.run(
                    "/usr/bin/install_name_tool", ["-id", entry.new, url.path]
                )
            } else {
                _ = try preparationTools.run(
                    "/usr/bin/install_name_tool", ["-change", entry.old, entry.new, url.path]
                )
            }
        }
    }

    private static let idDylibCommand: UInt32 = 0x0D
    private static let rpathCommand: UInt32 = 0x8000_001C
    private static let dependencyCommands: Set<UInt32> = [0x0C, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]

    private func isPathCommand(_ command: UInt32) -> Bool {
        command == Self.idDylibCommand || command == Self.rpathCommand
            || Self.dependencyCommands.contains(command)
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    // MARK: - Prepare for macOS

    /// Rewrites the bundle so macOS will load it as a Mac Catalyst app.
    /// Staged preparation uses `targetBundleURL` for all absolute load paths;
    /// ordinary installs default to the bundle being prepared.
    func prepareForMacOS(
        at bundleURL: URL,
        mode: PreparationMode = .compatibility,
        targetBundleURL: URL? = nil
    ) throws {
        let target = targetBundleURL ?? bundleURL
        unpreparedBinaries = []
        try patchInfoPlist(at: bundleURL)
        removeLegacySignatureArtifacts(at: bundleURL)
        try installMarketplaceKitStubIfNeeded(at: bundleURL, targetBundleURL: target)
        if target != bundleURL { try validateStagingIsolation(at: bundleURL) }
        _ = try patchMachOBinaries(at: bundleURL)
        switch mode {
        case .compatibility:
            try loadRuntime(at: bundleURL, targetBundleURL: target, addLoadCommand: true)
        case .compatibilityEnvironment:
            try loadRuntime(at: bundleURL, targetBundleURL: target, addLoadCommand: false)
        case .nativeContainer:
            try removeRuntimeArtifacts(at: bundleURL)
        }
        try validatePreparationMode(at: bundleURL, mode: mode, targetBundleURL: target)
        ensureExecutableBits(at: bundleURL)
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", bundleURL.path])
    }

    /// The selected mode, inferred from the marker/load command. This is only
    /// a hint for UI/callers; `setPreparationMode` validates the complete state.
    func currentPreparationMode(for app: InstalledApp) -> PreparationMode {
        if (try? itemExists(at: Self.injectionMarkerURL(in: app.bundleURL))) == true {
            return .compatibilityEnvironment
        }
        return BinaryPatcher.hasLoadDylib(at: app.executableURL, containing: "libPearRuntime")
            ? .compatibility : .nativeContainer
    }

    /// Sidecar that records a launcher-injected runtime. It lives next to the
    /// runtime so both the launcher and `currentPreparationMode` can see it
    /// without reading the executable.
    static func injectionMarkerURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Frameworks/.pear-injection")
    }

    private func itemExists(at url: URL) throws -> Bool {
        // fileExists follows symlinks, which would hide a dangling marker or
        // compatibility artifact from both validation and removal.
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    /// Prepares and signs a separate copy before atomically exchanging it with
    /// the installed bundle. Until that exchange, rollback is just discarding
    /// the copy; no failed preparation or signature can alter the original.
    func setPreparationMode(_ mode: PreparationMode, for app: InstalledApp, launchLease: AppLaunchLease? = nil) throws {
        let lease = try launchLease ?? AppLaunchLease.acquire(appID: app.id, libraryURL: libraryURL)
        defer { if launchLease == nil { lease.release() } }
        try lease.validate(appID: app.id, libraryURL: libraryURL)
        if try preparationModeIsValid(at: app.bundleURL, mode: mode, targetBundleURL: app.bundleURL) {
            return
        }

        // A sibling keeps the exchange on the same filesystem. Copy the current
        // bundle, not the IPA, so user-added resources and third-party changes survive.
        let transaction = app.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".pear-preparation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: transaction) }
        let staged = transaction.appendingPathComponent(app.bundleURL.lastPathComponent, isDirectory: true)
        _ = try preparationTools.run("/usr/bin/ditto", ["--clone", app.bundleURL.path, staged.path])
        try validateStagingIsolation(at: staged)
        let stagedApp = try makeInstalledApp(fromBundleAt: staged)
        _ = try preparationLoadPaths(at: stagedApp.executableURL)

        let previousUnpreparedBinaries = unpreparedBinaries
        do {
            try prepareForMacOS(at: staged, mode: mode, targetBundleURL: app.bundleURL)
            try signBundle(at: staged, mode: mode)
            _ = try preparationTools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            try validatePreparationMode(at: staged, mode: mode, targetBundleURL: app.bundleURL)

            // RENAME_SWAP is all-or-nothing, including on failure. The old
            // bundle ends up in `transaction` and is removed only after commit.
            guard renamex_np(staged.path, app.bundleURL.path, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSFilePathErrorKey: app.bundleURL.path
                ])
            }
        } catch {
            unpreparedBinaries = previousUnpreparedBinaries
            throw error
        }
    }

    private func validateStagingIsolation(at bundleURL: URL) throws {
        // Relative framework symlinks are fine. An absolute/external symlink
        // could make patching, xattr or codesign write through to the original.
        let root = bundleURL.resolvingSymlinksInPath().path
        var inspectionError: Error?
        guard let enumerator = fileManager.enumerator(
            at: bundleURL, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, error in inspectionError = error; return false }
        ) else {
            throw PearError.invalidPackage("Could not inspect staged bundle")
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                // Canonicalize the existing parent first: a dangling relative
                // link otherwise keeps aliases such as /private/var unresolved.
                let parent = URL(
                    fileURLWithPath: item.deletingLastPathComponent().resolvingSymlinksInPath().path,
                    isDirectory: true
                )
                let destination = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                let resolved = URL(fileURLWithPath: destination, relativeTo: parent)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                guard resolved == root || resolved.hasPrefix(root + "/") else {
                    throw PearError.invalidPackage("Mode switching cannot safely modify external symlink: \(item.path)")
                }
            }
        }
        if let inspectionError { throw inspectionError }
    }

    private struct PreparationLoadPaths {
        var dependencies: [(command: UInt32, path: String)] = []
        var rpaths: [String] = []
    }

    /// Unlike the patcher's best-effort predicates, this reader fails closed on
    /// unreadable/invalid executables and checks every 64-bit slice and exact path.
    private func preparationLoadPaths(at executableURL: URL) throws -> [PreparationLoadPaths] {
        let data = try Data(contentsOf: executableURL)
        let bases = BinaryPatcher.machO64Offsets(data)
        func invalid() -> PearError {
            .invalidPackage("Invalid Mach-O load commands: \(executableURL.lastPathComponent)")
        }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard !bases.isEmpty else { throw invalid() }
        return try bases.map { base in
            guard base + 32 <= data.count else { throw invalid() }
            let count = Int(u32(base + 16))
            let end = base + 32 + Int(u32(base + 20))
            guard end <= data.count, count <= (end - base - 32) / 8 else { throw invalid() }
            var paths = PreparationLoadPaths()
            var offset = base + 32
            for _ in 0..<count {
                guard offset + 8 <= end else { throw invalid() }
                let command = u32(offset)
                let size = Int(u32(offset + 4))
                guard size >= 8, offset + size <= end else { throw invalid() }
                let isDependency = [UInt32(0x0C), 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023].contains(command)
                if isDependency || command == BinaryPatcher.LoadCommand.rpath {
                    let minimum = isDependency ? 24 : 12
                    guard size >= minimum else { throw invalid() }
                    let nameOffset = Int(u32(offset + 8))
                    guard nameOffset >= minimum, nameOffset < size,
                          let terminator = data[(offset + nameOffset)..<(offset + size)].firstIndex(of: 0),
                          let path = String(data: data[(offset + nameOffset)..<terminator], encoding: .utf8)
                    else { throw invalid() }
                    if isDependency { paths.dependencies.append((command, path)) }
                    else { paths.rpaths.append(path) }
                }
                offset += size
            }
            guard offset == end else { throw invalid() }
            return paths
        }
    }

    private func preparationModeIsValid(
        at bundleURL: URL, mode: PreparationMode, targetBundleURL: URL
    ) throws -> Bool {
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        let slices = try preparationLoadPaths(at: app.executableURL)
        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        let targetFrameworks = targetBundleURL.appendingPathComponent("Frameworks")
        let marker = Self.injectionMarkerURL(in: bundleURL)
        let markerExists = try itemExists(at: marker)
        let artifacts = ["libPearRuntime.dylib", "libswiftUIKit.dylib", "libcxxcompat.dylib"]
        func regularFile(_ url: URL) -> Bool {
            (try? fileManager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular
        }

        switch mode {
        case .compatibility:
            guard !markerExists, regularFile(frameworks.appendingPathComponent(artifacts[0])) else { return false }
        case .compatibilityEnvironment:
            guard regularFile(marker), regularFile(frameworks.appendingPathComponent(artifacts[0])) else { return false }
            guard try Data(contentsOf: marker) == Data("environment\n".utf8) else { return false }
        case .nativeContainer:
            guard !markerExists,
                  try artifacts.allSatisfy({ try !itemExists(at: frameworks.appendingPathComponent($0)) })
            else { return false }
        }

        return slices.allSatisfy { paths in
            let runtimeLoads = paths.dependencies.filter { $0.path.contains("libPearRuntime") }
            let cxxLoads = paths.dependencies.filter { $0.path.contains("libcxxcompat") }
            if mode == .compatibility {
                guard runtimeLoads.count == 1,
                      runtimeLoads[0].command == BinaryPatcher.LoadCommand.loadDylib,
                      runtimeLoads[0].path == targetFrameworks.appendingPathComponent(artifacts[0]).path
                else { return false }
            } else if !runtimeLoads.isEmpty { return false }
            if mode == .nativeContainer { return cxxLoads.isEmpty }
            guard paths.rpaths.contains(targetFrameworks.path) else { return false }
            if !cxxLoads.isEmpty {
                guard regularFile(frameworks.appendingPathComponent("libcxxcompat.dylib")),
                      cxxLoads.allSatisfy({ $0.path == targetFrameworks.appendingPathComponent("libcxxcompat.dylib").path })
                else { return false }
            }
            // This also catches any accidentally staged MarketplaceKit paths.
            let allPaths = paths.dependencies.map(\.path) + paths.rpaths
            return bundleURL == targetBundleURL || !allPaths.contains { $0.hasPrefix(bundleURL.path + "/") }
        }
    }

    private func validatePreparationMode(
        at bundleURL: URL, mode: PreparationMode, targetBundleURL: URL
    ) throws {
        guard try preparationModeIsValid(at: bundleURL, mode: mode, targetBundleURL: targetBundleURL) else {
            throw PearError.invalidPackage("Preparation invariants failed for \(mode.rawValue)")
        }
    }

    /// Ensures no compatibility library is referenced or shipped. The native
    /// container adds no load commands to the app's executable.
    private func removeRuntimeArtifacts(at bundleURL: URL) throws {
        let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let marker = Self.injectionMarkerURL(in: bundleURL)
        if try itemExists(at: marker) {
            try fileManager.removeItem(at: marker)
        }
        for name in ["libPearRuntime.dylib", "libswiftUIKit.dylib", "libcxxcompat.dylib"] {
            let url = frameworks.appendingPathComponent(name)
            if try itemExists(at: url) {
                try fileManager.removeItem(at: url)
            }
        }
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        _ = try preparationTools.removeLoadDylib(app.executableURL, "libPearRuntime")
        _ = try preparationTools.removeLoadDylib(app.executableURL, "libcxxcompat")
    }

    /// `unzip` does not reliably restore the executable bit from an app package, and a
    /// patched copy can lose it too. Without it `Process` refuses to launch the
    /// app ("The file '…' doesn't exist.").
    private func ensureExecutableBits(at bundleURL: URL) {
        if let app = try? makeInstalledApp(fromBundleAt: bundleURL) {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.executableURL.path)
        }

        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        guard let items = try? fileManager.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items where item.pathExtension == "framework" {
            let binary = item.appendingPathComponent(item.deletingPathExtension().lastPathComponent)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }

    /// Copies the runtime into the bundle. With `addLoadCommand` the binary gets
    /// an `LC_LOAD_DYLIB`; without it the launcher injects the same library via
    /// `DYLD_INSERT_LIBRARIES` and a marker records the choice.
    private func loadRuntime(at bundleURL: URL, targetBundleURL: URL, addLoadCommand: Bool) throws {
        guard let runtime = preparationTools.runtimeLibraryURL() else {
            throw PearError.missingRuntimeComponent("libPearRuntime.dylib")
        }
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        let targetFrameworks = targetBundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let destination = frameworks.appendingPathComponent("libPearRuntime.dylib")
        if try itemExists(at: destination) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: runtime.resolvingSymlinksInPath(), to: destination)

        // Normalize old/duplicate paths in load-command mode too. Environment
        // mode only removes these commands; it must never create a runtime load.
        _ = try preparationTools.removeLoadDylib(app.executableURL, "libPearRuntime")
        let marker = Self.injectionMarkerURL(in: bundleURL)
        if addLoadCommand {
            if try itemExists(at: marker) {
                try fileManager.removeItem(at: marker)
            }
        } else {
            try Data("environment\n".utf8).write(to: marker, options: .atomic)
        }

        // The host does not provide the Swift UIKit overlay. Ship our small
        // source-built bridge next to the runtime, for frameworks that link it.
        let swiftOverlay = runtime.deletingLastPathComponent()
            .appendingPathComponent("libswiftUIKit.dylib")
        if fileManager.fileExists(atPath: swiftOverlay.path) {
            let overlayDestination = frameworks.appendingPathComponent("libswiftUIKit.dylib")
            if try itemExists(at: overlayDestination) {
                try fileManager.removeItem(at: overlayDestination)
            }
            try fileManager.copyItem(at: swiftOverlay.resolvingSymlinksInPath(), to: overlayDestination)
        }

        // A few builds carry a weak placeholder for a C++ runtime data symbol
        // that macOS does not export. Put the re-exporting compatibility
        // library in the bundle and point the binary's C++ dependency at it.
        let cxxCompat = runtime.deletingLastPathComponent()
            .appendingPathComponent("libcxxcompat.dylib")
        if fileManager.fileExists(atPath: cxxCompat.path),
           BinaryPatcher.containsSymbol(at: app.executableURL,
                                        named: "__ZNSt3__119piecewise_constructE") {
            let compatDestination = frameworks.appendingPathComponent("libcxxcompat.dylib")
            if try itemExists(at: compatDestination) {
                try fileManager.removeItem(at: compatDestination)
            }
            try fileManager.copyItem(at: cxxCompat.resolvingSymlinksInPath(), to: compatDestination)
            let dependencies = try preparationLoadPaths(at: app.executableURL)
                .flatMap { $0.dependencies.map(\.path) }
            let replacement = targetFrameworks.appendingPathComponent("libcxxcompat.dylib").path
            for path in Set(dependencies) where path == "/usr/lib/libc++.1.dylib"
                || path.contains("libcxxcompat") {
                if path != replacement {
                    _ = try preparationTools.run("/usr/bin/install_name_tool", [
                        "-change", path, replacement, app.executableURL.path
                    ])
                }
            }
        }

        // Absolute paths must describe the final installation, never staging.
        if addLoadCommand {
            try BinaryPatcher.addLoadDylib(
                at: app.executableURL,
                path: targetFrameworks.appendingPathComponent("libPearRuntime.dylib").path
            )
        }
        try BinaryPatcher.addRPath(at: app.executableURL, path: targetFrameworks.path)
    }

    private func patchInfoPlist(at bundleURL: URL) throws {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSMutableDictionary(contentsOf: infoURL),
              let mutable = info as? [String: Any] else {
            throw PearError.invalidPackage("Info.plist could not be read")
        }
        var updated = mutable
        updated["CFBundleSupportedPlatforms"] = ["MacOSX"]
        updated["DTPlatformName"] = "macosx"
        updated["LSMinimumSystemVersion"] = "15.0"

        let data = try PropertyListSerialization.data(
            fromPropertyList: updated, format: .binary, options: 0
        )
        try data.write(to: infoURL, options: .atomic)
    }

    /// Signature sidecars stop matching once the platform has been rewritten;
    /// remove them and let the final signing step create fresh ones.
    private func removeLegacySignatureArtifacts(at bundleURL: URL) {
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        for case let item as URL in enumerator {
            let name = item.lastPathComponent
            let ext = item.pathExtension.lowercased()

            if name == "SC_Info" || name == "_CodeSignature" {
                try? fileManager.removeItem(at: item)
                enumerator.skipDescendants()
            } else if ["supf", "supp", "supx"].contains(ext) {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    /// Patch every Mach-O image that participates in loading.
    @discardableResult
    private func patchMachOBinaries(at bundleURL: URL) throws -> Int {
        var count = 0
        for file in machOTargets(in: bundleURL) {
            guard BinaryPatcher.fileIsMachO64(file) else { continue }
            if BinaryPatcher.hasLegacyGuardMarkers(at: file) {
                unpreparedBinaries.append(file.lastPathComponent)
            }
            if try BinaryPatcher.patchFile(at: file) { count += 1 }
        }
        return count
    }

    /// Every Mach-O image in the bundle that participates in loading: the main
    /// executable, frameworks and plugins, and loose dylibs.
    private func machOTargets(in bundleURL: URL) -> [URL] {
        var targets = Set<URL>()

        if let app = try? makeInstalledApp(fromBundleAt: bundleURL) {
            targets.insert(app.executableURL)
        }

        for sub in ["Frameworks", "PlugIns"] {
            let dir = bundleURL.appendingPathComponent(sub)
            guard fileManager.fileExists(atPath: dir.path),
                  let enumerator = fileManager.enumerator(
                      at: dir, includingPropertiesForKeys: [.isRegularFileKey]
                  ) else { continue }
            for case let file as URL in enumerator {
                let isRegular = (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                if isRegular == true { targets.insert(file) }
            }
        }

        if let enumerator = fileManager.enumerator(
            at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            for case let file as URL in enumerator where file.pathExtension == "dylib" {
                targets.insert(file)
            }
        }

        return Array(targets)
    }

    /// Store builds may link `MarketplaceKit`, which macOS provides as
    /// resources only. When an image references the framework, copy the stub
    /// shipped with the runtime into the bundle and point the reference at
    /// that copy. A weak reference to a missing Swift framework otherwise
    /// aborts the process while it registers metadata, before `main` runs.
    private func installMarketplaceKitStubIfNeeded(at bundleURL: URL, targetBundleURL: URL) throws {
        let stubDirectory = bundleURL.appendingPathComponent(
            "Frameworks/MarketplaceKit.framework", isDirectory: true
        )
        let stubBinary = targetBundleURL.appendingPathComponent("Frameworks/MarketplaceKit.framework/MarketplaceKit")

        let referencing = machOTargets(in: bundleURL).filter { file in
            let path = file.standardizedFileURL.path
            let stubRoot = stubDirectory.standardizedFileURL.path
            guard path != stubRoot, !path.hasPrefix(stubRoot + "/") else { return false }
            return BinaryPatcher.hasLoadDylib(at: file, containing: "MarketplaceKit.framework")
                || BinaryPatcher.containsSymbol(at: file, withPrefix: "_$s14MarketplaceKit")
        }
        guard !referencing.isEmpty else { return }

        if !fileManager.fileExists(atPath: stubDirectory.path) {
            guard let source = AppLauncher.marketplaceKitStubURL() else {
                throw PearError.missingRuntimeComponent("MarketplaceKit.framework")
            }
            try fileManager.createDirectory(
                at: bundleURL.appendingPathComponent("Frameworks", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: stubDirectory)
        }

        // Absolute paths avoid any dependency on the app's run-path setup and
        // match how the compatibility runtime itself is loaded.
        let replacement = stubBinary.path
        for file in referencing {
            if BinaryPatcher.hasLoadDylib(at: file, containing: "MarketplaceKit.framework") {
                let listing = try Shell.run("/usr/bin/otool", ["-L", file.path])
                var stale = Set<String>()
                for line in listing.split(separator: "\n").dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let end = trimmed.range(of: " (compatibility version") else { continue }
                    let path = String(trimmed[..<end.lowerBound])
                    if path.contains("MarketplaceKit.framework") { stale.insert(path) }
                }
                for path in stale where path != replacement {
                    _ = try? Shell.run("/usr/bin/install_name_tool", [
                        "-change", path, replacement, file.path
                    ])
                }
            } else {
                try BinaryPatcher.addLoadDylib(at: file, path: replacement)
            }
        }
    }

    // MARK: - Helpers

    /// Builds an `InstalledApp` from a bundle's `Info.plist`.
    func makeInstalledApp(fromBundleAt bundleURL: URL) throws -> InstalledApp {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw PearError.invalidPackage("Info.plist could not be read: \(bundleURL.lastPathComponent)")
        }
        guard let bundleID = info["CFBundleIdentifier"] as? String else {
            throw PearError.missingBundleIdentifier
        }
        let executable = (info["CFBundleExecutable"] as? String) ?? ""
        guard !executable.isEmpty else {
            throw PearError.missingExecutable(bundleID)
        }

        let display = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? (bundleURL.deletingPathExtension().lastPathComponent)

        let iconName = (info["CFBundleIcons"] as? [String: Any])
            .flatMap { ($0["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String] }
            .flatMap { $0.last }
            ?? (info["CFBundleIconFile"] as? String)

        let iconURL = iconName.flatMap { name -> URL? in
            let candidates = [name, "\(name).png", "\(name)@2x.png", "\(name)@3x.png"]
            return candidates
                .map { bundleURL.appendingPathComponent($0) }
                .first { fileManager.fileExists(atPath: $0.path) }
        }

        let attrs = try? fileManager.attributesOfItem(atPath: bundleURL.path)
        let installedAt = (attrs?[.creationDate] as? Date) ?? Date()

        return InstalledApp(
            id: bundleID,
            displayName: display,
            bundleName: (info["CFBundleName"] as? String) ?? display,
            shortVersion: (info["CFBundleShortVersionString"] as? String) ?? "—",
            bundleVersion: (info["CFBundleVersion"] as? String) ?? "—",
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            bundleURL: bundleURL,
            executableName: executable,
            iconURL: iconURL,
            installedAt: installedAt
        )
    }

    /// Adhoc signing for a prepared app.
    ///
    /// A shipping app carries no extra entitlements. Real App Store builds have
    /// neither debug (`get-task-allow`) nor JIT keys, and an app can read them
    /// back with `csops`, so granting them here would make every install look
    /// like a debug repack. The debug set is written next to this file for
    /// explicit, short-lived debugging sessions only.
    ///
    /// Code is signed **inside-out**: every nested code object first, then the
    /// main executable, then the bundle. `codesign --deep` is deliberately NOT
    /// used: on an already-prepared app it can leave the original (now stale) platform
    /// signature on nested frameworks, which makes `dlopen` fail with
    /// "code signature invalid" and the app exit silently at launch.
    private func signBundle(at bundleURL: URL, mode: PreparationMode) throws {
        let entitlements = try ensureEntitlementsPath(for: bundleURL, mode: mode)

        // 1) nested code objects (frameworks, plugins, dylibs)
        for object in codeObjects(in: bundleURL) {
            try sign(object, entitlements: entitlements)
        }

        // 2) main executable
        let app = try makeInstalledApp(fromBundleAt: bundleURL)
        try sign(app.executableURL, entitlements: entitlements)

        // 3) the bundle itself
        try sign(bundleURL, entitlements: entitlements)
    }

    private func sign(_ url: URL, entitlements: String) throws {
        _ = try preparationTools.run("/usr/bin/codesign", [
            "--force", "--sign", "-",
            "--entitlements", entitlements,
            url.path
        ])
    }

    /// Nested code objects, shallowest-first per group: frameworks, then
    /// plugins, then loose dylibs.
    private func codeObjects(in bundleURL: URL) -> [URL] {
        var result: [URL] = []

        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        if let items = try? fileManager.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) {
            result += items.filter { $0.pathExtension == "framework" }
        }

        let plugins = bundleURL.appendingPathComponent("PlugIns")
        if let items = try? fileManager.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            result += items.filter { ["appex", "framework"].contains($0.pathExtension) }
        }

        if let enumerator = fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator where file.pathExtension == "dylib" {
                result.append(file)
            }
        }
        return result
    }

    /// Writes empty shipping/native-mode entitlements and a separate debug set.
    /// Neither shipping set enables App Sandbox isolation; debug entitlements
    /// are not selected automatically.
    private func ensureEntitlementsPath(for bundleURL: URL, mode: PreparationMode) throws -> String {
        try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)

        let entitlements = workRoot.appendingPathComponent("entitlements.plist")
        let nativeEntitlements = workRoot.appendingPathComponent("native-entitlements.plist")
        let debugEntitlements = workRoot.appendingPathComponent("debug-entitlements.plist")

        let shipping = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict/>
        </plist>
        """
        try shipping.write(to: entitlements, atomically: true, encoding: .utf8)

        let native = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict/>
        </plist>
        """
        try native.write(to: nativeEntitlements, atomically: true, encoding: .utf8)

        let debug = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.get-task-allow</key>
            <true/>
            <key>com.apple.security.cs.allow-jit</key>
            <true/>
            <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
            <true/>
            <key>com.apple.security.cs.disable-library-validation</key>
            <true/>
        </dict>
        </plist>
        """
        try debug.write(to: debugEntitlements, atomically: true, encoding: .utf8)
        return (mode == .nativeContainer ? nativeEntitlements : entitlements).path
    }
}
