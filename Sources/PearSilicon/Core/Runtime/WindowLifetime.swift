import CoreGraphics
import Foundation

/// Tracks a launched application's last real window. Offscreen/minimized
/// windows count as open. Failed WindowServer reads never imply a close.
struct WindowLifetime {
    private var sawWindow = false
    private var emptySince: TimeInterval?

    mutating func shouldStop(hasWindow: Bool?, now: TimeInterval) -> Bool {
        guard let hasWindow else { emptySince = nil; return false }
        if hasWindow {
            sawWindow = true
            emptySince = nil
            return false
        }
        guard sawWindow else { return false }
        if emptySince == nil { emptySince = now }
        return now - emptySince! >= 2
    }

    static func hasWindow(ownedPIDs: Set<Int32>) -> Bool? {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return rows.contains { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32, ownedPIDs.contains(pid),
                  let layer = row[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return false }
            return width > 32 && height > 32
        }
    }
}
