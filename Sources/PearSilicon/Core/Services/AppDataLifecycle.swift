import Foundation

/// Only owned paths are removed. Never searches the user's disk by app name.
struct AppDataLifecycle {
    let root: URL
    private let fm = FileManager.default

    init(root: URL) { self.root = LibraryPath.canonicalURL(root) }

    func removeIOSData(id: String) throws {
        try LibraryPath.validateComponent(id)
        let logs = root.appendingPathComponent("Logs")
        if fm.fileExists(atPath: logs.path) {
            _ = try ManagedAppFiles.existingDirectory(logs)
            for item in try fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
                where item.lastPathComponent.range(of: "^" + NSRegularExpression.escapedPattern(for: id) + "(\\.(legacy|native|host|wine))?(\\.[0-9]+)?\\.log$", options: .regularExpression) != nil {
                try fm.removeItem(at: item)
            }
        }
        for path in ["Games/\(id)", "ODR/\(id)", "Keychain/\(id)", "Keymaps/\(id).json", "Legacy32/Saves/\(id)", "Legacy32/Hosts/\(id).app", "Logs/\(id).log", "Logs/\(id).host.log", "NativeMigrationConflicts/\(id)"] {
            try removeOwned(path)
        }
    }

    /// Removes the macOS host bundle PearSilicon created for a 32-bit game
    /// (owned path, named by bundle ID) and unregisters it from LaunchServices.
    static func removeLegacyHost(id: String) throws {
        try LibraryPath.validateComponent(id)
        let bundle = AppPaths.legacyHostBundle(for: id)
        guard ManagedAppFiles.exists(bundle) else { return }
        _ = try? Shell.run(AppLauncher.lsregisterPath, ["-u", bundle.path])
        try FileManager.default.removeItem(at: bundle)
    }

    static func removeNativeContainer(id: String) throws {
        try LibraryPath.validateComponent(id)
        let container = AppPaths.nativeContainerData(for: id).deletingLastPathComponent()
        if ManagedAppFiles.exists(container) {
            try FileManager.default.removeItem(at: container)
        }
    }

    private func removeOwned(_ path: String) throws {
        try LibraryPath.validateRelative(path)
        let url = root.appendingPathComponent(path)
        guard ManagedAppFiles.exists(url) else { return }
        // Resolve the parent, never the final component: an owned symlink is
        // removed as a link, without following it to a host directory.
        guard LibraryPath.isInside(url.deletingLastPathComponent(), root: root) else {
            throw PearError.invalidPackage("Data path escapes the library")
        }
        if ManagedAppFiles.exists(url) { try fm.removeItem(at: url) }
    }

    func removeManaged(_ entry: LibraryEntry, keepData: Bool) throws {
        try LibraryPath.validateComponent(entry.manifest.id)
        guard LibraryPath.isInside(entry.directoryURL, root: root),
              entry.directoryURL.deletingLastPathComponent().lastPathComponent == entry.platform.rawValue else {
            throw PearError.invalidPackage("App is outside the library")
        }
        let saved = root.appendingPathComponent("SavedData/\(entry.platform.rawValue)/\(entry.manifest.id)")
        if keepData {
            guard !ManagedAppFiles.exists(saved) else {
                throw PearError.invalidPackage("Saved data already exists for this app; restore or remove it first")
            }
            guard LibraryPath.isInside(saved.deletingLastPathComponent(), root: root) else {
                throw PearError.invalidPackage("Saved data path escapes library")
            }
            try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: entry.directoryURL, to: saved)
        } else {
            try fm.removeItem(at: entry.directoryURL)
            try removeOwned("SavedData/\(entry.platform.rawValue)/\(entry.manifest.id)")
        }
    }

    static func restoreManagedData(root: URL, folder: String?, id: String, stage: URL) throws {
        guard let folder, ["mac-apps", "wine-apps"].contains(folder) else { return }
        let saved = root.appendingPathComponent("SavedData/\(folder)/\(id)")
        guard FileManager.default.fileExists(atPath: saved.path) else { return }
        try ManagedAppFiles.rejectRootSymlink(saved)
        guard LibraryPath.isInside(saved, root: root) else { throw PearError.invalidPackage("Saved data escapes library") }
        for name in ["Data", "Prefix"] {
            let from = saved.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = stage.appendingPathComponent(name)
            try FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: from, to: to)
        }
        // Some older games save beside their EXE. Restore missing files there,
        // and retain a complete copy so conflicting files remain recoverable.
        let payload = saved.appendingPathComponent("Payload")
        if FileManager.default.fileExists(atPath: payload.path) {
            func mergeMissing(_ source: URL, _ target: URL) throws {
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.copyItem(at: source, to: target)
                } else if (try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true {
                    try ManagedAppFiles.rejectRootSymlink(source)
                    try ManagedAppFiles.rejectRootSymlink(target)
                    for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                        try mergeMissing(child, target.appendingPathComponent(child.lastPathComponent))
                    }
                }
            }
            if folder == "wine-apps" { try mergeMissing(payload, stage.appendingPathComponent("Payload")) }
            let recovery = stage.appendingPathComponent("Data/RetainedProgramFiles-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: payload, to: recovery)
        }
    }

    /// Move old native-container content into the portable home. Conflicting
    /// files are retained inside the library for recovery, never overwritten.
    func importNativeData(id: String, source: URL) throws {
        try LibraryPath.validateComponent(id)
        guard fm.fileExists(atPath: source.path) else { return }
        _ = try ManagedAppFiles.existingDirectory(source)
        for name in ["Documents", "Library", "tmp"] {
            let child = source.appendingPathComponent(name)
            if ManagedAppFiles.exists(child) { try ManagedAppFiles.validateTree(child) }
        }
        let target = root.appendingPathComponent("Games/\(id)")
        func merge(_ from: URL, _ to: URL, relative: String) throws {
            if !fm.fileExists(atPath: to.path) {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                return
            }
            let a = try from.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let b = try to.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if a.isDirectory == true, b.isDirectory == true, a.isSymbolicLink != true, b.isSymbolicLink != true {
                for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
                    try merge(item, to.appendingPathComponent(item.lastPathComponent), relative: relative + "/" + item.lastPathComponent)
                }
                try fm.removeItem(at: from)
            } else {
                let backup = root.appendingPathComponent("NativeMigrationConflicts/\(id)/\(UUID().uuidString)/" + relative)
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: backup)
            }
        }
        let games = root.appendingPathComponent("Games")
        if ManagedAppFiles.exists(games) { _ = try ManagedAppFiles.existingDirectory(games) }
        if ManagedAppFiles.exists(target) { _ = try ManagedAppFiles.existingDirectory(target) }
        guard LibraryPath.isInside(target, root: root) else { throw PearError.invalidPackage("Data home escapes library") }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["Documents", "Library", "tmp"] {
            let from = source.appendingPathComponent(name)
            if ManagedAppFiles.exists(from) { try merge(from, target.appendingPathComponent(name), relative: name) }
        }
    }

    func validateForReset() throws {
        _ = try ManagedAppFiles.existingDirectory(root)
        guard StorageLocationStore.hasMarker(at: root) else {
            throw PearError.invalidPackage("Not a marked PearSilicon library")
        }
    }

    func reset() throws {
        try validateForReset()
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where item.lastPathComponent != StorageLocationStore.markerName {
            try fm.removeItem(at: item)
        }
    }
}
