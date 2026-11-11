import Darwin
import Foundation

/// Gatekeeper runs a quarantined app that was not moved by Finder from a
/// randomized, read-only copy ("App Translocation"). Replacing that copy would
/// fail or update nothing, so the updater resolves the bundle the user really
/// launched. Security.framework exports the needed functions without a header.
enum AppTranslocation {
    private typealias IsTranslocated = @convention(c) (
        CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> DarwinBoolean
    private typealias OriginalPath = @convention(c) (
        CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    nonisolated(unsafe) private static let security: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    /// Whether `url` lies inside a translocation mount.
    static func isTranslocated(_ url: URL) -> Bool {
        guard let symbol = dlsym(security, "SecTranslocateIsTranslocatedURL") else {
            return url.path.contains("/AppTranslocation/")
        }
        let function = unsafeBitCast(symbol, to: IsTranslocated.self)
        var translocated = DarwinBoolean(false)
        guard function(url as CFURL, &translocated, nil).boolValue else {
            return url.path.contains("/AppTranslocation/")
        }
        return translocated.boolValue
    }

    /// The bundle the user launched: `url` itself unless it is translocated.
    /// Returns nil when a translocated URL cannot be resolved.
    static func originalURL(for url: URL) -> URL? {
        guard isTranslocated(url) else { return url }
        guard let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(symbol, to: OriginalPath.self)
        guard let original = function(url as CFURL, nil)?.takeRetainedValue() as URL? else { return nil }
        return original.standardizedFileURL
    }
}
