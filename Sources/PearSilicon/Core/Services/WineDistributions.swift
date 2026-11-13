import Foundation

/// The Wine builds PearSilicon offers. MetalSharp Wine (native arm64, from
/// metalsharp/MetalSharp-Wine) is the default and is installed automatically
/// when a Windows game needs an engine.
struct WineDistribution: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// Newest GitHub release asset whose name matches `assetPattern`
        /// (a simple `*` glob). Verified against GitHub's published SHA-256.
        case githubRelease(repository: String, assetPattern: String)
        /// WineHQ builds handled by `WineReleaseService`.
        case wineHQ(WineReleaseChannel)
    }

    let id: String
    let name: String
    let summary: String
    let source: Source
    let recommended: Bool
    /// Runs Windows x86 code without Rosetta 2.
    let nativeArm64: Bool

    var homepage: URL? {
        switch source {
        case .githubRelease(let repository, _):
            URL(string: "https://github.com/\(repository)")
        case .wineHQ:
            URL(string: "https://github.com/\(WineReleaseService.repository)")
        }
    }

    /// Rosetta 2 is installed when its runtime library exists. The `oah`
    /// folder alone is not enough: it can hold only RosettaLinux.
    static var isRosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    static let rosettaInstallCommand = "softwareupdate --install-rosetta --agree-to-license"

    /// The signed arm64 app ZIP: its cross-architecture entitlement (needed for
    /// 32-bit Windows programs) is only valid inside the intact bundle.
    static let metalSharp = WineDistribution(
        id: "metalsharp", name: "MetalSharp Wine",
        summary: "Default. Native arm64 Wine with FEX (32- and 64-bit Windows programs), Direct3D on Metal, DXVK and VKD3D. No Rosetta.",
        source: .githubRelease(repository: "metalsharp/MetalSharp-Wine", assetPattern: "MetalSharp-Wine-*-arm64.zip"),
        recommended: true, nativeArm64: true
    )

    /// MetalSharp is the supported engine; x86_64/Rosetta engines are not offered.
    static let catalog: [WineDistribution] = [
        .metalSharp,
    ]

    static func distribution(for engine: WineEngine) -> WineDistribution? {
        if engine.distribution == .metalSharp { return .metalSharp }
        return nil
    }

    /// Only supported MetalSharp engines appear in launch and settings lists.
    static func ordered(_ engines: [WineEngine]) -> [WineEngine] {
        func rank(_ engine: WineEngine) -> Int {
            guard let distribution = distribution(for: engine),
                  let index = catalog.firstIndex(of: distribution) else { return catalog.count }
            return index
        }
        return engines.filter { $0.distribution == .metalSharp }.sorted {
            (rank($0), $0.name, $0.version) < (rank($1), $1.name, $1.version)
        }
    }
}

/// Launch and prefix defaults for MetalSharp Wine, built into PearSilicon so a
/// plain MetalSharp download behaves like the engine PearSilicon was tested
/// with. Environment values never override one set by the launcher or user.
enum MetalSharpDefaults {
    static let environment: [String: String] = [
        // msync: shared-memory synchronization, much faster than the wineserver path.
        "WINEMSYNC": "1",
        // Wine's debug channels cost real time in busy games; diagnostics
        // launches set WINEDEBUG explicitly.
        "WINEDEBUG": "-all",
        // Keep the cursor inside fullscreen games; windowed launchers stay free.
        "METALSHARP_CONFINE_CURSOR": "1",
    ]

    /// Imported once when PearSilicon creates a prefix: raw GCMouse input
    /// (smooth camera on Apple silicon) and Option keys as Alt.
    static let registry = """
    Windows Registry Editor Version 5.00

    [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
    "UseGCMouse"="Y"
    "LeftOptionIsAlt"="Y"
    "RightOptionIsAlt"="Y"

    """

    static func applies(to engine: WineEngine) -> Bool { engine.distribution == .metalSharp }
}

/// Installs catalog distributions into a `WineEngineStore`.
struct WineDistributionInstaller: Sendable {
    let releases: WineReleaseService

    init(releases: WineReleaseService = WineReleaseService()) {
        self.releases = releases
    }

