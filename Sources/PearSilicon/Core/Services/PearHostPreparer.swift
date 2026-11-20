import Foundation

/// Prepares an installed ARM64 iOS `.app` bundle to run on PearHost (native macOS
/// platform, zero `/System/iOSSupport`) using `runtime/build/host` frameworks.
enum PearHostPreparer {
    static let markerFileName = ".pearsilicon-pearhost"
    /// Libraries PearHost builds next to its frameworks and installs into
    /// every prepared bundle (macOS builds replacing the app's Catalyst ones).
    private static let hostLibraries = ["libcxxcompat.dylib", "libswiftUIKit.dylib"]

    /// Every framework PearHost built (runtime/host/build-host.sh): its own
    /// UIKit, OpenGLES and MetalKit, stand-ins for iOS-only frameworks
    /// (MessageUI, iAd, ...), overlays adding iOS-only API to a macOS
    /// framework (AVKit, GameController, ...), and MobileCoreServices.
    private static func hostFrameworks(in hostDir: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: hostDir.path)) ?? []
        return items.filter { $0.hasSuffix(".framework") }.map { String($0.dropLast(".framework".count)) }.sorted()
    }

    static func markerURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(markerFileName)
    }

    /// Bumped when preparation itself changes (which load commands are
    /// redirected, what is installed): an older bundle is prepared again.
    static let preparerVersion = 2

    /// The bundle was prepared by an older preparer (or not at all).
    static func needsPreparation(_ bundleURL: URL) -> Bool {
        let recorded = (try? String(contentsOf: markerURL(in: bundleURL), encoding: .utf8)) ?? ""
        return !recorded.contains("preparer=\(preparerVersion)\n")
    }

    static func isPrepared(_ bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(in: bundleURL).path)
            && FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Frameworks/UIKit.framework/UIKit").path)
    }

    static func locateHostFrameworks() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PEAR_HOST_FRAMEWORKS_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("PearHost", isDirectory: true))
        }
        // Development tree: walk up from executable or cwd to repo root -> runtime/build/host
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("runtime/build/host", isDirectory: true))
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<5 {
                candidates.append(dir.appendingPathComponent("runtime/build/host", isDirectory: true))
                dir = dir.deletingLastPathComponent()
            }
        }
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("UIKit.framework/UIKit").path)
        }
    }

    static func prepare(bundleURL: URL, executableName: String, hostDir: URL) throws {
        let fm = FileManager.default
        let frameworksDir = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        // Remove Catalyst-only shims if switching an already-prepared Catalyst bundle.
        for catalystArtifact in ["libPearRuntime.dylib", "libPearOpenGLES.dylib", "libswiftUIKit.dylib", "libcxxcompat.dylib", "PearANGLE", "MarketplaceKit.framework"] {
            let url = frameworksDir.appendingPathComponent(catalystArtifact)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }

        try installHostFrameworks(into: frameworksDir, from: hostDir)

        // Retarget executable + app-bundled frameworks to macOS platform.
        let host = hostFrameworks(in: hostDir)
        let exeURL = bundleURL.appendingPathComponent(executableName)
        try retargetMachO(at: exeURL, hostFrameworks: host, mainExecutable: true)

        if let items = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil) {
            for item in items {
                let name = item.lastPathComponent
                if host.contains(where: { name == "\($0).framework" }) || name == "PearANGLE" || hostLibraries.contains(name) {
                    continue
                }
                if name.hasSuffix(".framework") {
                    let fwBin = item.appendingPathComponent(String(name.dropLast(".framework".count)))
                    if fm.fileExists(atPath: fwBin.path) {
                        try? retargetMachO(at: fwBin, hostFrameworks: host)
                    }
                } else if name.hasSuffix(".dylib") {
                    try? retargetMachO(at: item, hostFrameworks: host)
                }
            }
        }

        try writeMarker(in: bundleURL, hostDir: hostDir)
    }

    /// A prepared bundle carries copies of the PearHost frameworks. When the
    /// runtime has been rebuilt since, replace those copies so the app runs the
    /// current PearHost. Returns true when the copies were refreshed.
    @discardableResult
    static func refreshHostFrameworksIfStale(bundleURL: URL, hostDir: URL) throws -> Bool {
        let marker = markerURL(in: bundleURL)
        let recorded = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        let current = hostStamp(hostDir)
        guard !current.isEmpty, !recorded.contains(current) else { return false }
        let frameworksDir = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try installHostFrameworks(into: frameworksDir, from: hostDir)
        try writeMarker(in: bundleURL, hostDir: hostDir)
        return true
    }

    /// Identifies a PearHost build: size and modification time of its UIKit image.
    static func hostStamp(_ hostDir: URL) -> String {
        let uikit = hostDir.appendingPathComponent("UIKit.framework/UIKit")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: uikit.path),
              let size = attrs[.size] as? NSNumber,
              let date = attrs[.modificationDate] as? Date else { return "" }
        return "host=\(size.int64Value):\(Int64(date.timeIntervalSince1970 * 1000))"
    }

    private static func writeMarker(in bundleURL: URL, hostDir: URL) throws {
        try Data("pearhost\n\(hostStamp(hostDir))\npreparer=\(preparerVersion)\n".utf8).write(to: markerURL(in: bundleURL), options: .atomic)
    }

    /// Copies the PearHost frameworks, PearANGLE and PearHost's libraries into
    /// <app>/Frameworks and signs them.
    private static func installHostFrameworks(into frameworksDir: URL, from hostDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        let host = hostFrameworks(in: hostDir)
        for item in host.map({ "\($0).framework" }) + ["PearANGLE"] + hostLibraries {
            let src = hostDir.appendingPathComponent(item)
            let dst = frameworksDir.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        // The UIKit Swift overlay is a Mac Catalyst build: retarget it like
        // the app's own images.
        let overlay = frameworksDir.appendingPathComponent("libswiftUIKit.dylib")
        if fm.fileExists(atPath: overlay.path) {
            try retargetMachO(at: overlay, hostFrameworks: host)
        }
        for fw in host {
            let fwBin = frameworksDir.appendingPathComponent("\(fw).framework/\(fw)")
            if fm.fileExists(atPath: fwBin.path) {
                _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", fwBin.path])
            }
        }
        let cxx = frameworksDir.appendingPathComponent("libcxxcompat.dylib")
        if fm.fileExists(atPath: cxx.path) {
            _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", cxx.path])
        }
    }

    private static func retargetMachO(at url: URL, hostFrameworks host: [String], mainExecutable: Bool = false) throws {
        // A bundle prepared earlier can name CoreServices twice (an older
        // PearHost preparation mapped MobileCoreServices to it); dyld refuses that.
        try dedupeDylibs(at: url)
        // Undo a Catalyst preparation of the same bundle (while the image is
        // still iOS/Catalyst, which is what BinaryPatcher edits): its runtime
        // dylib is removed above, and its load command is the last one
        // PackageInstaller appended, so dropping it keeps every bind ordinal.
        if BinaryPatcher.hasLoadDylib(at: url, containing: "libPearRuntime") {
            _ = try BinaryPatcher.removeLoadDylib(at: url, containing: "libPearRuntime")
        }
        _ = try BinaryPatcher.patchFile(at: url, targetPlatform: BinaryPatcher.Platform.macOS)
        // OpenGLES dependencies pointed at the Catalyst ANGLE shim go to
        // PearHost's OpenGLES.framework.
        let iosSupport = "/System/iOSSupport/System/Library/Frameworks/"
        for dep in dependencies(of: url) {
            var target: String?
            if dep.contains("libPearOpenGLES") {
                target = "@rpath/OpenGLES.framework/OpenGLES"
            } else if dep.hasSuffix("/libcxxcompat.dylib") && dep != "@rpath/libcxxcompat.dylib" {
                target = "@rpath/libcxxcompat.dylib"
            } else if dep.hasSuffix("libswiftUIKit.dylib") && dep != "@rpath/libswiftUIKit.dylib" {
                target = "@rpath/libswiftUIKit.dylib"
            } else if dep.hasPrefix(iosSupport), let fw = dep.dropFirst(iosSupport.count).split(separator: "/").first,
                      fw.hasSuffix(".framework") {
                // Never /System/iOSSupport: PearHost's framework of that name, or macOS's.
                let name = String(fw.dropLast(".framework".count))
                target = host.contains(name) ? "@rpath/\(name).framework/\(name)" : "/System/Library/Frameworks/\(name).framework/\(name)"
            } else if dep.hasPrefix("/System/Library/Frameworks/"), let fw = dep.split(separator: "/").dropFirst(3).first,
                      fw.hasSuffix(".framework") {
                let name = String(fw.dropLast(".framework".count))
                if host.contains(name) && dep == "/System/Library/Frameworks/\(name).framework/\(name)" {
                    target = "@rpath/\(name).framework/\(name)"
                }
            }
            if let target, target != dep {
                _ = runTool("/usr/bin/install_name_tool", ["-change", dep, target, url.path])
            }
        }
        let rpaths = rpaths(of: url)
        if !rpaths.contains("/usr/lib/swift") {
            _ = runTool("/usr/bin/install_name_tool", ["-add_rpath", "/usr/lib/swift", url.path])
        }
        // PearHost frameworks are reached through @rpath; apps built without
        // embedded frameworks (older titles) carry no such rpath.
        if mainExecutable && !rpaths.contains("@executable_path/Frameworks") {
            _ = runTool("/usr/bin/install_name_tool", ["-add_rpath", "@executable_path/Frameworks", url.path])
        }
        _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", url.path])
    }

    /// Points the later of two load commands naming the same dylib at a
    /// PearHost framework re-exporting that library, in place (both keep their
    /// ordinals, so every import still binds).
    static func dedupeDylibs(at url: URL) throws {
        let replacements = [
            "/System/Library/Frameworks/CoreServices.framework/CoreServices":
                "@rpath/MobileCoreServices.framework/MobileCoreServices",
        ]
        var data = try Data(contentsOf: url)
        guard data.count > 32 else { return }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard u32(0) == 0xFEED_FACF else { return }  // thin 64-bit images only
        let dylibCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x8000_0023, 0x8000_0020]
        var offset = 32
        var seen = Set<String>()
        var changed = false
        for _ in 0..<Int(u32(16)) {
            let cmd = u32(offset), size = Int(u32(offset + 4))
            if dylibCommands.contains(cmd) {
                let start = offset + Int(u32(offset + 8))
                let end = data[start..<(offset + size)].firstIndex(of: 0) ?? (offset + size)
                let name = String(decoding: data[start..<end], as: UTF8.self)
                if seen.contains(name), let new = replacements[name], new.utf8.count < offset + size - start {
                    var bytes = Array(new.utf8)
                    bytes += Array(repeating: 0, count: offset + size - start - bytes.count)
                    data.replaceSubrange(start..<(offset + size), with: bytes)
                    changed = true
                }
                seen.insert(name)
            }
            offset += size
        }
        if changed { try data.write(to: url) }  // in place: keeps the mode bits
    }

    private static func toolOutput(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// LC_RPATH entries of the image (`otool -l`).
    private static func rpaths(of url: URL) -> [String] {
        let lines = toolOutput("/usr/bin/otool", ["-l", url.path]).split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        for (index, line) in lines.enumerated() where line == "cmd LC_RPATH" && index + 2 < lines.count {
            let entry = lines[index + 2]
            guard entry.hasPrefix("path ") else { continue }
            var path = String(entry.dropFirst("path ".count))
            if let end = path.range(of: " (offset") { path = String(path[..<end.lowerBound]) }
            result.append(path)
        }
        return result
    }

    /// Install names of the image's dependencies (`otool -L`).
    private static func dependencies(of url: URL) -> [String] {
        let text = toolOutput("/usr/bin/otool", ["-L", url.path])
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let end = trimmed.range(of: " (compatibility") else { return nil }
            return String(trimmed[..<end.lowerBound])
        }
    }

    @discardableResult
    private static func runTool(_ path: String, _ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}
