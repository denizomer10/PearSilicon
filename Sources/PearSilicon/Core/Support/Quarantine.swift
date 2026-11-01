import Darwin
import Foundation

/// Explicit, per-copy Gatekeeper quarantine handling. macOS attaches
/// `com.apple.quarantine` to files downloaded by browsers. Removing it from a
/// managed copy is a user decision, not something an importer should do silently.
enum Quarantine {
    static let attribute = "com.apple.quarantine"

    static func isQuarantined(_ url: URL) -> Bool {
        url.path.withCString { getxattr($0, attribute, nil, 0, 0, XATTR_NOFOLLOW) > 0 }
    }

    /// Removes the quarantine attribute from the selected managed tree only.
    /// Extended attributes that are not writable are reported rather than
    /// silently ignored.
    static func remove(from root: URL) throws {
        let root = LibraryPath.canonicalURL(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var failures: [String] = []
        var items = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: []
        ) {
            for case let item as URL in enumerator { items.append(item) }
        }
        for item in items {
            let result: Int32 = item.path.withCString { path in
                removexattr(path, attribute, XATTR_NOFOLLOW)
            }
            if result != 0, errno != ENOATTR {
                failures.append("\(item.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
        guard failures.isEmpty else {
            throw PearError.invalidPackage(
                "Could not remove the quarantine flag from every file: " + failures.prefix(3).joined(separator: ", ")
            )
        }
    }
}
