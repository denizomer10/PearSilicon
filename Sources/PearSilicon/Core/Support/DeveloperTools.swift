import Foundation

/// Whether a full development toolchain is available, and which developer
/// directory is active.
///
/// The compatibility runtime needs only the macOS SDK and its iOSSupport
/// frameworks, so the Command Line Tools are enough for `runtime/build.sh`.
/// The GUI and the project build commands need the full toolchain because the
/// SwiftUI macro plugins ship with it.
enum DeveloperTools {

    enum ToolchainStatus: Equatable, Sendable {
        /// A full toolchain is selected as the active developer directory.
        case ready
        /// The full toolchain is installed, but the selector points at the
        /// command-line tools (or another incomplete installation).
        case installedButNotSelected(toolchainPath: String, activePath: String?)
        /// No full toolchain was found in the usual locations and none is
        /// selected.
        case missing

        var isReady: Bool { self == .ready }
    }

    /// Output of the platform's developer-directory selector.
    static func activeDeveloperDirectory() -> String? {
        guard let output = try? Shell.run("/usr/bin/xcode-select", ["-p"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The first complete toolchain found in the standard application
    /// locations. Discovery is by structure (`Contents/Developer`), not by a
    /// product name, so a renamed installation still works.
    static func installedToolchainPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        // An explicitly selected toolchain always wins, even from a custom
        // location.
        if let active = activeDeveloperDirectory(),
           let range = active.range(of: ".app/Contents/Developer") {
            candidates.append(String(active[..<range.upperBound]))
        }

        for directory in ["/Applications", "\(home)/Applications"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for item in items where item.hasSuffix(".app") {
                candidates.append("\(directory)/\(item)")
            }
        }

        return candidates.first {
            FileManager.default.fileExists(atPath: "\($0)/Contents/Developer")
        }
    }

    static func toolchainStatus() -> ToolchainStatus {
        status(activePath: activeDeveloperDirectory(), installedPath: installedToolchainPath())
    }

    /// Pure form of `toolchainStatus()`, so the decision can be tested without
    /// touching the machine's developer directory.
    static func status(activePath: String?, installedPath: String?) -> ToolchainStatus {
        if let activePath, activePath.contains(".app/Contents/Developer") {
            return .ready
        }
        if let installedPath {
            return .installedButNotSelected(toolchainPath: installedPath, activePath: activePath)
        }
        return .missing
    }

    /// Shell command that selects a full toolchain installation.
    static func selectCommand(for toolchainPath: String) -> String {
        "sudo xcode-select -s \"\(toolchainPath)/Contents/Developer\""
    }

    /// Whether `runtime/build.sh` can run with the active developer directory.
    /// It only needs the macOS SDK's iOSSupport frameworks, which the Command
    /// Line Tools also provide.
    static func runtimeBuildAvailable() -> Bool {
        guard let output = try? Shell.run(
            "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]
        ) else { return false }
        let sdk = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sdk.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: "\(sdk)/System/iOSSupport/System/Library/Frameworks"
        )
    }
}