    func install(
        _ distribution: WineDistribution, store: WineEngineStore,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> WineEngine {
        switch distribution.source {
        case .wineHQ(let channel):
            let check = try await releases.latest(channel: channel)
            return try await releases.install(check, store: store, progress: progress)

        case .githubRelease(let repository, let pattern):
            progress("Looking up \(distribution.name)…")
            let asset = try await Self.latestAsset(repository: repository, pattern: pattern)
            return try await releases.installArchive(
                from: asset.url, assetName: asset.name, sha256: asset.sha256,
                engineID: "\(distribution.id)-\(Self.safeComponent(asset.version))",
                name: distribution.name, version: asset.version,
                distribution: distribution.id == WineDistribution.metalSharp.id ? .metalSharp : .fork,
                store: store, progress: progress
            )
        }
    }

    // MARK: - Helpers

    static func safeComponent(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    /// A non-2xx answer. 403/429 from api.github.com means the unauthenticated
    /// rate limit (60 requests/hour) is used up.
    struct HTTPStatusError: LocalizedError {
        let host: String
        let status: Int
        var errorDescription: String? {
            status == 403 || status == 429
                ? "\(host) is rate-limiting requests (HTTP \(status)); try again later"
                : "\(host) answered HTTP \(status)"
        }
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(host: url.host ?? "server", status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    /// `WS12WhiskyWine2.5.0_3.tar.xz` with pattern `WS12WhiskyWine*.tar.xz` → `2.5.0_3`.
    static func versionLabel(asset name: String, pattern: String) -> String {
        var label = name
        for suffix in [".tar.xz", ".tar.gz", ".zip"] where label.hasSuffix(suffix) {
            label.removeLast(suffix.count)
        }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if let prefix = parts.first, !prefix.isEmpty, label.hasPrefix(prefix), label.count > prefix.count {
            label.removeFirst(prefix.count)
        }
        // `MetalSharp-Wine-*-arm64.zip` → drop `-arm64` as well.
        if parts.count > 1, var suffix = parts.last {
            for ext in [".tar.xz", ".tar.gz", ".zip"] where suffix.hasSuffix(ext) { suffix.removeLast(ext.count) }
            if !suffix.isEmpty, label.hasSuffix(suffix), label.count > suffix.count { label.removeLast(suffix.count) }
        }
        return label.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
    }

    static func matches(_ name: String, pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, name.hasPrefix(first) else { return false }
        var rest = Substring(name.dropFirst(first.count))
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return parts.count == 1 ? rest.isEmpty : rest.hasSuffix(parts.last ?? "")
    }

    struct Asset: Sendable {
        let name: String
        let url: URL
        let sha256: String
        let version: String
    }

    /// Newest matching asset across recent releases. Requires GitHub's digest,
    /// so every fork download is verified like WineHQ builds.
    static func latestAsset(repository: String, pattern: String) async throws -> Asset {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let size: Int64
                let digest: String?
                let browser_download_url: URL
                let updated_at: String?
            }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!
        let releases: [Release]
        do {
            releases = try JSONDecoder().decode([Release].self, from: try await fetch(url))
        } catch let error as HTTPStatusError where error.status == 403 || error.status == 429 {
            // The API's anonymous quota is spent; the public release pages are
            // not API calls and publish the same SHA-256 digests.
            return try await latestAssetFromReleasePages(repository: repository, pattern: pattern)
        }
        for release in releases where !release.draft {
            // Only assets with a GitHub-published SHA-256 are installable;
            // newest first, so an older unhashed upload never blocks a newer one.
            let candidates = release.assets
                .filter { matches($0.name, pattern: pattern) && $0.size > 0 && $0.size <= WineReleaseService.maximumDownloadBytes }
                .compactMap { asset in
                    asset.digest.flatMap(WineReleaseService.normalizedHash).map { (asset, $0) }
                }
                .sorted { ($0.0.updated_at ?? "", $0.0.name) > ($1.0.updated_at ?? "", $1.0.name) }
            guard let (asset, hash) = candidates.first else { continue }
            return Asset(name: asset.name, url: asset.browser_download_url, sha256: hash,
                         version: versionLabel(asset: asset.name, pattern: pattern))
        }
        throw WineReleaseError.notFound("No release of \(repository) has a verifiable asset matching \(pattern)")
    }

    /// Fallback when the GitHub API is rate-limited: the release feed gives the
    /// tags and each tag's asset page lists names, download links and SHA-256s.
    static func latestAssetFromReleasePages(repository: String, pattern: String) async throws -> Asset {
        let atom = String(decoding: try await fetch(URL(string: "https://github.com/\(repository)/releases.atom")!), as: UTF8.self)
        let tags = WineReleaseService.tags(inAtom: atom)
        for tag in tags.prefix(10) {
            guard let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let page = URL(string: "https://github.com/\(repository)/releases/expanded_assets/\(escaped)") else { continue }
            // One missing or unreadable release page must not hide older ones.
            guard let data = try? await fetch(page) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let marker = "/\(repository)/releases/download/\(tag)/"
            var names: [String] = []
            var cursor = html.startIndex
            while let range = html.range(of: marker, range: cursor..<html.endIndex) {
                let name = String(html[range.upperBound...].prefix { $0 != "\"" && $0 != "?" && $0 != "<" })
                if matches(name, pattern: pattern), !names.contains(name) { names.append(name) }
                cursor = range.upperBound
            }
            for name in names.sorted(by: >) {
                guard let hash = digest(of: marker + name, in: html, nextEntry: marker),
                      let url = URL(string: "https://github.com\(marker)\(name)") else { continue }
                return Asset(name: name, url: url, sha256: hash, version: versionLabel(asset: name, pattern: pattern))
            }
        }
        throw WineReleaseError.notFound("No release of \(repository) has a verifiable asset matching \(pattern)")
    }

    /// The `sha256:` digest inside one asset's entry on a release asset page:
    /// only between that asset's link and the next asset's link, so an asset
    /// without a published digest never borrows its neighbour's.
    static func digest(of link: String, in html: String, nextEntry marker: String) -> String? {
        guard let start = html.range(of: "\"" + link + "\"") ?? html.range(of: link) else { return nil }
        let end = html.range(of: marker, range: start.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
        let entry = html[start.upperBound..<end]
        guard let label = entry.range(of: "sha256:") else { return nil }
        let hex = entry[label.upperBound...].prefix { $0.isHexDigit }
        return hex.count == 64 ? hex.lowercased() : nil
    }
}
