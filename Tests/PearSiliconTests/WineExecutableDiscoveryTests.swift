import Foundation
import XCTest
@testable import PearSilicon

final class WineExecutableDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-wine-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("MZ".utf8)))
    }

    func testRecommendsGameProgramAndHidesRedistributables() throws {
        try touch("DELTARUNE.exe")
        try touch("chapter1_windows/chapter1.exe")
        try touch("_CommonRedist/dxwebsetup.exe")
        try touch("_CommonRedist/VisualCppRedist_AIO_x86_x64.exe")
        try touch("unins000.exe")

        let candidates = WineExecutableDiscovery.candidates(in: root)
        XCTAssertEqual(candidates.first?.path, "DELTARUNE.exe")
        XCTAssertTrue(candidates.first?.isRecommended == true)
        XCTAssertFalse(candidates.contains { $0.path.contains("_CommonRedist") })
        XCTAssertFalse(candidates.contains { $0.path == "unins000.exe" })
    }

    func testSingleExecutableIsRecommended() throws {
        try touch("Game.exe")
        let candidates = WineExecutableDiscovery.candidates(in: root)
        XCTAssertEqual(candidates.map(\.path), ["Game.exe"])
        XCTAssertTrue(candidates[0].isRecommended)
    }

    func testOnlyRedistributablesAreNeverRecommended() throws {
        try touch("_CommonRedist/dxwebsetup.exe")
        try touch("_CommonRedist/VisualCppRedist_AIO_x86_x64.exe")
        let candidates = WineExecutableDiscovery.candidates(in: root)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(candidates.contains { $0.isRecommended })
    }

    func testEmptyFolderHasNoCandidates() throws {
        XCTAssertTrue(WineExecutableDiscovery.candidates(in: root).isEmpty)
    }

    func testShallowerProgramWinsWhenNamesDoNotMatch() throws {
        try touch("bin/launcher.exe")
        try touch("bin/deep/helper.exe")
        let candidates = WineExecutableDiscovery.candidates(in: root)
        XCTAssertEqual(candidates.first?.path, "bin/launcher.exe")
    }
}
