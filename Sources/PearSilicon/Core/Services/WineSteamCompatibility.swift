import Foundation

/// MetalSharp Wine's kernelbase launcher rule matches the path
/// "\Steam\bin\cef\" and appends flags to every Steam CEF child, which makes
/// StorageService fail (FATAL target_services.cc, process_state_.InitCalled()).
///
/// The installed client is started unchanged through a link at the root of C:
/// (`C:\PearSiliconSteam` → its folder), which avoids that path. A drive
/// letter mapped to the Steam folder avoided it too, but Steam then records the
/// drive root as its install folder and asks to repair it on the next start.
/// Client files, registry and the signed engine stay untouched, and an existing
/// file or link with the alias name is never replaced.
enum WineSteamCompatibility {
    /// Not containing "\Steam\", so the CEF path no longer matches the rule.
    static let aliasName = "PearSiliconSteam"
    /// Files that identify the installed client, never SteamSetup or a game's
    /// Steam API library.
    static let clientMarkers = ["steamclient64.dll", "bin/cef/cef.win64/steamwebhelper.exe"]

    static func prepareLaunchPath(for entry: LibraryEntry, engine: WineEngine) throws -> String? {
        guard entry.platform == .wine, engine.distribution == .metalSharp,
              let launch = entry.manifest.wineLaunchPath,
              launch.hasPrefix("Prefix/drive_c/") else { return nil }
        let executable = try WineInstallation.validatedLaunchURL(entry)
        let folder = executable.deletingLastPathComponent()
        guard executable.lastPathComponent.lowercased() == "steam.exe",
              folder.lastPathComponent.lowercased() == "steam" else { return nil }
        // Markers must be regular files inside the client folder (no links).
        // Installers often make that folder group-writable (Steam uses 0775),
        // so no ownership rule applies to the client's own folder.
        for marker in clientMarkers {
            var current = folder
            for part in marker.split(separator: "/") {
                current.appendPathComponent(String(part))
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { return nil }
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: current.path, isDirectory: &directory), !directory.boolValue else { return nil }
        }
        let driveC = entry.prefixURL.appendingPathComponent("drive_c")
        guard LibraryPath.isInside(folder, root: driveC) else { return nil }

        // The link target is relative to drive_c, so the entry stays portable.
        let relative = String(launch.dropFirst("Prefix/drive_c/".count))
        let target = (relative as NSString).deletingLastPathComponent
        guard !target.isEmpty, target != aliasName else { return nil }
        _ = try ManagedAppFiles.existingDirectory(driveC)
        let link = driveC.appendingPathComponent(aliasName)
        if ManagedAppFiles.exists(link) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target else {
                throw PearError.launchFailed("\(entry.displayName) needs C:\\\(aliasName) as a link to its folder, but that name is already used in this prefix.")
            }
        } else {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        guard LibraryPath.isInside(link.appendingPathComponent(executable.lastPathComponent), root: entry.directoryURL) else {
            throw PearError.invalidPackage("Program alias escapes the entry")
        }
        return "C:\\" + aliasName + "\\" + URL(fileURLWithPath: launch).lastPathComponent
    }
}
