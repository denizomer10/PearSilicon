import Foundation

/// All user-facing strings. English only by design.
@MainActor
enum L10n {
    static let appName = "PearSilicon"

    // General
    static let ready = "Ready"
    static let library = "Library"
    static let settings = "Settings"
    static let search = "Search"
    static let install = "Install Package"
    static let launch = "Launch"
    static let uninstall = "Uninstall"
    static let revealInFinder = "Reveal in Finder"
    static let emptyLibrary = "Your library is empty. Click \"Install Package\" to add an app."
    static let noSelection = "Select an app"

    // Detail sections
    static let overview = "Overview"
    static let keymap = "Keymap"
    static let executable = "Executable"
    static let bundleID = "Bundle ID"
    static let version = "Version"
    static let minimumOS = "Minimum OS"
    static let path = "Path"
    static let installedAt = "Installed"

    // Keymap
    static let autoKeymap = "Auto Keymap"
    static let editKeymap = "Edit Keymap"
    static let resetKeymap = "Reset"
    static let addBinding = "Add Binding"
    static let noKeymap = "No keymap yet. Generate one automatically or add bindings manually."
    static let generateKeymap = "Generate"
    static let keyColumn = "Key"
    static let actionColumn = "Action"

    // Templates
    static func installing(_ name: String) -> String { "Installing: \(name)" }
    static func installed(_ name: String) -> String { "Installed: \(name)" }
    static func installedUnprepared(_ name: String) -> String {
        "Installed: \(name) — warning: some files could not be adapted for this platform, so the app may crash at launch."
    }
    static func installedCorrupted(_ name: String, files: [String]) -> String {
        let sample = files.prefix(3).joined(separator: ", ")
        let more = files.count > 3 ? " and \(files.count - 3) more" : ""
        return "Installed: \(name) — warning: \(files.count) file(s) failed their CRC check and may be damaged (\(sample)\(more)). Re-download the package if the app crashes."
    }
    static func launching(_ name: String) -> String { "Launching: \(name)" }
    static func removed(_ name: String) -> String { "Removed: \(name)" }
    static func error(_ message: String) -> String { "Error: \(message)" }
}
