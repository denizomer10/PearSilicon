import AppKit
import Foundation
// Stops only an isolated probe created by prepare-angle-game-probes.py.
guard CommandLine.arguments.count == 3, let index = Int(CommandLine.arguments[1]) else { exit(64) }
let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [[String: String]]
guard rows.indices.contains(index), let id = rows[index]["id"], id.hasSuffix(".angleprobe"), let path = rows[index]["bundle"] else { exit(65) }
let expected = URL(fileURLWithPath: path).resolvingSymlinksInPath()
for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
    guard app.bundleURL?.resolvingSymlinksInPath() == expected else { continue }
    print("Stopped isolated probe pid=\(app.processIdentifier) result=\(app.forceTerminate())")
}
