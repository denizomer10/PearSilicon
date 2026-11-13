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
let log = manifest.deletingLastPathComponent().appendingPathComponent("\(index)-runtime.log")
if FileManager.default.fileExists(atPath: log.path) {
    let previous = log.deletingLastPathComponent().appendingPathComponent("\(index)-runtime-\(Int(Date().timeIntervalSince1970)).log")
    try FileManager.default.moveItem(at: log, to: previous)
}
let config = NSWorkspace.OpenConfiguration()
config.activates = false
config.createsNewApplicationInstance = true
var environment = [
 "PEAR_GRAPHICS_BACKEND":"angle",
 "PEAR_ANGLE_LIB_DIR":app.appendingPathComponent("Frameworks/PearANGLE").path,
 "DYLD_INSERT_LIBRARIES":app.appendingPathComponent("Frameworks/libPearRuntime.dylib").path,
 "DYLD_FRAMEWORK_PATH":"/System/iOSSupport/System/Library/Frameworks",
 "DYLD_LIBRARY_PATH":"/System/iOSSupport/usr/lib",
 "PEAR_SUPPORT_ROOT":manifest.deletingLastPathComponent().appendingPathComponent("support").path,
 "PEAR_HOME_DIR":home, "HOME":home, "CFFIXED_USER_HOME":home, "TMPDIR":home+"/tmp/",
 "PEAR_KEYCHAIN_DIR":home+"/Keychain", "PEAR_ODR_PATH":home+"/ODR",
 "PEAR_LOG_FILE":manifest.deletingLastPathComponent().appendingPathComponent("\(index)-runtime.log").path,
 "PEAR_DEBUG_GL":"1", "PEAR_DEBUG_VIEWS":"1", "PEAR_DEBUG_TOUCH":"1", "PEAR_DEBUG_METAL":"1",
 "PEAR_MOUSE_TOUCH":"1",
 "PEAR_NO_BACKGROUND_EXIT":"1"
]
// Mirror the normal launcher's compatibility selection, using the original
// game's saved overrides while keeping this probe's data directory isolated.
let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
let originalID = String(row["id"]!.dropLast(".angleprobe".count))
let defaults = UserDefaults(suiteName: "com.pearsilicon.app")!
let sdk = (info["DTSDKName"] as? String ?? "").replacingOccurrences(of: "iphoneos", with: "")
let sdkMajor = Int(sdk.split(separator: ".").first ?? "") ?? 0
let detectedLegacy = info["UIApplicationSceneManifest"] == nil && sdkMajor > 0 && sdkMajor < 15
let legacy = (defaults.object(forKey: "legacyBridge.enabled." + originalID) as? Bool) ?? detectedLegacy
if legacy {
    environment["PEAR_LEGACY_ATTACH_LAYER"] = "1"
    environment["PEAR_LEGACY_WINDOW_LAYER_ONLY"] = "1"
    environment["PEAR_DIRECT_LEGACY_TOUCH"] = "1"
    if let size = defaults.string(forKey: "legacyBridge.resolution." + originalID), size != "auto" {
        environment["PEAR_LEGACY_LOGICAL_SIZE"] = size
    }
}
environment["PEAR_ALLOW_POINTER_LOCK"] = index == 1 ? "1" : "0"
environment["PEAR_DEBUG_POINTER"] = "1"
if CommandLine.arguments.contains("--disable-device") { environment["PEAR_RUNTIME_DISABLE"] = "device" }
if CommandLine.arguments.contains("--no-fit") {
    environment["PEAR_NO_GL_FIT"] = "1"
    environment["PEAR_NO_GL_VIEWPORT_FIT"] = "1"
}
if CommandLine.arguments.contains("--legacy-identity") {
    environment["PEAR_DEVICE_MODEL"] = "iPhone6,1"
}
if CommandLine.arguments.contains("--wait-for-debugger") {
    let gate = app.appendingPathComponent("Frameworks/libPearProbeWait.dylib")
    guard FileManager.default.fileExists(atPath: gate.path) else { fatalError("Missing probe-only debugger gate") }
    environment["DYLD_INSERT_LIBRARIES"] = gate.path + ":" + environment["DYLD_INSERT_LIBRARIES"]!
    environment["PEAR_NO_SIGNAL_LOG"] = "1"
}
if CommandLine.arguments.contains("--trace-paths") {
    environment["PEAR_DEBUG_PATHS"] = "1"
    environment["PEAR_DEBUG_ALL_PATHS"] = "1"
    environment["PEAR_FS_LOG_FILE"] = manifest.deletingLastPathComponent().appendingPathComponent("\(index)-files.log").path
}
if CommandLine.arguments.contains("--native-window") {
    for key in ["PEAR_LEGACY_ATTACH_LAYER", "PEAR_LEGACY_WINDOW_LAYER_ONLY", "PEAR_DIRECT_LEGACY_TOUCH"] {
        environment.removeValue(forKey: key)
    }
}
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
