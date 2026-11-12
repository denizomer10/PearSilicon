import Foundation

/// Installer detection is a hint, never a reason to execute an imported file.
/// Windows setup still presents its own UI; selection happens after it finishes.
enum WineInstallation {
    static func isInstaller(source: URL, name: String) -> Bool {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.lowercased()
        if base.contains("unins") { return false }
        if base.contains("setup") || base == "install" || base.hasSuffix("installer") { return true }
        guard let handle = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 8 * 1024 * 1024)) ?? Data()
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\0", with: "").lowercased()
        return ["inno setup setup data", "nullsoft install system", "nsis error", "installshield", "wixbundle"].contains { text.contains($0) }
    }

    static func validatedLaunchURL(_ entry: LibraryEntry) throws -> URL {
        let path = entry.manifest.wineLaunchPath ?? entry.manifest.payloadPath
        try LibraryPath.validateRelative(path)
        guard path.hasPrefix("Payload/Program/") || path.hasPrefix("Prefix/drive_c/") else {
            throw PearError.invalidPackage("Select a program inside this entry's program folder or private C: drive")
        }
        let root = entry.directoryURL.appendingPathComponent(path.hasPrefix("Prefix/") ? "Prefix/drive_c" : "Payload/Program")
        _ = try ManagedAppFiles.existingDirectory(root)
        guard LibraryPath.isInside(root, root: entry.directoryURL) else { throw PearError.invalidPackage("Program drive escapes entry") }
        let file = try ManagedAppFiles.regularFile(entry.directoryURL.appendingPathComponent(path), inside: root)
        try ManagedExecutable.validatePE(file)
        return file
    }

    static func installedExecutables(_ entry: LibraryEntry) -> [String: String] {
        let fm = FileManager.default
        let drive = entry.prefixURL.appendingPathComponent("drive_c")
        guard (try? ManagedAppFiles.existingDirectory(drive)) != nil,
              LibraryPath.isInside(drive, root: entry.directoryURL) else { return [:] }
        guard let walk = fm.enumerator(at: drive, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return [:] }
        var result: [String: String] = [:]
        var visited = 0
        for case let url as URL in walk {
            visited += 1
            if visited > 50_000 { break }
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            if values.isSymbolicLink == true { walk.skipDescendants(); continue }
            let path = String(url.path.dropFirst(drive.path.count + 1))
            if path.lowercased().hasPrefix("windows/") || path.lowercased() == "windows" { walk.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe", LibraryPath.isInside(url, root: drive) else { continue }
            result["Prefix/drive_c/" + path] = "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }

    static func candidates(_ entry: LibraryEntry, changedOnly: Bool = false) -> [WineExecutableCandidate] {
        let baseline = entry.manifest.wineInstallBaseline ?? [:]
        let files = installedExecutables(entry)
        let helpers = ["unins", "uninstall", "setup", "install", "crash", "report", "update", "service", "helper", "redist", "dxdiag", "dxweb", "vcredist", "vc_redist"]
        let paths = files.keys.sorted().filter { path in
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            guard !helpers.contains(where: name.contains), !changedOnly || baseline[path] != files[path] else { return false }
            var candidate = entry
            candidate.manifest.wineLaunchPath = path
            return (try? validatedLaunchURL(candidate)) != nil
        }
        let installerName = entry.payloadURL.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: "setup", with: "").replacingOccurrences(of: "installer", with: "")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let matching = paths.filter { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() == installerName }
        return paths.map { WineExecutableCandidate(path: $0, isRecommended: paths.count == 1 || (matching.count == 1 && matching[0] == $0)) }
    }
}
