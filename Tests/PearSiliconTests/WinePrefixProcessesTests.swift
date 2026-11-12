import Darwin
import Foundation
import XCTest
@testable import PearSilicon

final class WinePrefixProcessesTests: XCTestCase {
    private func wineEntry(_ f: ManagedAppTestFixture) throws -> LibraryEntry {
        let source = f.root.appendingPathComponent("Game.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        return try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: f.library, engineID: "metalsharp-6.0")
    }

    /// A real process, started like a Windows program: working directory inside the entry.
    private func spawn(in directory: URL) throws -> Process {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.currentDirectoryURL = directory
        try process.run()
        return process
    }

    func testFindsEveryProcessOfTheEntryAndForceStopsThem() async throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try wineEntry(f)
        let other = try ManagedAppTestFixture(name: "other"); defer { other.remove() }
        let otherEntry = try wineEntry(other)
        let game = try spawn(in: entry.payloadURL.deletingLastPathComponent())
        let orphanLike = try spawn(in: entry.prefixURL.appendingPathComponent("drive_c/Program Files/Launcher"))
        let unrelated = try spawn(in: otherEntry.prefixURL.appendingPathComponent("drive_c"))
        defer { for p in [game, orphanLike, unrelated] where p.isRunning { p.terminate() } }

        let scan = WinePrefixProcesses.scan([entry, otherEntry])
        XCTAssertEqual(Set(scan[entry.id]?.map(\.pid) ?? []), [game.processIdentifier, orphanLike.processIdentifier])
        XCTAssertEqual(scan[otherEntry.id]?.map(\.pid), [unrelated.processIdentifier])
        XCTAssertTrue(WinePrefixProcesses.hasProgram(scan[entry.id]))

        // No engine is needed to stop what is left; only this entry is touched.
        let left = await WinePrefixProcesses.forceStop(entry, engine: nil)
        XCTAssertEqual(left, [])
        game.waitUntilExit(); orphanLike.waitUntilExit()
        XCTAssertEqual(game.terminationReason, .uncaughtSignal)
        XCTAssertEqual(game.terminationStatus, SIGKILL)
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertNil(WinePrefixProcesses.scan([entry])[entry.id])
    }

    func testWineServicesAloneAreNotARunningProgram() {
        func member(_ name: String, server: Bool = false) -> WinePrefixProcesses.Member {
            .init(pid: 1, name: name, isServer: server)
        }
        let services = [member("services.exe"), member("winedevice.exe"), member("explorer.exe"),
                        member("plugplay.exe"), member("svchost.exe"), member("rpcss.exe"), member("x", server: true)]
        XCTAssertFalse(WinePrefixProcesses.hasProgram(services))
        XCTAssertFalse(WinePrefixProcesses.hasProgram(nil))
        XCTAssertTrue(WinePrefixProcesses.hasProgram(services + [member("gta-vc.exe")]))
        XCTAssertTrue(WinePrefixProcesses.hasProgram([member("steamwebhelper.exe")]))
    }

    /// Wine names the server folder after the prefix's device and inode in hex.
    func testServerDirectoryFollowsWineNaming() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let entry = try wineEntry(f)
        var info = stat()
        XCTAssertEqual(stat(entry.prefixURL.path, &info), 0)
        let expected = "/private/tmp/.wine-\(getuid())/server-\(String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))"
        XCTAssertEqual(WinePrefixProcesses.serverDirectory(for: entry.prefixURL), expected)
        XCTAssertNil(WinePrefixProcesses.serverDirectory(for: f.root.appendingPathComponent("missing")))
    }
}
