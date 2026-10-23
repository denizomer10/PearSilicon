import Foundation

/// Whether a full Xcode is available, and which developer directory is active.
///
/// PearSilicon itself runs without Xcode, but its tooling does not: building
/// the runtime needs the Catalyst SDK, and `pearsilicon xcode` /
/// `./scripts/build-app.sh` need `xcodebuild` and the SwiftUI macro plugins that
/// ship with Xcode rather than the Command Line Tools.
enum DeveloperTools {

    enum XcodeStatus: Equatable, Sendable {
        /// A full Xcode is selected as the active developer directory.
        case ready
        /// Xcode is installed, but `xcode-select` points at the Command Line
        /// Tools (or another non-Xcode toolchain).
        case installedButNotSelected(xcodePath: String, activePath: String?)
        /// No Xcode.app was found in the usual locations and none is selected.
        case missing

        var isReady: Bool { self == .ready }
    }

    /// Store page for Xcode.
    static let xcodeStoreURL = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!

    /// Output of `xcode-select -p`, e.g. `/Applications/Xcode.app/Contents/Developer`.
    static func activeDeveloperDirectory() -> String? {
        guard let output = try? Shell.run("/usr/bin/xcode-select", ["-p"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The first Xcode installation found in the standard locations.
    static func installedXcodePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/Xcode.app",
            "/Applications/Xcode-beta.app",
            "\(home)/Applications/Xcode.app",
            "\(home)/Applications/Xcode-beta.app",
        ]

        // An explicitly selected Xcode always wins, even from a custom location.
        if let active = activeDeveloperDirectory(),
           let range = active.range(of: ".app/Contents/Developer") {
            candidates.insert(String(active[..<range.upperBound]), at: 0)
        }

        return candidates.first {
            FileManager.default.fileExists(atPath: "\($0)/Contents/Developer")
        }
    }

    static func xcodeStatus() -> XcodeStatus {
        status(activePath: activeDeveloperDirectory(), installedPath: installedXcodePath())
    }

    /// Pure form of `xcodeStatus()`, so the decision can be tested without
    /// touching the machine's developer directory.
    static func status(activePath: String?, installedPath: String?) -> XcodeStatus {
        if let activePath, activePath.contains(".app/Contents/Developer") {
            return .ready
        }
        if let installedPath {
            return .installedButNotSelected(xcodePath: installedPath, activePath: activePath)
        }
        return .missing
    }

    /// Shell command that selects an Xcode installation.
    static func selectCommand(for xcodePath: String) -> String {
        "sudo xcode-select -s \"\(xcodePath)/Contents/Developer\""
    }
}
