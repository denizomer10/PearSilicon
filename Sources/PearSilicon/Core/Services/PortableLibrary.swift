import Foundation

struct PortableLibrarySnapshot: Sendable {
    var iosApps: [InstalledApp] = []
    var macEntries: [LibraryEntry] = []
    var wineEntries: [LibraryEntry] = []
    var warnings: [String] = []

    func entries(for platform: LibraryPlatform) -> [LibraryEntry] {
        switch platform {
        case .iOS: []
        case .macOS: macEntries
        case .wine: wineEntries
        }
    }
}

enum BundleKind: Sendable {
    case iOS
    case macOS
}

/// Reads the three portable library folders. Installed iOS packages keep their
/// flat layout (`ios-apps/<bundle>.app`) for compatibility with the existing
/// runtime; their saves, keychain and ODR data still live inside the same
/// PearSilicon root. Mac and Wine apps use self-contained `LibraryEntry`
/// directories.
struct PortableLibrary: Sendable {
    static let iOSFolder = LibraryPlatform.iOS.rawValue
    static let macFolder = LibraryPlatform.macOS.rawValue
    static let wineFolder = LibraryPlatform.wine.rawValue

    let rootURL: URL
    private var fileManager: FileManager { .default }

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    var iosURL: URL { rootURL.appendingPathComponent(Self.iOSFolder, isDirectory: true) }
    var macURL: URL { rootURL.appendingPathComponent(Self.macFolder, isDirectory: true) }
    var wineURL: URL { rootURL.appendingPathComponent(Self.wineFolder, isDirectory: true) }
    var legacyApplicationsURL: URL { rootURL.appendingPathComponent("Applications", isDirectory: true) }

    func scan() -> PortableLibrarySnapshot {
        var snapshot = PortableLibrarySnapshot()
        snapshot.iosApps = scanIOS(warnings: &snapshot.warnings)
        snapshot.macEntries = scanEntries(in: macURL, platform: .macOS, warnings: &snapshot.warnings)
        snapshot.wineEntries = scanEntries(in: wineURL, platform: .wine, warnings: &snapshot.warnings)
        return snapshot
    }

