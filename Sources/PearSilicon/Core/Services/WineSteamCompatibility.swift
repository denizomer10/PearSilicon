import Foundation

/// MetalSharp v6's kernelbase launcher rule matches "\Steam\bin\cef\"
/// and appends flags to *every* Steam CEF child, including StorageService.
/// Starting the unchanged client through a private drive-root alias avoids
/// that path rule. Steam and Chromium keep their own child arguments.
enum WineSteamCompatibility {
    static let driveLetter = "s"

    static func prepareLaunchPath(for entry: LibraryEntry, engine: WineEngine) throws -> String? {
        guard entry.platform == .wine,
              PearWineCompatibilityService.runtimeKey(for: engine) == "pearwine-metalsharp-arm64@1.0.1",
              let launch = entry.manifest.wineLaunchPath,
              launch.hasPrefix("Prefix/drive_c/") else { return nil }
        let executable = try WineInstallation.validatedLaunchURL(entry)
        let folder = executable.deletingLastPathComponent()
        guard executable.lastPathComponent.lowercased() == "steam.exe",
              folder.lastPathComponent.lowercased() == "steam" else { return nil }
        // A file named steam.exe alone is insufficient. This is the installed
        // client, never SteamSetup or an arbitrary game's Steam API library.
        for marker in ["steamclient64.dll", "bin/cef/cef.win64/steamwebhelper.exe"] {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(marker).path) else { return nil }
            _ = try ManagedAppFiles.regularFile(folder.appendingPathComponent(marker), inside: entry.directoryURL)
        }
        let relative = String(launch.dropFirst("Prefix/".count))
        let target = "../" + (relative as NSString).deletingLastPathComponent
        let devices = entry.prefixURL.appendingPathComponent("dosdevices")
        if !ManagedAppFiles.exists(devices) { try ManagedAppFiles.makeDirectory(devices) }
        _ = try ManagedAppFiles.existingDirectory(devices)
        guard LibraryPath.isInside(devices, root: entry.directoryURL) else { throw PearError.invalidPackage("Wine drives escape the entry") }
        let link = devices.appendingPathComponent("\(driveLetter):")
        if ManagedAppFiles.exists(link) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target else {
                throw PearError.launchFailed("Steam compatibility needs the private S: drive, but this prefix already uses it for another location.")
            }
        } else {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        return "S:\\" + URL(fileURLWithPath: launch).lastPathComponent
    }
}
