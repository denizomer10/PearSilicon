import AppKit
import Darwin
import Foundation

/// A copy-only importer. This deliberately does not use the iOS binary patcher,
/// codesign, LaunchServices, a shell, or the caller's injection environment.
struct ManagedAppService: Sendable {
    static let windowsExecutableOnlyImportHint = "Executable-only import copies just this .exe, not its DLLs or game assets. Prefer importing the program's folder and selecting an executable relative to that folder."
    static let isolationNotice = "Mac apps launch natively from the managed copy with HOME, CFFIXED_USER_HOME and TMPDIR redirected into the entry's Data folder. This is not a VM and does not add filesystem isolation: an app that opens absolute host paths can still reach them. Apps that require installers, privileged helpers or write beside their executable may not work."

    @MainActor private static var processes: [UUID: ManagedAppProcess] = [:]

    func importMacApp(from source: URL, libraryRoot: URL) throws -> LibraryEntry {
        let source = try ManagedAppFiles.sourceDirectory(source)
        try ManagedAppFiles.validateTree(source)
        let info = try Self.macBundleInfo(source)
        try ManagedAppFiles.rejectRecursiveCopy(source: source, root: libraryRoot)
        let payloadPath = "Payload/\(source.lastPathComponent)"
        let manifest = LibraryManifest(
            id: info.id, platform: .macOS, displayName: info.name,
            version: info.version, payloadPath: payloadPath
        )
        let directory = try ManagedAppFiles.install(
            root: libraryRoot, folder: LibraryPlatform.macOS.rawValue, id: manifest.id
        ) { stage, _ in
            try Self.makeEntryDirectories(stage)
            let copy = stage.appendingPathComponent(payloadPath)
            // copyItem preserves bundle contents, resource forks and extended
            // attributes on macOS; no code or signing metadata is rewritten.
            try FileManager.default.copyItem(at: source, to: copy)
            try ManagedAppFiles.validateTree(copy)
            let copiedInfo = try Self.macBundleInfo(copy)
            guard copiedInfo.id == info.id, copiedInfo.executable == info.executable,
                              copiedInfo.name == info.name, copiedInfo.version == info.version else {
                throw PearError.invalidPackage("Bundle metadata changed during import")
            }
            try Self.writeManifest(manifest, in: stage)
        }
        return LibraryEntry(manifest: manifest, directoryURL: directory)
    }

    /// Preferred Windows import: the entire selected directory is copied, and
    /// executablePath must be a relative path within it, never a host path.
    func importWindowsFolder(
        from source: URL, executablePath: String, libraryRoot: URL,
        engineID: String, displayName: String? = nil
    ) throws -> LibraryEntry {
        try LibraryPath.validateComponent(engineID)
        try LibraryPath.validateRelative(executablePath)
        let source = try ManagedAppFiles.sourceDirectory(source)
        try LibraryPath.validateComponent(source.lastPathComponent)
        try ManagedAppFiles.validateTree(source)
        let executable = try ManagedAppFiles.regularFile(
            source.appendingPathComponent(executablePath), inside: source
        )
        try ManagedExecutable.validatePE(executable)
        return try importWindows(
            source: source, executablePath: executablePath, isFolder: true,
            id: source.lastPathComponent, libraryRoot: libraryRoot,
            engineID: engineID, displayName: displayName
        )
    }

    /// Explicitly imports ONLY the selected executable. UI callers should show
    /// windowsExecutableOnlyImportHint before offering this alternative.
    func importWindowsExecutable(
        from source: URL, libraryRoot: URL, engineID: String, displayName: String? = nil
    ) throws -> LibraryEntry {
        try LibraryPath.validateComponent(engineID)
        try ManagedAppFiles.rejectRootSymlink(source)
        let source = try ManagedAppFiles.regularFile(source, inside: source.deletingLastPathComponent())
        try LibraryPath.validateComponent(source.lastPathComponent)
        try ManagedExecutable.validatePE(source)
        return try importWindows(
            source: source, executablePath: source.lastPathComponent, isFolder: false,
            id: source.deletingPathExtension().lastPathComponent,
            libraryRoot: libraryRoot, engineID: engineID, displayName: displayName
        )
    }

    private func importWindows(
        source: URL, executablePath: String, isFolder: Bool, id: String,
        libraryRoot: URL, engineID: String, displayName: String?
    ) throws -> LibraryEntry {
        try LibraryPath.validateComponent(id)
        let name = try ManagedAppFiles.displayText(displayName ?? id)
        try ManagedAppFiles.rejectRecursiveCopy(source: source, root: libraryRoot)
        var manifest = LibraryManifest(
            id: id, platform: .wine, displayName: name, version: "1.0",
            payloadPath: "Payload/Program/\(executablePath)", wineEngineID: engineID
        )
        manifest.wineEngineGraphics = true
        manifest.wineInstaller = WineInstallation.isInstaller(source: source.appendingPathComponent(isFolder ? executablePath : "").standardizedFileURL, name: executablePath)
        if !isFolder { manifest.wineInstaller = WineInstallation.isInstaller(source: source, name: executablePath) }
        manifest.wineInstallState = manifest.wineInstaller == true ? "pending" : nil
        let directory = try ManagedAppFiles.install(
            root: libraryRoot, folder: LibraryPlatform.wine.rawValue, id: id
        ) { stage, _ in
            try Self.makeEntryDirectories(stage)
            let program = stage.appendingPathComponent("Payload/Program", isDirectory: true)
            if isFolder {
                try FileManager.default.copyItem(at: source, to: program)
            } else {
                try ManagedAppFiles.makeDirectory(program)
                try FileManager.default.copyItem(at: source, to: program.appendingPathComponent(executablePath))
            }
            try ManagedAppFiles.validateTree(program)
            try ManagedExecutable.validatePE(try ManagedAppFiles.regularFile(
                stage.appendingPathComponent(manifest.payloadPath), inside: program
            ))
            try Self.writeManifest(manifest, in: stage)
        }
        return LibraryEntry(manifest: manifest, directoryURL: directory)
    }

