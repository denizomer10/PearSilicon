import Foundation

/// A Windows executable found while importing a game folder.
struct WineExecutableCandidate: Identifiable, Hashable, Sendable {
    /// Path relative to the selected folder, using `/` separators.
    let path: String
    /// True when the heuristic is confident this is the game's main program.
    let isRecommended: Bool

    var id: String { path }
}

/// Finds likely game executables inside an imported folder without executing
/// anything. Wine entries must point at one concrete `.exe`; a game folder can
/// contain dozens (redistributables, crash reporters, updaters), so the importer
/// must not present an undifferentiated list.
enum WineExecutableDiscovery {
    /// Directory names that almost never contain the game program.
    private static let excludedDirectories: Set<String> = [
        "_commonredist", "commonredist", "redist", "redistributables", "installers",
        "installer", "support", "tools", "dxsetup", "dotnet", "vcredist"
    ]

    /// File-name fragments that identify installers/helpers rather than the game.
    private static let excludedNameFragments: [String] = [
        "unins", "uninstall", "setup", "install", "vcredist", "dxsetup", "dxwebsetup",
        "dotnet", "oalinst", "crash", "report", "updater", "update", "patcher",
        "config", "settings", "editor", "server", "benchmark", "diagnostic"
    ]

    /// Given a selected folder, returns executable candidates sorted from the
    /// most to the least likely main program. An empty result means the folder
    /// truly contains no `.exe`.
    static func candidates(in folder: URL, maximum: Int = 200) -> [WineExecutableCandidate] {
        let all = executablePaths(in: folder, maximum: maximum)
        guard !all.isEmpty else { return [] }

        let folderName = folder.lastPathComponent.lowercased()
        let scored = all.map { path -> (path: String, score: Int, excluded: Bool) in
            let components = path.split(separator: "/").map { $0.lowercased() }
            let name = components.last.map { String($0) } ?? ""
            let base = name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
            var score = 0
            var excluded = false

            if components.dropLast().contains(where: { component in
                excludedDirectories.contains(component)
                    || component.hasPrefix("_")
                    || component == "redist"
            }) {
                excluded = true
            }
            if excludedNameFragments.contains(where: { base.contains($0) }) {
                excluded = true
            }
            if base == folderName {
                score += 100
            } else if folderName.contains(base) || base.contains(folderName) {
                score += 35
            }
            if ["game", "play", "start", "launcher"].contains(where: { base.contains($0) }) {
                score += 15
            }
            // Shallower programs are more likely the title's entry point.
            score -= max(0, components.count - 1) * 20
            return (path, score, excluded)
        }

        let plausible = scored.filter { !$0.excluded }
        let pool = plausible.isEmpty ? scored : plausible
        let sorted = pool.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        guard let best = sorted.first else { return [] }
        let clearlyBest = !plausible.isEmpty
            && (sorted.count == 1
                || (sorted.dropFirst().first.map { best.score - $0.score >= 15 } ?? true))
        return sorted.map {
            WineExecutableCandidate(
                path: $0.path,
                isRecommended: clearlyBest && $0.path == best.path
            )
        }
    }

    private static func executablePaths(in folder: URL, maximum: Int) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let root = folder.standardizedFileURL.path
        var result: [String] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            result.append(String(full.dropFirst(root.count + 1)))
            if result.count >= maximum { break }
        }
        return result
    }
}
