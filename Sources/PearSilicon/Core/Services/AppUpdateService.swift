import CryptoKit
import Darwin
import Foundation
import zlib

// These models deliberately do not depend on GUI state or UserDefaults. Constructing
// the service does no I/O; only an explicit check/stage call contacts GitHub.
enum UpdateChannel: String, Codable, Sendable {
    case developmentBeta
    case stable
}

struct UpdateAsset: Codable, Equatable, Sendable {
    let id: Int64
    let name: String
    let size: Int64
    let browserDownloadURL: URL
    let digest: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, digest, state
        case browserDownloadURL = "browser_download_url"
    }

    var sha256: String? { AppUpdateIdentity.normalizedDigest(digest) }
}

struct UpdateRelease: Codable, Equatable, Sendable {
    let id: Int64
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let targetCommitish: String?
    let htmlURL: URL?
    let publishedAt: String?
    let assets: [UpdateAsset]

    enum CodingKeys: String, CodingKey {
        case id, name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case targetCommitish = "target_commitish"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

struct AppUpdateIdentity: Equatable, Codable, Sendable {
    let version: String
    let build: String
    let commit: String?
    let assetSHA256: String?

    init(version: String, build: String = "", commit: String? = nil, assetSHA256: String? = nil) {
        self.version = version
        self.build = build
        self.commit = commit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.assetSHA256 = Self.normalizedDigest(assetSHA256)
    }

    /// PearBuildCommit should contain the full Git commit, not a branch name.
    /// A caller can inject a known installed asset digest (e.g. from its install
    /// receipt). A ZIP's digest cannot be embedded in that same ZIP's Info.plist.
    init(bundle: Bundle = .main, assetSHA256: String? = nil) {
        self.init(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            commit: bundle.object(forInfoDictionaryKey: "PearBuildCommit") as? String,
            assetSHA256: assetSHA256 ?? bundle.object(forInfoDictionaryKey: "PearBuildAssetSHA256") as? String
        )
    }

    static func normalizedDigest(_ value: String?) -> String? {
        guard var value = value?.lowercased() else { return nil }
        if value.hasPrefix("sha256:") { value.removeFirst(7) }
        return isHex(value, length: 64) ? value : nil
    }

