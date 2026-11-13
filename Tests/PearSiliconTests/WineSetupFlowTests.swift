import Foundation
import XCTest
@testable import PearSilicon

@MainActor
final class WineSetupFlowTests: XCTestCase {
    func testImportRunsSetupWaitsForChildAndSelectsInstalledProgram() async throws {
        let fixture = try ManagedAppTestFixture()
        defer { fixture.remove() }
        let engineSource = fixture.root.appendingPathComponent("FakeEngine")
        let bin = engineSource.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineSource.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let c = fixture.root.appendingPathComponent("fake.c")
        try #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <sys/stat.h>
        int main(int argc, char **argv) {
            const char *prefix = getenv("WINEPREFIX");
            char path[4096], from[4096];
            if (argc > 1 && !strcmp(argv[1], "-w")) { sleep(2); return 0; }
            if (argc > 1 && !strcmp(argv[1], "-k")) return 0;
            if (argc > 1 && !strcmp(argv[1], "regedit.exe")) return 0;
            if (argc > 1 && strstr(argv[1], "wineboot")) {
                snprintf(path,sizeof(path),"%s/system.reg",prefix);
                FILE *f=fopen(path,"w"); fputs("WINE REGISTRY Version 2\n",f); fclose(f); return 0;
            }
            if (argc > 1 && strstr(argv[1], "SteamSetup")) {
                if (fork() == 0) {
                    sleep(1);
                    snprintf(path,sizeof(path),"%s/drive_c",prefix); mkdir(path,0700);
                    snprintf(path,sizeof(path),"%s/drive_c/Steam",prefix); mkdir(path,0700);
                    snprintf(path,sizeof(path),"%s/drive_c/Steam/steam.exe",prefix);
                    snprintf(from,sizeof(from),"%s/../Payload/Program/SteamSetup.exe",getenv("HOME"));
                    FILE *in=fopen(from,"rb"), *out=fopen(path,"wb");
                    if (!in || !out) _exit(2);
                    int ch; while((ch=fgetc(in))!=EOF) fputc(ch,out);
                    fclose(in); fclose(out); _exit(0);
                }
                return 0;
            }
            sleep(30); return 0;
        }
        """#.write(to: c, atomically: true, encoding: .utf8)
        _ = try Shell.run("/usr/bin/clang", [c.path, "-o", bin.appendingPathComponent("wine").path])
        try FileManager.default.copyItem(at: bin.appendingPathComponent("wine"), to: bin.appendingPathComponent("wineserver"))
        try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
        let engine = try WineEngineStore(rootURL: fixture.library.appendingPathComponent("Engines")).registerLocalEngine(
            from: engineSource, id: "test-wine", name: "Test", version: "1", executablePath: "bin/wine", distribution: .metalSharp, licenseConfirmed: true)
        let source = fixture.root.appendingPathComponent("SteamSetup.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        let state = AppState(storageRootURL: fixture.library, observesWorkspace: false)
        try await state.refreshLibrary()
        await state.importWindowsExecutable(at: source, engineID: engine.id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if state.managedEntries.first?.manifest.wineInstallState == "ready" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let entry = try XCTUnwrap(state.managedEntries.first)
        defer { state.stop(entry) }
        XCTAssertEqual(entry.manifest.wineInstallState, "ready", state.statusMessage)
        XCTAssertEqual(entry.manifest.wineLaunchPath, "Prefix/drive_c/Steam/steam.exe")
        XCTAssertTrue(entry.manifest.payloadPath.hasSuffix("SteamSetup.exe"))
        XCTAssertFalse(state.activeWineInstallations.contains(entry.id))
        let saved = try JSONDecoder().decode(LibraryManifest.self, from: Data(contentsOf: entry.manifestURL))
        XCTAssertEqual(saved.wineLaunchPath, entry.manifest.wineLaunchPath)
        await state.launch(entry)
        XCTAssertTrue(state.isRunning(entry), state.statusMessage)
    }
}