    /// A side-effect-free, inspectable launch plan. No unsandboxed fallback is
    /// ever used, even if the profile prevents an otherwise valid app running.
    func launchConfiguration(
        for entry: LibraryEntry, engine: WineEngine? = nil,
        metalHUDEnabled: Bool? = nil
    ) throws -> ManagedAppLaunchConfiguration {
        try Self.validateEntry(entry)
        try ManagedAppFiles.validateTree(entry.directoryURL)
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL
        switch entry.platform {
        case .macOS:
            guard engine == nil else { throw PearError.invalidPackage("A Mac app does not use a Wine engine") }
            let info = try Self.macBundleInfo(entry.payloadURL)
            guard info.id == entry.manifest.id else { throw PearError.invalidPackage("Bundle identifier does not match the manifest") }
            executable = try ManagedAppFiles.regularFile(
                entry.payloadURL.appendingPathComponent("Contents/MacOS/\(info.executable)"),
                inside: entry.payloadURL
            )
            arguments = []
            workingDirectory = entry.payloadURL
        case .wine:
            guard let engine, engine.id == entry.manifest.wineEngineID else {
                throw PearError.launchFailed("Select the Wine engine recorded in this game's manifest")
            }
            try engine.validate()
            let runtime = engine.wineHome
            let backend = entry.manifest.wineEngineGraphics == true ? .moltenVK : (entry.manifest.graphicsBackend ?? .moltenVK)
            switch backend {
            case .moltenVK:
                break
            case .dxmt:
                guard Self.engineExposesMetalViewAPI(engine) else {
                    throw PearError.launchFailed(
                        "This Wine engine does not export winemac's Metal view API, so DXMT cannot create its Metal surface. Use the MoltenVK + DXVK backend instead."
                    )
                }
                let dxmt = engine.rootURL.appendingPathComponent("Graphics/DXMT", isDirectory: true)
                guard FileManager.default.fileExists(atPath: dxmt.appendingPathComponent("x86_64-windows/d3d11.dll").path),
                      FileManager.default.fileExists(atPath: dxmt.appendingPathComponent("x86_64-unix/winemetal.so").path) else {
                    throw PearError.launchFailed(
                        "DXMT is selected but not installed for this engine. Install it in Settings → Wine → Graphics components."
                    )
                }
            }
            _ = runtime
            let archs = (try? Shell.run("/usr/bin/lipo", ["-archs", engine.executableURL.path])) ?? ""
            if !archs.split(whereSeparator: \.isWhitespace).contains("arm64"),
               !WineDistribution.isRosettaInstalled {
                throw PearError.launchFailed(
                    "This Wine build is x86_64 and needs Rosetta 2. Install it with `softwareupdate --install-rosetta` or register an arm64 engine."
                )
            }
            let program = try WineInstallation.validatedLaunchURL(entry)
            executable = engine.executableURL
            arguments = [program.path]
            workingDirectory = program.deletingLastPathComponent()
        case .iOS:
            throw PearError.invalidPackage("Use the iOS launcher for an iOS library entry")
        }
        let profile = ""
        let configuredExecutable = executable
        let configuredArguments = arguments
        return ManagedAppLaunchConfiguration(
            executableURL: configuredExecutable,
            arguments: configuredArguments,
            environment: Self.environment(for: entry, engine: engine, metalHUDEnabled: metalHUDEnabled),
            workingDirectoryURL: workingDirectory, sandboxProfile: profile
        )
    }

