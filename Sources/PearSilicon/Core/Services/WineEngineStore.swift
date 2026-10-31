import CryptoKit
import Darwin
import Foundation

/// Engines are descriptors of a private, self-contained copy, not a shell
/// command or an environment-provided Wine installation. executablePath is
/// relative to rootURL. The store rebases rootURL when loading a moved store.
struct WineEngine: Codable, Hashable, Identifiable, Sendable {
    enum Distribution: String, Codable, Sendable {
        case gamePortingToolkit
        case community
    }

    static let manifestFilename = "pear-wine-engine.json"
    var id: String
    var name: String
    var version: String
    var rootURL: URL
    var executablePath: String
    var distribution: Distribution

    var executableURL: URL { rootURL.appendingPathComponent(executablePath) }

    func validate() throws {
        try LibraryPath.validateComponent(id)
        _ = try ManagedAppFiles.displayText(name)
        _ = try ManagedAppFiles.displayText(version)
        try LibraryPath.validateRelative(executablePath)
        guard executablePath.hasPrefix("Runtime/"), rootURL.lastPathComponent == id else {
            throw PearError.invalidPackage("Invalid self-contained Wine engine layout")
        }
        _ = try ManagedAppFiles.existingDirectory(rootURL)
        let runtime = rootURL.appendingPathComponent("Runtime", isDirectory: true)
        _ = try ManagedAppFiles.existingDirectory(runtime)
        try ManagedAppFiles.validateTree(runtime)
        let executable = try ManagedAppFiles.regularFile(executableURL, inside: runtime)
        // A shell wrapper may escape its package or use an ambient Wine. Select
        // the package's actual native wine/wine64 binary instead.
        try ManagedExecutable.validateMacOS(executable)
    }
}

/// Registration never executes an engine. There is intentionally no automatic
/// "latest GPTK", Apple-account login, license acceptance, or archive extractor.
struct WineEngineStore: Sendable {
    static let officialGPTKDownloadURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
    static let gptkDownloadNotice = "Download Game Porting Toolkit from Apple yourself and review/accept Apple's license. Choose its self-contained runtime directory and native Wine executable. PearSilicon does not fetch GPTK, claim a latest version, install Homebrew dependencies, or accept a license on your behalf."
    static let communityDownloadNotice = "Only download an engine from a URL you trust after reviewing its license. Supply an independently obtained SHA-256. A matching hash proves integrity, not publisher identity or safety. Downloads are saved as opaque archives; inspect/extract them manually and then register a self-contained runtime directory."
    static let defaultMaximumDownloadBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumAllowedDownloadBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    /// The transport must stream to the supplied, initially absent file and
    /// enforce maximumBytes before writing a chunk. Postflight also checks the
    /// size/hash/type. Injection permits focused tests without any real network.
    typealias Download = @Sendable (_ url: URL, _ destination: URL, _ maximumBytes: Int64) async throws -> Void

    let rootURL: URL
    private let download: Download

    init(rootURL: URL, download: @escaping Download = WineEngineStore.downloadHTTPS) {
        self.rootURL = rootURL
        self.download = download
    }

    /// Always copies the directory. No reference-in-place mode can accidentally
    /// launch or modify a user's existing installation. executablePath is
    /// relative to the selected source directory, e.g. bin/wine64.
    func registerLocalEngine(
        from source: URL, id: String, name: String, version: String,
        executablePath: String, distribution: WineEngine.Distribution = .community,
        licenseConfirmed: Bool
    ) throws -> WineEngine {
        guard licenseConfirmed else { throw PearError.invalidPackage("Review the engine's license and explicitly confirm it before registration") }
        try Self.validateID(id)
        _ = try ManagedAppFiles.displayText(name)
        _ = try ManagedAppFiles.displayText(version)
        try LibraryPath.validateRelative(executablePath)
        let source = try ManagedAppFiles.sourceDirectory(source)
        try ManagedAppFiles.rejectRecursiveCopy(source: source, root: rootURL)
        try ManagedAppFiles.validateTree(source)
        try ManagedExecutable.validateMacOS(try ManagedAppFiles.regularFile(
            source.appendingPathComponent(executablePath), inside: source
        ))
        var installed: WineEngine?
        _ = try ManagedAppFiles.install(root: rootURL, id: id) { stage, destination in
            let runtime = stage.appendingPathComponent("Runtime", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: runtime)
            try ManagedAppFiles.validateTree(runtime)
            try ManagedExecutable.validateMacOS(try ManagedAppFiles.regularFile(
                runtime.appendingPathComponent(executablePath), inside: runtime
            ))
            let engine = WineEngine(
                id: id, name: name, version: version, rootURL: destination,
                executablePath: "Runtime/\(executablePath)", distribution: distribution
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(engine).write(to: stage.appendingPathComponent(WineEngine.manifestFilename), options: .atomic)
            installed = engine
        }
        guard let installed else { throw PearError.invalidPackage("Wine engine transaction did not produce a descriptor") }
        return installed
    }

    /// Read-only, including for a store that has never been created. Malformed
    /// visible entries fail closed rather than becoming arbitrary launch paths.
    func engines() throws -> [WineEngine] {
        let root = try ManagedAppFiles.canonicalRoot(rootURL)
        guard ManagedAppFiles.exists(root) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try children.filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "Downloads" }
            .map { directory in
                _ = try ManagedAppFiles.existingDirectory(directory)
                let manifest = try ManagedAppFiles.regularFile(
                    directory.appendingPathComponent(WineEngine.manifestFilename), inside: directory
                )
                var engine = try JSONDecoder().decode(WineEngine.self, from: ManagedAppFiles.readSmallFile(manifest))
                try Self.validateID(engine.id)
                guard engine.id == directory.lastPathComponent else { throw PearError.invalidPackage("Wine engine ID does not match its directory") }
                // Never trust a persisted absolute path after a portable move.
                engine.rootURL = directory
                try engine.validate()
                return engine
            }.sorted { $0.id < $1.id }
    }

