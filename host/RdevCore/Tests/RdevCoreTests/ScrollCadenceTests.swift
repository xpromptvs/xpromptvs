import XCTest
@testable import RdevCore

final class ScrollCadenceTests: XCTestCase {
    /// A steady stream is the control arm: if this reported spread, nothing else it says means anything.
    func testASteadyStreamHasNoSpread() {
        var c = ScrollCadence()
        for i in 0..<50 { c.record(at: Double(i) * 0.00833) }
        let s = c.drain()!
        XCTAssertEqual(s.samples, 49)
        XCTAssertEqual(s.medianMs, 8.33, accuracy: 0.01)
        XCTAssertEqual(s.p95Ms, 8.33, accuracy: 0.01)
        XCTAssertEqual(s.spreadMs, 0, accuracy: 0.01)   // the number the interpolator would remove
        XCTAssertEqual(s.gestures, 1)
    }

    func testSpreadIsTheDeviationFromTheMedian_notTheRange() {
        // A single outlier must not dominate: the question is how much of the stream is uneven,
        // which is what a buffer would have to absorb, not the worst pair of events in a window.
        var c = ScrollCadence()
        var t = 0.0
        for _ in 0..<40 { t += 0.009; c.record(at: t) }
        t += 0.030; c.record(at: t)                      // one hiccup
        let s = c.drain()!
        XCTAssertEqual(s.medianMs, 9.0, accuracy: 0.01)
        XCTAssertLessThan(s.spreadMs, 2.0)               // p95 of |interval - median|
        XCTAssertEqual(s.maxMs, 30.0, accuracy: 0.01)    // ...and the outlier is still reported
    }

    /// LOAD-BEARING: an idle gap between two gestures is NOT jitter. Counting it would make every
    /// window's spread a function of how long the user paused, which is not a property of anything.
    func testAnIdleGapSplitsGesturesAndIsNotCounted() {
        var c = ScrollCadence()
        var t = 0.0
        for _ in 0..<20 { t += 0.009; c.record(at: t) }
        t += 3.0; c.record(at: t)                        // three seconds later: a new gesture
        for _ in 0..<20 { t += 0.009; c.record(at: t) }
        let s = c.drain()!
        XCTAssertEqual(s.gestures, 2)
        XCTAssertEqual(s.samples, 39)                    // 40 intervals minus the idle one
        XCTAssertEqual(s.maxMs, 9.0, accuracy: 0.01)     // the 3s gap never became a sample
    }

    func testTheGestureGapThresholdIsTheBoundary() {
        var c = ScrollCadence(gestureGap: 0.25)
        c.record(at: 0)
        c.record(at: 0.24)                               // just inside: still one gesture
        c.record(at: 0.24 + 0.26)                        // just outside: a new one
        let s = c.drain()!
        XCTAssertEqual(s.gestures, 2)
        XCTAssertEqual(s.samples, 1)
    }

    func testDrainIsEmptyUntilThereIsAnInterval() {
        var c = ScrollCadence()
        XCTAssertNil(c.drain())                          // nothing recorded
        c.record(at: 1.0)
        XCTAssertNil(c.drain())                          // ONE event is not an interval
    }

    func testDrainClearsSoEachWindowDescribesItself() {
        // An ever-growing average stops responding to change — the same rule `[latency]` follows.
        var c = ScrollCadence()
        c.record(at: 0); c.record(at: 0.010)
        XCTAssertEqual(c.drain()!.samples, 1)
        XCTAssertNil(c.drain())
        c.record(at: 5.0); c.record(at: 5.020)
        let s = c.drain()!
        XCTAssertEqual(s.samples, 1)
        XCTAssertEqual(s.medianMs, 20.0, accuracy: 0.01)   // not blended with the earlier 10ms
    }

    func testTheLineNamesEveryFieldAndSurvivesAnEmptyWindow() {
        var c = ScrollCadence()
        var t = 0.0
        for _ in 0..<10 { t += 0.009; c.record(at: t) }
        let line = c.report(source: "win:42")!
        XCTAssertTrue(line.hasPrefix("[scroll] win:42 "), line)
        for field in ["n=", "gestures=", "p50=", "p95=", "spread=", "min=", "max="] {
            XCTAssertTrue(line.contains(field), "missing \(field) in: \(line)")
        }
        XCTAssertNil(c.report(source: "win:42"))   // a quiet window prints NOTHING, never zeroes
    }
}
