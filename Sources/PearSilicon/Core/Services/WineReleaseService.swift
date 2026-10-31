import CryptoKit
import Darwin
import Foundation

enum WineReleaseChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case stable
    case staging
    case devel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stable: "WineHQ Stable"
        case .staging: "WineHQ Staging"
        case .devel: "WineHQ Development"
        }
    }
    fileprivate var assetPrefix: String {
        switch self {
        case .stable: "wine-stable-"
        case .staging: "wine-staging-"
        case .devel: "wine-devel-"
        }
    }
}

struct WineReleaseCheck: Sendable {
    let channel: WineReleaseChannel
    let tag: String
    let releaseName: String
    let assetName: String
    let assetURL: URL
    let sha256: String
    let size: Int64
    let releasePage: URL?
}

/// Checks verified open-source WineHQ builds published for macOS and installs
/// them as self-contained engines. Downloads happen only after an explicit user
/// action. The GitHub SHA-256 authenticates the bytes, not the publisher.
actor WineReleaseService {
    static let repository = "Gcenx/macOS_Wine_builds"
    static let maximumDownloadBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumExtractedBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumEntries = 150_000

    private struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
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
        let name: String?
        let draft: Bool
        let prerelease: Bool
        let htmlURL: URL?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case name, draft, prerelease, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private struct Transport: Sendable {
        var listReleases: @Sendable (URL) async throws -> Data
        var download: @Sendable (URL, URL) async throws -> URLResponse
        var expandedAssets: @Sendable (URL) async throws -> String

        static let live = Transport(
            listReleases: { url in
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw WineReleaseError.network("No HTTP response from GitHub") }
                guard http.statusCode == 200 else {
                    if http.statusCode == 403 {
                        throw WineReleaseError.network("GitHub API rate limit reached. Try again later or register a local open-source Wine build in Settings.")
                    }
                    throw WineReleaseError.network("GitHub returned HTTP \(http.statusCode)")
                }
                return data
            },
            download: { url, destination in
                var request = URLRequest(url: url)
                request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw WineReleaseError.network("The Wine download did not return HTTP 200")
                }
                guard let finalHost = http.url?.host?.lowercased(),
                      finalHost == "github.com" || finalHost.hasSuffix(".githubusercontent.com") else {
                    throw WineReleaseError.network("The Wine download redirected outside GitHub")
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                return http
            },
            expandedAssets: { url in
                var request = URLRequest(url: url)
                request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw WineReleaseError.network("Could not read GitHub's release asset list")
                }
                return String(decoding: data, as: UTF8.self)
            }
        )
    }

    private let transport: Transport

    init() {
        transport = .live
    }

    init(listReleases: @escaping @Sendable (URL) async throws -> Data,
         download: @escaping @Sendable (URL, URL) async throws -> URLResponse) {
        var live = Transport.live
        live.listReleases = listReleases
        live.download = download
        transport = live
    }

    /// Looks through recent releases for the newest asset matching the selected
    /// open-source WineHQ channel. Stable releases are less frequent than devel,
    /// so this cannot assume the newest release contains every channel.
    func latest(channel: WineReleaseChannel) async throws -> WineReleaseCheck {
        do {
            return try await latestFromAPI(channel: channel)
        } catch {
            // The unauthenticated GitHub API is limited to 60 requests/hour per
            // address. A shared connection can exhaust that without the user
            // doing anything wrong, so fall back to the public Atom feed and the
            // asset page, which publish the same tag and SHA-256.
            return try await latestFromAtom(channel: channel)
        }
    }

    private func latestFromAPI(channel: WineReleaseChannel) async throws -> WineReleaseCheck {
        var url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=30")!
        for page in 0..<3 {
            let data = try await transport.listReleases(url)
            let releases = try JSONDecoder().decode([Release].self, from: data)
            for release in releases where !release.draft && !release.prerelease {
                guard let asset = release.assets.first(where: {
                    $0.name.hasPrefix(channel.assetPrefix) && $0.name.hasSuffix("-osx64.tar.xz")
                }) else { continue }
                guard asset.size > 0, asset.size <= Self.maximumDownloadBytes else {
                    throw WineReleaseError.invalid("The selected Wine asset has an unsupported size")
                }
                let hash = try await digest(for: asset, tag: release.tagName)
                return WineReleaseCheck(
                    channel: channel, tag: release.tagName,
                    releaseName: release.name ?? release.tagName,
                    assetName: asset.name, assetURL: asset.browserDownloadURL,
                    sha256: hash, size: asset.size, releasePage: release.htmlURL
                )
            }
            if page == 2 { break }
            url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=30&page=\(page + 2)")!
        }
        throw WineReleaseError.notFound(
            "No verified \(channel.title) macOS build was found in recent releases. Try another channel or register a local engine."
        )
    }

    private func latestFromAtom(channel: WineReleaseChannel) async throws -> WineReleaseCheck {
        let atom = try await transport.expandedAssets(
            URL(string: "https://github.com/\(Self.repository)/releases.atom")!
        )
        let tags = Self.tags(inAtom: atom)
        guard !tags.isEmpty else {
            throw WineReleaseError.network("GitHub's release feed is unavailable")
        }
        for tag in tags.prefix(15) {
            let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
            let page = try await transport.expandedAssets(
                URL(string: "https://github.com/\(Self.repository)/releases/expanded_assets/\(escaped)")!
            )
            guard let assetName = Self.assetName(channel: channel, inAssetsHTML: page),
                  let hash = Self.hash(for: assetName, inAssetsHTML: page) else { continue }
            let encodedName = assetName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetName
            let url = URL(string: "https://github.com/\(Self.repository)/releases/download/\(escaped)/\(encodedName)")!
            return WineReleaseCheck(
                channel: channel, tag: tag, releaseName: tag,
                assetName: assetName, assetURL: url, sha256: hash, size: 0,
                releasePage: URL(string: "https://github.com/\(Self.repository)/releases/tag/\(escaped)")
            )
        }
        throw WineReleaseError.notFound(
            "No verified \(channel.title) macOS build was found in the release feed."
        )
    }

    static func tags(inAtom atom: String) -> [String] {
        var tags: [String] = []
        var cursor = atom.startIndex
        while let linkStart = atom.range(of: "<entry>", range: cursor..<atom.endIndex) {
            guard let linkEnd = atom.range(of: "</entry>", range: linkStart.upperBound..<atom.endIndex) else { break }
            let entry = atom[linkStart.upperBound..<linkEnd.lowerBound]
            if let titleStart = entry.range(of: "<title>"),
               let titleEnd = entry.range(of: "</title>", range: titleStart.upperBound..<entry.endIndex) {
                let title = entry[titleStart.upperBound..<titleEnd.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, !tags.contains(title) { tags.append(title) }
            }
            cursor = linkEnd.upperBound
        }
        return tags
    }

    static func assetName(channel: WineReleaseChannel, inAssetsHTML html: String) -> String? {
        var cursor = html.startIndex
        while let range = html.range(of: channel.assetPrefix, range: cursor..<html.endIndex) {
            let tail = html[range.lowerBound...].prefix(160)
            if let suffix = tail.range(of: "-osx64.tar.xz") {
                let name = String(tail[..<suffix.upperBound])
                let valid = name.allSatisfy {
                    $0.isLetter || $0.isNumber || [".", "-", "_"].contains($0)
                }
                if valid, name.hasPrefix(channel.assetPrefix) { return name }
            }
            cursor = range.upperBound
        }
        return nil
    }

    static func hash(for assetName: String, inAssetsHTML html: String) -> String? {
        guard let nameRange = html.range(of: assetName),
              let hashRange = html.range(of: "sha256:", range: nameRange.upperBound..<html.endIndex) else {
            return nil
        }
        let hex = html[hashRange.upperBound...].prefix(80).prefix { $0.isHexDigit }
        guard hex.count == 64 else { return nil }
        return String(hex).lowercased()
    }

    /// Downloads, hashes, safely extracts and installs the selected engine.
    /// The archive is removed after a successful install.
    func install(
        _ check: WineReleaseCheck, store: WineEngineStore,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> WineEngine {
        let root = try ManagedAppFiles.canonicalRoot(store.rootURL)
        let madeRoot = !ManagedAppFiles.exists(root)
        if madeRoot { try ManagedAppFiles.makeDirectory(root) }
        let staging = root.appendingPathComponent(".wine-download-\(UUID().uuidString)", isDirectory: true)
        var keepStaging = false
        defer {
            if !keepStaging { try? FileManager.default.removeItem(at: staging) }
            if madeRoot { _ = rmdir(root.path) }
        }
        try ManagedAppFiles.makeDirectory(staging)
        let archive = staging.appendingPathComponent("wine.tar.xz")
        progress("Downloading \(check.assetName)…")
        try await transport.download(check.assetURL, archive)
        try Task.checkCancellation()
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= Self.maximumDownloadBytes else {
            throw WineReleaseError.invalid("The downloaded Wine archive is empty or too large")
        }
        progress("Verifying SHA-256…")
        guard try WineReleaseService.sha256(of: archive) == check.sha256.lowercased() else {
            throw WineReleaseError.invalid("Wine archive SHA-256 mismatch; the download was discarded")
        }
        progress("Checking archive paths…")
        try Self.validateTarListing(archive)
        let extracted = staging.appendingPathComponent("Extracted", isDirectory: true)
        try ManagedAppFiles.makeDirectory(extracted)
        progress("Extracting Wine…")
        _ = try Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", extracted.path, "--no-same-owner"])
        try Self.validateExtractedTree(extracted)
        let found = try Self.findWineExecutable(in: extracted)
        let engineID = Self.engineID(channel: check.channel, tag: check.tag)
        progress("Installing \(found.relativeExecutable)…")
        let engine = try store.installDownloadedEngine(
            extractedRoot: found.root, id: engineID,
            name: "Wine \(check.channel.title.replacingOccurrences(of: "WineHQ ", with: ""))",
            version: check.tag, executablePath: found.relativeExecutable,
            distribution: .wineHQ
        )
        keepStaging = false
        progress("Installed \(engine.name) \(engine.version)")
        return engine
    }

    // MARK: - Asset selection

    private func digest(for asset: Release.Asset, tag: String) async throws -> String {
        if let digest = asset.digest, let hash = Self.normalizedHash(digest) { return hash }
        // Older releases may omit the API digest. The HTML asset list publishes
        // the same SHA-256 next to the file; require it rather than skipping
        // verification.
        let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let url = URL(string: "https://github.com/\(Self.repository)/releases/expanded_assets/\(escaped)")!
        let html = try await transport.expandedAssets(url)
        guard let nameRange = html.range(of: asset.name),
              let hashRange = html.range(of: "sha256:", range: nameRange.upperBound..<html.endIndex) else {
            throw WineReleaseError.invalid("GitHub did not publish a SHA-256 for \(asset.name)")
        }
        let tail = html[hashRange.upperBound...].prefix(80)
        let hex = tail.prefix { $0.isHexDigit }
        guard hex.count == 64 else {
            throw WineReleaseError.invalid("GitHub's SHA-256 for \(asset.name) is malformed")
        }
        return String(hex).lowercased()
    }

    static func normalizedHash(_ value: String) -> String? {
        var value = value.lowercased()
        if value.hasPrefix("sha256:") { value.removeFirst(7) }
        return value.count == 64 && value.allSatisfy(\.isHexDigit) ? value : nil
    }

    static func engineID(channel: WineReleaseChannel, tag: String) -> String {
        let safeTag = tag.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "wine-\(channel.rawValue)-\(String(safeTag))"
    }

    static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Archive admission

    private static func validateTarListing(_ archive: URL) throws {
        let names = try Shell.run("/usr/bin/tar", ["-tJf", archive.path])
        var count = 0
        for line in names.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.isEmpty else { continue }
            count += 1
            guard count <= maximumEntries else {
                throw WineReleaseError.invalid("The Wine archive contains too many entries")
            }
            try validateEntryName(String(line))
        }
        let verbose = try Shell.run("/usr/bin/tar", ["-tvJf", archive.path])
        for line in verbose.split(separator: "\n") {
            // mode links owner group size month day time name…
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count >= 9, let first = fields[0].first else { continue }
            if "bcps".contains(first) {
                throw WineReleaseError.invalid("The Wine archive contains a device or special file")
            }
            let rest = String(fields[8])
            if first == "l", let range = rest.range(of: " -> ", options: .backwards) {
                let entry = String(rest[..<range.lowerBound])
                let target = String(rest[range.upperBound...])
                try validateEntryName(entry)
                try validateSymlink(entry: entry, target: target)
            } else if first == "h", let range = rest.range(of: " link to ", options: .backwards) {
                let entry = String(rest[..<range.lowerBound])
                let target = String(rest[range.upperBound...])
                try validateEntryName(entry)
                try validateLinkTarget(target)
            }
        }
    }

    private static func validateEntryName(_ name: String) throws {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        // Directory entries commonly end in "/". Ignore only that trailing empty
        // component; empty components elsewhere are ambiguous and rejected.
        let meaningful = components.last == "" ? components.dropLast() : components
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"),
              !name.contains("\\"), !name.contains("\0"),
              !meaningful.contains(".."), !meaningful.contains("") else {
            throw WineReleaseError.invalid("The Wine archive contains an unsafe path: \(name)")
        }
    }

    private static func validateLinkTarget(_ target: String) throws {
        guard !target.hasPrefix("/"), !target.hasPrefix("~"), !target.contains("\\"),
              !target.contains("\0"),
              !target.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw WineReleaseError.invalid("The Wine archive contains a link that escapes its directory")
        }
    }

    /// Resolves a relative symlink against the entry's directory and rejects a
    /// target that climbs above the extraction root. Internal `../gac/...` links
    /// are normal in Wine's Mono tree and are allowed.
    private static func validateSymlink(entry: String, target: String) throws {
        guard !target.hasPrefix("/"), !target.hasPrefix("~"), !target.contains("\\"),
              !target.contains("\0") else {
            throw WineReleaseError.invalid("The Wine archive contains an absolute or unsafe link")
        }
        var stack = entry.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        guard !stack.isEmpty else {
            throw WineReleaseError.invalid("The Wine archive contains a link with no parent directory")
        }
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !stack.isEmpty else {
                    throw WineReleaseError.invalid("The Wine archive contains a link that escapes the archive")
                }
                stack.removeLast()
            } else {
                stack.append(component)
            }
        }
        guard !stack.isEmpty else {
            throw WineReleaseError.invalid("The Wine archive contains a link that escapes the archive")
        }
    }

    private static func validateExtractedTree(_ root: URL) throws {
        var count = 0
        var bytes: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            count += 1
            guard count <= maximumEntries else {
                throw WineReleaseError.invalid("The Wine archive exceeded the entry limit after extraction")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let relative = String(url.path.dropFirst(root.path.count + 1))
                try validateSymlink(entry: relative, target: target)
                guard LibraryPath.isInside(url, root: root) else {
                    throw WineReleaseError.invalid("The Wine archive contains an external symbolic link")
                }
            }
            if values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
                guard bytes <= maximumExtractedBytes else {
                    throw WineReleaseError.invalid("The extracted Wine runtime is too large")
                }
            }
        }
    }

    /// Finds the shallowest native `wine64`/`wine` executable and derives the
    /// runtime root that contains `bin`, `lib` and `share`.
    static func findWineExecutable(in extracted: URL) throws -> (root: URL, relativeExecutable: String) {
        guard let enumerator = FileManager.default.enumerator(
            at: extracted, includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WineReleaseError.invalid("Could not inspect the extracted Wine runtime")
        }
        var best: (url: URL, depth: Int)?
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maximumEntries { break }
            guard ["wine64", "wine"].contains(url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            guard values?.isRegularFile == true, values?.isExecutable == true else { continue }
            guard (try? ManagedExecutable.validateMacOS(url)) != nil else { continue }
            let depth = url.pathComponents.count
            if best == nil || depth < best!.depth {
                best = (url, depth)
            }
        }
        guard let executable = best?.url else {
            throw WineReleaseError.invalid("The archive contains no native Wine executable")
        }
        let parent = executable.deletingLastPathComponent()
        let root = parent.lastPathComponent == "bin" ? parent.deletingLastPathComponent() : parent
        guard LibraryPath.isInside(executable, root: root) else {
            throw WineReleaseError.invalid("The Wine executable escapes its runtime root")
        }
        let relative = String(executable.path.dropFirst(root.path.count + 1))
        return (root, relative)
    }
}

enum WineReleaseError: LocalizedError, Sendable {
    case network(String)
    case invalid(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .network(let message), .invalid(let message), .notFound(let message): message
        }
    }
}
