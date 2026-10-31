import Foundation
import XCTest
@testable import PearSilicon

/// Exercises the managed Wine launch path with a tiny native fake "wine"
/// executable and a minimal PE program. It verifies prefix bootstrap, sandboxed
/// spawn, process ownership and shutdown. It does not run a real Windows game
/// or prove compatibility with any particular game.
@MainActor
final class ManagedWineLaunchSmokeTests: XCTestCase {

    func testFakeWineBootstrapsAPrivatePrefixLaunchesAndStops() async throws {
        let clang = "/usr/bin/clang"
        guard FileManager.default.isExecutableFile(atPath: clang) else {
            throw XCTSkip("clang is not available")
        }
        let root = URL(fileURLWithPath: try Self.realPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("pear-wine-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engineSource = root.appendingPathComponent("EngineSource/bin", isDirectory: true)
        let gameSource = root.appendingPathComponent("GameSource", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: engineSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gameSource, withIntermediateDirectories: true)

        let source = engineSource.appendingPathComponent("wine64.c")
        try Data("""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            const char *prefix = getenv("WINEPREFIX");
            if (!prefix) return 2;
            char path[4096];
            snprintf(path, sizeof(path), "%s/system.reg", prefix);
            FILE *f = fopen(path, "w");
            if (f) { fputs("WINE REGISTRY Version 2\\n", f); fclose(f); }
            if (argc > 1 && strstr(argv[1], "wineboot")) return 0;
            sleep(30);
            return 0;
        }
        """.utf8).write(to: source)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: clang)
        compile.arguments = ["-O0", "-o", engineSource.appendingPathComponent("wine64").path, source.path]
        let pipe = Pipe()
        compile.standardOutput = pipe
        compile.standardError = pipe
        try compile.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw XCTSkip("Could not compile the fake Wine engine: \(String(decoding: output, as: UTF8.self))")
        }

        let engine = try WineEngineStore(rootURL: root.appendingPathComponent("Engines"))
            .registerLocalEngine(
                from: root.appendingPathComponent("EngineSource"), id: "fake-wine",
                name: "Fake Wine", version: "test", executablePath: "bin/wine64",
                licenseConfirmed: true
            )
        XCTAssertEqual(engine.distribution, .community)

        try Self.minimalPE().write(to: gameSource.appendingPathComponent("Game.exe"))
        let entry = try ManagedAppService().importWindowsFolder(
            from: gameSource, executablePath: "Game.exe",
            libraryRoot: library, engineID: engine.id, displayName: "Smoke Game"
        )

        let process = try await ManagedAppService().launch(entry, engine: engine, activate: false)
        defer { process.stop() }
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entry.prefixURL.appendingPathComponent("system.reg").path
        ))
        // The engine-created host mappings must have been removed from the prefix.
        let dosdevices = entry.prefixURL.appendingPathComponent("dosdevices")
        if let links = try? FileManager.default.contentsOfDirectory(atPath: dosdevices.path) {
            XCTAssertFalse(links.contains { $0.lowercased() == "z:" })
        }

        process.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(process.isRunning)
    }

    /// Minimal PE32+ console/executable image accepted by the admission check.
    private static func minimalPE() -> Data {
        var data = Data(count: 1_024)
        func set16(_ value: UInt16, _ offset: Int) {
            data[offset] = UInt8(value & 0xff)
            data[offset + 1] = UInt8((value >> 8) & 0xff)
        }
        func set32(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
        }
        data[0] = 0x4d
        data[1] = 0x5a
        set32(64, 60)
        data.replaceSubrange(64..<68, with: Data([0x50, 0x45, 0, 0]))
        set16(0x8664, 68)       // machine
        set16(1, 70)            // sections
        set16(240, 84)          // optional header size
        set16(0x0022, 86)       // executable, not a DLL
        let optional = 88
        set16(0x20b, optional)  // PE32+
        set16(2, optional + 68) // GUI subsystem
        set32(0, optional + 108) // data directories
        set32(368, optional + 60) // SizeOfHeaders
        let section = 64 + 24 + 240
        set32(16, section + 16)  // SizeOfRawData
        set32(512, section + 20) // PointerToRawData
        return data
    }

    private static func realPath(_ url: URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
