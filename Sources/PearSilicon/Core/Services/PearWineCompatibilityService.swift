import Foundation
import PearWineKit

enum WineCompatibilityFailure: LocalizedError {
    case identity(String)
    var errorDescription: String? { switch self { case .identity(let message): message } }
}

struct WineCompatibilityReport: Codable, Sendable {
    let engineID: String
    let assessment: PearWineAssessment?
    let signatureVerified: Bool
    let note: String

    var summary: String {
        guard let assessment else { return note }
        let cpu = assessment.executable.architecture
        if let runtime = assessment.runtime, !runtime.eligible { return "\(cpu): \(runtime.reasons.joined(separator: "; "))" }
        let profile = assessment.profile?.title ?? "No game-specific profile"
        return "\(cpu) • \(profile) • gameplay unverified"
    }
}

/// Reuses the pinned PearWine API; never interprets a proposal as permission to
/// run a game or to change graphics DLLs. Existing explicit launches remain the
/// execution boundary. Catalog CPU/OS checks gate only a verified known engine.
struct PearWineCompatibilityService: Sendable {
    let client: PearWineClient
    init(client: PearWineClient = PearWineClient()) { self.client = client }

    static func runtimeKey(for engine: WineEngine) -> String? {
        guard engine.distribution == .pearWine, engine.id == "pearwine-1.0.1",
              engine.isAppBundleRuntime else { return nil }
        return "pearwine-metalsharp-arm64@1.0.1"
    }

    func assess(_ entry: LibraryEntry, engine: WineEngine) throws -> WineCompatibilityReport {
        let executable = try WineInstallation.validatedLaunchURL(entry)
        let assessment = try client.assessment(executable: executable, runtime: Self.runtimeKey(for: engine),
                                               storage: entry.libraryRootURL.appendingPathComponent("Compatibility"))
        var verified = false
        if let known = assessment.runtime, let team = known.signing_team, let hash = known.cdhash {
            let bundle = engine.wineHome.deletingLastPathComponent()
            do {
                _ = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
                let signing = try Shell.run("/usr/bin/codesign", ["-dv", "--verbose=4", bundle.path])
                guard signing.split(separator: "\n").contains("TeamIdentifier=\(team)"),
                      signing.split(separator: "\n").contains("CDHash=\(hash)") else {
                    throw WineCompatibilityFailure.identity("Installed Wine differs from its PearWine registry identity. Reinstall the engine.")
                }
            } catch {
                throw WineCompatibilityFailure.identity("Wine signature identity check failed: " + error.localizedDescription)
            }
            verified = true
        }
        return WineCompatibilityReport(engineID: engine.id, assessment: assessment, signatureVerified: verified,
            note: verified ? "Registry identity verified; CPU/OS assessment only. No gameplay certification or graphics changes."
                           : "This engine has no verified registry binding. The current manual engine choice is retained.")
    }

    static func persist(_ report: WineCompatibilityReport, for entry: LibraryEntry) throws {
        let file = entry.dataURL.appendingPathComponent("pearwine-compatibility.json")
        if ManagedAppFiles.exists(file) { _ = try ManagedAppFiles.regularFile(file, inside: entry.dataURL) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: file, options: .atomic)
    }
}
