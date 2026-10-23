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

    var executableURL: URL {
        bundleURL.appendingPathComponent(executableName)
    }
}
