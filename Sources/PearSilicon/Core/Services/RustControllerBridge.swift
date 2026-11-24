import Darwin
import Foundation

struct RustControllerDeviceState: Codable, Equatable, Sendable {
    let leftX: Double
    let leftY: Double
    let rightX: Double
    let rightY: Double
    let l2: Double
    let r2: Double
    let gyroX: Double?
    let gyroY: Double?
    let gyroZ: Double?
    let accelX: Double?
    let accelY: Double?
    let accelZ: Double?
    let buttons: [String]
}

struct RustControllerDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: String
    let kindDisplay: String
    let transport: String
    let vendorId: Int
    let productId: Int
    let batteryPercent: Int?
    let latencyUs: UInt64
    let reportRateHz: UInt32
    let connected: Bool
    let enabled: Bool
    let rawHex: String?
    let state: RustControllerDeviceState
}

private struct RustControllerSnapshot: Codable {
    let revision: UInt64
    let lowLatencyMode: Bool
    let pollingHz: Int
    let joyconCombineMode: String
    let devices: [RustControllerDevice]
}

/// Bridges PearSilicon's Controller Settings & Keymapper to `libpear_controller.dylib`
/// (pure-Rust IOKit HID + CoreBluetooth Switch 2 Joy-Con engine).
@MainActor
final class RustControllerBridge: ObservableObject {
    @Published private(set) var engineLoaded = false
    @Published private(set) var devices: [RustControllerDevice] = []
    @Published private(set) var loadError: String?

    private typealias FnStart = @convention(c) (UnsafePointer<CChar>?) -> Bool
    private typealias FnStop = @convention(c) () -> Void
    private typealias FnRevision = @convention(c) () -> UInt64
    private typealias FnSetConfig = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias FnSetBleScan = @convention(c) (Bool) -> Void
    private typealias FnSnapshot = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias FnFreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias FnTestHaptics = @convention(c) () -> Void

    private var handle: UnsafeMutableRawPointer?
    private var fnStart: FnStart?
    private var fnStop: FnStop?
    private var fnRevision: FnRevision?
    private var fnSetConfig: FnSetConfig?
    private var fnSetBleScan: FnSetBleScan?
    private var fnSnapshot: FnSnapshot?
    private var fnFreeString: FnFreeString?
    private var fnTestHaptics: FnTestHaptics?
    private var pollTimer: Timer?
    private var lastRevision: UInt64 = 0

    func start(with settings: ControllerSettings, interval: TimeInterval = 1.0 / 15.0) {
        if !loadLibraryIfNeeded() {
            return
        }
        if let json = settings.encodedJSON() {
            _ = json.withCString { ptr in
                fnStart?(ptr)
            }
        } else {
            _ = fnStart?(nil)
        }
        startPolling(interval: interval)
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func applyConfig(_ settings: ControllerSettings) {
        guard engineLoaded, let json = settings.encodedJSON() else { return }
        json.withCString { ptr in
            fnSetConfig?(ptr)
        }
        lastRevision = 0
        refreshSnapshot()
    }

    func setBLEScan(_ enabled: Bool) {
        guard engineLoaded else { return }
        fnSetBleScan?(enabled)
    }

    func testHaptics() {
        guard engineLoaded else { return }
        fnTestHaptics?()
    }

    func refreshSnapshot() {
        guard engineLoaded, let fnSnapshot else { return }
        if let fnRevision {
            let rev = fnRevision()
            if rev != 0 && rev == lastRevision {
                return
            }
            lastRevision = rev
        }
        guard let cPtr = fnSnapshot() else { return }
        defer { fnFreeString?(cPtr) }
        let json = String(cString: cPtr)
        guard let data = json.data(using: .utf8),
              let snap = try? JSONDecoder().decode(RustControllerSnapshot.self, from: data) else {
            return
        }
        if snap.devices != devices {
            devices = snap.devices
        }
    }

    private func startPolling(interval: TimeInterval) {
        stopPolling()
        lastRevision = 0
        refreshSnapshot()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSnapshot()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func loadLibraryIfNeeded() -> Bool {
        if engineLoaded { return true }
        let fm = FileManager.default
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath {
            candidates.append((res as NSString).appendingPathComponent("PearHost/libpear_controller.dylib"))
            candidates.append((res as NSString).appendingPathComponent("libpear_controller.dylib"))
        }
        let cwd = fm.currentDirectoryPath
        candidates.append((cwd as NSString).appendingPathComponent("build/host/libpear_controller.dylib"))
        candidates.append((cwd as NSString).appendingPathComponent("runtime/build/host/libpear_controller.dylib"))
        candidates.append("/Users/mac/PearRuntime/build/host/libpear_controller.dylib")

        for path in candidates where fm.fileExists(atPath: path) {
            if let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                handle = h
                fnStart = dlsym(h, "pear_controller_start").map { unsafeBitCast($0, to: FnStart.self) }
                fnStop = dlsym(h, "pear_controller_stop").map { unsafeBitCast($0, to: FnStop.self) }
                fnRevision = dlsym(h, "pear_controller_revision").map { unsafeBitCast($0, to: FnRevision.self) }
                fnSetConfig = dlsym(h, "pear_controller_set_config_json").map { unsafeBitCast($0, to: FnSetConfig.self) }
                fnSetBleScan = dlsym(h, "pear_controller_set_ble_scan").map { unsafeBitCast($0, to: FnSetBleScan.self) }
                fnSnapshot = dlsym(h, "pear_controller_snapshot_json").map { unsafeBitCast($0, to: FnSnapshot.self) }
                fnFreeString = dlsym(h, "pear_controller_free_string").map { unsafeBitCast($0, to: FnFreeString.self) }
                fnTestHaptics = dlsym(h, "pear_controller_test_haptics").map { unsafeBitCast($0, to: FnTestHaptics.self) }
                if fnStart != nil && fnSnapshot != nil {
                    engineLoaded = true
                    loadError = nil
                    return true
                }
            }
        }
        loadError = "libpear_controller.dylib not found. Rebuild PearHost to enable pure-Rust controller detection."
        return false
    }
}