    /// Wine bootstrap and the game run as direct native processes. The private
    /// prefix and redirected HOME stay in place; host root drive mappings are
    /// removed and a per-entry g: drive exposes only the game's Payload/Program.
    /// Only a direct child Process is tracked/stopped; detached Wine helpers may
    /// outlive it. We never kill by PID supplied by a caller or by bundle ID.
    @MainActor
    func launch(
        _ entry: LibraryEntry, engine: WineEngine? = nil,
        metalHUDEnabled: Bool? = nil, activate: Bool = true,
        arguments extraArguments: [String] = [], diagnostics: Bool = false
    ) async throws -> ManagedAppProcess {
        guard !runningProcesses.contains(where: { $0.entryDirectoryURL == entry.directoryURL.standardizedFileURL }) else {
            throw PearError.launchFailed("This managed entry already has a tracked running process")
        }
        try Self.validateEntry(entry)
        if entry.platform == .wine {
            try Self.sanitizeWinePrefix(for: entry)
        }
        var configuration = try launchConfiguration(for: entry, engine: engine, metalHUDEnabled: metalHUDEnabled)
        if entry.platform == .wine,
           !ManagedAppFiles.exists(entry.prefixURL.appendingPathComponent("system.reg")) {
            guard let engine else { throw PearError.launchFailed("A Wine engine is required") }
            configuration.arguments = ["wineboot.exe", "-u"]
            let bootstrap = try spawn(configuration, entry: entry, purpose: .wineBootstrap, activate: false)
            do {
                // First-run FEX translation and prefix setup in a signed ARM64
                // bundle can exceed 45 seconds on an M1. Keep a bounded wait.
                let deadline = ContinuousClock.now.advanced(by: .seconds(engine.isAppBundleRuntime ? 180 : 45))
                while bootstrap.isRunning {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else {
                        throw PearError.launchFailed("Wine prefix bootstrap timed out; see Data/launch.log")
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard bootstrap.terminationStatus == 0 else {
                    throw PearError.launchFailed("Wine prefix bootstrap failed; see Data/launch.log")
                }
            } catch {
                bootstrap.stop()
                throw error
            }
            // wineboot can exit before wineserver flushes the new registry.
            // Do not reject a successfully initialized prefix in that interval.
            let registryDeadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !ManagedAppFiles.exists(entry.prefixURL.appendingPathComponent("system.reg")),
                  ContinuousClock.now < registryDeadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            // Wine commonly creates z: -> / and absolute user-folder links.
            // Delete the links, not their targets, before admitting the game.
            try Self.sanitizeWinePrefix(for: entry)
            guard ManagedAppFiles.exists(entry.prefixURL.appendingPathComponent("system.reg")) else {
                throw PearError.launchFailed("Wine did not initialize the private prefix")
            }
            // PearWine prefix defaults (GCMouse raw input, Option as Alt). Best
            // effort: a failed import never blocks the game.
            // The prefix has no host root drive, so the file is copied into C:.
            if let registry = WineDistributionInstaller.registryDefaults(for: engine) {
                let staged = entry.prefixURL.appendingPathComponent("drive_c/pearwine-defaults.reg")
                try? FileManager.default.removeItem(at: staged)
                try? FileManager.default.copyItem(at: registry, to: staged)
                configuration.arguments = ["regedit.exe", "/S", "C:\\pearwine-defaults.reg"]
                if let importer = try? spawn(configuration, entry: entry, purpose: .wineBootstrap, activate: false) {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                    while importer.isRunning, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    if importer.isRunning { importer.stop() }
                }
            }
            configuration = try launchConfiguration(for: entry, engine: engine, metalHUDEnabled: metalHUDEnabled)
        }
        try Task.checkCancellation()
        if entry.platform == .wine {
            if let engine {
                // DXVK is a native D3D11 implementation. Wine only looks for it
                // in the game directory or the prefix, so the engine-level
                // component is mirrored into this game's private prefix (and
                // restored when another backend is selected).
                try Self.synchronizeDXVK(for: entry, engine: engine)
            }
            // Use a real Windows drive letter for the program path. Without it,
            // GameMaker resolves data.win through \\?\unix\... and shows a file
            // dialog instead of starting the game.
            configuration.arguments = [try Self.prepareWineGameDrive(for: entry)] + extraArguments
            if diagnostics { configuration.environment["WINEDEBUG"] = "err+all" }
        }
        let launched = try spawn(configuration, entry: entry, purpose: .application, activate: activate)
        if entry.platform == .wine, let engine {
            launched.trackWineSession(server: engine.executableURL.deletingLastPathComponent().appendingPathComponent("wineserver"),
                                      environment: configuration.environment)
        }
        return launched
    }

    @MainActor var runningProcesses: [ManagedAppProcess] {
        Self.processes = Self.processes.filter { $0.value.isRunning }
        return Array(Self.processes.values)
    }

    @MainActor
    private func spawn(
        _ configuration: ManagedAppLaunchConfiguration, entry: LibraryEntry,
        purpose: ManagedAppProcess.Purpose, activate: Bool
    ) throws -> ManagedAppProcess {
        let log = try ManagedAppFiles.openPrivateLog(entry.dataURL.appendingPathComponent("launch.log"))
        defer { try? log.close() }
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        let handle = ManagedAppProcess(process: process, entry: entry, purpose: purpose)
        let id = handle.id
        handle.onSessionEnded = { Self.processes.removeValue(forKey: id) }
        process.terminationHandler = { [weak handle] _ in
            Task { @MainActor in
                if let handle, !handle.isRunning { Self.processes.removeValue(forKey: id) }
            }
        }
        try process.run()
        Self.processes[id] = handle
        if activate {
            Task { @MainActor [weak handle] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let handle, handle.isRunning else { return }
                NSRunningApplication(processIdentifier: handle.processIdentifier)?.activate(options: [.activateAllWindows])
            }
        }
        return handle
    }

    /// A per-entry drive letter that exposes only this game's Payload/Program
    /// directory. GameMaker-style runners derive their data path from the module
    /// path and fail on Wine's `\\?\unix\...` form, which appears when the
    /// prefix has no host drive mapping. The relative link stays inside the
    /// entry, so backups and portable moves keep working without exposing `/`.
    static let wineGameDriveLetter = "g"

    static func prepareWineGameDrive(for entry: LibraryEntry) throws -> String {
        guard entry.platform == .wine else {
            throw PearError.invalidPackage("A game drive is only valid for Wine entries")
        }
        if let path = entry.manifest.wineLaunchPath, path.hasPrefix("Prefix/drive_c/") {
            _ = try WineInstallation.validatedLaunchURL(entry)
            return "C:\\" + path.dropFirst("Prefix/drive_c/".count).replacingOccurrences(of: "/", with: "\\")
        }
        let programRoot = entry.directoryURL.appendingPathComponent("Payload/Program", isDirectory: true)
        _ = try ManagedAppFiles.existingDirectory(programRoot)
        let dosdevices = entry.prefixURL.appendingPathComponent("dosdevices", isDirectory: true)
        if !ManagedAppFiles.exists(dosdevices) { try ManagedAppFiles.makeDirectory(dosdevices) }

        let link = dosdevices.appendingPathComponent("\(wineGameDriveLetter):")
        let target = "../../Payload/Program"
        if let current = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            guard current == target else {
                throw PearError.launchFailed(
                    "The Wine prefix has a conflicting \(wineGameDriveLetter): drive mapping; remove it from dosdevices first"
                )
            }
        } else if ManagedAppFiles.exists(link) {
            throw PearError.launchFailed(
                "The Wine prefix has a conflicting \(wineGameDriveLetter): entry; it is not a symlink"
            )
        } else {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }

        let prefix = "Payload/Program/"
        let launchPath = entry.manifest.wineLaunchPath ?? entry.manifest.payloadPath
        guard launchPath.hasPrefix(prefix) else {
            throw PearError.invalidPackage("Wine payload is not inside Payload/Program")
        }
        let relative = launchPath.dropFirst(prefix.count)
            .replacingOccurrences(of: "/", with: "\\")
        return "\(wineGameDriveLetter.uppercased()):\\\(relative)"
    }

    // MARK: - DXVK (native D3D11 → Vulkan → MoltenVK)

    static let dxvkMarkerFilename = "pear-dxvk.json"
    static let dxvkBackupDirectory = "pear-dxvk-backup"
    static let dxvkFileNames = ["d3d11.dll", "d3d10core.dll"]

    private struct DXVKMarker: Codable {
        var version: Int = 1
        var files: [String: String]
    }

    /// Mirrors the engine's DXVK component into this game's prefix before a
    /// launch, or restores Wine's original files when another backend is chosen.
    /// The marker records exactly which files this app wrote, so a foreign file
    /// is never deleted. Runs after prefix initialization and before spawning.
    static func synchronizeDXVK(for entry: LibraryEntry, engine: WineEngine) throws {
        guard entry.platform == .wine else { return }
        let backend = entry.manifest.graphicsBackend ?? .moltenVK
        let install = entry.manifest.wineEngineGraphics != true && backend == .moltenVK && GraphicsComponentService.isDXVKInstalled(in: engine.rootURL)
        let system32 = entry.prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        guard ManagedAppFiles.exists(system32) else {
            if install {
                throw PearError.launchFailed(
                    "The Wine prefix is not initialized yet; start the game once before DXVK can be prepared."
                )
            }
            return
        }
        let markerURL = entry.prefixURL.appendingPathComponent(dxvkMarkerFilename)
        let marker = try readDXVKMarker(markerURL, inside: entry.prefixURL)
        let backup = entry.prefixURL.appendingPathComponent(dxvkBackupDirectory, isDirectory: true)
        let updated = install
            ? try installDXVKFiles(from: engine.rootURL, into: system32, backup: backup, marker: marker)
            : try restoreDXVKFiles(in: system32, backup: backup, marker: marker)
        try writeDXVKMarker(updated, to: markerURL, inside: entry.prefixURL)
    }

    private static func readDXVKMarker(_ url: URL, inside prefix: URL) throws -> DXVKMarker? {
        guard ManagedAppFiles.exists(url) else { return nil }
        let file = try ManagedAppFiles.regularFile(url, inside: prefix)
        guard let marker = try? JSONDecoder().decode(DXVKMarker.self, from: ManagedAppFiles.readSmallFile(file)),
              marker.version == 1 else {
            return nil
        }
        return marker
    }

    private static func writeDXVKMarker(_ marker: DXVKMarker?, to url: URL, inside prefix: URL) throws {
        guard let marker, !marker.files.isEmpty else {
            if ManagedAppFiles.exists(url) {
                _ = try ManagedAppFiles.regularFile(url, inside: prefix)
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: url, options: .atomic)
    }

    private static func installDXVKFiles(
        from engineRoot: URL, into system32: URL, backup: URL, marker: DXVKMarker?
    ) throws -> DXVKMarker {
        let component = engineRoot.appendingPathComponent("Graphics/DXVK/x64", isDirectory: true)
        var files = marker?.files ?? [:]
        for name in dxvkFileNames {
            let source = try ManagedAppFiles.regularFile(component.appendingPathComponent(name), inside: component)
            let sourceHash = try WineReleaseService.sha256(of: source)
            let destination = system32.appendingPathComponent(name)
            var currentHash: String?
            if ManagedAppFiles.exists(destination) {
                let current = try ManagedAppFiles.regularFile(destination, inside: system32)
                currentHash = try WineReleaseService.sha256(of: current)
            }
            if currentHash != sourceHash {
                // Back up Wine's original once. A previous DXVK copy (tracked in
                // the marker, or recognised by its pinned hash after a manual
                // marker deletion) is ours and must not overwrite that backup.
                let known = name == "d3d11.dll"
                    ? GraphicsComponentService.dxvkD3D11SHA256
                    : GraphicsComponentService.dxvkD3D10CoreSHA256
                if let currentHash, currentHash != known, files[name] != currentHash {
                    try backupDXVKFile(destination, to: backup, name: name)
                }
                try replaceFile(at: destination, with: source)
            }
            files[name] = sourceHash
        }
        return DXVKMarker(files: files)
    }

    private static func restoreDXVKFiles(
        in system32: URL, backup: URL, marker: DXVKMarker?
    ) throws -> DXVKMarker? {
        guard let marker, !marker.files.isEmpty else { return marker }
        for name in dxvkFileNames {
            guard let recorded = marker.files[name] else { continue }
            let destination = system32.appendingPathComponent(name)
            guard ManagedAppFiles.exists(destination) else { continue }
            let current = try ManagedAppFiles.regularFile(destination, inside: system32)
            guard try WineReleaseService.sha256(of: current) == recorded else { continue }
            let saved = backup.appendingPathComponent(name)
            if ManagedAppFiles.exists(saved) {
                let original = try ManagedAppFiles.regularFile(saved, inside: backup)
                try replaceFile(at: destination, with: original)
                try FileManager.default.removeItem(at: original)
            } else {
                try FileManager.default.removeItem(at: destination)
            }
        }
        if ManagedAppFiles.exists(backup),
           (try? FileManager.default.contentsOfDirectory(atPath: backup.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: backup)
        }
        return nil
    }

    private static func backupDXVKFile(_ file: URL, to backup: URL, name: String) throws {
        if !ManagedAppFiles.exists(backup) { try ManagedAppFiles.makeDirectory(backup) }
        let destination = backup.appendingPathComponent(name)
        guard !ManagedAppFiles.exists(destination) else { return }
        let temporary = backup.appendingPathComponent(".pear-\(name)-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: file, to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            let error = ManagedAppFiles.posix(destination)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Publishes a copied file with rename(2) so a partially written DLL can
    /// never be loaded, and a symlink at the destination is replaced, not followed.
    private static func replaceFile(at destination: URL, with source: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".pear-\(destination.lastPathComponent)-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            let error = ManagedAppFiles.posix(destination)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// DXMT dlsyms winemac's C API (`macdrv_view_create_metal_view`,
    /// `get_win_data`, ...). Release Wine builds hide those symbols, and DXMT
    /// aborts while creating its swapchain. Refuse the backend instead of
    /// presenting a doomed launch. A missing `nm` answers conservatively false.
    static func engineExposesMetalViewAPI(_ engine: WineEngine) -> Bool {
        let wineLib = engine.wineHome.appendingPathComponent("lib/wine", isDirectory: true)
        for arch in ["x86_64-unix", "aarch64-unix", "i386-unix", "arm-unix"] {
            let winemac = wineLib.appendingPathComponent(arch).appendingPathComponent("winemac.so")
            guard FileManager.default.fileExists(atPath: winemac.path) else { continue }
            let symbols = (try? Shell.run("/usr/bin/nm", ["-gU", winemac.path])) ?? ""
            if symbols.contains("macdrv_view_create_metal_view") || symbols.contains("macdrv_functions") {
                return true
            }
        }
        return false
    }

    static func environment(
        for entry: LibraryEntry, engine: WineEngine? = nil, metalHUDEnabled: Bool? = nil,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // An allowlist, not a blacklist: no inherited DYLD_*, PEAR_*, WINE*,
        // launch-agent, framework, executable search, or shared-home overrides.
        var result = [
            "HOME": entry.dataURL.path, "CFFIXED_USER_HOME": entry.dataURL.path,
            "TMPDIR": entry.dataURL.appendingPathComponent("tmp", isDirectory: true).path + "/",
            "PATH": "/usr/bin:/bin", "USER": "pear", "LOGNAME": "pear",
            "XDG_CACHE_HOME": entry.dataURL.appendingPathComponent("Library/Caches").path,
            "XDG_CONFIG_HOME": entry.dataURL.appendingPathComponent("Library/Preferences").path,
            "XDG_DATA_HOME": entry.dataURL.appendingPathComponent("Library/Application Support").path,
            "MTL_HUD_ENABLED": (metalHUDEnabled ?? entry.manifest.metalHUDEnabled) ? "1" : "0"
        ]
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key], value.utf8.count < 128,
               !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                result[key] = value
            }
        }
        if entry.platform == .wine {
            result["WINEPREFIX"] = entry.prefixURL.path
            result["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
            result["WINEDEBUG"] = "-all"
            if let engine {
                let runtime = engine.wineHome
                let bin = engine.executableURL.deletingLastPathComponent()
                result["PATH"] = bin.path + ":/usr/bin:/bin"
                // Running the release's bin/wine directly bypasses its .app
                // wrapper, so supply the paths that wrapper normally exports.
                result["WINELOADER"] = engine.executableURL.path
                result["WINESERVER"] = engine.executableURL.deletingLastPathComponent()
                    .appendingPathComponent("wineserver").path
                result["WINEDLLPATH"] = runtime.appendingPathComponent("lib/wine", isDirectory: true).path
                result["WINEDATADIR"] = runtime.appendingPathComponent("share/wine", isDirectory: true).path
                result["DYLD_FALLBACK_LIBRARY_PATH"] = runtime.appendingPathComponent("lib", isDirectory: true).path
                // What a `bin/wine` wrapper would export (MetalSharp/PearWine):
                // the bundled GStreamer plugins for in-game video and audio.
                let gstreamer = runtime.appendingPathComponent("lib/gstreamer-1.0", isDirectory: true)
                if FileManager.default.fileExists(atPath: gstreamer.path) {
                    result["GST_PLUGIN_SYSTEM_PATH_1_0"] = gstreamer.path
                    let scanner = runtime.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner")
                    if FileManager.default.isExecutableFile(atPath: scanner.path) {
                        result["GST_PLUGIN_SCANNER_1_0"] = scanner.path
                    }
                }
                let moltenVK = runtime.appendingPathComponent("share/vulkan/icd.d/MoltenVK_icd.json")
                if FileManager.default.fileExists(atPath: moltenVK.path) {
                    result["VK_ICD_FILENAMES"] = moltenVK.path
                    result["VK_DRIVER_FILES"] = moltenVK.path
                }
                // PearWine ships its own launch defaults (msync, cursor
                // confinement…). They never override a value set above.
                for (key, value) in WineDistributionInstaller.environmentDefaults(for: engine) where result[key] == nil {
                    result[key] = value
                }
                let graphics = engine.rootURL.appendingPathComponent("Graphics", isDirectory: true)
                if entry.manifest.wineEngineGraphics != true {
                    switch entry.manifest.graphicsBackend ?? .moltenVK {
                    case .dxmt:
                        let dxmt = graphics.appendingPathComponent("DXMT", isDirectory: true)
                        result["WINEDLLPATH"] = dxmt.path + ":" + result["WINEDLLPATH"]!
                        result["WINEDLLOVERRIDES"] = "d3d11,dxgi,d3d10core,winemetal=n,b;winemenubuilder.exe=d"
                    case .moltenVK:
                        // DXVK is native D3D11; without it the game falls back to
                        // wined3d's OpenGL renderer, which presents black on this
                        // engine for GameMaker-style D3D11 titles.
                        if GraphicsComponentService.isDXVKInstalled(in: engine.rootURL) {
                            result["WINEDLLOVERRIDES"] = "d3d11,d3d10core=n;winemenubuilder.exe=d"
                        }
                    }
                }
            }
        }
        return result
    }

    static func sandboxProfile(for entry: LibraryEntry, engine: WineEngine? = nil) throws -> String {
        var readable = [
            "/System/Library", "/System/Applications", "/System/Cryptexes",
            "/System/Volumes/Preboot/Cryptexes", "/usr/lib", "/usr/share", "/usr/bin", "/bin",
            "/Library", "/private/etc", "/private/var/db/dyld",
            "/private/var/db/timezone", "/usr/libexec/rosetta",
            "/Library/Apple/usr/libexec/oah", LibraryPath.canonicalPath(entry.directoryURL)
        ]
        if let engine { readable.append(LibraryPath.canonicalPath(engine.rootURL.appendingPathComponent("Runtime"))) }
        var writable = [LibraryPath.canonicalPath(entry.dataURL)]
        if entry.platform == .wine {
            writable.append(LibraryPath.canonicalPath(entry.prefixURL))
            // wineserver creates its per-user server directory under /tmp even
            // when TMPDIR points into the game's Data folder. Allow only this
            // narrow per-user subpath, never all of /tmp.
            writable.append("/private/tmp/.wine-\(getuid())")
        }
        func quoted(_ path: String) throws -> String {
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw PearError.invalidPackage("Control characters in a sandbox path")
            }
            return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let reads = try readable.map { "(subpath \(try quoted($0)))" }.joined(separator: " ")
        let writes = try writable.map { "(subpath \(try quoted($0)))" }.joined(separator: " ")
        let privateTemp = try quoted(LibraryPath.canonicalPath(entry.dataURL.appendingPathComponent("tmp")))
        let wineTemp = try quoted("/private/tmp/.wine-\(getuid())")
        // Never allow all of /System: /System/Volumes/Data exposes user homes.
                // Deliberately no (allow default), home-wide access, shared /tmp, user
        // preference broker, LaunchServices handoff, or Apple-event permission.
        return """
        (version 1)
        (deny default)
        (allow process-exec process-fork)
        (allow signal (target self))
        (allow sysctl-read)
        (allow ipc-posix-shm)
        (allow mach-lookup (global-name-prefix "com.apple."))
        (allow iokit-open)
        (allow user-preference-read)
        (allow user-preference-write (subpath \(try quoted(LibraryPath.canonicalPath(entry.dataURL.appendingPathComponent("Library/Preferences"))))))
        (allow network-outbound (remote ip "*:*"))
        (allow network-bind (local ip "*:*"))
        (allow network-bind network-inbound (local unix-socket (subpath \(privateTemp))))
        (allow network-outbound (remote unix-socket (subpath \(privateTemp))))
        (allow network-bind network-inbound (local unix-socket (subpath \(wineTemp))))
        (allow network-outbound (remote unix-socket (subpath \(wineTemp))))
        (allow file-map-executable \(reads))
        (allow file-read-metadata (literal "/") (subpath "/Users")
            (literal "/tmp") (literal "/private/tmp")
            (literal "/System/Volumes/Data") (literal "/var") (literal "/private/var"))
        (allow file-read* \(reads)
            (literal "/") (literal "/private/var")
            (literal "/dev/autofs_nowait")
            (literal "/private/etc/localtime")
            (literal "/private/etc/hosts")
            (literal "/private/etc/resolv.conf")
            (literal "/dev/null") (literal "/dev/zero")
            (literal "/dev/random") (literal "/dev/urandom"))
        (allow file-write* \(writes) (literal "/dev/null"))
        """
    }

    /// Safe to call only for our managed entries. Removes mappings, never host
    /// targets. The sandbox remains necessary: Wine can recreate links later.
    static func sanitizeWinePrefix(for entry: LibraryEntry) throws {
        try validateEntry(entry)
        guard entry.platform == .wine else { throw PearError.invalidPackage("Not a Wine entry") }
        let prefix = entry.prefixURL
        try ManagedAppFiles.walk(prefix) { url, status in
            guard status.st_mode & S_IFMT == S_IFLNK else {
                if url.lastPathComponent.lowercased() == "z:", url.deletingLastPathComponent().lastPathComponent == "dosdevices" {
                    throw PearError.invalidPackage("Refusing a non-symlink Wine z: mapping")
                }
                return
            }
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let isZ = url.lastPathComponent.lowercased() == "z:" && url.deletingLastPathComponent().lastPathComponent == "dosdevices"
            // A per-entry drive mapping (for example g: -> ../../Payload/Program)
            // is portable because it resolves inside this entry, not to the host.
            let staysInEntry = LibraryPath.isInside(url, root: entry.directoryURL)
            if isZ || target.hasPrefix("/") || !staysInEntry {
                try FileManager.default.removeItem(at: url)
            }
        }
        try ManagedAppFiles.validateTree(prefix, allowedLinkRoot: entry.directoryURL)
    }

    private static func validateEntry(_ entry: LibraryEntry) throws {
        try LibraryPath.validate(entry.manifest, directory: entry.directoryURL)
        guard entry.manifest.platform != .iOS,
              entry.directoryURL.lastPathComponent == entry.manifest.id,
              entry.directoryURL.deletingLastPathComponent().lastPathComponent == entry.platform.rawValue,
              entry.manifest.payloadPath.hasPrefix("Payload/") else {
            throw PearError.invalidPackage("Not a managed Mac/Wine entry layout")
        }
        let root = try ManagedAppFiles.existingDirectory(entry.libraryRootURL)
        let platform = try ManagedAppFiles.existingDirectory(root.appendingPathComponent(entry.platform.rawValue))
        _ = try ManagedAppFiles.existingDirectory(platform.appendingPathComponent(entry.manifest.id))
        _ = try ManagedAppFiles.existingDirectory(entry.dataURL)
        _ = try ManagedAppFiles.existingDirectory(entry.dataURL.appendingPathComponent("tmp"))
        _ = try ManagedAppFiles.existingDirectory(entry.prefixURL)
        let manifestURL = try ManagedAppFiles.regularFile(entry.manifestURL, inside: entry.directoryURL)
        let data = try ManagedAppFiles.readSmallFile(manifestURL)
        guard try JSONDecoder().decode(LibraryManifest.self, from: data) == entry.manifest else {
            throw PearError.invalidPackage("Entry manifest changed; reload the library before launching")
        }
    }

    private static func makeEntryDirectories(_ stage: URL) throws {
        for path in ["Payload", "Data", "Prefix", "Data/tmp", "Data/Documents", "Data/Library",
                     "Data/Library/Caches", "Data/Library/Preferences", "Data/Library/Application Support"] {
            try ManagedAppFiles.makeDirectory(stage.appendingPathComponent(path, isDirectory: true))
        }
    }

    private static func writeManifest(_ manifest: LibraryManifest, in directory: URL) throws {
        try LibraryPath.validate(manifest, directory: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(LibraryManifest.filename), options: .atomic)
    }

    private static func macBundleInfo(_ bundle: URL) throws -> (id: String, name: String, version: String, executable: String) {
        guard bundle.pathExtension.lowercased() == "app" else { throw PearError.invalidPackage("Select a macOS .app bundle") }
        try LibraryPath.validateComponent(bundle.lastPathComponent)
        _ = try ManagedAppFiles.existingDirectory(bundle)
        let plist = try ManagedAppFiles.regularFile(bundle.appendingPathComponent("Contents/Info.plist"), inside: bundle)
        guard let info = try PropertyListSerialization.propertyList(
            from: ManagedAppFiles.readSmallFile(plist), options: [], format: nil
        ) as? [String: Any] else { throw PearError.invalidPackage("Missing macOS Contents/Info.plist") }
        guard let id = info["CFBundleIdentifier"] as? String else { throw PearError.missingBundleIdentifier }
        try LibraryPath.validateComponent(id)
        guard id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw PearError.invalidPackage("Unsafe macOS bundle identifier")
        }
        guard let executable = info["CFBundleExecutable"] as? String else { throw PearError.missingExecutable(id) }
        try LibraryPath.validateComponent(executable)
        guard info["LSRequiresIPhoneOS"] as? Bool != true,
              (info["CFBundlePackageType"] as? String).map({ $0 == "APPL" }) ?? true,
              (info["DTPlatformName"] as? String).map({ $0.lowercased() == "macosx" }) ?? true,
              (info["CFBundleSupportedPlatforms"] as? [String]).map({ !$0.isEmpty && $0.allSatisfy { $0 == "MacOSX" } }) ?? true else {
            throw PearError.invalidPackage("The bundle is not a native macOS build")
        }
        let binary = try ManagedAppFiles.regularFile(bundle.appendingPathComponent("Contents/MacOS/\(executable)"), inside: bundle)
        try ManagedExecutable.validateMacOS(binary)
        let name = try ManagedAppFiles.displayText((info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundle.deletingPathExtension().lastPathComponent)
        let version = try ManagedAppFiles.displayText((info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "1.0")
        return (id, name, version, executable)
    }
}

struct ManagedAppLaunchConfiguration: Sendable {
    let executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    let workingDirectoryURL: URL
    let sandboxProfile: String
}

/// Unforgeable by callers: there is intentionally no initializer taking a PID,
/// bundle ID, NSRunningApplication, or arbitrary Process.
@MainActor
final class ManagedAppProcess: Identifiable {
    enum Purpose: Sendable { case application, wineBootstrap }
    let id = UUID()
    let entryDirectoryURL: URL
    let purpose: Purpose
    private let process: Process
    var processIdentifier: Int32 { process.processIdentifier }
    private var sessionMonitoring = false
    private var monitor: Task<Void, Never>?
    private var waiter: Process?
    private var server: URL?
    private var serverEnvironment: [String: String] = [:]
    fileprivate var onSessionEnded: (() -> Void)?
    var isRunning: Bool { process.isRunning || sessionMonitoring }
    var terminationStatus: Int32? { isRunning ? nil : process.terminationStatus }

    fileprivate init(process: Process, entry: LibraryEntry, purpose: Purpose) {
        self.process = process
        self.entryDirectoryURL = entry.directoryURL.standardizedFileURL
        self.purpose = purpose
    }

    /// Keep tracking the private Wine session across Steam/bootstrapper re-exec.
    /// A per-prefix wineserver wait is never a machine-wide process-name probe.
    fileprivate func trackWineSession(server: URL, environment: [String: String]) {
        guard FileManager.default.isExecutableFile(atPath: server.path) else { return }
        self.server = server
        self.serverEnvironment = environment
        sessionMonitoring = true
        monitor = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.sessionMonitoring = false
                self.waiter = nil
                if !self.process.isRunning { self.onSessionEnded?() }
            }
            var exitedAt: ContinuousClock.Instant?
            do {
                while !Task.isCancelled {
                    let child = Process()
                    child.executableURL = server
                    child.arguments = ["-w"]
                    child.environment = environment
                    child.standardOutput = FileHandle.nullDevice
                    child.standardError = FileHandle.nullDevice
                    self.waiter = child
                    try child.run()
                    while child.isRunning { try await Task.sleep(for: .milliseconds(200)) }
                    if !self.process.isRunning {
                        if self.process.terminationStatus != 0 { break }
                        if exitedAt == nil { exitedAt = .now }
                        if ContinuousClock.now - exitedAt! >= .seconds(2) { break }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch { /* Stop/cancellation closes only the owned session. */ }
        }
    }

    func stop() {
        monitor?.cancel()
        if let waiter, waiter.isRunning { kill(waiter.processIdentifier, SIGKILL) }
        if let server {
            let shutdown = Process()
            shutdown.executableURL = server
            shutdown.arguments = ["-k"]
            shutdown.environment = serverEnvironment
            shutdown.standardOutput = FileHandle.nullDevice
            shutdown.standardError = FileHandle.nullDevice
            try? shutdown.run()
        }
        sessionMonitoring = false
        onSessionEnded?()
        // The process is still running, so this PID is still ours. SIGKILL
        // bypasses hung run loops and blocked input handlers.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

// Shared admission and transaction primitives for the two copy-only services.
// These reject pre-existing link escapes. Like ordinary filesystem APIs they
// do not defend against a hostile process with the same UID concurrently
// replacing our private directories; this is not a multi-user security vault.
enum ManagedAppFiles {
    static func status(_ url: URL) throws -> stat {
        guard url.isFileURL, !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PearError.invalidPackage("Expected a local filesystem path")
        }
        var result = stat()
        guard lstat(url.path, &result) == 0 else { throw posix(url) }
        return result
    }

    static func exists(_ url: URL) -> Bool {
        var result = stat()
        return lstat(url.path, &result) == 0
    }

    static func posix(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }

    static func rejectRootSymlink(_ url: URL) throws {
        guard try status(url).st_mode & S_IFMT != S_IFLNK else {
            throw PearError.invalidPackage("A selected root or executable cannot be a symlink: \(url.lastPathComponent)")
        }
    }

    static func sourceDirectory(_ url: URL) throws -> URL {
        try rejectRootSymlink(url)
        let value = LibraryPath.canonicalURL(url)
        guard try status(value).st_mode & S_IFMT == S_IFDIR else { throw PearError.invalidPackage("Select a directory") }
        return value
    }

    static func existingDirectory(_ url: URL) throws -> URL {
        // Check each ancestor as well, not just the last component. macOS's
        // fixed /var, /tmp and /etc aliases are not user-controlled pivots, and
        // every temporary fixture lives under /var, so resolve exactly those.
        let value = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in value.pathComponents.dropFirst() {
            let next = current.appendingPathComponent(component, isDirectory: true)
            let info = try status(next)
            if info.st_mode & S_IFMT == S_IFLNK, ["/var", "/tmp", "/etc"].contains(next.path) {
                current = URL(fileURLWithPath: "/private" + next.path, isDirectory: true)
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw PearError.invalidPackage("Managed directory contains a symlink or non-directory: \(next.path)")
            }
            current = next
        }
        let info = try status(value)
        guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw PearError.invalidPackage("Managed directory must be owned by this user and not writable by other users")
        }
        return value
    }

    static func canonicalRoot(_ url: URL) throws -> URL {
        guard url.isFileURL, url.standardizedFileURL.path != "/" else { throw PearError.invalidPackage("Invalid managed root") }
        let selected = url.standardizedFileURL
        try LibraryPath.validateComponent(selected.lastPathComponent)
        var parent = URL(fileURLWithPath: "/", isDirectory: true)
        for component in selected.deletingLastPathComponent().pathComponents.dropFirst() {
            parent.appendPathComponent(component, isDirectory: true)
            let info = try status(parent)
            if info.st_mode & S_IFMT == S_IFLNK, ["/var", "/tmp", "/etc"].contains(parent.path) {
                // macOS's fixed system aliases are not user-controlled pivots.
                // Foundation's resolvingSymlinksInPath deliberately leaves /var
                // unresolved, so map the known aliases explicitly.
                parent = URL(fileURLWithPath: "/private" + parent.path, isDirectory: true)
            } else if info.st_mode & S_IFMT != S_IFDIR {
                throw PearError.invalidPackage("The managed root's ancestors must be real directories, not symlinks")
            }
        }
        let result = parent.appendingPathComponent(selected.lastPathComponent, isDirectory: true)
        if exists(result) { _ = try existingDirectory(result) }
        return result
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    static func displayText(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PearError.invalidPackage("Invalid display name or version")
        }
        return text
    }

    static func regularFile(_ url: URL, inside root: URL) throws -> URL {
        guard LibraryPath.isInside(url, root: root) else { throw PearError.invalidPackage("File escapes its managed directory") }
        let resolved = LibraryPath.canonicalURL(url)
        let info = try status(resolved)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_mode & 0o6000 == 0 else {
            throw PearError.invalidPackage("Expected a single-link regular file, not a hardlink or special file: \(url.lastPathComponent)")
        }
        return resolved
    }

    static func readSmallFile(_ url: URL) throws -> Data {
        let reader = try ManagedBinaryReader(url)
        guard reader.size <= 1_048_576 else { throw PearError.invalidPackage("Metadata file exceeds 1 MiB") }
        return try reader.read(0, Int(reader.size))
    }

    static func walk(_ root: URL, visit: (URL, stat) throws -> Void) throws {
        var count = 0
        func recurse(_ directory: URL, depth: Int) throws {
            guard depth < 128 else { throw PearError.invalidPackage("Directory tree is too deep") }
            let rootInfo = try status(directory)
            guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw PearError.invalidPackage("Directory traversal through a symlink") }
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                count += 1
                guard count <= 1_000_000 else { throw PearError.invalidPackage("Directory tree contains too many files") }
                let info = try status(child)
                try visit(child, info)
                if info.st_mode & S_IFMT == S_IFDIR { try recurse(child, depth: depth + 1) }
            }
        }
        try recurse(root, depth: 0)
    }

    static func validateTree(_ root: URL, allowedLinkRoot: URL? = nil) throws {
        try rejectRootSymlink(root)
        try walk(root) { url, info in
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard info.st_mode & 0o6000 == 0 else { throw PearError.invalidPackage("Set-ID directory is not allowed") }
            case S_IFREG:
                guard info.st_nlink == 1, info.st_mode & 0o6000 == 0 else {
                    throw PearError.invalidPackage("Hardlinked or set-ID file is not allowed: \(url.lastPathComponent)")
                }
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let staysInRoot = LibraryPath.isInside(url, root: root)
                let staysInAllowed = allowedLinkRoot.map { LibraryPath.isInside(url, root: $0) } ?? false
                guard !target.hasPrefix("/"), staysInRoot || staysInAllowed,
                      FileManager.default.fileExists(atPath: url.path) else {
                    throw PearError.invalidPackage("External, absolute or dangling symlink is not allowed: \(url.lastPathComponent)")
                }
            default:
                throw PearError.invalidPackage("Special files are not allowed: \(url.lastPathComponent)")
            }
        }
    }

    static func rejectRecursiveCopy(source: URL, root: URL) throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        guard root != source, !LibraryPath.isInside(root, root: source) else {
            throw PearError.invalidPackage("The managed destination cannot be inside the imported directory")
        }
    }

    /// Stages on the destination filesystem and publishes with RENAME_EXCL.
    /// Empty platform folders created by a failed first install are removed.
    static func install(
        root requestedRoot: URL, folder: String? = nil, id: String,
        build: (URL, URL) throws -> Void
    ) throws -> URL {
        try LibraryPath.validateComponent(id)
        if let folder { try LibraryPath.validateComponent(folder) }
        let root = try canonicalRoot(requestedRoot)
        let madeRoot = !exists(root)
        if madeRoot { try makeDirectory(root) }
        var madeFolder = false
        let parent = folder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        var stage: URL?
        defer {
            if let stage { try? FileManager.default.removeItem(at: stage) }
            if madeFolder { _ = rmdir(parent.path) }
            if madeRoot { _ = rmdir(root.path) }
        }
        if !exists(parent) { try makeDirectory(parent); madeFolder = true }
        _ = try existingDirectory(parent)
        let destination = parent.appendingPathComponent(id, isDirectory: true)
        guard !exists(destination) else { throw PearError.invalidPackage("Destination already exists; nothing was overwritten: \(id)") }
        let temporary = parent.appendingPathComponent(".pear-stage-\(UUID().uuidString)", isDirectory: true)
        try makeDirectory(temporary)
        stage = temporary
        try build(temporary, destination)
        try AppDataLifecycle.restoreManagedData(root: root, folder: folder, id: id, stage: temporary)
        try validateTree(temporary)
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw posix(parent) }
        defer { close(parentFD) }
        guard renameatx_np(parentFD, temporary.lastPathComponent, parentFD, id, UInt32(RENAME_EXCL)) == 0 else {
            throw posix(destination)
        }
        stage = nil
        if let folder, ["mac-apps", "wine-apps"].contains(folder) {
            let saved = root.appendingPathComponent("SavedData/\(folder)/\(id)")
            if exists(saved) { try FileManager.default.removeItem(at: saved) }
        }
        return destination
    }

