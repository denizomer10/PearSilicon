import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    /// Bundle identifier (ör. com.example.app)
    let id: String
    let displayName: String
    let bundleName: String
    let shortVersion: String
    let bundleVersion: String
    let minimumOSVersion: String?
    /// Disk üzerindeki .app klasörü.
    let bundleURL: URL
    /// Info.plist'teki CFBundleExecutable
    let executableName: String
    /// PNG ikonun bulunduğu yol (varsa).
    let iconURL: URL?
    let installedAt: Date
    /// The executable is 32-bit (armv7), so macOS cannot load it and it runs
    /// inside PearLegacyEngine instead of the Catalyst runtime.
    var isLegacy32Bit: Bool = false

    var executableURL: URL {
        bundleURL.appendingPathComponent(executableName)
    }
}
