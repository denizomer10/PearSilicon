import Foundation

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
final class IPAInstaller: @unchecked Sendable {

    private let fileManager = FileManager.default
    private let libraryURL: URL
    private let workRoot: URL

    /// Files that still carried a legacy guard field at the last install. Such
    /// a file was not prepared for this platform and its app may not launch;
    /// surface this to the user instead of failing silently.
    private(set) var unpreparedBinaries: [String] = []

    /// Files whose ZIP entry failed its CRC check at the last install. `unzip`
    /// still extracts them, but the bytes are damaged; the app may crash when
    /// it reads one. Reported instead of aborting the whole install.
    private(set) var corruptedFiles: [String] = []

    init(libraryURL: URL) {
        self.libraryURL = libraryURL
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

    func install(ipaAt url: URL) async throws -> InstalledApp {
        guard fileManager.fileExists(atPath: url.path) else {
            throw PearError.ipaNotFound(url.lastPathComponent)
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
            throw PearError.invalidIPA("no .app inside Payload")
        }

        let probe = try makeInstalledApp(fromBundleAt: app)

        // 3) move into library
        let destination = libraryURL.appendingPathComponent("\(probe.id).app", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: app, to: destination)

        // 4) prepare for macOS and 5) sign
        try finalizeInstall(at: destination)

        return try makeInstalledApp(fromBundleAt: destination)
    }

    /// Installs an already-built `.app` bundle (for example the product of an
    /// Xcode build) instead of a package. The bundle is copied as-is (ditto, so
    /// symlinks and extended attributes survive), then prepared and signed the
    /// same way an app package is.
    ///
    /// Simulator builds are rejected: their binaries target the simulator
    /// runtime and cannot be turned into Mac Catalyst binaries.
    func installBundle(at sourceURL: URL) async throws -> InstalledApp {
        // A bundle install never goes through `unzip`, so clear any result
        // left over from a previous app package install; otherwise the caller would
        // report that app package's damaged files against this bundle.
        corruptedFiles = []
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PearError.ipaNotFound(sourceURL.lastPathComponent)
        }
        if isSimulatorBuild(at: sourceURL) {
            throw PearError.invalidIPA(
                "\(sourceURL.lastPathComponent) is a simulator build. "
                + "Build for a device (destination generic/platform=iOS) or run \"pearsilicon xcode\" instead."
            )
        }

        let probe = try makeInstalledApp(fromBundleAt: sourceURL)
        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)

        let destination = libraryURL.appendingPathComponent("\(probe.id).app", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try Shell.run("/usr/bin/ditto", [sourceURL.path, destination.path])

        try finalizeInstall(at: destination)
        return try makeInstalledApp(fromBundleAt: destination)
    }

    /// Prepares a bundle that is already in the library and signs it.
    private func finalizeInstall(at destination: URL) throws {
        try prepareForMacOS(at: destination)
        try signBundle(at: destination)
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

    // MARK: - Prepare for macOS

    /// Rewrites the bundle so macOS will load it as a Mac Catalyst app.
    func prepareForMacOS(at bundleURL: URL) throws {
        unpreparedBinaries = []
        try patchInfoPlist(at: bundleURL)
        removeLegacySignatureArtifacts(at: bundleURL)
        _ = try patchMachOBinaries(at: bundleURL)
        try loadRuntime(at: bundleURL)
        ensureExecutableBits(at: bundleURL)
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", bundleURL.path])
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

    /// Copies the runtime into the bundle and adds an `LC_LOAD_DYLIB` so the
    /// dynamic linker loads it at launch. The older environment-variable loading
    /// path is refused for these processes, but a real load command is honored.
    private func loadRuntime(at bundleURL: URL) throws {
        guard let runtime = AppLauncher.runtimeLibraryURL() else { return }

        let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let destination = frameworks.appendingPathComponent("libPearRuntime.dylib")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: runtime, to: destination)

        if let app = try? makeInstalledApp(fromBundleAt: bundleURL) {
            try BinaryPatcher.addLoadDylib(
                at: app.executableURL,
                path: "@executable_path/Frameworks/libPearRuntime.dylib"
            )
        }
    }

    private func patchInfoPlist(at bundleURL: URL) throws {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSMutableDictionary(contentsOf: infoURL),
              let mutable = info as? [String: Any] else {
            throw PearError.invalidIPA("Info.plist could not be read")
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
        var targets = Set<URL>()

        // main executable
        if let app = try? makeInstalledApp(fromBundleAt: bundleURL) {
            targets.insert(app.executableURL)
        }

        // frameworks and plugins
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

        // loose dylibs anywhere in the bundle
        if let enumerator = fileManager.enumerator(
            at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            for case let file as URL in enumerator where file.pathExtension == "dylib" {
                targets.insert(file)
            }
        }

        var count = 0
        for file in targets {
            guard BinaryPatcher.fileIsMachO64(file) else { continue }
            if BinaryPatcher.hasLegacyGuardMarkers(at: file) {
                unpreparedBinaries.append(file.lastPathComponent)
            }
            if try BinaryPatcher.patchFile(at: file) { count += 1 }
        }
        return count
    }

    // MARK: - Helpers

    /// Builds an `InstalledApp` from a bundle's `Info.plist`.
    func makeInstalledApp(fromBundleAt bundleURL: URL) throws -> InstalledApp {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw PearError.invalidIPA("Info.plist could not be read: \(bundleURL.lastPathComponent)")
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

    /// Adhoc signing with the entitlements the macOS loader needs.
    ///
    /// Code is signed **inside-out**: every nested code object first, then the
    /// main executable, then the bundle. `codesign --deep` is deliberately NOT
    /// used: on an already-prepared app it can leave the original (now stale) platform
    /// signature on nested frameworks, which makes `dlopen` fail with
    /// "code signature invalid" and the app exit silently at launch.
    private func signBundle(at bundleURL: URL) throws {
        let entitlements = try ensureEntitlementsPath()

        // 1) nested code objects (frameworks, plugins, dylibs)
        for object in codeObjects(in: bundleURL) {
            try sign(object, entitlements: entitlements)
        }

        // 2) main executable
        if let app = try? makeInstalledApp(fromBundleAt: bundleURL) {
            try sign(app.executableURL, entitlements: entitlements)
        }

        // 3) the bundle itself
        try sign(bundleURL, entitlements: entitlements)
    }

    private func sign(_ url: URL, entitlements: String) throws {
        try Shell.run("/usr/bin/codesign", [
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

    private func ensureEntitlementsPath() throws -> String {
        let entitlements = workRoot.appendingPathComponent("entitlements.plist")
        if !fileManager.fileExists(atPath: entitlements.path) {
            try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)
            let plist = """
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
            try plist.write(to: entitlements, atomically: true, encoding: .utf8)
        }
        return entitlements.path
    }
}