    static func openPrivateLog(_ url: URL) throws -> FileHandle {
        // Do not truncate until after fstat: a hardlink must not alter its target.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix(url) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw PearError.invalidPackage("Unsafe managed log file")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// Header-only admission, not code-signature, malware, Rosetta, or compatibility
/// verification. No executable is run while inspecting/importing it.
enum ManagedExecutable {
    static func validateMacOS(_ url: URL) throws {
        let reader = try ManagedBinaryReader(url, executable: true)
        let head = try reader.read(0, 8)
        let magic = u32(head, 0, little: false)
        if [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(u32(head, 4, little: little))
            guard (1...32).contains(count) else { throw invalid("Invalid universal Mach-O slice count") }
            let stride = fat64 ? 32 : 20
            let table = try reader.read(8, count * stride)
            var ranges: [Range<UInt64>] = []
            for index in 0..<count {
                let start = index * stride
                let offset = fat64 ? u64(table, start + 8, little: little) : UInt64(u32(table, start + 8, little: little))
                let size = fat64 ? u64(table, start + 16, little: little) : UInt64(u32(table, start + 12, little: little))
                guard offset >= UInt64(8 + count * stride), offset <= reader.size, size <= reader.size - offset, size >= 32 else {
                    throw invalid("Invalid universal Mach-O slice bounds")
                }
                let range = offset..<(offset + size)
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw invalid("Overlapping Mach-O slices") }
                ranges.append(range)
                try validateSlice(reader, offset: offset, size: size)
            }
        } else {
            try validateSlice(reader, offset: 0, size: reader.size)
        }
    }

    private static func validateSlice(_ reader: ManagedBinaryReader, offset: UInt64, size: UInt64) throws {
        let header = try reader.read(offset, 32)
        let magic = u32(header, 0, little: false)
        guard magic == 0xcffaedfe || magic == 0xfeedfacf else { throw invalid("Expected a 64-bit native macOS Mach-O executable") }
        let little = magic == 0xcffaedfe
        let cpu = u32(header, 4, little: little)
        guard [UInt32(0x01000007), 0x0100000c].contains(cpu), u32(header, 12, little: little) == 2 else {
            throw invalid("Unsupported macOS executable architecture or Mach-O file type")
        }
        let count = Int(u32(header, 16, little: little))
        let length = Int(u32(header, 20, little: little))
        guard count > 0, count <= 65_536, length <= 16_777_216, size >= 32,
              UInt64(length) <= size - 32 else { throw invalid("Invalid Mach-O load command bounds") }
        let commands = try reader.read(offset + 32, length)
        var cursor = 0
        var macOS = false
        for _ in 0..<count {
            guard cursor <= length - 8 else { throw invalid("Truncated Mach-O load command") }
            let command = u32(commands, cursor, little: little)
            let bytes = Int(u32(commands, cursor + 4, little: little))
            guard bytes >= 8, bytes % 4 == 0, bytes <= length - cursor else { throw invalid("Invalid Mach-O command length") }
            if command == 0x32 {
                guard bytes >= 24, u32(commands, cursor + 8, little: little) == 1,
                      UInt64(u32(commands, cursor + 20, little: little)) * 8 <= UInt64(bytes - 24) else {
                    throw invalid("Not a native macOS build (LC_BUILD_VERSION)")
                }
                macOS = true
            } else if command == 0x24 {
                guard bytes >= 16 else { throw invalid("Invalid LC_VERSION_MIN_MACOSX") }
                macOS = true
            } else if [UInt32(0x25), 0x2f, 0x30].contains(command) {
                throw invalid("iOS, tvOS and watchOS executables are not native Mac apps")
            }
            cursor += bytes
        }
        guard cursor == length, macOS else { throw invalid("Executable has no unambiguous macOS build platform") }
    }

    /// Bounded header admission check for a Windows program. This is not a
    /// complete loader validation; Wine decides whether the image can run.
    /// Real games can declare SizeOfHeaders past the first section (including
    /// the tested gta-vc.exe). Allow this overlap, while retaining bounded
    /// headers, section tables and nonempty raw section ranges.
    static func validatePE(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "exe" else { throw invalid("Select a Windows .exe") }
        let reader = try ManagedBinaryReader(url)
        guard reader.size >= 64 else { throw invalid("Missing Windows DOS/PE signature") }
        let dos = try reader.read(0, 64)
        guard dos[0] == 0x4d, dos[1] == 0x5a else { throw invalid("Missing Windows DOS/PE signature") }
        let offset = UInt64(u32(dos, 60, little: true))
        guard offset >= 4, offset + 24 <= reader.size else { throw invalid("Invalid PE header offset") }
        let header = try reader.read(offset, 24)
        guard Array(header.prefix(4)) == [0x50, 0x45, 0, 0] else {
            throw invalid("Not a Windows PE program (16-bit DOS/NE programs are not supported)")
        }
        let machine = u16(header, 4)
        // x86 (including 32-bit games via WoW64), x64 and ARM64.
        guard [UInt16(0x14c), 0x8664, 0xaa64].contains(machine) else {
            throw invalid("This Windows program is built for a CPU Wine cannot run on Apple silicon")
        }
        let sections = Int(u16(header, 6))
        let optionalBytes = Int(u16(header, 20))
        let flags = u16(header, 22)
        guard flags & 0x0002 != 0, flags & 0x2000 == 0 else {
            throw invalid("Not a Windows program (DLLs and drivers are not launch targets)")
        }
        guard optionalBytes >= (machine == 0x14c ? 96 : 112), offset + 24 + UInt64(optionalBytes) <= reader.size else {
            throw invalid("Invalid Windows PE optional header")
        }
        let optional = try reader.read(offset + 24, optionalBytes)
        guard u16(optional, 0) == (machine == 0x14c ? 0x10b : 0x20b) else {
            throw invalid("Invalid Windows PE optional header")
        }
        // 1 = native/driver, 10–13 = EFI images, 16 = boot application.
        let subsystem = u16(optional, 68)
        guard ![UInt16(1), 10, 11, 12, 13, 16].contains(subsystem) else {
            throw invalid("This is a driver or firmware image, not a Windows program")
        }
        // Require a complete section table before checking its raw ranges.
        let tableOffset = offset + 24 + UInt64(optionalBytes)
        guard tableOffset + UInt64(sections) * 40 <= reader.size else {
            throw invalid("The Windows program is truncated (section table missing)")
        }
        let table = try reader.read(tableOffset, sections * 40)
        for index in 0..<sections {
            let bytes = UInt64(u32(table, index * 40 + 16, little: true))
            let start = UInt64(u32(table, index * 40 + 20, little: true))
            guard bytes == 0 || (start <= reader.size && bytes <= reader.size - start) else {
                throw invalid("PE section escapes the file")
            }
        }
    }

    private static func invalid(_ message: String) -> PearError { .invalidPackage(message) }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func u32(_ data: Data, _ offset: Int, little: Bool) -> UInt32 {
        let bytes = little ? Array(data[offset..<(offset + 4)].reversed()) : Array(data[offset..<(offset + 4)])
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func u64(_ data: Data, _ offset: Int, little: Bool) -> UInt64 {
        let bytes = little ? Array(data[offset..<(offset + 8)].reversed()) : Array(data[offset..<(offset + 8)])
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

final class ManagedBinaryReader {
    private let handle: FileHandle
    let size: UInt64

    init(_ url: URL, executable: Bool = false) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ManagedAppFiles.posix(url) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_mode & 0o6000 == 0,
              !executable || info.st_mode & 0o111 != 0 else {
            close(fd)
            throw PearError.invalidPackage("Unsafe or non-executable regular file: \(url.lastPathComponent)")
        }
        size = UInt64(info.st_size)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw PearError.invalidPackage("Truncated executable or metadata")
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw PearError.invalidPackage("File changed while reading") }
        return data
    }
}
