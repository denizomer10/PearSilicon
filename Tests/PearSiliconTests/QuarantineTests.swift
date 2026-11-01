import Darwin
import Foundation
import XCTest
@testable import PearSilicon

final class QuarantineTests: XCTestCase {

    func testDetectsAndRemovesQuarantineWithoutTouchingOtherAttributes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("Contents/Helpers/tool")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: nested)

        let value = "0083;00000000;Safari;"
        for path in [root, nested] {
            let result = path.path.withCString { setxattr($0, Quarantine.attribute, value, value.utf8.count, 0, 0) }
            XCTAssertEqual(result, 0)
        }
        XCTAssertTrue(Quarantine.isQuarantined(root))
        XCTAssertTrue(Quarantine.isQuarantined(nested))

        try Quarantine.remove(from: root)
        XCTAssertFalse(Quarantine.isQuarantined(root))
        XCTAssertFalse(Quarantine.isQuarantined(nested))
        XCTAssertEqual(try String(contentsOf: nested), "tool")
    }
}
