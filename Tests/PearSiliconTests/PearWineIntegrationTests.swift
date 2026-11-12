import Foundation
import PearWineKit
import XCTest
@testable import PearSilicon

final class PearWineIntegrationTests: XCTestCase {
    func testPinnedAPIAssessesActualPEAndLeavesUnknownEngineUncertified() throws {
        try XCTSkipIf(PearWineClient.systemPython == nil, "Python is not installed")
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let source = f.root.appendingPathComponent("Game.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        let entry = try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: f.library, engineID: "custom")
        let engine = WineEngine(id: "custom", name: "Custom", version: "1", rootURL: f.root,
                                executablePath: "Runtime/bin/wine", distribution: .community)
        let report = try PearWineCompatibilityService().assess(entry, engine: engine)
        XCTAssertEqual(report.assessment?.executable.architecture, "x86_64")
        XCTAssertFalse(report.signatureVerified)
        XCTAssertFalse(report.assessment?.execution_allowed ?? true)
        try PearWineCompatibilityService.persist(report, for: entry)
        let decoded = try JSONDecoder().decode(WineCompatibilityReport.self, from: Data(contentsOf: entry.dataURL.appendingPathComponent("pearwine-compatibility.json")))
        XCTAssertEqual(decoded.assessment, report.assessment)
    }
    func testKnownEngineNameAloneCannotClaimRegistryIdentity() throws {
        try XCTSkipIf(PearWineClient.systemPython == nil, "Python is not installed")
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let source = f.root.appendingPathComponent("Game.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        let entry = try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: f.library, engineID: "pearwine-1.0.1")
        let engine = WineEngine(id: "pearwine-1.0.1", name: "PearWine", version: "1.0.1", rootURL: f.root,
            executablePath: "Runtime/MetalSharp-Wine.app/Contents/MacOS/wine", distribution: .pearWine)
        XCTAssertThrowsError(try PearWineCompatibilityService().assess(entry, engine: engine)) {
            XCTAssertTrue($0 is WineCompatibilityFailure)
        }
    }
}

@MainActor
final class WineSessionTrackingTests: XCTestCase {
    func testLauncherReexecIsTrackedAndStopIsConfinedToItsPrefix() async throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let source = f.root.appendingPathComponent("Engine")
        let bin = source.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let code = f.root.appendingPathComponent("session.c")
        try #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <signal.h>
        int main(int argc,char **argv) {
            char path[4096]; const char *prefix=getenv("WINEPREFIX");
            if (!prefix) return 2;
            if (argc>1 && strstr(argv[1],"wineboot")) {
                snprintf(path,sizeof(path),"%s/system.reg",prefix);
                FILE *f=fopen(path,"w"); fputs("WINE REGISTRY Version 2\n",f); fclose(f); return 0;
            }
            snprintf(path,sizeof(path),"%s/child.pid",prefix);
            if (argc>1 && (!strcmp(argv[1],"-w") || !strcmp(argv[1],"-k"))) {
                FILE *f=fopen(path,"r"); if (!f) return 0;
                int pid=0;fscanf(f,"%d",&pid);fclose(f);if(pid<=0)return 0;
                if(!strcmp(argv[1],"-k")){kill(pid,SIGKILL);return 0;}
                while(kill(pid,0)==0)usleep(100000);
                return 0;
            }
            int pid=fork();if(pid==0){sleep(15);_exit(0);}
            FILE *f=fopen(path,"w");fprintf(f,"%d",pid);fclose(f);return 0;
        }
        """#.write(to: code, atomically: true, encoding: .utf8)
        _ = try Shell.run("/usr/bin/clang", [code.path,"-o",bin.appendingPathComponent("wine").path])
        try FileManager.default.copyItem(at: bin.appendingPathComponent("wine"), to: bin.appendingPathComponent("wineserver"))
        let engine = try WineEngineStore(rootURL: f.enginesRoot).registerLocalEngine(from: source, id: "session-wine", name: "Session", version: "1", executablePath: "bin/wine", licenseConfirmed: true)
        let service = ManagedAppService()
        var entries: [LibraryEntry] = []
        for name in ["A", "B"] {
            let exe = f.root.appendingPathComponent(name + ".exe")
            try ManagedAppTestFixture.pe().write(to: exe)
            entries.append(try service.importWindowsExecutable(from: exe, libraryRoot: f.library, engineID: engine.id))
        }
        let a = try await service.launch(entries[0], engine: engine, activate: false)
        let b = try await service.launch(entries[1], engine: engine, activate: false)
        defer { a.stop(); b.stop() }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(a.isRunning, "Re-exec child must outlive its initial launcher")
        XCTAssertTrue(b.isRunning)
        a.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(a.isRunning)
        XCTAssertTrue(b.isRunning, "Stopping A must not stop another private Wine prefix")
    }
}

final class WineStartupHealthTests: XCTestCase {
    func testOldSteamErrorsDoNotFailNewLaunchButFreshErrorsDo() throws {
        let f = try ManagedAppTestFixture(); defer { f.remove() }
        let source = f.root.appendingPathComponent("steam.exe")
        try ManagedAppTestFixture.pe().write(to: source)
        let entry = try ManagedAppService().importWindowsExecutable(from: source, libraryRoot: f.library, engineID: "test")
        let log = entry.launchExecutableURL.deletingLastPathComponent().appendingPathComponent("bin/cef/cef.win64/debug.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let failure = "[FATAL:target_services.cc(121)] Check failed: process_state_.InitCalled().\n"
        try failure.write(to: log, atomically: true, encoding: .utf8)
        let snapshot = WineStartupHealth(entry: entry)
        XCTAssertTrue(snapshot.issues().isEmpty)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(failure.utf8)); try handle.close()
        XCTAssertEqual(snapshot.issues().count, 1)
    }
}
