import CryptoKit
import Foundation

struct RemoteGraphicsAsset: Sendable {
    let tag: String
    let name: String
    let url: URL
    let sha256: String
}

/// Downloads optional graphics translation components. MoltenVK is bundled with
/// the Wine engine and needs no download. DXMT provides D3D10/11 → Metal.
/// KosmicKrisp is an arm64 Vulkan ICD and therefore cannot load into an x86_64
/// Wine process; installation is allowed, but launch refuses it on x86_64.
actor GraphicsComponentService {
    static let dxmtRepository = "3Shain/dxmt"
    static let kosmicRepository = "Anonymous137-sudo/Khronos_AppleICDs"
    static let maximumDownloadBytes: Int64 = 128 * 1_024 * 1_024

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let digest: String?
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case draft, prerelease, assets
            case tagName = "tag_name"
        }
    }

    func latestDXMT() async throws -> RemoteGraphicsAsset {
        try await latest(
            repository: Self.dxmtRepository,
            accepts: { $0.hasPrefix("dxmt-") && $0.hasSuffix("-builtin.tar.gz") },
            includePrereleases: false
        )
    }

    func latestKosmicKrisp() async throws -> RemoteGraphicsAsset {
        try await latest(
            repository: Self.kosmicRepository,
            accepts: { $0.hasSuffix(".pkg") && $0.contains("Preview") },
            includePrereleases: true
        )
    }

    private func latest(
        repository: String, accepts: (String) -> Bool, includePrereleases: Bool
    ) async throws -> RemoteGraphicsAsset {
        do {
            return try await latestFromAPI(
                repository: repository, accepts: accepts, includePrereleases: includePrereleases
            )
        } catch {
            return try await latestFromFeed(repository: repository, accepts: accepts)
        }
    }

    private func latestFromAPI(
        repository: String, accepts: (String) -> Bool, includePrereleases: Bool
    ) async throws -> RemoteGraphicsAsset {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WineReleaseError.network("GitHub API unavailable")
        }
        for release in try JSONDecoder().decode([Release].self, from: data)
        where !release.draft && (includePrereleases || !release.prerelease) {
            guard let asset = release.assets.first(where: { accepts($0.name) }),
                  asset.size > 0, asset.size <= Self.maximumDownloadBytes,
                  let hash = Self.hash(asset.digest) else { continue }
            return RemoteGraphicsAsset(
                tag: release.tagName, name: asset.name,
                url: asset.browserDownloadURL, sha256: hash
            )
        }
        throw WineReleaseError.notFound("No matching graphics component asset was found")
    }

    private func latestFromFeed(
        repository: String, accepts: (String) -> Bool
    ) async throws -> RemoteGraphicsAsset {
        var request = URLRequest(url: URL(string: "https://github.com/\(repository)/releases.atom")!)
        request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
        let (atomData, _) = try await URLSession.shared.data(for: request)
        let atom = String(decoding: atomData, as: UTF8.self)
        for tag in Self.releaseTags(inAtom: atom).prefix(20) {
            let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
            var assetRequest = URLRequest(
                url: URL(string: "https://github.com/\(repository)/releases/expanded_assets/\(escaped)")!
            )
            assetRequest.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
            guard let (htmlData, _) = try? await URLSession.shared.data(for: assetRequest) else { continue }
            let html = String(decoding: htmlData, as: UTF8.self)
            let names = Self.assetNames(inHTML: html)
            for name in names where accepts(name) {
                guard let hash = WineReleaseService.hash(for: name, inAssetsHTML: html) else { continue }
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                return RemoteGraphicsAsset(
                    tag: tag, name: name,
                    url: URL(string: "https://github.com/\(repository)/releases/download/\(escaped)/\(encoded)")!,
                    sha256: hash
                )
            }
        }
        throw WineReleaseError.notFound("No matching graphics component asset was found in the release feed")
    }

    /// Installs DXMT into `<engine>/Graphics/DXMT`. It is a per-engine overlay;
    /// WINEDLLPATH and per-game overrides select it without modifying Wine.
    func installDXMT(_ asset: RemoteGraphicsAsset, engineRoot: URL) async throws -> URL {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("dxmt.tar.gz")
        try await download(asset, to: archive)
        try Self.validateTar(archive, compressedWithGzip: true)
        let extracted = work.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", extracted.path, "--no-same-owner"])
        guard let windows = Self.findDirectory(named: "x86_64-windows", under: extracted),
              let unix = Self.findDirectory(named: "x86_64-unix", under: extracted),
              FileManager.default.fileExists(atPath: windows.appendingPathComponent("d3d11.dll").path),
              FileManager.default.fileExists(atPath: windows.appendingPathComponent("winemetal.dll").path),
              FileManager.default.fileExists(atPath: unix.appendingPathComponent("winemetal.so").path) else {
            throw WineReleaseError.invalid("DXMT archive does not contain x86_64 Windows/Unix components")
        }
        let destination = engineRoot.appendingPathComponent("Graphics/DXMT", isDirectory: true)
        return try Self.replace(destination) { staging in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: windows, to: staging.appendingPathComponent("x86_64-windows")
            )
            try FileManager.default.copyItem(
                at: unix, to: staging.appendingPathComponent("x86_64-unix")
            )
        }
    }

    /// Installs the arm64 KosmicKrisp ICD (driver + loader manifest). The game
    /// will refuse this backend on an x86_64 Wine engine.
    func installKosmicKrisp(_ asset: RemoteGraphicsAsset, engineRoot: URL) async throws -> URL {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let package = work.appendingPathComponent("kosmickrisp.pkg")
        try await download(asset, to: package)
        let expanded = work.appendingPathComponent("Expanded", isDirectory: true)
        _ = try Shell.run("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path])
        guard let avk = Self.findDirectory(named: "avk143", under: expanded),
              let icdDirectory = Self.findDirectory(named: "icd.d", under: expanded),
              let icd = try? FileManager.default.contentsOfDirectory(at: icdDirectory, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "json" }),
              FileManager.default.fileExists(atPath: avk.appendingPathComponent("libvulkan_kosmickrisp.dylib").path) else {
            throw WineReleaseError.invalid("KosmicKrisp package does not contain the expected ICD payload")
        }
        let archs = (try? Shell.run("/usr/bin/lipo", ["-archs", avk.appendingPathComponent("libvulkan_kosmickrisp.dylib").path])) ?? ""
        guard archs.split(whereSeparator: \.isWhitespace).contains("arm64") else {
            throw WineReleaseError.invalid("KosmicKrisp driver is not an arm64 build")
        }
        let destination = engineRoot.appendingPathComponent("Graphics/KosmicKrisp", isDirectory: true)
        return try Self.replace(destination) { staging in
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent("lib", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent("share/vulkan/icd.d", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: avk, to: staging.appendingPathComponent("lib/avk143"))
            try FileManager.default.copyItem(
                at: icd, to: staging.appendingPathComponent("share/vulkan/icd.d/\(icd.lastPathComponent)")
            )
        }
    }

    // MARK: - Download and archives

    private func download(_ asset: RemoteGraphicsAsset, to destination: URL) async throws {
        var request = URLRequest(url: asset.url)
        request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let host = http.url?.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".githubusercontent.com") else {
            throw WineReleaseError.network("Graphics component download did not come from GitHub")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= Self.maximumDownloadBytes else {
            throw WineReleaseError.invalid("Graphics component download is empty or too large")
        }
        guard try WineReleaseService.sha256(of: temporary) == asset.sha256.lowercased() else {
            throw WineReleaseError.invalid("Graphics component SHA-256 mismatch; download discarded")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearSilicon-Graphics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func hash(_ digest: String?) -> String? {
        guard let digest = WineReleaseService.normalizedHash(digest ?? "") else { return nil }
        return digest
    }

    private static func assetNames(inHTML html: String) -> [String] {
        var names: [String] = []
        var cursor = html.startIndex
        while let range = html.range(of: "/releases/download/", range: cursor..<html.endIndex) {
            guard let quote = html[range.upperBound...].firstIndex(of: "\"") else { break }
            let path = html[range.upperBound..<quote]
            if let name = path.split(separator: "/").last, !names.contains(String(name)) {
                names.append(String(name))
            }
            cursor = quote
        }
        return names
    }

    /// Atom entry titles are human-readable ("Version 0.80"), while expanded
    /// asset URLs need the tag ("v0.80"). Extract the tag from the alternate
    /// link instead of assuming the title is the tag.
    static func releaseTags(inAtom atom: String) -> [String] {
        var tags: [String] = []
        var cursor = atom.startIndex
        while let range = atom.range(of: "/releases/tag/", range: cursor..<atom.endIndex) {
            guard let quote = atom[range.upperBound...].firstIndex(of: "\"") else { break }
            let tag = String(atom[range.upperBound..<quote])
            if !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
            cursor = quote
        }
        return tags
    }

    private static func findDirectory(named name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == name,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return url
            }
        }
        return nil
    }

    private static func validateTar(_ archive: URL, compressedWithGzip: Bool) throws {
        let flag = compressedWithGzip ? "-tzf" : "-tJf"
        let verboseFlag = compressedWithGzip ? "-tvzf" : "-tvJf"
        let names = try Shell.run("/usr/bin/tar", [flag, archive.path])
        for line in names.split(separator: "\n", omittingEmptySubsequences: true) {
            let name = String(line)
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            let meaningful = components.last == "" ? components.dropLast() : components
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !meaningful.contains(".."), !meaningful.contains("") else {
                throw WineReleaseError.invalid("Graphics archive contains an unsafe path")
            }
        }
        let verbose = try Shell.run("/usr/bin/tar", [verboseFlag, archive.path])
        for line in verbose.split(separator: "\n") {
            guard let first = line.first else { continue }
            if "bcps".contains(first) {
                throw WineReleaseError.invalid("Graphics archive contains a special file")
            }
            if first == "l" || first == "h",
               let range = line.range(of: first == "l" ? " -> " : " link to ") {
                let target = String(line[range.upperBound...])
                guard !target.hasPrefix("/"), !target.contains(".."), !target.contains("\\") else {
                    throw WineReleaseError.invalid("Graphics archive contains an escaping link")
                }
            }
        }
    }

    private static func replace(_ destination: URL, build: (URL) throws -> Void) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        var movedOld: URL?
        do {
            try build(staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                movedOld = parent.appendingPathComponent(".old-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: destination, to: movedOld!)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            if let movedOld { try? FileManager.default.removeItem(at: movedOld) }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if let movedOld, !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.moveItem(at: movedOld, to: destination)
            }
            throw error
        }
    }
}
