import XCTest
@testable import RdevCore

final class ScrollInjectionTests: XCTestCase {
    // MARK: - unit

    func testOnlyTheExplicitPixelSpellingSelectsPixels() {
        XCTAssertEqual(ScrollUnit(wire: "px"), .pixel)
        XCTAssertEqual(ScrollUnit(wire: "line"), .line)
    }

    /// LOAD-BEARING. A client that predates `unit` sends LINE deltas. Defaulting absent to pixels
    /// would post `3` as three PIXELS instead of three lines — a stale cached client would scroll
    /// about a fortieth of what it asked for, which reads as "scrolling barely works".
    func testAbsentOrUnknownUnitMeansLine() {
        XCTAssertEqual(ScrollUnit(wire: nil), .line)
        XCTAssertEqual(ScrollUnit(wire: "banana"), .line)
    }

    // MARK: - accumulator

    /// THE BUG THIS EXISTS FOR: the old path did `Int32((-dy).rounded())`, so a slow trackpad drag
    /// of 0.4 px per event rounded to zero forever and the window never moved at all.
    func testSubPixelDeltasAccumulateIntoRealScroll() {
        var acc = PixelScrollAccumulator()
        var total: Int32 = 0
        for _ in 0..<10 { total += acc.take(dx: 0, dy: 0.4).y }
        XCTAssertEqual(total, 4)
    }

    func testWholePixelsPassThroughImmediately() {
        var acc = PixelScrollAccumulator()
        XCTAssertEqual(acc.take(dx: -3, dy: 12).x, -3)
    }

    /// Truncation must be TOWARD ZERO on both signs, or the remainder changes sign and a steady
    /// drag alternates direction.
    func testNegativeFractionsAccumulateWithoutFlippingSign() {
        var acc = PixelScrollAccumulator()
        var total: Int32 = 0
        for _ in 0..<10 { total += acc.take(dx: 0, dy: -0.4).y }
        XCTAssertEqual(total, -4)
    }

    func testTheRemainderIsKeptRatherThanDiscarded() {
        var acc = PixelScrollAccumulator()
        XCTAssertEqual(acc.take(dx: 0, dy: 1.5).y, 1)
        XCTAssertEqual(acc.take(dx: 0, dy: 0.5).y, 1)   // 0.5 carried + 0.5 = 1
    }

    // MARK: - phase machine

    func testFirstEventBeginsAndLaterEventsChange() {
        var m = ScrollPhaseMachine()
        XCTAssertEqual(m.event(now: 100.0), .began)
        XCTAssertEqual(m.event(now: 100.01), .changed)
        XCTAssertEqual(m.event(now: 100.02), .changed)
    }

    func testTheGestureEndsOnlyAfterTheQuietInterval() {
        var m = ScrollPhaseMachine()
        _ = m.event(now: 100.0)
        XCTAssertNil(m.expire(now: 100.0 + ScrollPhaseMachine.quietInterval / 2))
        XCTAssertEqual(m.expire(now: 100.0 + ScrollPhaseMachine.quietInterval), .ended)
        XCTAssertFalse(m.isActive)
    }

    /// `ended` fires ONCE. A second timer firing must not emit a second `ended`, which reads to an
    /// app as a gesture that ended twice.
    func testEndIsNotRepeated() {
        var m = ScrollPhaseMachine()
        _ = m.event(now: 100.0)
        XCTAssertEqual(m.expire(now: 200.0), .ended)
        XCTAssertNil(m.expire(now: 300.0))
    }

    func testANewGestureBeginsAgainAfterEnding() {
        var m = ScrollPhaseMachine()
        _ = m.event(now: 100.0)
        _ = m.expire(now: 200.0)
        XCTAssertEqual(m.event(now: 201.0), .began)
    }

    /// `reset` is what a focus change / release calls: the NEXT gesture must open with `began`.
    func testResetForcesTheNextEventToBegin() {
        var m = ScrollPhaseMachine()
        _ = m.event(now: 100.0)
        m.reset()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.event(now: 100.01), .began)
    }
}
