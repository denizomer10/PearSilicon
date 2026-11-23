import CryptoKit
import Darwin
import Foundation

/// Prepares an installed ARM64 iOS `.app` bundle to run on PearHost (native macOS
/// platform, zero `/System/iOSSupport`) using `runtime/build/host` frameworks.
enum PearHostPreparer {
    static let markerFileName = ".pearsilicon-pearhost"
    /// Libraries PearHost builds next to its frameworks and installs into
    /// every prepared bundle (macOS builds replacing the app's Catalyst ones).
    private static let hostLibraries = ["libcxxcompat.dylib", "libswiftUIKit.dylib", "libPearHostPlaceholder.dylib"]

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        var error: Error?
        func setIfEmpty(_ err: Error) {
            lock.lock()
            if error == nil { error = err }
            lock.unlock()
        }
    }

    private struct MachOLoadInfo {
        let dependencies: [String]
        let rpaths: [String]
        let hasCodeSignature: Bool
    }

    /// Runs `body` in parallel across Apple silicon cores. Throws the first error encountered.
    private static func parallelForEach<T: Sendable>(_ items: [T], _ body: @Sendable (T) throws -> Void) throws {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            try body(items[0])
            return
        }
        let box = ErrorBox()
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            do {
                try body(items[index])
            } catch {
                box.setIfEmpty(error)
            }
        }
        if let err = box.error { throw err }
    }

    private static func cloneOrCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        if Darwin.clonefile(src.path, dst.path, 0) == 0 {
            return
        }
        try fm.copyItem(at: src, to: dst)
    }

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
    static let preparerVersion = 4

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

    static func prepare(
        bundleURL: URL, executableName: String, hostDir: URL, runtime: RuntimeSnapshot? = nil
    ) throws {
        guard let runtime = runtime ?? runtimeSnapshot(hostDir) else {
            throw PearError.missingRuntimeComponent("PearHost frameworks")
        }
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

        // Retarget executable + app-bundled frameworks to macOS platform in parallel.
        let host = hostFrameworks(in: hostDir)
        let exeURL = bundleURL.appendingPathComponent(executableName)
        try retargetMachO(at: exeURL, hostFrameworks: host, mainExecutable: true)

        if let items = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil) {
            var targets: [URL] = []
            for item in items {
                let name = item.lastPathComponent
                if host.contains(where: { name == "\($0).framework" }) || name == "PearANGLE" || hostLibraries.contains(name) {
                    continue
                }
                if name.hasSuffix(".framework") {
                    let fwBin = item.appendingPathComponent(String(name.dropLast(".framework".count)))
                    if fm.fileExists(atPath: fwBin.path) {
                        targets.append(fwBin)
                    }
                } else if name.hasSuffix(".dylib") {
                    targets.append(item)
                }
            }
            try parallelForEach(targets) { url in
                try? retargetMachO(at: url, hostFrameworks: host)
            }
        }

        try runtime.writeMarker(in: bundleURL)
    }

    struct RuntimeSnapshot: Sendable {
        let stamp: String
        let components: [String: Component]

        struct Component: Sendable {
            let revision: String
            let binaries: [String]
        }

        func changedComponents(in bundleURL: URL) -> [String] {
            let recorded = (try? String(contentsOf: markerURL(in: bundleURL), encoding: .utf8)) ?? ""
            let lines = Set(recorded.split(separator: "\n").map(String.init))
            let sameBuild = lines.contains(stamp)
            let frameworks = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
            return components.keys.sorted().filter { name in
                guard let component = components[name] else { return false }
                return !(sameBuild || lines.contains(componentLine(name, component)))
                    || !component.binaries.allSatisfy {
                        FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
                    }
            }
        }

        func writeMarker(in bundleURL: URL) throws {
            let entries = components.sorted { $0.key < $1.key }.map { componentLine($0.key, $0.value) }
            let marker = ["pearhost", stamp, "preparer=\(preparerVersion)"] + entries
            try Data((marker.joined(separator: "\n") + "\n").utf8)
                .write(to: markerURL(in: bundleURL), options: .atomic)
        }

        private func componentLine(_ name: String, _ component: Component) -> String {
            "component=\(name):\(component.revision)"
        }
    }

    /// Tracks bundled host images, including independently rebuilt overlays and ANGLE.
    static func runtimeSnapshot(_ hostDir: URL) -> RuntimeSnapshot? {
        let files = hostBinaryPaths(hostDir)
        guard files.contains("UIKit.framework/UIKit") else { return nil }
        var entries: [String] = []
        var grouped: [String: [(path: String, entry: String)]] = [:]
        for file in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: hostDir.appendingPathComponent(file).path),
                  let size = attrs[.size] as? NSNumber,
                  let date = attrs[.modificationDate] as? Date else { return nil }
            let entry = "\(file):\(size.int64Value):\(date.timeIntervalSince1970)"
            entries.append(entry)
            let component = file.split(separator: "/", maxSplits: 1).first.map(String.init) ?? file
            grouped[component, default: []].append((file, entry))
        }
        func hash(_ entries: [String]) -> String {
            String(describing: SHA256.hash(data: Data(entries.joined(separator: "\n").utf8)))
        }
        return RuntimeSnapshot(stamp: "host=\(hash(entries))", components: grouped.mapValues {
            RuntimeSnapshot.Component(revision: hash($0.map(\.entry)), binaries: $0.map(\.path))
        })
    }

    @discardableResult
    static func refreshHostFrameworksIfStale(bundleURL: URL, hostDir: URL) throws -> Bool {
        guard let runtime = runtimeSnapshot(hostDir) else { return false }
        let components = runtime.changedComponents(in: bundleURL)
        guard !components.isEmpty else { return false }
        try refreshHostFrameworks(bundleURL: bundleURL, hostDir: hostDir, runtime: runtime, components: components)
        return true
    }

    static func refreshHostFrameworks(
        bundleURL: URL, hostDir: URL, runtime: RuntimeSnapshot, components: [String]
    ) throws {
        let frameworksDir = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try installHostFrameworks(into: frameworksDir, from: hostDir, components: components)
        try runtime.writeMarker(in: bundleURL)
    }

    static func hostFrameworksAreCurrent(bundleURL: URL, hostDir: URL) -> Bool {
        guard let runtime = runtimeSnapshot(hostDir) else { return false }
        return runtime.changedComponents(in: bundleURL).isEmpty
    }

    private static func hostBinaryPaths(_ hostDir: URL) -> [String] {
        let angle = hostDir.appendingPathComponent("PearANGLE", isDirectory: true)
        let angleLibraries = ((try? FileManager.default.contentsOfDirectory(atPath: angle.path)) ?? [])
            .filter { $0.hasSuffix(".dylib") }.map { "PearANGLE/\($0)" }
        return (hostFrameworks(in: hostDir).map { "\($0).framework/\($0)" } + hostLibraries + angleLibraries)
            .filter { FileManager.default.fileExists(atPath: hostDir.appendingPathComponent($0).path) }
            .sorted()
    }

    static func hostStamp(_ hostDir: URL) -> String {
        runtimeSnapshot(hostDir)?.stamp ?? ""
    }

    /// Clones/copies PearHost frameworks, PearANGLE and PearHost's libraries into
    /// `<app>/Frameworks`. Preserves ad-hoc signatures from `hostDir` via `clonefile`/`copyItem`
    /// and only signs or retargets items that are unsigned or non-macOS.
    private static func installHostFrameworks(into frameworksDir: URL, from hostDir: URL, components: [String]? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        let host = hostFrameworks(in: hostDir)
        let items = components ?? (host.map { "\($0).framework" } + ["PearANGLE"] + hostLibraries)
        let existingItems = items.filter { fm.fileExists(atPath: hostDir.appendingPathComponent($0).path) }
        try parallelForEach(existingItems) { item in
            let src = hostDir.appendingPathComponent(item)
            let dst = frameworksDir.appendingPathComponent(item)
            try cloneOrCopy(from: src, to: dst)
        }

        // Retarget libswiftUIKit.dylib only if not already macOS-platform.
        let overlay = frameworksDir.appendingPathComponent("libswiftUIKit.dylib")
        if existingItems.contains("libswiftUIKit.dylib"), fm.fileExists(atPath: overlay.path),
           (try? BinaryPatcher.buildPlatform(at: overlay)) != BinaryPatcher.Platform.macOS {
            try retargetMachO(at: overlay, hostFrameworks: host)
        }

        // Only sign copied host Mach-O images if an un-signed build tree was used.
        var unsigned: [URL] = []
        for fw in host where existingItems.contains("\(fw).framework") {
            let fwBin = frameworksDir.appendingPathComponent("\(fw).framework/\(fw)")
            if fm.fileExists(atPath: fwBin.path),
               let info = readMachOLoadInfo(at: fwBin), !info.hasCodeSignature {
                unsigned.append(fwBin)
            }
        }
        let cxx = frameworksDir.appendingPathComponent("libcxxcompat.dylib")
        if existingItems.contains("libcxxcompat.dylib"), fm.fileExists(atPath: cxx.path),
           let info = readMachOLoadInfo(at: cxx), !info.hasCodeSignature {
            unsigned.append(cxx)
        }
        try parallelForEach(unsigned) { bin in
            _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", bin.path])
        }
    }

    private static func retargetMachO(at url: URL, hostFrameworks host: [String], mainExecutable: Bool = false) throws {
        // A bundle prepared earlier can name CoreServices twice (an older
        // PearHost preparation mapped MobileCoreServices to it); dyld refuses that.
        let deduped = try dedupeDylibs(at: url)
        var removedRuntime = false
        // Undo a Catalyst preparation of the same bundle (while the image is
        // still iOS/Catalyst, which is what BinaryPatcher edits): its runtime
        // dylib is removed above, and its load command is the last one
        // PackageInstaller appended, so dropping it keeps every bind ordinal.
        if BinaryPatcher.hasLoadDylib(at: url, containing: "libPearRuntime") {
            removedRuntime = try BinaryPatcher.removeLoadDylib(at: url, containing: "libPearRuntime")
        }
        let platformPatched = try BinaryPatcher.patchFile(at: url, targetPlatform: BinaryPatcher.Platform.macOS)

        let info = readMachOLoadInfo(at: url)
        let deps = info?.dependencies ?? dependencies(of: url)
        let currentRpaths = info?.rpaths ?? rpaths(of: url)
        var installNameArgs: [String] = []

        // OpenGLES dependencies pointed at the Catalyst ANGLE shim go to
        // PearHost's OpenGLES.framework.
        let iosSupport = "/System/iOSSupport/System/Library/Frameworks/"
        for dep in deps {
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
                installNameArgs.append(contentsOf: ["-change", dep, target])
            }
        }
        if !currentRpaths.contains("/usr/lib/swift") {
            installNameArgs.append(contentsOf: ["-add_rpath", "/usr/lib/swift"])
        }
        // Older preparations embedded their original installation path.
        // After a disk switch or copy that path can still exist, so dyld can
        // pick an older runtime before reaching the bundle's relative path.
        for path in Set(currentRpaths).sorted() where path.hasPrefix("/") {
            let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            if components.count >= 2, components.last == "Frameworks",
               components[components.count - 2].hasSuffix(".app") {
                installNameArgs.append(contentsOf: ["-delete_rpath", path])
            }
        }
        // PearHost frameworks are reached through @rpath; apps built without
        // embedded frameworks (older titles) carry no such rpath.
        if mainExecutable && !currentRpaths.contains("@executable_path/Frameworks") {
            installNameArgs.append(contentsOf: ["-add_rpath", "@executable_path/Frameworks"])
        }

        if !installNameArgs.isEmpty {
            guard runTool("/usr/bin/install_name_tool", installNameArgs + [url.path]) == 0 else {
                throw PearError.invalidPackage("Could not update library paths in \(url.lastPathComponent)")
            }
        }

        // dyld gathers interposers at launch. Games that dlopen UnityFramework
        // may load UIKit too late for its app-local Keychain implementation.
        var addedUIKit = false
        let uikit = "@rpath/UIKit.framework/UIKit"
        if mainExecutable, host.contains("UIKit"), !BinaryPatcher.hasLoadDylib(at: url, containing: uikit) {
            addedUIKit = try BinaryPatcher.addLoadDylib(at: url, path: uikit, allowMacOS: true)
        }

        let modified = deduped || removedRuntime || platformPatched || !installNameArgs.isEmpty || addedUIKit
        if modified || info?.hasCodeSignature == false {
            _ = runTool("/usr/bin/codesign", ["-f", "-s", "-", url.path])
        }
    }

    /// Reads thin 64-bit Mach-O load commands (`LC_LOAD_*`, `LC_RPATH`, `LC_CODE_SIGNATURE`)
    /// directly in memory, avoiding `otool` subprocess overhead. Returns `nil` for non-thin-64 images.
    private static func readMachOLoadInfo(at url: URL) -> MachOLoadInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 32), header.count == 32 else { return nil }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard u32(header, 0) == 0xFEED_FACF else { return nil }
        let ncmds = Int(u32(header, 16))
        let sizeofcmds = Int(u32(header, 20))
        guard ncmds >= 0, sizeofcmds > 0, sizeofcmds <= 4 * 1024 * 1024 else {
            return MachOLoadInfo(dependencies: [], rpaths: [], hasCodeSignature: false)
        }
        guard let cmds = try? handle.read(upToCount: sizeofcmds), cmds.count == sizeofcmds else { return nil }

        let dylibCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]
        var deps: [String] = []
        var rpaths: [String] = []
        var hasSig = false
        var offset = 0

        for _ in 0..<ncmds {
            guard offset + 8 <= cmds.count else { break }
            let cmd = u32(cmds, offset)
            let size = Int(u32(cmds, offset + 4))
            guard size >= 8, offset + size <= cmds.count else { break }

            if dylibCommands.contains(cmd), size >= 12 {
                let strOffset = Int(u32(cmds, offset + 8))
                if strOffset >= 12, strOffset < size {
                    let start = offset + strOffset
                    let end = cmds[start..<(offset + size)].firstIndex(of: 0) ?? (offset + size)
                    deps.append(String(decoding: cmds[start..<end], as: UTF8.self))
                }
            } else if cmd == 0x8000_001C, size >= 12 { // LC_RPATH
                let strOffset = Int(u32(cmds, offset + 8))
                if strOffset >= 12, strOffset < size {
                    let start = offset + strOffset
                    let end = cmds[start..<(offset + size)].firstIndex(of: 0) ?? (offset + size)
                    rpaths.append(String(decoding: cmds[start..<end], as: UTF8.self))
                }
            } else if cmd == 0x1D { // LC_CODE_SIGNATURE
                hasSig = true
            }
            offset += size
        }
        return MachOLoadInfo(dependencies: deps, rpaths: rpaths, hasCodeSignature: hasSig)
    }

    /// Points the later of two load commands naming the same dylib at a
    /// PearHost framework re-exporting that library, in place (both keep their
    /// ordinals, so every import still binds).
    @discardableResult
    static func dedupeDylibs(at url: URL) throws -> Bool {
        let replacements = [
            "/System/Library/Frameworks/CoreServices.framework/CoreServices":
                "@rpath/MobileCoreServices.framework/MobileCoreServices",
        ]
        var data = try Data(contentsOf: url)
        guard data.count > 32 else { return false }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard u32(0) == 0xFEED_FACF else { return false }  // thin 64-bit images only
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
        return changed
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