    fileprivate static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct AppUpdateCheck: Equatable, Sendable {
    enum Reason: String, Sendable {
        case newerVersion
        case changedAsset
        case changedCommit
        case unknownCurrentRevision
    }

    let channel: UpdateChannel
    let release: UpdateRelease
    let asset: UpdateAsset
    let commit: String
    /// nil means up to date. Missing local revision metadata is never silently
    /// interpreted as proof that a moving beta is current.
    let reason: Reason?
    var isUpdateAvailable: Bool { reason != nil }
}

struct StagedAppUpdate: Sendable {
    let update: AppUpdateCheck
    let directoryURL: URL
    let archiveURL: URL
    let bundleURL: URL
    let identity: AppUpdateIdentity
    fileprivate let token: UUID
}

struct AppUpdateInstallation: Sendable {
    let installedBundleURL: URL
    /// Kept on the destination volume. Do not delete until the user accepts the
    /// new build; rollback() uses this exact bundle, not a reconstructed copy.
    let rollbackBundleURL: URL
    let receiptURL: URL
    let update: AppUpdateCheck
    fileprivate let token: UUID
}

enum AppUpdateError: LocalizedError, Sendable {
    case invalidMetadata(String)
    case unsafeURL(String)
    case missingDigest
    case limitExceeded(String)
    case integrity(String)
    case invalidArchive(String)
    case invalidBundle(String)
    case operation(String)
    case runningApplication(String)
    case staleRelease
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidMetadata(let message), .unsafeURL(let message), .limitExceeded(let message),
             .integrity(let message), .invalidArchive(let message), .invalidBundle(let message),
             .operation(let message): return message
        case .missingDigest: return "This release asset has no valid GitHub SHA-256 digest; it cannot be installed."
        case .runningApplication(let path):
            return "Quit PearSilicon and all protected games before replacing this app: \(path)"
        case .staleRelease: return "The release changed during the update. Check for updates again."
        case .httpStatus(let status): return "GitHub returned HTTP \(status). Try the explicit update check again later."
        }
    }
}

/// Explicit, opt-in updater for denizomer10/PearSilicon. No timers, telemetry,
/// launch hooks, elevated privileges, shell scripts, or automatic self-replacement.
/// GitHub's digest authenticates the downloaded bytes against GitHub's metadata;
/// it is NOT a publisher signature. Current ad-hoc releases are not notarized.
actor AppUpdateService {
    static let defaultStagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PearSilicon-Updates", isDirectory: true)

    struct Limits: Sendable {
        var maximumDownloadBytes: Int64 = 512 * 1024 * 1024
        var maximumExpandedBytes: Int64 = 2 * 1024 * 1024 * 1024
        var maximumArchiveEntries: Int = 100_000
        var requestTimeout: TimeInterval = 300
        var commandTimeout: TimeInterval = 90
    }

    /// Injectable file-streaming transport. Fixtures must write to destination;
    /// service-level size, response URL and digest checks still apply afterwards.
    struct Transport: Sendable {
        var fetch: @Sendable (URLRequest, URL, Int64, TimeInterval) async throws -> HTTPURLResponse

        static let live = Transport { request, destination, maximumBytes, timeout in
            try await UpdateHTTPTransfer.fetch(
                request, to: destination, maximumBytes: maximumBytes, timeout: timeout
            )
        }
    }

    private let current: AppUpdateIdentity
    private let stagingRoot: URL
    private let limits: Limits
    private let transport: Transport
    private var stages: [UUID: StagedAppUpdate] = [:]
    private struct InstallationRecord {
        let installation: AppUpdateInstallation
        let installedIdentity: UpdateFileIdentity
        let installedRevision: String
        let rollbackRevision: String
    }
    private var installations: [UUID: InstallationRecord] = [:]

    init(
        current: AppUpdateIdentity = AppUpdateIdentity(),
        stagingRoot: URL = AppUpdateService.defaultStagingRoot,
        limits: Limits = Limits(),
        transport: Transport = .live
    ) {
        self.current = current
        self.stagingRoot = stagingRoot
        self.limits = limits
        self.transport = transport
    }

    /// Call only for a user-initiated action. Stable uses GitHub's latest
    /// non-prerelease; beta uses the mutable development-beta release.
    func checkForUpdates(channel: UpdateChannel = .developmentBeta) async throws -> AppUpdateCheck {
        try validateLimits()
        let path = channel == .developmentBeta ? "releases/tags/development-beta" : "releases/latest"
        let release: UpdateRelease = try await api(path)
        let asset = try Self.selectAsset(in: release, channel: channel, limits: limits)
        let commit = try await resolveTag(release.tagName)
        return try Self.evaluate(release: release, asset: asset, commit: commit, current: current, channel: channel)
    }

    /// Downloads to a private directory, hashes before any extraction, admits
    /// the ZIP's complete listing/content, then uses ditto and verifies the app.
    /// The source and any installed .app are never modified by staging.
    func stage(_ update: AppUpdateCheck) async throws -> StagedAppUpdate {
        try validateLimits()
        let selected = try Self.selectAsset(in: update.release, channel: update.channel, limits: limits)
        guard selected == update.asset, AppUpdateIdentity.isHex(update.commit, length: 40) else {
            throw AppUpdateError.invalidMetadata("Invalid update selection.")
        }
        try await requireUnchanged(update)
        let directory = try makeWorkspace()
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: directory) } }
        let archive = directory.appendingPathComponent("release.zip")
        let response = try await transport.fetch(
            Self.request(update.asset.browserDownloadURL, api: false), archive,
            update.asset.size, limits.requestTimeout
        )
        try Self.validateResponse(response, api: false)
        try Self.quarantine(archive)
        try verifyArchiveDigest(archive, asset: update.asset)
        // In-place betas may change while the transfer is in flight. Never
        // associate a new tag commit with an old/mutated release asset.
        try await requireUnchanged(update)
        try Task.checkCancellation()
        let bundle = try extractAndVerify(archive, into: directory.appendingPathComponent("Extracted"))
        let identity = try Self.bundleIdentity(at: bundle).identity
        if let embedded = identity.commit, AppUpdateIdentity.isHex(embedded, length: 40), embedded != update.commit {
            throw AppUpdateError.integrity("The app's PearBuildCommit disagrees with the resolved release tag.")
        }
        let result = StagedAppUpdate(
            update: update, directoryURL: directory, archiveURL: archive, bundleURL: bundle,
            identity: identity, token: UUID()
        )
        stages[result.token] = result
        keep = true
        return result
    }

    /// Explicit replacement, usable from a separate, stopped-app installer/CLI.
    /// It deliberately refuses to replace the app executing this service.
    ///
    /// Pass ALL game bundle URLs in protecting, including CLI-launched games.
    /// The parent must hold its launch/preparation leases across this call;
    /// requireStopped is rechecked immediately before the atomic commit. Process
    /// enumeration independently checks all same-UID executables in these apps.
    /// No userspace updater can exclude an unrelated, noncooperating launch.
    /// The GUI should stage, explain quitting/relaunching, and never auto-retry.
    func replaceNonrunningApp(
        _ staged: StagedAppUpdate,
        at destinationURL: URL,
        protecting gameBundleURLs: [URL],
        requireStopped: @Sendable () throws -> Void
    ) throws -> AppUpdateInstallation {
        guard let known = stages[staged.token], known.archiveURL == staged.archiveURL else {
            throw AppUpdateError.operation("This service did not verify that staged update.")
        }
        let destination = try Self.replacementDestination(destinationURL)
        guard !Self.contains(destination, known.directoryURL), !Self.contains(known.directoryURL, destination) else {
            throw AppUpdateError.operation("The installation destination and staging directory must be separate.")
        }
        let lock = try UpdateInstallLock(destination: destination)
        defer { lock.release() }
        try requireStopped()
        try Self.requireNoProcesses(in: [destination] + gameBundleURLs)
        let original = try Self.fileIdentity(destination)
        let originalRevision = try UpdateTree.fingerprint(destination)
        let transaction = try Self.makePrivateDirectory(in: destination.deletingLastPathComponent(), prefix: ".pear-update-")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: transaction) } }
        // Re-extract the hash-verified archive instead of trusting a staged app
        // that may have been edited/re-signed since it was shown in Finder.
        try verifyArchiveDigest(known.archiveURL, asset: known.update.asset)
        let replacement = try extractAndVerify(known.archiveURL, into: transaction.appendingPathComponent("Payload"))
        let replacementID = try Self.fileIdentity(replacement)
        let replacementRevision = try UpdateTree.fingerprint(replacement)
        let receiptURL = transaction.appendingPathComponent("receipt.json")
        let receipt = UpdateInstallReceipt(
            releaseID: known.update.release.id, assetID: known.update.asset.id,
            assetSHA256: known.update.asset.sha256!, commit: known.update.commit,
            bundleRevision: replacementRevision,
            destinationPath: destination.path
        )
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        guard try Self.fileIdentity(destination) == original,
              try UpdateTree.fingerprint(destination) == originalRevision else {
            throw AppUpdateError.operation("The installed app changed before the update could commit.")
        }
        try requireStopped()
        try Self.requireNoProcesses(in: [destination] + gameBundleURLs)
        guard try Self.fileIdentity(destination) == original else {
            throw AppUpdateError.operation("The destination changed immediately before replacement.")
        }
        try Self.swap(replacement, destination)
        // There are no fallible post-commit operations. RENAME_SWAP leaves the
        // complete old app at replacement, with no missing-destination window.
        committed = true
        let result = AppUpdateInstallation(
            installedBundleURL: destination, rollbackBundleURL: replacement, receiptURL: receiptURL,
            update: known.update, token: UUID()
        )
        installations[result.token] = InstallationRecord(
            installation: result, installedIdentity: replacementID,
            installedRevision: replacementRevision, rollbackRevision: originalRevision
        )
        return result
    }

    /// Atomic rollback is explicit, on this same service instance, and refuses
    /// running apps/games. The replaced new build remains at rollbackBundleURL.
    /// After a service restart the preserved bundle is still available in Finder.
    func rollback(
        _ installation: AppUpdateInstallation,
        protecting gameBundleURLs: [URL],
        requireStopped: @Sendable () throws -> Void
    ) throws {
        guard let record = installations[installation.token],
              record.installation.installedBundleURL == installation.installedBundleURL else {
            throw AppUpdateError.operation("Unknown update installation.")
        }
        let known = record.installation
        let destination = try Self.replacementDestination(known.installedBundleURL)
        let lock = try UpdateInstallLock(destination: destination)
        defer { lock.release() }
        guard try Self.fileIdentity(destination) == record.installedIdentity,
              try UpdateTree.fingerprint(destination) == record.installedRevision,
              try UpdateTree.fingerprint(known.rollbackBundleURL) == record.rollbackRevision else {
            throw AppUpdateError.operation("An app has changed; refusing to overwrite it during rollback.")
        }
        try verifyBundle(known.rollbackBundleURL, workDirectory: known.rollbackBundleURL.deletingLastPathComponent())
        try requireStopped()
        try Self.requireNoProcesses(in: [destination] + gameBundleURLs)
        try Self.swap(known.rollbackBundleURL, destination)
        installations.removeValue(forKey: installation.token)
    }

    func discard(_ staged: StagedAppUpdate) throws {
        guard let known = stages[staged.token] else { return }
        try FileManager.default.removeItem(at: known.directoryURL)
        stages.removeValue(forKey: staged.token)
    }

    /// Receipts are outside the signed app. Match their complete bundle content
    /// before using their digest for same-commit/repacked beta detection.
    static func identity(of bundleURL: URL, matching receiptURL: URL) throws -> AppUpdateIdentity {
        guard try regularFileSize(receiptURL) <= 64 * 1024 else { throw AppUpdateError.integrity("The update receipt is too large.") }
        let receipt = try JSONDecoder().decode(UpdateInstallReceipt.self, from: Data(contentsOf: receiptURL))
        let bundle = try bundleIdentity(at: bundleURL)
        guard bundleURL.resolvingSymlinksInPath().path == receipt.destinationPath,
              try UpdateTree.fingerprint(bundleURL) == receipt.bundleRevision else {
            throw AppUpdateError.integrity("The update receipt does not match this installed bundle.")
        }
        return AppUpdateIdentity(
            version: bundle.identity.version, build: bundle.identity.build,
            commit: bundle.identity.commit, assetSHA256: receipt.assetSHA256
        )
    }

    static func selectAsset(in release: UpdateRelease, channel: UpdateChannel, limits: Limits = Limits()) throws -> UpdateAsset {
        guard release.id > 0, !release.draft, !release.tagName.isEmpty,
              release.tagName.utf8.count <= 200,
              !release.tagName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !release.tagName.contains(".."), !release.tagName.contains("\\") else {
            throw AppUpdateError.invalidMetadata("The release metadata is invalid or unpublished.")
        }
        if channel == .developmentBeta {
            guard release.tagName == "development-beta" else {
                throw AppUpdateError.invalidMetadata("Expected the development-beta release.")
            }
        } else {
            guard !release.prerelease, UpdateVersion(release.tagName) != nil else {
                throw AppUpdateError.invalidMetadata("The stable channel requires a numbered, non-prerelease release.")
            }
        }
        // Prefer the architecture-specific package, never source ZIPs or DMGs.
        let names = ["pearsilicon-macos-arm64.zip", "pearsilicon-arm64.zip", "pearsilicon.zip"]
        for name in names {
            let matches = release.assets.filter { $0.name.lowercased() == name }
            guard matches.count <= 1 else { throw AppUpdateError.invalidMetadata("Ambiguous release assets.") }
            guard let asset = matches.first else { continue }
            guard asset.id > 0, asset.size > 0, asset.size <= limits.maximumDownloadBytes,
                  asset.state == nil || asset.state == "uploaded" else {
                throw AppUpdateError.limitExceeded("The release asset is incomplete, empty or exceeds the download limit.")
            }
            guard asset.digest?.lowercased().hasPrefix("sha256:") == true, asset.sha256 != nil else {
                throw AppUpdateError.missingDigest
            }
            try UpdateURLPolicy.validate(asset.browserDownloadURL, api: false, initialAsset: true)
            let components = asset.browserDownloadURL.path.split(separator: "/").map(String.init)
            guard components.count == 6, components[4] == release.tagName, components[5] == asset.name else {
                throw AppUpdateError.unsafeURL("The asset URL does not match this release and filename.")
            }
            return asset
        }
        throw AppUpdateError.invalidMetadata("No supported PearSilicon Apple silicon ZIP is attached to this release.")
    }

    static func evaluate(
        release: UpdateRelease, asset: UpdateAsset, commit: String,
        current: AppUpdateIdentity, channel: UpdateChannel
    ) throws -> AppUpdateCheck {
        guard AppUpdateIdentity.isHex(commit, length: 40), asset.sha256 != nil else {
            throw AppUpdateError.invalidMetadata("A resolved Git commit and SHA-256 asset digest are required.")
        }
        var reason: AppUpdateCheck.Reason?
        if channel == .stable, let remote = UpdateVersion(release.tagName), let local = UpdateVersion(current.version), remote != local {
            reason = remote > local ? .newerVersion : nil
        } else if let digest = current.assetSHA256 {
            reason = digest == asset.sha256 ? nil : .changedAsset
        } else if let localCommit = current.commit, AppUpdateIdentity.isHex(localCommit, length: 40) {
            reason = localCommit == commit ? nil : .changedCommit
        } else {
            reason = .unknownCurrentRevision
        }
        return AppUpdateCheck(channel: channel, release: release, asset: asset, commit: commit, reason: reason)
    }

    private func validateLimits() throws {
        guard limits.maximumDownloadBytes > 0, limits.maximumExpandedBytes > 0,
              limits.maximumArchiveEntries > 0, limits.maximumArchiveEntries < 1_000_000,
              limits.requestTimeout.isFinite, limits.requestTimeout > 0, limits.requestTimeout <= 3600,
              limits.commandTimeout.isFinite, limits.commandTimeout > 0, limits.commandTimeout <= 600 else {
            throw AppUpdateError.invalidMetadata("Invalid update resource limits.")
        }
    }

    private static let apiBase = "https://api.github.com/repos/denizomer10/PearSilicon/"

    private static func request(_ url: URL, api: Bool) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("PearSilicon-Update", forHTTPHeaderField: "User-Agent")
        request.setValue(api ? "application/vnd.github+json" : "application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if api { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        return request
    }

    private func api<T: Decodable & Sendable>(_ path: String) async throws -> T {
        guard let url = URL(string: Self.apiBase + path) else { throw AppUpdateError.invalidMetadata("Invalid GitHub API path.") }
        try UpdateURLPolicy.validate(url, api: true)
        let directory = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("response.json")
        let maximum: Int64 = 2 * 1024 * 1024
        let response = try await transport.fetch(Self.request(url, api: true), file, maximum, min(limits.requestTimeout, 30))
        try Self.validateResponse(response, api: true)
        guard try Self.regularFileSize(file) <= maximum else { throw AppUpdateError.limitExceeded("GitHub metadata is too large.") }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }

    private struct GitObject: Decodable, Sendable {
        struct Object: Decodable, Sendable { let sha: String; let type: String }
        let object: Object
    }

    private func resolveTag(_ tag: String) async throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = tag.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw AppUpdateError.invalidMetadata("Invalid release tag.")
        }
        let reference: GitObject = try await api("git/ref/tags/" + encoded)
        var object = reference.object
        for _ in 0..<8 {
            guard AppUpdateIdentity.isHex(object.sha, length: 40) else {
                throw AppUpdateError.invalidMetadata("GitHub did not return a full Git object SHA.")
            }
            if object.type == "commit" { return object.sha }
            guard object.type == "tag" else { throw AppUpdateError.invalidMetadata("The release tag does not point to a commit.") }
            let annotated: GitObject = try await api("git/tags/" + object.sha)
            object = annotated.object
        }
        throw AppUpdateError.invalidMetadata("The annotated release tag chain is too deep.")
    }

    private func requireUnchanged(_ update: AppUpdateCheck) async throws {
        let release: UpdateRelease = try await api("releases/\(update.release.id)")
        let asset = try Self.selectAsset(in: release, channel: update.channel, limits: limits)
        guard release.id == update.release.id, release.tagName == update.release.tagName,
              asset == update.asset, try await resolveTag(release.tagName) == update.commit else {
            throw AppUpdateError.staleRelease
        }
    }

    private static func validateResponse(_ response: HTTPURLResponse, api: Bool) throws {
        guard response.statusCode == 200 else { throw AppUpdateError.httpStatus(response.statusCode) }
        guard let url = response.url else { throw AppUpdateError.unsafeURL("The response has no URL.") }
        try UpdateURLPolicy.validate(url, api: api)
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw AppUpdateError.integrity("Encoded update responses are not supported.")
        }
    }

    private func verifyArchiveDigest(_ archive: URL, asset: UpdateAsset) throws {
        guard try Self.regularFileSize(archive) == asset.size, asset.size <= limits.maximumDownloadBytes else {
            throw AppUpdateError.integrity("The downloaded ZIP size does not match GitHub's asset metadata.")
        }
        guard let expected = asset.sha256, try RuntimeRevision.sha256(of: archive) == expected else {
            throw AppUpdateError.integrity("The downloaded ZIP does not match GitHub's SHA-256 digest.")
        }
    }

    private func extractAndVerify(_ archive: URL, into directory: URL) throws -> URL {
        let listing = try UpdateZIPArchive.validate(at: archive, limits: limits)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try UpdateCommand.run(
            "/usr/bin/ditto", ["-x", "-k", "--noacl", archive.path, directory.path],
            in: directory.deletingLastPathComponent(), timeout: limits.commandTimeout
        )
        try UpdateTree.validate(directory, maximumBytes: limits.maximumExpandedBytes, maximumEntries: limits.maximumArchiveEntries)
        let bundle = directory.appendingPathComponent(listing.bundleName, isDirectory: true)
        try verifyBundle(bundle, workDirectory: directory.deletingLastPathComponent())
        try Self.quarantine(bundle)
        return bundle
    }

    private func verifyBundle(_ bundle: URL, workDirectory: URL) throws {
        let info = try Self.bundleIdentity(at: bundle)
        _ = try UpdateCommand.run(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path],
            in: workDirectory, timeout: limits.commandTimeout
        )
        let archs = try UpdateCommand.run(
            "/usr/bin/lipo", ["-archs", info.executable.path], in: workDirectory, timeout: limits.commandTimeout
        ).split(whereSeparator: { $0.isWhitespace })
        guard archs.contains("arm64") || archs.contains("arm64e") else {
            throw AppUpdateError.invalidBundle("The update executable does not contain an Apple silicon architecture.")
        }
    }

    private static func quarantine(_ file: URL) throws {
        // Keep Gatekeeper's downloaded-code boundary. Never mark an ad-hoc
        // release user-approved or remove quarantine to make it launch silently.
        let timestamp = String(UInt64(Date().timeIntervalSince1970), radix: 16)
        let value = Data("0083;\(timestamp);PearSilicon;\(UUID().uuidString)".utf8)
        let result = value.withUnsafeBytes {
            setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw AppUpdateError.operation("Cannot quarantine the downloaded update: \(errno)") }
    }

    private static func bundleIdentity(at bundle: URL) throws -> (identity: AppUpdateIdentity, executable: URL) {
        guard try fileType(bundle) == S_IFDIR, bundle.pathExtension == "app" else {
            throw AppUpdateError.invalidBundle("Expected a real .app directory, not a symbolic link.")
        }
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard try fileType(bundle.appendingPathComponent("Contents")) == S_IFDIR,
              try fileType(plist) == S_IFREG, try regularFileSize(plist) <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.pearsilicon.app",
              info["CFBundlePackageType"] as? String == "APPL",
              let executableName = info["CFBundleExecutable"] as? String,
              !executableName.isEmpty, executableName != ".", executableName != "..",
              !executableName.contains("/"), !executableName.contains("\\"), !executableName.contains("\0") else {
            throw AppUpdateError.invalidBundle("The update is not a com.pearsilicon.app application bundle.")
        }
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let executable = macOS.appendingPathComponent(executableName)
        guard try fileType(macOS) == S_IFDIR, try fileType(executable) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.invalidBundle("The app has no regular executable in Contents/MacOS.")
        }
        return (AppUpdateIdentity(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            commit: info["PearBuildCommit"] as? String
        ), executable)
    }

    private func makeWorkspace() throws -> URL {
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = stagingRoot.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(stagingRoot.lastPathComponent)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppUpdateError.operation("The update staging root is not a private directory.") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o777 == 0o700 else {
            throw AppUpdateError.operation("The update staging root must be owned by this user with mode 0700.")
        }
        return try Self.makePrivateDirectory(in: root, prefix: "stage-")
    }

    private static func makePrivateDirectory(in parent: URL, prefix: String) throws -> URL {
        let directory = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw AppUpdateError.operation("Cannot create a private update transaction: \(errno)") }
        return directory
    }

    private static func replacementDestination(_ url: URL) throws -> URL {
        guard url.isFileURL, url.pathExtension == "app" else { throw AppUpdateError.invalidBundle("The destination must be an existing .app.") }
        let destination = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        _ = try bundleIdentity(at: destination)
        return destination
    }

    private static func contains(_ root: URL, _ child: URL) -> Bool {
        let root = root.resolvingSymlinksInPath().path
        let child = child.resolvingSymlinksInPath().path
        return child == root || child.hasPrefix(root + "/")
    }

    fileprivate static func fileType(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AppUpdateError.operation("Cannot inspect \(url.lastPathComponent): \(errno)") }
        return info.st_mode & S_IFMT
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw AppUpdateError.integrity("Expected a regular, unlinked update file.")
        }
        return info.st_size
    }

    private static func fileIdentity(_ url: URL) throws -> UpdateFileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw AppUpdateError.operation("The installation directory has disappeared or changed type.")
        }
        return UpdateFileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func swap(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw AppUpdateError.operation("Atomic app exchange failed (\(errno)); the original app was not removed.")
        }
    }

    private static func requireNoProcesses(in bundles: [URL]) throws {
        let roots = bundles.map { $0.resolvingSymlinksInPath().path }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw AppUpdateError.operation("Cannot enumerate running processes safely.") }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2 + 64)
        let used = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard used > 0, used < pids.count else { throw AppUpdateError.operation("The running process snapshot was incomplete.") }
        for pid in pids.prefix(Int(used)) where pid > 0 {
            var info = proc_bsdinfo()
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
            }
            guard read == MemoryLayout<proc_bsdinfo>.size else {
                if kill(pid, 0) == 0 { throw AppUpdateError.operation("Cannot inspect a running process; quit apps and retry.") }
                continue
            }
            guard info.pbi_uid == getuid() else { continue }
            // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift.
            var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let size = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard size > 0 else {
                if kill(pid, 0) != 0, errno == ESRCH { continue }
                throw AppUpdateError.operation("Cannot resolve a running executable; refusing replacement.")
            }
            let path = URL(fileURLWithPath: String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)).resolvingSymlinksInPath().path
            if let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                throw AppUpdateError.runningApplication(root)
            }
        }
    }
}

