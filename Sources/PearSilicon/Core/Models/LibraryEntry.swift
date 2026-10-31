import Darwin
import Foundation

/// On-disk names are part of the portable library format, not localized UI labels.
enum LibraryPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case iOS = "ios-apps"
    case macOS = "mac-apps"
    case wine = "wine-apps"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .iOS: "iOS Apps"
        case .macOS: "Mac Apps"
        case .wine: "Wine Games"
        }
    }
    var symbol: String {
        switch self {
        case .iOS: "iphone"
        case .macOS: "desktopcomputer"
        case .wine: "gamecontroller"
        }
    }
}

struct LibraryManifest: Codable, Hashable, Sendable {
    static let filename = "pear-app.json"
    var formatVersion: Int = 1
    var id: String
    var platform: LibraryPlatform
    var displayName: String
    var version: String
    /// Bundle (iOS/macOS) or Windows executable, relative to the entry directory.
    var payloadPath: String
    var createdAt: Date = Date()
    var wineEngineID: String? = nil
    var metalHUDEnabled: Bool = false
    var runtimeRevision: String? = nil
    /// Used only for rebasing iOS absolute load commands after a library is moved.
    var preparedDirectoryPath: String? = nil
}

struct LibraryEntry: Identifiable, Hashable, Sendable {
    var manifest: LibraryManifest
    let directoryURL: URL

    var id: String { directoryURL.standardizedFileURL.path }
    var platform: LibraryPlatform { manifest.platform }
    var displayName: String { manifest.displayName }
    var payloadURL: URL { directoryURL.appendingPathComponent(manifest.payloadPath) }
    var dataURL: URL { directoryURL.appendingPathComponent("Data", isDirectory: true) }
    var prefixURL: URL { directoryURL.appendingPathComponent("Prefix", isDirectory: true) }
    var libraryRootURL: URL { directoryURL.deletingLastPathComponent().deletingLastPathComponent() }
    var manifestURL: URL { directoryURL.appendingPathComponent(LibraryManifest.filename) }
}

/// All external manifests and archive paths cross this admission boundary.
enum LibraryPath {
    static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 200,
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PearError.invalidPackage("Unsafe library identifier")
        }
    }

    static func validateRelative(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PearError.invalidPackage("Unsafe relative library path")
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PearError.invalidPackage("Unsafe relative library path")
        }
    }

    static func canonicalPath(_ url: URL) -> String {
        // POSIX realpath keeps the canonical /private/var form. Foundation's
        // resolvingSymlinksInPath can rewrite an existing /private/var path back
        // to /var, which makes otherwise identical managed paths compare unequal.
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: canonicalPath(url))
    }

    static func isInside(_ child: URL, root: URL) -> Bool {
        let rootPath = canonicalPath(root)
        let childPath = canonicalPath(child)
        return childPath.hasPrefix(rootPath + "/")
    }

    static func validate(_ manifest: LibraryManifest, directory: URL) throws {
        guard manifest.formatVersion == 1 else {
            throw PearError.invalidPackage("Unsupported PearSilicon library format")
        }
        try validateComponent(manifest.id)
        try validateRelative(manifest.payloadPath)
        guard isInside(directory.appendingPathComponent(manifest.payloadPath), root: directory) else {
            throw PearError.invalidPackage("Application payload escapes its library entry")
        }
    }
}
