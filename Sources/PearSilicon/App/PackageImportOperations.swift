import Foundation

/// The GUI's package boundary, injectable without launching apps or preparing real bundles.
@MainActor
struct PackageImportOperations {
    var installArchive: (URL) async throws -> InstalledApp
    var installBundle: (URL) async throws -> InstalledApp
    var startAccessing: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stopAccessing: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }

    static func live(installer: PackageInstaller) -> Self {
        Self(
            installArchive: { try await installer.install(packageAt: $0) },
            installBundle: { try await installer.installBundle(at: $0) }
        )
    }

    func install(at url: URL) async throws -> InstalledApp {
        let localHost = url.host == nil || url.host?.lowercased() == "localhost"
        guard url.isFileURL, localHost else { throw PackageImportError.unsupportedInput }
        let install: (URL) async throws -> InstalledApp
        switch url.pathExtension.lowercased() {
        case "ipa":
            install = installArchive
        case "app":
            install = installBundle
        default:
            throw PackageImportError.unsupportedInput
        }

        // A security-scoped URL must stay accessible for the whole async import,
        // and the stop must only be paired with a successful start.
        let scoped = startAccessing(url)
        defer { if scoped { stopAccessing(url) } }
        return try await install(url)
    }
}

enum PackageImportError: LocalizedError {
    case unsupportedInput

    var errorDescription: String? {
        "PearSilicon only accepts a local .ipa archive or .app bundle."
    }
}