private struct UpdateFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

private struct UpdateInstallReceipt: Codable {
    let releaseID: Int64
    let assetID: Int64
    let assetSHA256: String
    let commit: String
    let bundleRevision: String
    let destinationPath: String
}

private struct UpdateVersion: Comparable {
    let numbers: [UInt64]
    init?(_ string: String) {
        let text = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var numbers: [UInt64] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(piece) else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
}

// Exact-host allowlist, applied before the first request AND every redirect.
// CDN signed query parameters are permitted only on GitHub's asset hosts.
enum UpdateURLPolicy {
    static func validate(_ url: URL, api: Bool, initialAsset: Bool = false) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c"),
              !url.path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw AppUpdateError.unsafeURL("Update URLs must use HTTPS without credentials, fragments or path traversal.")
        }
        if api {
            guard host == "api.github.com", parts.query == nil,
                  url.path.hasPrefix("/repos/denizomer10/PearSilicon/") else {
                throw AppUpdateError.unsafeURL("Only the PearSilicon GitHub API is allowed.")
            }
        } else if host == "github.com" {
            guard url.path.hasPrefix("/denizomer10/PearSilicon/releases/download/"), parts.query == nil else {
                throw AppUpdateError.unsafeURL("Only PearSilicon release download URLs are allowed.")
            }
        } else {
            guard !initialAsset,
                  ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) else {
                throw AppUpdateError.unsafeURL("The update redirected outside GitHub's release asset hosts.")
            }
        }
    }
}

