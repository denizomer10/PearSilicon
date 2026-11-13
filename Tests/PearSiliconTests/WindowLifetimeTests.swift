import XCTest
@testable import PearSilicon

final class WindowLifetimeTests: XCTestCase {
    func testOnlyStopsAfterARealWindowClosesForTheGracePeriod() {
        var state = WindowLifetime()
        XCTAssertFalse(state.shouldStop(hasWindow: false, now: 0))
        XCTAssertFalse(state.shouldStop(hasWindow: false, now: 100)) // startup without a window
        XCTAssertFalse(state.shouldStop(hasWindow: true, now: 101))
        XCTAssertFalse(state.shouldStop(hasWindow: false, now: 102))
        XCTAssertFalse(state.shouldStop(hasWindow: true, now: 103)) // replacement/minimized window
        XCTAssertFalse(state.shouldStop(hasWindow: false, now: 104))
        XCTAssertTrue(state.shouldStop(hasWindow: false, now: 106))
    }
    func testUnknownWindowServerStateDoesNotTerminateApplication() {
        var state = WindowLifetime()
        XCTAssertFalse(state.shouldStop(hasWindow: true, now: 0))
        XCTAssertFalse(state.shouldStop(hasWindow: false, now: 1))
        XCTAssertFalse(state.shouldStop(hasWindow: nil, now: 10))
        XCTAssertFalse(state.shouldStop(hasWindow: false, now: 20))
    }
}
