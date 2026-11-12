import Foundation

/// A live Wine process may be a crash dialog. Only fresh, entry-local log
/// messages are considered; a previous launch's errors cannot fail this one.
struct WineStartupHealth: Sendable {
    let logURL: URL?
    let initialSize: UInt64
    let entryRoot: URL

    init(entry: LibraryEntry) {
        entryRoot = entry.directoryURL
        if entry.platform == .wine, entry.launchExecutableURL.lastPathComponent.lowercased() == "steam.exe" {
            logURL = entry.launchExecutableURL.deletingLastPathComponent().appendingPathComponent("bin/cef/cef.win64/debug.log")
        } else { logURL = nil }
        initialSize = logURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.uint64Value } ?? 0
    }
    func issues() -> [String] {
        guard let logURL, let file = try? ManagedAppFiles.regularFile(logURL, inside: entryRoot),
              let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end < initialSize ? 0 : initialSize
        guard end > start else { return [] }
        try? handle.seek(toOffset: max(start, end > 256 * 1024 ? end - 256 * 1024 : 0))
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("FATAL:target_services.cc") && text.contains("process_state_.InitCalled()") {
            return ["Steam's CEF storage service failed to initialize in this Wine build. A running process does not verify a working Steam window."]
        }
        return []
    }
}
