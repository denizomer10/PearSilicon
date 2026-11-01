import Foundation

/// Resolves a GitHub repository to the newest downloadable Wine engine archive.
/// A user pastes a repository URL; PearSilicon finds the latest release asset
/// automatically and falls back to the repository's source ZIP when the project
/// has no release. No user-supplied SHA-256 is required: GitHub's digest is
/// verified when it exists, and TLS plus an exact-host allowlist protect the
/// transfer. Release archives are saved for explicit registration; a source ZIP
/// is also extracted so its layout can be inspected.
struct CommunityWineService: Sendable {
    static let notice = "Only download from a GitHub repository you trust. A matching hash proves integrity, not the publisher's identity or safety. Review the engine's license before use."

    struct Archive: Sendable, Equatable {
        let repository: String
        let tag: String
        let assetName: String
        let url: URL
        let sha256: String?
        let isRepositoryArchive: Bool
    }

    enum CommunityError: LocalizedError {
        case invalidRepository
        case noRelease
        case network(String)
        case invalidArchive(String)

        var errorDescription: String? {
            switch self {
            case .invalidRepository:
                return "Enter a GitHub repository such as https://github.com/owner/repo"
            case .noRelease:
                return "This repository has no downloadable release archive or source ZIP"
            case .network(let message):
                return message
            case .invalidArchive(let message):
                return "The downloaded archive is not safe: \(message)"
            }
        }
    }

    static let maximumArchiveBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browserDownloadURL: URL
            let digest: String?
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

    private struct Repository: Decodable {
        let defaultBranch: String
        enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
    }

    /// Parses a GitHub repository URL (or `owner/repo`) and ignores trailing
    /// release/tag paths. Only github.com is accepted.
    static func repositoryParts(_ input: String) throws -> (owner: String, repo: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 500 else { throw CommunityError.invalidRepository }
        if text.contains("://") {
            guard let url = URL(string: text), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "github.com", url.user == nil, url.password == nil else {
                throw CommunityError.invalidRepository
            }
            text = url.path
        } else if text.lowercased().hasPrefix("github.com/") {
            text = String(text.dropFirst("github.com".count))
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              !parts.contains(where: { $0 == "." || $0 == ".." }),
              parts[0] != ".", parts[0] != ".." else { throw CommunityError.invalidRepository }
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo.removeLast(4) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !parts[0].isEmpty, !repo.isEmpty, repo != ".", repo != "..",
              parts[0].unicodeScalars.allSatisfy(allowed.contains),
              repo.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CommunityError.invalidRepository
        }
        return (parts[0], repo)
    }

