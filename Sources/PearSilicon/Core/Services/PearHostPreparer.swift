import Foundation

/// Prepares an installed ARM64 iOS `.app` bundle to run on PearHost (native macOS
/// platform, zero `/System/iOSSupport`) using `runtime/build/host` frameworks.
enum PearHostPreparer {
    static let markerFileName = ".pearsilicon-pearhost"
    private static let redirectedFrameworks = ["UIKit", "iAd", "OpenGLES", "MetalKit"]

    static func markerURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(markerFileName)
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
        for catalystArtifact in ["libPearRuntime.dylib", "libPearOpenGLES.dylib", "libswiftUIKit.dylib", "PearANGLE", "MarketplaceKit.framework"] {
            let url = frameworksDir.appendingPathComponent(catalystArtifact)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }

        try installHostFrameworks(into: frameworksDir, from: hostDir)

        // Retarget executable + app-bundled frameworks to macOS platform.
        let exeURL = bundleURL.appendingPathComponent(executableName)
        try retargetMachO(at: exeURL, mainExecutable: true)

        if let items = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil) {
            for item in items {
                let name = item.lastPathComponent
                if redirectedFrameworks.contains(where: { name == "\($0).framework" }) || name == "PearANGLE" {
                    continue
                }
                if name.hasSuffix(".framework") {
                    let fwBin = item.appendingPathComponent(String(name.dropLast(".framework".count)))
                    if fm.fileExists(atPath: fwBin.path) {
                        try? retargetMachO(at: fwBin)
                    }
                } else if name.hasSuffix(".dylib") {
                    try? retargetMachO(at: item)
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
        try Data("pearhost\n\(hostStamp(hostDir))\n".utf8).write(to: markerURL(in: bundleURL), options: .atomic)
    }

    /// Copies the PearHost frameworks (and PearANGLE) into <app>/Frameworks and signs them.
    private static func installHostFrameworks(into frameworksDir: URL, from hostDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        for fw in redirectedFrameworks {
            let src = hostDir.appendingPathComponent("\(fw).framework", isDirectory: true)
            let dst = frameworksDir.appendingPathComponent("\(fw).framework", isDirectory: true)
            if fm.fileExists(atPath: src.path) {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
        }
        let angleSrc = hostDir.appendingPathComponent("PearANGLE", isDirectory: true)
        let angleDst = frameworksDir.appendingPathComponent("PearANGLE", isDirectory: true)
        if fm.fileExists(atPath: angleSrc.path) {
            if fm.fileExists(atPath: angleDst.path) { try fm.removeItem(at: angleDst) }
            try fm.copyItem(at: angleSrc, to: angleDst)
        }
        for fw in redirectedFrameworks {
            let fwBin = frameworksDir.appendingPathComponent("\(fw).framework/\(fw)")
            if fm.fileExists(atPath: fwBin.path) {
                _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", fwBin.path])
            }
        }
    }

    private static func retargetMachO(at url: URL, mainExecutable: Bool = false) throws {
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
        for dep in dependencies(of: url) where dep.contains("libPearOpenGLES") {
            _ = runTool("/usr/bin/install_name_tool", ["-change", dep, "@rpath/OpenGLES.framework/OpenGLES", url.path])
        }
        for fw in redirectedFrameworks {
            let sysPath = "/System/Library/Frameworks/\(fw).framework/\(fw)"
            let rpath = "@rpath/\(fw).framework/\(fw)"
            _ = runTool("/usr/bin/install_name_tool", ["-change", sysPath, rpath, url.path])
        }
        _ = runTool("/usr/bin/install_name_tool", [
            "-change",
            "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            url.path,
        ])
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