    func engine(id: String) throws -> WineEngine? {
        try Self.validateID(id)
        return try engines().first { $0.id == id }
    }

    /// Downloads *only* an opaque artifact, never extracts or executes it. No
    /// credentials/cookies or redirects are followed by the default transport.
    /// Caller confirmation is required for each request; it is not inferred
    /// from a previously accepted license for some other version.
    func downloadCommunityArchive(
        from url: URL, sha256: String, licenseConfirmed: Bool,
        maximumBytes: Int64 = WineEngineStore.defaultMaximumDownloadBytes
    ) async throws -> URL {
        guard licenseConfirmed else { throw PearError.invalidPackage("Explicit engine license confirmation is required before downloading") }
        try Self.validateDownloadURL(url)
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw PearError.invalidPackage("Supply the engine archive's full SHA-256 (64 hexadecimal digits)") }
        guard maximumBytes > 0, maximumBytes <= Self.maximumAllowedDownloadBytes else {
            throw PearError.invalidPackage("Engine download limit must be between 1 byte and 8 GiB")
        }
        let root = try ManagedAppFiles.canonicalRoot(rootURL)
        let madeRoot = !ManagedAppFiles.exists(root)
        if madeRoot { try ManagedAppFiles.makeDirectory(root) }
        let stage = root.appendingPathComponent(".pear-download-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stage)
            if madeRoot { _ = rmdir(root.path) }
        }
        try ManagedAppFiles.makeDirectory(stage)
        let stagedFile = stage.appendingPathComponent("artifact")
        try Task.checkCancellation()
        try await download(url, stagedFile, maximumBytes)
        try Task.checkCancellation()
        try ManagedAppFiles.rejectRootSymlink(stagedFile)
        let file = try ManagedAppFiles.regularFile(stagedFile, inside: stage)
        let reader = try ManagedBinaryReader(file)
        guard reader.size > 0, reader.size <= UInt64(maximumBytes) else {
            throw PearError.invalidPackage("Engine download is empty or exceeds the configured size limit")
        }
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < reader.size {
            try Task.checkCancellation()
            let count = Int(min(65_536, reader.size - offset))
            hasher.update(data: try reader.read(offset, count))
            offset += UInt64(count)
        }
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == sha256.lowercased() else { throw PearError.invalidPackage("Engine archive SHA-256 mismatch; download discarded") }
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        var madeDownloads = false
        if !ManagedAppFiles.exists(downloads) { try ManagedAppFiles.makeDirectory(downloads); madeDownloads = true }
        defer { if madeDownloads { _ = rmdir(downloads.path) } }
        _ = try ManagedAppFiles.existingDirectory(downloads)
        let destination = downloads.appendingPathComponent(actualHash + ".archive")
        guard renamex_np(file.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ManagedAppFiles.posix(destination)
        }
        return destination
    }

    private static func validateID(_ id: String) throws {
        try LibraryPath.validateComponent(id)
        guard !id.hasPrefix("."), id.caseInsensitiveCompare("Downloads") != .orderedSame else {
            throw PearError.invalidPackage("Wine engine identifier is reserved")
        }
    }

    private static func validateDownloadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw PearError.invalidPackage("An explicit HTTPS download URL without credentials or a fragment is required")
        }
    }

    private static func downloadHTTPS(_ url: URL, _ destination: URL, _ maximumBytes: Int64) async throws {
        try validateDownloadURL(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: EngineDownloadNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url else {
            throw PearError.invalidPackage("Engine download requires an HTTP 200 response from the exact requested URL; redirects are not followed")
        }
        guard response.expectedContentLength <= maximumBytes else { throw PearError.invalidPackage("Engine download exceeds the configured size limit") }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManagedAppFiles.posix(destination) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var count: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard count < maximumBytes else { throw PearError.invalidPackage("Engine download exceeds the configured size limit") }
            count += 1
            buffer.append(byte)
            if buffer.count == 65_536 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
    }
}

private final class EngineDownloadNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
