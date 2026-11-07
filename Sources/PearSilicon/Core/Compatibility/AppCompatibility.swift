import Foundation

/// Detected window/input needs of an installed iOS app.
///
/// The rule mirrors the runtime's `PearIsLegacyApp()`: an app is treated as
/// legacy when it has no UIKit scene manifest and was built with an SDK older
/// than iOS 15. Keeping both sides in sync means the manager only applies the
/// automatic bridges when the runtime will honour them.
struct AppCompatibility: Equatable, Sendable {
    /// True when Info.plist declares a `UIApplicationSceneManifest`.
    let usesSceneManifest: Bool
    /// Raw `DTSDKName` value, for display (for example `iphoneos10.3`).
    let sdkName: String?
    /// Parsed SDK major version, or `nil` when the value is missing/unreadable.
    let sdkMajor: Int?

    static let modern = AppCompatibility(usesSceneManifest: true, sdkName: nil, sdkMajor: nil)

    /// Older, scene-less apps need the window re-attach and direct touch bridge.
    var isLegacyRuntime: Bool {
        guard !usesSceneManifest, let sdkMajor else { return false }
        return sdkMajor > 0 && sdkMajor < 15
    }

    /// Short status shown in the detail pane.
    var summary: String {
        if isLegacyRuntime, let sdkMajor {
            return "Legacy UIKit app (iOS \(sdkMajor) SDK)"
        }
        if usesSceneManifest {
            return "Modern UIKit app with scenes"
        }
        return "Modern UIKit app"
    }

    /// One-line explanation of what the automatic bridge changes.
    var detail: String {
        if isLegacyRuntime {
            return "PearSilicon applies the window re-attach and mouse-to-touch bridge automatically."
        }
        return "The game handles its own window and mouse input; no compatibility bridge is applied."
    }

    // MARK: - Detection

    /// Reads the bundle's root `Info.plist`. Results are cached by path and
    /// modification date so SwiftUI re-renders do not re-read every plist.
    static func detect(bundleURL: URL) -> AppCompatibility {
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        let attributes = try? FileManager.default.attributesOfItem(atPath: plistURL.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(plistURL.path)|\(modified)"

        if let cached = cache.value(for: key) { return cached }

        var info: [String: Any] = [:]
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = plist as? [String: Any] {
            info = dictionary
        }
        let compatibility = make(from: info)
        cache.store(compatibility, for: key)
        return compatibility
    }

    static func make(from info: [String: Any]) -> AppCompatibility {
        let sdkName = info["DTSDKName"] as? String
        return AppCompatibility(
            usesSceneManifest: info["UIApplicationSceneManifest"] != nil,
            sdkName: sdkName,
            sdkMajor: sdkMajor(from: sdkName)
        )
    }

    /// `iphoneos10.3` → `10`, `macosx14.0` → `14`. Missing or malformed
    /// values return `nil`, which is treated as modern (no bridge).
    static func sdkMajor(from name: String?) -> Int? {
        guard let raw = name?.lowercased(), !raw.isEmpty else { return nil }
        let version: String
        if raw.hasPrefix("iphoneos") {
            version = String(raw.dropFirst("iphoneos".count))
        } else if raw.hasPrefix("macosx") {
            version = String(raw.dropFirst("macosx".count))
        } else {
            version = raw
        }
        guard let major = Int(version.split(separator: ".").first ?? "") else { return nil }
        return major
    }

    private static let cache = CompatibilityCache()
}

/// Small lock-protected cache; `AppCompatibility` is immutable.
private final class CompatibilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: AppCompatibility] = [:]

    func value(for key: String) -> AppCompatibility? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func store(_ value: AppCompatibility, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}
