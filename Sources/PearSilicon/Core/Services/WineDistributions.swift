import Foundation

/// The Wine builds PearSilicon offers, in the order it recommends them.
/// PearWine comes first; the others are Apple silicon forks used as fallbacks
/// when a game does not run on PearWine.
struct WineDistribution: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// `pearwine.json` in the PearWine repository: a pinned base build plus
        /// the PearWine overlay.
        case pearWineManifest(repository: String, branch: String)
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
        case .pearWineManifest(let repository, _), .githubRelease(let repository, _):
            URL(string: "https://github.com/\(repository)")
        case .wineHQ:
            URL(string: "https://github.com/\(WineReleaseService.repository)")
        }
    }

    static let pearWine = WineDistribution(
        id: "pearwine", name: "PearWine",
        summary: "Recommended. Best compatibility: native arm64 Wine 11 with FEX, Mullion (Direct3D 10–12 on Metal), DXVK and VKD3D. No Rosetta.",
        source: .pearWineManifest(repository: "denizomer10/PearWine", branch: "main"),
        recommended: true, nativeArm64: true
    )

    /// Recommended first, then fallbacks from most to least likely to help.
    static let catalog: [WineDistribution] = [
        .pearWine,
        WineDistribution(
            id: "metalsharp", name: "MetalSharp Wine",
            summary: "PearWine's upstream: arm64 Wine 11 with FEX. Try it when a PearWine change breaks a game.",
            source: .githubRelease(repository: "metalsharp/MetalSharp-Wine", assetPattern: "MetalSharp-Wine-*-arm64.zip"),
            recommended: false, nativeArm64: true
        ),
        WineDistribution(
            id: "sikarugir", name: "Sikarugir Wine 11",
            summary: "CrossOver-lineage Wine for macOS (x86_64, needs Rosetta 2). Good for older DirectX 9 games and launchers.",
            source: .githubRelease(repository: "Sikarugir-App/Engines", assetPattern: "WS12WineSikarugir11.0*.tar.xz"),
            recommended: false, nativeArm64: false
        ),
        WineDistribution(
            id: "whiskywine", name: "WhiskyWine",
            summary: "Whisky's Wine with Apple's D3DMetal (x86_64, needs Rosetta 2). Try it for DirectX 11/12 games.",
            source: .githubRelease(repository: "Sikarugir-App/Engines", assetPattern: "WS12WhiskyWine*.tar.xz"),
            recommended: false, nativeArm64: false
        ),
        WineDistribution(
            id: "winehq-staging", name: "WineHQ Staging",
            summary: "Official WineHQ build (x86_64, needs Rosetta 2).",
            source: .wineHQ(.staging), recommended: false, nativeArm64: false
        ),
        WineDistribution(
            id: "winehq-devel", name: "WineHQ Development",
            summary: "Newest official WineHQ build (x86_64, needs Rosetta 2).",
            source: .wineHQ(.devel), recommended: false, nativeArm64: false
        ),
    ]

    static func distribution(for engine: WineEngine) -> WineDistribution? {
        catalog.first { engine.id == $0.id || engine.id.hasPrefix($0.id + "-") }
            ?? (engine.distribution == .wineHQ ? catalog.first { $0.id == "winehq-staging" } : nil)
    }

    /// Installed engines ordered the way PearSilicon recommends them:
    /// PearWine first, then catalog order, then everything else by name.
    static func ordered(_ engines: [WineEngine]) -> [WineEngine] {
        func rank(_ engine: WineEngine) -> Int {
            guard let distribution = distribution(for: engine),
                  let index = catalog.firstIndex(of: distribution) else { return catalog.count }
            return index
        }
        return engines.sorted { (rank($0), $0.name, $0.version) < (rank($1), $1.name, $1.version) }
    }
}

/// `pearwine.json`, the release description published in the PearWine repository.
struct PearWineManifest: Decodable, Sendable {
    struct Base: Decodable, Sendable {
        let name: String
        let url: URL
        let asset: String
        let sha256: String
        let size: Int64
    }
    struct Overlay: Decodable, Sendable {
        let asset: String
        let url: URL?
        let sha256: String?
    }
    let schema: String
    let name: String
    let version: String
    let wine: String
    let base: Base
    let overlay: Overlay?
    let environment: [String: String]?
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

