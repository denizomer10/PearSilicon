import Darwin
import Foundation
import PearDebugKit

/// PearSilicon's view of a Wine entry's processes. Finding them is PearDebug's
/// `WineProcesses` (shared with `peardebug wine ps`); this adds the entry and
/// engine specifics: which folders belong to an entry and how its engine stops
/// a prefix.
enum WinePrefixProcesses {
    typealias Member = WineProcesses.Member

    static func target(for entry: LibraryEntry) -> WineProcesses.Target {
        WineProcesses.Target(id: entry.id, root: entry.directoryURL, prefix: entry.prefixURL)
    }

    /// Processes of each Wine entry, keyed by entry ID. One scan of the process table.
    static func scan(_ entries: [LibraryEntry]) -> [String: [Member]] {
        WineProcesses.scan(entries.filter { $0.platform == .wine }.map(target(for:)))
    }

    /// Whether a Windows program (not just Wine's services) is running.
    static func hasProgram(_ members: [Member]?) -> Bool { WineProcesses.hasProgram(members) }

    static func serverDirectory(for prefix: URL) -> String? { WineProcesses.serverDirectory(for: prefix) }

    /// Force-quits everything in the entry's prefix: `wineserver -k9` through
    /// the engine (SIGKILL to every client), then SIGKILL to whatever is left,
    /// including orphans and the wineserver. Returns the processes still alive.
    @discardableResult
    static func forceStop(_ entry: LibraryEntry, engine: WineEngine?, timeout: Duration = .seconds(5)) async -> [Member] {
        if let engine {
            let server = engine.executableURL.deletingLastPathComponent().appendingPathComponent("wineserver")
            if FileManager.default.isExecutableFile(atPath: server.path) {
                let kill = Process()
                kill.executableURL = server
                kill.arguments = ["-k9"]
                kill.environment = ManagedAppService.environment(for: entry, engine: engine)
                kill.standardOutput = FileHandle.nullDevice
                kill.standardError = FileHandle.nullDevice
                if (try? kill.run()) != nil {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while kill.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                    if kill.isRunning { kill.terminate() }
                }
            }
        }
        return await WineProcesses.kill(target(for: entry), timeout: timeout)
    }
}