    /// New iOS installs go to `ios-apps`. The legacy `Applications` folder is
    /// still read so an existing library keeps working without a forced move.
    func scanIOS(warnings: inout [String]) -> [InstalledApp] {
        var seen: Set<String> = []
        var apps: [InstalledApp] = []
        let installer = PackageInstaller(libraryURL: iosURL)
        for folder in [iosURL, legacyApplicationsURL] {
            guard let bundles = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for bundle in bundles where bundle.pathExtension == "app" {
                do {
                    let app = try installer.makeInstalledApp(fromBundleAt: bundle)
                    guard !seen.contains(app.id) else { continue }
                    seen.insert(app.id)
                    apps.append(app)
                } catch {
                    warnings.append("\(bundle.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func scanEntries(in folder: URL, platform: LibraryPlatform, warnings: inout [String]) -> [LibraryEntry] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [LibraryEntry] = []
        for directory in children where directory.hasDirectoryPath {
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(LibraryManifest.filename))
                let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
                guard manifest.platform == platform else {
                    warnings.append("\(directory.lastPathComponent): manifest belongs to \(manifest.platform.rawValue)")
                    continue
                }
                try LibraryPath.validate(manifest, directory: directory)
                guard directory.lastPathComponent == manifest.id else {
                    throw PearError.invalidPackage("Manifest id does not match its folder")
                }
                entries.append(LibraryEntry(manifest: manifest, directoryURL: directory))
            } catch {
                warnings.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func classify(_ bundle: URL) throws -> BundleKind {
        func plist(_ url: URL) -> [String: Any]? {
            NSDictionary(contentsOf: url) as? [String: Any]
        }
        if let info = plist(bundle.appendingPathComponent("Contents/Info.plist")) {
            let name = (info["DTPlatformName"] as? String)?.lowercased()
            let supported = info["CFBundleSupportedPlatforms"] as? [String] ?? []
            if name == "macosx" || supported.contains("MacOSX") { return .macOS }
            throw PearError.invalidPackage("This bundle is not a native macOS app")
        }
        if let info = plist(bundle.appendingPathComponent("Info.plist")) {
            if info["LSRequiresIPhoneOS"] as? Bool == true { return .iOS }
            let supported = info["CFBundleSupportedPlatforms"] as? [String] ?? []
            if supported.contains(where: { $0.hasPrefix("iPhone") || $0.hasPrefix("iPad") }) { return .iOS }
        }
        throw PearError.invalidPackage(
            "Could not tell whether this bundle is an iOS or macOS app. Install an .ipa for iOS."
        )
    }

    /// A clone-based snapshot shaped like a portable entry, so the same
    /// single-file backup format covers an iOS app's bundle, saves, keychain
    /// store, ODR packs and keymap. APFS clones keep the extra logical copies
    /// cheap on the internal volume.
    func makeIOSSnapshot(for app: InstalledApp, in workRoot: URL) throws -> URL {
        let directory = workRoot.appendingPathComponent("ios-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fileManager.removeItem(at: directory) } }

        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        _ = try Shell.run("/usr/bin/ditto", ["--clone", app.bundleURL.path, payload.appendingPathComponent(app.bundleURL.lastPathComponent).path])

        let sources: [(String, URL)] = [
            ("Data", rootURL.appendingPathComponent("Games/\(app.id)", isDirectory: true)),
            ("Keychain", rootURL.appendingPathComponent("Keychain/\(app.id)", isDirectory: true)),
            ("ODR", rootURL.appendingPathComponent("ODR/\(app.id)", isDirectory: true)),
        ]
        for (name, source) in sources where fileManager.fileExists(atPath: source.path) {
            _ = try Shell.run("/usr/bin/ditto", ["--clone", source.path, directory.appendingPathComponent(name).path])
        }
        let keymap = rootURL.appendingPathComponent("Keymaps/\(app.id).json")
        if fileManager.fileExists(atPath: keymap.path) {
            try fileManager.copyItem(at: keymap, to: directory.appendingPathComponent("Keymap.json"))
        }

        let manifest = LibraryManifest(
            id: app.id, platform: .iOS, displayName: app.displayName,
            version: app.shortVersion, payloadPath: "Payload/\(app.bundleURL.lastPathComponent)"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(LibraryManifest.filename), options: .atomic
        )
        keep = true
        return directory
    }

    /// After restoring a portable iOS entry, put the bundle and its data back
    /// into the flat library layout the iOS runtime uses.
    func installRestoredIOSEntry(
        _ entry: LibraryEntry, replacing: Bool, rollbackRoot: URL
    ) throws -> InstalledApp {
        guard entry.platform == .iOS else { throw PearError.invalidPackage("Not an iOS backup") }
        let bundleName = (entry.manifest.payloadPath as NSString).lastPathComponent
        let sourceBundle = entry.payloadURL
        var warnings: [String] = []
        let existing = scanIOS(warnings: &warnings).first { $0.id == entry.manifest.id }
        try fileManager.createDirectory(at: iosURL, withIntermediateDirectories: true)
        if let existing, !replacing {
            throw PearError.invalidPackage("\(entry.displayName) is already installed; remove it or use Restore and Replace")
        }
        let destinationBundle = existing?.bundleURL
            ?? iosURL.appendingPathComponent("\(entry.manifest.id).app", isDirectory: true)
        if existing == nil, fileManager.fileExists(atPath: destinationBundle.path) {
            throw PearError.invalidPackage("A different app already occupies \(destinationBundle.lastPathComponent)")
        }
        try fileManager.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
        let rollback = rollbackRoot.appendingPathComponent("\(entry.manifest.id)-\(UUID().uuidString)", isDirectory: true)
        var movedExisting = false
        if let existing {
            try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
            try fileManager.moveItem(at: existing.bundleURL, to: rollback.appendingPathComponent("App.app"))
            movedExisting = true
        }
        do {
            try fileManager.moveItem(at: sourceBundle, to: destinationBundle)

            func restoreData(_ name: String, to destination: URL) throws {
                let source = entry.directoryURL.appendingPathComponent(name, isDirectory: true)
                guard fileManager.fileExists(atPath: source.path) else { return }
                if fileManager.fileExists(atPath: destination.path) {
                    guard replacing else {
                        throw PearError.invalidPackage(
                            "\(entry.displayName) already has \(name) data; use Restore and Replace"
                        )
                    }
                    let old = rollback.appendingPathComponent(name, isDirectory: true)
                    try fileManager.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: destination, to: old)
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: destination)
            }
            try restoreData("Data", to: rootURL.appendingPathComponent("Games/\(entry.manifest.id)", isDirectory: true))
            try restoreData("Keychain", to: rootURL.appendingPathComponent("Keychain/\(entry.manifest.id)", isDirectory: true))
            try restoreData("ODR", to: rootURL.appendingPathComponent("ODR/\(entry.manifest.id)", isDirectory: true))

            let keymap = entry.directoryURL.appendingPathComponent("Keymap.json")
            if fileManager.fileExists(atPath: keymap.path) {
                let destination = rootURL.appendingPathComponent("Keymaps/\(entry.manifest.id).json")
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    guard replacing else {
                        throw PearError.invalidPackage(
                            "\(entry.displayName) already has a keymap; use Restore and Replace"
                        )
                    }
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: keymap, to: destination)
            }

            let installer = PackageInstaller(libraryURL: iosURL)
            let app = try installer.makeInstalledApp(fromBundleAt: destinationBundle)
            guard app.id == entry.manifest.id else {
                throw PearError.invalidPackage("Restored bundle identifier does not match its manifest")
            }
            _ = bundleName
            return app
        } catch {
            try? fileManager.removeItem(at: destinationBundle)
            if movedExisting,
               fileManager.fileExists(atPath: rollback.appendingPathComponent("App.app").path) {
                try? fileManager.moveItem(at: rollback.appendingPathComponent("App.app"), to: destinationBundle)
            }
            throw error
        }
    }
}
