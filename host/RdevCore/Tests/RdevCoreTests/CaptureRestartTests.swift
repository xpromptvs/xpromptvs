import XCTest
@testable import RdevCore

/// A capture that dies is started again (`CaptureRestart`, 2026-10-07: a window picked before its palette preview loaded
/// stayed dark — the stream died and nothing started it again).
final class CaptureRestartTests: XCTestCase {
    func testBacksOffDoublingThenGivesUp() {
        var r = CaptureRestart()
        let delays = (0 ..< 7).map { _ in r.next(code: -3805, ranFor: 1) }
        XCTAssertEqual(delays, [0.25, 0.5, 1, 2, 4, 8, nil])
    }

    func testAPermissionRefusalIsNeverRetried() {
        var r = CaptureRestart()
        XCTAssertNil(r.next(code: CaptureRestart.permissionDenied, ranFor: nil))
        XCTAssertEqual(r.attempts, 0)
    }

    /// A stream that ran a while before dying is a fresh failure, not the seventh of a burst.
    func testAHealthyRunStartsTheCountAfresh() {
        var r = CaptureRestart()
        for _ in 0 ..< CaptureRestart.maxAttempts { _ = r.next(code: -3805, ranFor: nil) }
        XCTAssertNil(r.next(code: -3805, ranFor: 5), "a short run after a burst is still the burst")
        XCTAssertEqual(r.next(code: -3805, ranFor: CaptureRestart.healthyAfter), 0.25)
    }

    func testAStartThatNeverRanCountsAndAFailureWithNoCodeIsRetried() {
        var r = CaptureRestart()
        XCTAssertEqual(r.next(code: nil, ranFor: nil), 0.25)
        XCTAssertEqual(r.next(code: nil, ranFor: nil), 0.5)
    }
}