        case .pearWineManifest(let repository, let branch):
            progress("Reading the PearWine release…")
            let manifestURL = URL(string: "https://raw.githubusercontent.com/\(repository)/\(branch)/pearwine.json")!
            let manifest = try JSONDecoder().decode(PearWineManifest.self, from: try await Self.fetch(manifestURL))
            guard manifest.schema == "pearwine/v1" else {
                throw WineReleaseError.invalid("This PearSilicon version does not understand \(manifest.schema); update PearSilicon")
            }
            guard manifest.base.size > 0, manifest.base.size <= WineReleaseService.maximumDownloadBytes else {
                throw WineReleaseError.invalid("The PearWine base build has an unsupported size")
            }
            let overlay = manifest.overlay
            return try await releases.installArchive(
                from: manifest.base.url, assetName: manifest.base.asset, sha256: manifest.base.sha256,
                engineID: "pearwine-\(Self.safeComponent(manifest.version))",
                name: "PearWine", version: "\(manifest.version) (Wine \(manifest.wine))",
                distribution: .pearWine, store: store,
                prepare: { root in
                    guard let overlay, let url = overlay.url, let sha = overlay.sha256 else { return }
                    progress("Applying the PearWine overlay…")
                    try await Self.applyOverlay(url: url, sha256: sha, into: root)
                },
                progress: progress
            )

        case .githubRelease(let repository, let pattern):
            progress("Looking up \(distribution.name)…")
            let asset = try await Self.latestAsset(repository: repository, pattern: pattern)
            return try await releases.installArchive(
                from: asset.url, assetName: asset.name, sha256: asset.sha256,
                engineID: "\(distribution.id)-\(Self.safeComponent(asset.version))",
                name: distribution.name, version: asset.version,
                distribution: .fork, store: store, progress: progress
            )
        }
    }

    // MARK: - Helpers

    static func safeComponent(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WineReleaseError.network("\(url.host ?? "server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
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
        let releases = try JSONDecoder().decode([Release].self, from: try await fetch(url))
        for release in releases where !release.draft {
            let candidates = release.assets
                .filter { matches($0.name, pattern: pattern) && $0.size > 0 && $0.size <= WineReleaseService.maximumDownloadBytes }
                .sorted { ($0.updated_at ?? "", $0.name) > ($1.updated_at ?? "", $1.name) }
            guard let asset = candidates.first else { continue }
            guard let digest = asset.digest, let hash = WineReleaseService.normalizedHash(digest) else {
                throw WineReleaseError.invalid("GitHub did not publish a SHA-256 for \(asset.name)")
            }
            let version = asset.name.replacingOccurrences(of: ".tar.xz", with: "")
            return Asset(name: asset.name, url: asset.browser_download_url, sha256: hash,
                         version: release.tag_name == "v1.0" ? version : "\(release.tag_name) \(version)")
        }
        throw WineReleaseError.notFound("No release of \(repository) has an asset matching \(pattern)")
    }

    /// Downloads the small PearWine overlay (only `share/pearwine/…` files),
    /// verifies it, and extracts it over the runtime root.
    static func applyOverlay(url: URL, sha256: String, into root: URL) async throws {
        guard let expected = WineReleaseService.normalizedHash(sha256) else {
            throw WineReleaseError.invalid("The PearWine overlay has no valid SHA-256")
        }
        let data = try await fetch(url)
        guard data.count < 16 * 1_024 * 1_024 else { throw WineReleaseError.invalid("The PearWine overlay is too large") }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("pearwine-overlay-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: archive) }
        try data.write(to: archive)
        guard try WineReleaseService.sha256(of: archive) == expected else {
            throw WineReleaseError.invalid("PearWine overlay SHA-256 mismatch; nothing was applied")
        }
        let listing = try Shell.run("/usr/bin/tar", ["-tzf", archive.path])
        for entry in listing.split(separator: "\n") {
            guard entry.hasPrefix("share/"), !entry.contains(".."), !entry.hasPrefix("/") else {
                throw WineReleaseError.invalid("The PearWine overlay contains an unexpected path: \(entry)")
            }
        }
        _ = try Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", root.path, "--no-same-owner"])
    }

    /// PearWine launch defaults (`share/pearwine/pearwine.env`): NAME=value lines.
    static func environmentDefaults(for engine: WineEngine) -> [String: String] {
        let file = engine.rootURL.appendingPathComponent("Runtime/share/pearwine/pearwine.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals])
            // Only plain Wine/graphics switches; never paths or loader variables.
            guard key.range(of: "^[A-Z][A-Z0-9_]{1,63}$", options: .regularExpression) != nil,
                  !key.hasPrefix("DYLD_"), !["HOME", "PATH", "WINEPREFIX", "WINELOADER", "WINESERVER"].contains(key) else { continue }
            result[key] = String(trimmed[trimmed.index(after: equals)...])
        }
        return result
    }

    /// Prefix defaults imported once after a PearWine prefix is created.
    static func registryDefaults(for engine: WineEngine) -> URL? {
        let file = engine.rootURL.appendingPathComponent("Runtime/share/pearwine/pearwine-defaults.reg")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
