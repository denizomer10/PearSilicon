// Compatibility stub for the pre-iOS 26 public MarketplaceKit surface that
// store builds link against. The host ships the framework as resources only,
// so without a binary dyld cannot satisfy the weak references and aborts
// while registering Swift metadata.
//
// The declarations mirror the framework's Swift interface, including the
// throwing async `current` getter: a non-throwing implementation leaves the
// caller's error slot undefined, which crashes the process. Distribution
// channels are reported as `other`; the runtime never simulates a marketplace
// or a purchase. `TransactionReporting` is deliberately absent: generating a
// reporting token without a real transaction would fabricate one.

public enum AppDistributor {
    case appStore
    case testFlight
    case marketplace(String)
    case web
    case other

    public static var current: AppDistributor {
        get async throws { .other }
    }

    /// The interface gates this property on iOS 26.4. It is exported
    /// unconditionally so a newer client can link, and reports no region.
    public static var eligibilityRegion: String? {
        get async { nil }
    }
}

public enum MarketplaceKitError: Error, CustomStringConvertible, Sendable, Codable, Equatable, Hashable {
    case unsupportedPlatform

    public var description: String {
        "Marketplace features are unavailable on this platform."
    }
}

public let MarketplaceKitURIScheme = "marketplacekit"