    /// Newest non-draft release with an archive asset; prefers a stable release.
    /// When the project has no releases, returns the repository source ZIP.
    func resolve(input: String) async throws -> Archive {
        let (owner, repo) = try Self.repositoryParts(input)
        let base = "https://api.github.com/repos/\(owner)/\(repo)"
        // A repository with no releases returns 200 and an empty array; a
        // failed API request (rate limit, network) must not silently turn into
        // a source-tree download.
        let releases: [Release] = try await api("\(base)/releases")
        do {
            let ordered = releases.enumerated()
                .filter { !$0.element.draft }
                .sorted { lhs, rhs in
                    if lhs.element.prerelease != rhs.element.prerelease { return !lhs.element.prerelease }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
            for release in ordered {
                guard let asset = Self.selectAsset(in: release) else { continue }
                let digest = asset.digest.flatMap(Self.normalizedSHA256)
                return Archive(
                    repository: "\(owner)/\(repo)", tag: release.tagName, assetName: asset.name,
                    url: asset.browserDownloadURL, sha256: digest, isRepositoryArchive: false
                )
            }
        }
        let branch: String
        if let metadata: Repository = try? await api(base) {
            branch = metadata.defaultBranch
        } else {
            branch = "main"
        }
        guard let url = URL(string: "https://codeload.github.com/\(owner)/\(repo)/zip/refs/heads/\(branch)") else {
            throw CommunityError.noRelease
        }
        return Archive(
            repository: "\(owner)/\(repo)", tag: branch, assetName: "\(repo)-\(branch).zip",
            url: url, sha256: nil, isRepositoryArchive: true
        )
    }

    private static func selectAsset(in release: Release) -> Release.Asset? {
        let archiveExtensions = [".tar.xz", ".txz", ".tar.gz", ".tgz", ".zip", ".tar.bz2", ".tbz2"]
        let candidates = release.assets.filter { asset in
            asset.size > 0 && asset.size <= maximumArchiveBytes
                && archiveExtensions.contains(where: { asset.name.lowercased().hasSuffix($0) })
        }
        let preferred = candidates.first { asset in
            let name = asset.name.lowercased()
            return name.contains("macos") || name.contains("osx") || name.contains("darwin")
        }
        return preferred ?? candidates.first
    }

    private static func normalizedSHA256(_ digest: String) -> String? {
        var value = digest.lowercased()
        if value.hasPrefix("sha256:") { value.removeFirst(7) }
        return value.count == 64 && value.allSatisfy(\.isHexDigit) ? value : nil
    }

    /// Downloads into `Engines/Downloads`, verifies GitHub's digest when it is
    /// available, and extracts a repository ZIP. Returns the saved file and the
    /// extracted directory when applicable.
    func download(_ archive: Archive, downloadsRoot: URL) async throws -> (file: URL, extracted: URL?) {
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        let safeRepo = archive.repository.replacingOccurrences(of: "/", with: "-")
        let safeTag = archive.tag.replacingOccurrences(of: "/", with: "-")
        let ext = [".tar.xz", ".tar.gz", ".tgz", ".zip", ".tar.bz2", ".txz", ".tbz2"]
            .first { archive.assetName.lowercased().hasSuffix($0) } ?? ".archive"
        let destination = downloadsRoot.appendingPathComponent("\(safeRepo)-\(safeTag)\(ext)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: archive.url)
        request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CommunityError.network("The archive download did not return HTTP 200")
        }
        guard Self.isAllowedDownloadHost(http.url?.host) else {
            throw CommunityError.network("The archive download left GitHub")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= Self.maximumArchiveBytes else {
            throw CommunityError.invalidArchive("empty or larger than the 8 GiB limit")
        }
        if let expected = archive.sha256 {
            let actual = try Self.sha256(of: temporary)
            guard actual == expected else {
                throw CommunityError.invalidArchive("SHA-256 mismatch; the download was discarded")
            }
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        guard archive.isRepositoryArchive else { return (destination, nil) }
        let extracted = try Self.extractZIP(destination, into: downloadsRoot
            .appendingPathComponent("\(safeRepo)-\(safeTag)", isDirectory: true))
        return (destination, extracted)
    }

    private func api<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString), url.scheme == "https", url.host?.lowercased() == "api.github.com" else {
            throw CommunityError.invalidRepository
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PearSilicon", forHTTPHeaderField: "User-Agent")
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CommunityError.network("GitHub metadata is unavailable (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        guard data.count <= 4 * 1_024 * 1_024 else { throw CommunityError.network("GitHub metadata is too large") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }

    static func isAllowedDownloadHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["github.com", "codeload.github.com", "release-assets.githubusercontent.com",
                "objects.githubusercontent.com"].contains(host)
    }

    private static func sha256(of url: URL) throws -> String {
        try WineReleaseService.sha256(of: url)
    }

    private static func extractZIP(_ archive: URL, into destination: URL) throws -> URL {
        let listing = try Shell.run("/usr/bin/unzip", ["-Z1", archive.path])
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let name = String(line)
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !parts.contains(".."), !name.contains("\\") else {
                throw CommunityError.invalidArchive("unsafe path \(name)")
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
        return destination
    }
}

private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              CommunityWineService.isAllowedDownloadHost(request.url?.host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