/// Streaming, content-based runtime identity. No mtime/version heuristic and no
/// whole-library Data allocations. Missing optional libraries are part of the
/// fingerprint, so their addition/removal also triggers a parent's refresh.
enum RuntimeRevision {
    static let componentNames = [
        "libPearRuntime.dylib", "libswiftUIKit.dylib", "libcxxcompat.dylib", "MarketplaceKit.framework"
    ]

    static func sha256(of file: URL) throws -> String {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppUpdateError.integrity("Cannot open file for hashing: \(file.lastPathComponent)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw AppUpdateError.integrity("Only regular files can be hashed.")
        }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw AppUpdateError.integrity("A file changed while it was being hashed.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Use the app's Contents/Resources for the supplied runtime and a game's
    /// Frameworks directory for the installed runtime. nil means no runtime.
    static func fingerprint(in directory: URL) throws -> String? {
        let runtime = directory.appendingPathComponent(componentNames[0])
        var status = stat()
        if lstat(runtime.path, &status) != 0 {
            if errno == ENOENT { return nil }
            throw AppUpdateError.integrity("Cannot inspect the installed runtime.")
        }
        var hasher = SHA256()
        func add(_ text: String) { hasher.update(data: Data(text.utf8)); hasher.update(data: Data([0])) }
        add("PearSilicon-runtime-revision-v1")
        for name in componentNames {
            let component = directory.appendingPathComponent(name)
            if lstat(component.path, &status) != 0 {
                guard errno == ENOENT else { throw AppUpdateError.integrity("Cannot inspect runtime component \(name).") }
                add(name); add("missing")
                continue
            }
            try UpdateTree.validate(component, maximumBytes: 2 * 1024 * 1024 * 1024, maximumEntries: 100_000)
            var items = [component]
            if status.st_mode & S_IFMT == S_IFDIR {
                guard let enumerator = FileManager.default.enumerator(at: component, includingPropertiesForKeys: nil) else {
                    throw AppUpdateError.integrity("Cannot enumerate runtime component \(name).")
                }
                while let item = enumerator.nextObject() as? URL { items.append(item) }
            }
            for item in items.sorted(by: { $0.path < $1.path }) {
                let relative = String(item.path.dropFirst(directory.path.count + 1))
                add(relative)
                switch try AppUpdateService.fileType(item) {
                case S_IFREG: add("file"); add(try sha256(of: item))
                case S_IFDIR: add("directory")
                case S_IFLNK: add("symlink"); add(try FileManager.default.destinationOfSymbolicLink(atPath: item.path))
                default: throw AppUpdateError.integrity("Unsupported runtime file type.")
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum UpdateTree {
    static func fingerprint(_ root: URL) throws -> String {
        try validate(root, maximumBytes: 2 * 1024 * 1024 * 1024, maximumEntries: 100_000)
        var items = [root]
        if try AppUpdateService.fileType(root) == S_IFDIR {
            var error: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, issue in
                error = issue
                return false
            }) else { throw AppUpdateError.operation("Cannot fingerprint the update bundle.") }
            while let item = enumerator.nextObject() as? URL { items.append(item) }
            if let error { throw error }
        }
        var hasher = SHA256()
        func add(_ value: String) { hasher.update(data: Data(value.utf8)); hasher.update(data: Data([0])) }
        for item in items.sorted(by: { $0.path < $1.path }) {
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw AppUpdateError.integrity("A bundle file disappeared while hashing.") }
            add(String(item.path.dropFirst(root.path.count)))
            add(String(info.st_mode & 0o177777))
            switch info.st_mode & S_IFMT {
            case S_IFREG: add(try RuntimeRevision.sha256(of: item))
            case S_IFLNK: add(try FileManager.default.destinationOfSymbolicLink(atPath: item.path))
            case S_IFDIR: break
            default: throw AppUpdateError.integrity("Unsupported bundle file type.")
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ root: URL, maximumBytes: Int64, maximumEntries: Int) throws {
        let base = root.resolvingSymlinksInPath().path
        var total: Int64 = 0
        var count = 0
        func inspect(_ item: URL) throws {
            count += 1
            var info = stat()
            guard count <= maximumEntries, lstat(item.path, &info) == 0 else {
                throw AppUpdateError.limitExceeded("The extracted update has too many entries or cannot be inspected.")
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                guard info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes - total else {
                    throw AppUpdateError.limitExceeded("The update contains hard links or exceeds the expanded size limit.")
                }
                total += info.st_size
            case S_IFDIR: break
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                let resolved = item.resolvingSymlinksInPath().path
                guard !target.hasPrefix("/"), !target.contains("\\"),
                      resolved.hasPrefix(base + "/"), FileManager.default.fileExists(atPath: resolved) else {
                    throw AppUpdateError.invalidArchive("The update contains an escaping or dangling symbolic link.")
                }
            default: throw AppUpdateError.invalidArchive("The update contains a special filesystem entry.")
            }
            guard info.st_mode & 0o6000 == 0 else { throw AppUpdateError.invalidArchive("Set-ID files are not allowed in updates.") }
        }
        try inspect(root)
        if try AppUpdateService.fileType(root) == S_IFDIR {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw AppUpdateError.operation("Cannot enumerate extracted update.") }
            while let item = enumerator.nextObject() as? URL { try inspect(item) }
            if let enumerationError { throw enumerationError }
        }
    }
}

private final class UpdateInstallLock {
    private var descriptor: Int32
    init(destination: URL) throws {
        let path = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).update.lock")
        descriptor = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppUpdateError.operation("Cannot acquire the app replacement lock.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw AppUpdateError.operation("Another replacement is active or the replacement lock is unsafe.")
        }
    }
    func release() { if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    deinit { release() }
}

private enum UpdateCommand {
    static func run(_ tool: String, _ arguments: [String], in directory: URL, timeout: TimeInterval) throws -> String {
        let output = directory.appendingPathComponent("tool-\(UUID().uuidString).log")
        let fd = open(output.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppUpdateError.operation("Cannot create the update tool log.") }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? log.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            var info = stat()
            let tooLarge = fstat(fd, &info) != 0 || info.st_size > 1024 * 1024
            if ContinuousClock.now >= deadline || tooLarge || Task<Never, Never>.isCancelled {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                try Task.checkCancellation()
                throw AppUpdateError.limitExceeded("\((tool as NSString).lastPathComponent) exceeded its time/output limit.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try log.seek(toOffset: 0)
        let data = try log.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw AppUpdateError.limitExceeded("Update tool output is too large.") }
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.operation("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)): \(text.prefix(4096))")
        }
        return text
    }
}

/// One serial delegate per transfer; the lock also covers task cancellation.
/// Bodies go straight to disk, and limits are enforced before each write.
private final class UpdateHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let maximumBytes: Int64
    private let timeout: TimeInterval
    private let isAPI: Bool
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var redirects = 0
    private var cancelled = false

    private init(request: URLRequest, destination: URL, maximumBytes: Int64, timeout: TimeInterval) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.timeout = timeout
        self.isAPI = request.url?.host == "api.github.com"
    }

    static func fetch(_ request: URLRequest, to destination: URL, maximumBytes: Int64, timeout: TimeInterval) async throws -> HTTPURLResponse {
        let transfer = UpdateHTTPTransfer(request: request, destination: destination, maximumBytes: maximumBytes, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(request, continuation: $0) }
        } onCancel: { transfer.cancel() }
    }

    private func start(_ request: URLRequest, continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        do {
            guard let url = request.url else { throw AppUpdateError.unsafeURL("Missing update URL.") }
            try UpdateURLPolicy.validate(url, api: isAPI, initialAsset: !isAPI)
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw AppUpdateError.operation("Cannot create the update download file.") }
            file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = min(timeout, 30)
            config.timeoutIntervalForResource = timeout
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.urlCredentialStorage = nil
            config.waitsForConnectivity = false
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session
            self.continuation = continuation
            var bounded = request
            bounded.timeoutInterval = min(timeout, 30)
            bounded.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            task = session.dataTask(with: bounded)
            task?.resume()
        } catch {
            try? file?.close()
            continuation.resume(throwing: error)
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        task?.cancel()
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        do {
            redirects += 1
            guard redirects <= 5, let url = request.url else { throw AppUpdateError.unsafeURL("Too many update redirects.") }
            try UpdateURLPolicy.validate(url, api: isAPI)
            // Reconstruct headers: never forward arbitrary credentials/cookies.
            var redirected = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(timeout, 30))
            redirected.setValue("PearSilicon-Update", forHTTPHeaderField: "User-Agent")
            redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            redirected.setValue(isAPI ? "application/vnd.github+json" : "application/octet-stream", forHTTPHeaderField: "Accept")
            completionHandler(redirected)
        } catch { failure = error; completionHandler(nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard let http = response as? HTTPURLResponse, let url = http.url else { throw AppUpdateError.integrity("Invalid update response.") }
            try UpdateURLPolicy.validate(url, api: isAPI)
            guard http.statusCode == 200 else { throw AppUpdateError.httpStatus(http.statusCode) }
            guard http.expectedContentLength <= maximumBytes else { throw AppUpdateError.limitExceeded("The update response exceeds its byte limit.") }
            if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
                throw AppUpdateError.integrity("Compressed HTTP update responses are not accepted.")
            }
            self.response = http
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard failure == nil, !cancelled else { dataTask.cancel(); return }
            guard Int64(data.count) <= maximumBytes - received else { throw AppUpdateError.limitExceeded("The update exceeded its download byte limit.") }
            try file?.write(contentsOf: data)
            received += Int64(data.count)
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let callback = continuation
        continuation = nil
        do { try file?.close() } catch { if failure == nil { failure = error } }
        file = nil
        let result: Result<HTTPURLResponse, Error>
        if cancelled { result = .failure(CancellationError()) }
        else if let failure = failure ?? error { result = .failure(failure) }
        else if let response { result = .success(response) }
        else { result = .failure(AppUpdateError.integrity("GitHub returned no update response.")) }
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        callback?.resume(with: result)
    }
}

/// ZIP admission happens BEFORE ditto. Rejects ambiguous names, special files,
/// hidden local records, alternate-path/link extra fields, ZIP64/multidisk,
/// overlapping entries, escaping/cyclic links and writes through link parents.
/// Every stream is also inflated with bounded memory to verify its actual size
/// and CRC, rather than trusting a ZIP bomb's advertised expanded size.
enum UpdateZIPArchive {
    struct Listing { let bundleName: String; let entryCount: Int; let expandedBytes: Int64 }
    private struct Entry {
        let name: String
        let key: String
        let directory: Bool
        let symlink: Bool
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressed: Int64
        let expanded: Int64
        let offset: UInt64
    }

    static func validate(at archive: URL, limits: AppUpdateService.Limits = .init()) throws -> Listing {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard limits.maximumDownloadBytes > 0, limits.maximumExpandedBytes > 0, limits.maximumArchiveEntries > 0 else {
            throw invalid("Invalid ZIP admission limits.")
        }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, offset <= length, UInt64(count) <= length - offset else { throw invalid("ZIP record lies outside the file.") }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw invalid("Truncated ZIP record.") }
            return data
        }
        guard length >= 22, length <= UInt64(limits.maximumDownloadBytes) else { throw invalid("Invalid ZIP size.") }
        let tailLength = Int(min(length, 65_557))
        let tail = try read(length - UInt64(tailLength), tailLength)
        // A signature in a ZIP comment is not an EOCD unless its length agrees.
        let possible = (0...(tail.count - 22)).reversed().first {
            tail.updateU32($0) == 0x06054b50 && $0 + 22 + Int(tail.updateU16($0 + 20)) == tail.count
        }
        guard let end = possible else { throw invalid("ZIP end record is missing.") }
        let count = Int(tail.updateU16(end + 10))
        let centralSize = UInt64(tail.updateU32(end + 12))
        let centralOffset = UInt64(tail.updateU32(end + 16))
        guard tail.updateU16(end + 4) == 0, tail.updateU16(end + 6) == 0,
              tail.updateU16(end + 8) == count, count > 0, count < 0xffff,
              count <= limits.maximumArchiveEntries,
              centralOffset + centralSize == length - UInt64(tailLength) + UInt64(end),
              centralSize <= 64 * 1024 * 1024 else { throw invalid("Unsupported ZIP64/multidisk or inconsistent ZIP directory.") }
        var entries: [Entry] = []
        var keys = Set<String>()
        var offset = centralOffset
        var expanded: Int64 = 0
        var bundleName: String?
        for _ in 0..<count {
            let header = try read(offset, 46)
            guard header.updateU32(0) == 0x02014b50 else { throw invalid("Invalid ZIP directory entry.") }
            let nameLength = Int(header.updateU16(28))
            let extraLength = Int(header.updateU16(30))
            let commentLength = Int(header.updateU16(32))
            let bytes = try read(offset + 46, nameLength)
            guard let rawName = String(data: bytes, encoding: .utf8) else { throw invalid("ZIP entry names must be UTF-8.") }
            let directory = rawName.hasSuffix("/")
            let name = directory ? String(rawName.dropLast()) : rawName
            try validateName(name)
            let components = name.split(separator: "/").map(String.init)
            let first = components[0] == "__MACOSX" ? (components.count > 1 ? components[1] : "") : components[0]
            if name != "__MACOSX" {
                guard first.hasSuffix(".app"), first != ".app", bundleName == nil || first == bundleName else {
                    throw invalid("The ZIP must contain exactly one top-level .app and its optional __MACOSX metadata.")
                }
                bundleName = first
            }
            let key = canonical(name)
            guard keys.insert(key).inserted else { throw invalid("Duplicate or case/Unicode-colliding ZIP paths.") }
            let mode = mode_t(header.updateU32(38) >> 16)
            let kind = mode & S_IFMT
            let symlink = kind == S_IFLNK
            guard [0, S_IFREG, S_IFDIR, S_IFLNK].contains(kind), mode & 0o6000 == 0,
                  (kind != S_IFDIR || directory), (!directory || kind == 0 || kind == S_IFDIR),
                  !symlink || components[0] != "__MACOSX", header.updateU16(34) == 0 else {
                throw invalid("Special files, set-ID files and metadata symlinks are not allowed.")
            }
            let flags = header.updateU16(8)
            let method = header.updateU16(10)
            let compressed = Int64(header.updateU32(20))
            let size = Int64(header.updateU32(24))
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  compressed != 0xffff_ffff, size != 0xffff_ffff,
                  size <= limits.maximumExpandedBytes - expanded,
                  !symlink || size <= 4096,
                  !directory || size == 0 else { throw invalid("Unsupported encryption/compression or excessive ZIP size.") }
            expanded += size
            try validateExtras(try read(offset + 46 + UInt64(nameLength), extraLength))
            entries.append(Entry(
                name: rawName, key: key, directory: directory, symlink: symlink, flags: flags, method: method,
                crc: header.updateU32(16), compressed: compressed, expanded: size, offset: UInt64(header.updateU32(42))
            ))
            offset += UInt64(46 + nameLength + extraLength + commentLength)
            guard offset <= centralOffset + centralSize else { throw invalid("ZIP directory overflow.") }
        }
        guard offset == centralOffset + centralSize, let bundleName else { throw invalid("The ZIP has no app bundle.") }
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        var existingPaths = keys
        for entry in entries {
            var parents = entry.key.split(separator: "/").map(String.init)
            parents.removeLast()
            while !parents.isEmpty {
                let parentKey = parents.joined(separator: "/")
                existingPaths.insert(parentKey)
                if let parent = byKey[parentKey], !parent.directory {
                    throw invalid("A ZIP entry writes through a file or symlink parent.")
                }
                parents.removeLast()
            }
        }
        var links: [String: String] = [:]
        var nextLocal: UInt64 = 0
        for entry in entries.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            guard entry.offset == nextLocal else { throw invalid("Overlapping, hidden or prepended ZIP records.") }
            let local = try read(entry.offset, 30)
            let nameLength = Int(local.updateU16(26))
            let extraLength = Int(local.updateU16(28))
            let name = try read(entry.offset + 30, nameLength)
            guard local.updateU32(0) == 0x04034b50, local.updateU16(6) == entry.flags,
                  local.updateU16(8) == entry.method, name == Data(entry.name.utf8) else {
                throw invalid("ZIP local and central records disagree.")
            }
            try validateExtras(try read(entry.offset + 30 + UInt64(nameLength), extraLength))
            let dataOffset = entry.offset + UInt64(30 + nameLength + extraLength)
            guard dataOffset <= centralOffset, UInt64(entry.compressed) <= centralOffset - dataOffset else { throw invalid("ZIP data overlaps its directory.") }
            let linkData = try validateStream(entry, handle: handle, offset: dataOffset)
            if entry.symlink {
                guard let target = String(data: linkData, encoding: .utf8), !target.isEmpty,
                      !target.hasPrefix("/"), !target.contains("\\"), !target.contains(":"),
                      !target.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                    throw invalid("Invalid symbolic link target.")
                }
                links[entry.key] = target
            }
            nextLocal = dataOffset + UInt64(entry.compressed)
            if entry.flags & 8 != 0 {
                var descriptor = try read(nextLocal, 12)
                if descriptor.updateU32(0) == 0x08074b50 {
                    nextLocal += 4
                    descriptor = try read(nextLocal, 12)
                }
                guard descriptor.updateU32(0) == entry.crc,
                      Int64(descriptor.updateU32(4)) == entry.compressed, Int64(descriptor.updateU32(8)) == entry.expanded else {
                    throw invalid("Invalid ZIP data descriptor.")
                }
                nextLocal += 12
            } else {
                guard local.updateU32(14) == entry.crc,
                      Int64(local.updateU32(18)) == entry.compressed, Int64(local.updateU32(22)) == entry.expanded else {
                    throw invalid("ZIP local sizes or CRC disagree.")
                }
            }
        }
        guard nextLocal == centralOffset else { throw invalid("Unlisted ZIP records precede the central directory.") }
        for (link, target) in links {
            try Task.checkCancellation()
            var components = link.split(separator: "/").map(String.init)
            components.removeLast()
            components += target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var stack: [String] = []
            var visited: Set<String> = [link]
            var index = 0
            while index < components.count {
                let component = components[index]
                index += 1
                if component == "." || component.isEmpty { continue }
                if component == ".." {
                    guard stack.count > 1 else { throw invalid("A ZIP symlink escapes the app bundle.") }
                    stack.removeLast()
                } else {
                    stack.append(component)
                    let key = canonical(stack.joined(separator: "/"))
                    if let nested = links[key] {
                        guard visited.insert(key).inserted, visited.count <= 64 else { throw invalid("Cyclic ZIP symlinks.") }
                        stack.removeLast()
                        components = stack + nested.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + components.dropFirst(index)
                        stack = []
                        index = 0
                    }
                }
            }
            guard stack.first == canonical(bundleName), !stack.isEmpty else { throw invalid("A ZIP symlink escapes the app bundle.") }
            let resolved = canonical(stack.joined(separator: "/"))
            guard existingPaths.contains(resolved) else {
                throw invalid("Dangling ZIP symlinks are not allowed.")
            }
        }
        return Listing(bundleName: bundleName, entryCount: count, expandedBytes: expanded)
    }

    private static func canonical(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    private static func validateName(_ name: String) throws {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.utf8.count <= 4096, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid("Unsafe ZIP entry path.") }
    }

    private static func validateExtras(_ extra: Data) throws {
        var offset = 0
        while offset < extra.count {
            guard extra.count - offset >= 4 else { throw invalid("Truncated ZIP extra field.") }
            let id = extra.updateU16(offset)
            let length = Int(extra.updateU16(offset + 2))
            // Timestamps/UIDs only. In particular, reject Unicode alternate
            // paths, PKWARE/ASi hardlinks and ZIP64 reinterpretations.
            guard [UInt16(0x5455), 0x7875, 0x5855, 0x000a].contains(id), length <= extra.count - offset - 4 else {
                throw invalid("Unsupported path/link/metadata ZIP extra field.")
            }
            offset += 4 + length
        }
    }

    private static func validateStream(_ entry: Entry, handle: FileHandle, offset: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        var remaining = entry.compressed
        var actual: Int64 = 0
        var crc: uLong = crc32(0, nil, 0)
        var link = Data()
        func consume(_ bytes: UnsafePointer<UInt8>, _ count: Int) throws {
            guard Int64(count) <= entry.expanded - actual else { throw invalid("ZIP data expands beyond its declared size.") }
            actual += Int64(count)
            crc = crc32(crc, bytes, uInt(count))
            if entry.symlink { link.append(bytes, count: count) }
        }
        if entry.method == 0 {
            guard entry.compressed == entry.expanded else { throw invalid("Invalid stored ZIP entry sizes.") }
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Int(min(remaining, 65_536))) ?? Data()
                guard !chunk.isEmpty else { throw invalid("Truncated ZIP payload.") }
                try chunk.withUnsafeBytes { try consume($0.baseAddress!.assumingMemoryBound(to: UInt8.self), chunk.count) }
                remaining -= Int64(chunk.count)
            }
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid("Cannot initialize ZIP inflation.") }
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: 65_536)
            var ended = false
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Int(min(remaining, 65_536))) ?? Data()
                guard !chunk.isEmpty, !ended else { throw invalid("Truncated or trailing ZIP deflate data.") }
                remaining -= Int64(chunk.count)
                try chunk.withUnsafeBytes { input in
                    stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    stream.avail_in = uInt(chunk.count)
                    repeat {
                        let before = stream.avail_in
                        let result = output.withUnsafeMutableBufferPointer { buffer in
                            stream.next_out = buffer.baseAddress
                            stream.avail_out = uInt(buffer.count)
                            return inflate(&stream, Z_NO_FLUSH)
                        }
                        let produced = output.count - Int(stream.avail_out)
                        guard result == Z_OK || result == Z_STREAM_END else { throw invalid("Invalid deflate stream in ZIP.") }
                        try output.withUnsafeBufferPointer { try consume($0.baseAddress!, produced) }
                        if result == Z_STREAM_END {
                            guard remaining == 0, stream.avail_in == 0 else { throw invalid("Trailing ZIP deflate data.") }
                            ended = true
                            break
                        }
                        guard produced > 0 || stream.avail_in < before else { throw invalid("ZIP inflation made no progress.") }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                }
            }
            guard ended else { throw invalid("Incomplete ZIP deflate stream.") }
        }
        guard actual == entry.expanded, UInt32(truncatingIfNeeded: crc) == entry.crc else { throw invalid("ZIP entry size or CRC verification failed.") }
        return link
    }

    private static func invalid(_ message: String) -> AppUpdateError { .invalidArchive(message) }
}

private extension Data {
    func updateU16(_ offset: Int) -> UInt16 {
        withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }
    func updateU32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}
