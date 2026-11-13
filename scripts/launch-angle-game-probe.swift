import AppKit
import Foundation
// Launches only an explicitly prepared isolated test, without activation.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
guard CommandLine.arguments.count >= 2, let index = Int(CommandLine.arguments[1]) else {
    print("usage: swift scripts/launch-angle-game-probe.swift <0|1> [games.json]"); exit(64)
}
let manifest = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : root.appendingPathComponent("build/angle-game-tests/games.json")
let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [[String:String]]
guard rows.indices.contains(index) else { print("Test index out of range"); exit(64) }
let row = rows[index]
guard let id = row["id"], id.hasSuffix(".angleprobe"), NSRunningApplication.runningApplications(withBundleIdentifier:id).isEmpty else {
    print("Refusing a non-test bundle or an already running test"); exit(65)
}
let app = URL(fileURLWithPath: row["bundle"]!)
let home = row["home"]!
let config = NSWorkspace.OpenConfiguration()
config.activates = false
config.createsNewApplicationInstance = true
var environment = [
 "PEAR_GRAPHICS_BACKEND":"angle",
 "PEAR_ANGLE_LIB_DIR":root.appendingPathComponent("runtime/third_party/angle/out/PearMetal").path,
 "DYLD_INSERT_LIBRARIES":app.appendingPathComponent("Frameworks/libPearRuntime.dylib").path,
 "DYLD_FRAMEWORK_PATH":"/System/iOSSupport/System/Library/Frameworks",
 "DYLD_LIBRARY_PATH":"/System/iOSSupport/usr/lib",
 "PEAR_SUPPORT_ROOT":manifest.deletingLastPathComponent().appendingPathComponent("support").path,
 "PEAR_HOME_DIR":home, "HOME":home, "CFFIXED_USER_HOME":home, "TMPDIR":home+"/tmp/",
 "PEAR_KEYCHAIN_DIR":home+"/Keychain", "PEAR_ODR_PATH":home+"/ODR",
 "PEAR_LOG_FILE":manifest.deletingLastPathComponent().appendingPathComponent("\(index)-runtime.log").path,
 "PEAR_DEBUG_GL":"1", "PEAR_DEBUG_TOUCH":"1", "PEAR_DEBUG_METAL":"1",
 "PEAR_MOUSE_TOUCH":"1",
 "PEAR_NO_BACKGROUND_EXIT":"1"
]
environment["PEAR_ALLOW_POINTER_LOCK"] = index == 1 ? "1" : "0"
environment["PEAR_DEBUG_POINTER"] = "1"
config.environment = environment
var finished = false
NSWorkspace.shared.openApplication(at: app, configuration: config) { running, error in
 if let running, running.processIdentifier > 0 {
  print("Started isolated \(row["label"]!) pid=\(running.processIdentifier)")
  try? "\(running.processIdentifier)\n".write(to: manifest.deletingLastPathComponent().appendingPathComponent("\(index).pid"), atomically: true, encoding: .utf8)
 } else { print("Launch failed: \(String(describing:error))") }
 finished=true
}
while !finished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
