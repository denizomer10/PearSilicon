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

        // Copy PearHost frameworks into <app>/Frameworks.
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

        // Retarget executable + app-bundled frameworks to macOS platform.
        let exeURL = bundleURL.appendingPathComponent(executableName)
        try retargetMachO(at: exeURL)

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

        // Ad-hoc sign all PearHost frameworks.
        for fw in redirectedFrameworks {
            let fwBin = frameworksDir.appendingPathComponent("\(fw).framework/\(fw)")
            if fm.fileExists(atPath: fwBin.path) {
                _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", fwBin.path])
            }
        }

        try Data("pearhost\n".utf8).write(to: markerURL(in: bundleURL), options: .atomic)
    }

    private static func retargetMachO(at url: URL) throws {
        _ = try BinaryPatcher.patchFile(at: url, targetPlatform: BinaryPatcher.Platform.macOS)
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
        _ = runTool("/usr/bin/install_name_tool", ["-add_rpath", "/usr/lib/swift", url.path])
        _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", url.path])
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
