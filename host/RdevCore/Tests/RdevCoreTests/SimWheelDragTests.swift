import XCTest
@testable import RdevCore

/// An iOS simulator has NO scroll service (spec, "Measured" — Scroll), so a wheel over one is a synthesized
/// one-finger drag. A drag that moves too little is a TAP, so the press waits for the slop.
final class SimWheelDragTests: XCTestCase {
    // An iPhone 18 Pro in points.
    private func drag() -> SimWheelDrag { SimWheelDrag(pointW: 402, pointH: 874) }

    func testAMovementUnderTheSlopNeverPresses() {
        var d = drag()
        XCTAssertEqual(d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 3, nowMs: 0), [])
        XCTAssertEqual(d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 4, nowMs: 10), [])
        XCTAssertEqual(d.tick(nowMs: 500), [], "a drag that never pressed has nothing to release")
    }

    /// Scrolling DOWN (dy > 0) moves the content UP, so the finger drags UP from where the pointer is.
    func testPassingTheSlopPressesAtThePointerAndDragsAgainstTheScroll() {
        var d = drag()
        let ev = d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 87.4, nowMs: 0)
        XCTAssertEqual(ev.count, 2)
        XCTAssertEqual(ev.first, .start([SimPoint(x: 0.5, y: 0.5)]))
        guard case .move(let p) = ev.last else { return XCTFail("expected a move, got \(ev)") }
        XCTAssertEqual(p[0].x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p[0].y, 0.4, accuracy: 1e-9)   // 87.4 pt of 874 = 0.1, upward
    }

    func testMoreDeltaMovesTheSameFinger() {
        var d = drag()
        _ = d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 87.4, nowMs: 0)
        let ev = d.wheel(x: 0.5, y: 0.5, dxPoints: 40.2, dyPoints: 0, nowMs: 16)
        guard case .move(let p) = ev.first, ev.count == 1 else { return XCTFail("\(ev)") }
        XCTAssertEqual(p[0].x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(p[0].y, 0.4, accuracy: 1e-9)
    }

    func testIdleReleasesWhereTheFingerIs() {
        var d = drag()
        _ = d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 87.4, nowMs: 0)
        XCTAssertEqual(d.tick(nowMs: 100), [], "not idle yet")
        let ev = d.tick(nowMs: 120)
        guard case .end(let p) = ev.first, ev.count == 1 else { return XCTFail("\(ev)") }
        XCTAssertEqual(p[0].y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(d.tick(nowMs: 400), [])
    }

    /// A finger that would leave the screen releases at the edge, and the next delta starts a fresh drag from
    /// the pointer — a long wheel run scrolls as far as it likes.
    func testTheEdgeReleasesAndTheNextDeltaStartsAgain() {
        var d = drag()
        _ = d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 400, nowMs: 0)
        let ev = d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 200, nowMs: 16)
        XCTAssertEqual(ev.count, 2)
        guard case .move(let last) = ev.first, case .end = ev.last else { return XCTFail("\(ev)") }
        XCTAssertEqual(last[0].y, 0.0, accuracy: 1e-9)
        let next = d.wheel(x: 0.5, y: 0.5, dxPoints: 0, dyPoints: 87.4, nowMs: 32)
        XCTAssertEqual(next.first, .start([SimPoint(x: 0.5, y: 0.5)]))
    }

    /// FINAL REVIEW I4. A pointer within the slop of an edge pressed, moved to the clamped edge and lifted in one breath —
    /// a TAP (at the top, the status bar: scroll to top). And a touch that STARTS at an edge is a system gesture. So a
    /// press lands at least `edgeInsetPoints` inside every edge, and its first move clears the slop.
    func testAWheelAtAnyEdgePressesInsideAndNeverTaps() {
        let w = 402.0, h = 874.0
        let cases: [(x: Double, y: Double, dx: Double, dy: Double)] = [
            (0.5, 4 / h, 0, 10),        // top, scrolling down: the finger moves up, toward the edge
            (0.5, 1 - 4 / h, 0, -10),   // bottom, scrolling up
            (4 / w, 0.5, 10, 0),        // left
            (1 - 4 / w, 0.5, -10, 0),   // right
        ]
        for c in cases {
            var d = SimWheelDrag(pointW: w, pointH: h)
            let ev = d.wheel(x: c.x, y: c.y, dxPoints: c.dx, dyPoints: c.dy, nowMs: 0)
            guard ev.count == 2, case .start(let a) = ev[0], case .move(let b) = ev[1] else {
                XCTFail("\(c): expected a press and a move, no lift — got \(ev)"); continue
            }
            let inset = SimWheelDrag.edgeInsetPoints
            XCTAssertGreaterThanOrEqual(a[0].x * w, inset - 1e-9, "\(c)"); XCTAssertLessThanOrEqual(a[0].x * w, w - inset + 1e-9, "\(c)")
            XCTAssertGreaterThanOrEqual(a[0].y * h, inset - 1e-9, "\(c)"); XCTAssertLessThanOrEqual(a[0].y * h, h - inset + 1e-9, "\(c)")
            let moved = (((b[0].x - a[0].x) * w) * ((b[0].x - a[0].x) * w) + ((b[0].y - a[0].y) * h) * ((b[0].y - a[0].y) * h)).squareRoot()
            XCTAssertGreaterThanOrEqual(moved, SimWheelDrag.slopPoints, "\(c): the first move must clear the slop")
        }
    }

    /// THE GATE'S G4, 2026-10-14: a wheel at the top of an iPhone 18 Pro pressed 30 pt down — inside the STATUS BAR —
    /// and the app recorded nothing: the system took the touch (a scroll-to-top tap, or, scrolling up, a pull-down from
    /// the status bar). So a press lands at least `topInsetPoints` below the shown frame's top, both ways of scrolling.
    func testAWheelAtTheTopPressesBelowTheStatusBar() {
        let w = 402.0, h = 874.0
        for dy in [10.0, -10.0] {
            var d = SimWheelDrag(pointW: w, pointH: h)
            let ev = d.wheel(x: 0.25, y: 2 / h, dxPoints: 0, dyPoints: dy, nowMs: 0)
            guard case .start(let a)? = ev.first else { XCTFail("dy \(dy): expected a press, got \(ev)"); continue }
            XCTAssertGreaterThan(a[0].y * h, 62, "dy \(dy): a Dynamic Island iPhone's status bar runs to ~62 pt")
        }
    }
}
