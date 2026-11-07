import CoreGraphics
import XCTest
@testable import ShellstormCore

/// A client window's expand/restore in lockstep with its page: the frame each step asks for, and what the
/// web view is sized to before the window moves (docs/desktop-app.md, "Expand and restore").
final class LockstepResizeTests: XCTestCase {
    private let small = CGRect(x: 100, y: 300, width: 800, height: 600)
    private let big = CGRect(x: 0, y: 25, width: 1512, height: 920)

    func testStartsWhereTheWindowIsAndLandsExactlyOnTheTarget() {
        let r = LockstepResize(from: small, to: big, start: 10, duration: 0.24)
        XCTAssertEqual(r.frame(at: 10).frame, small)
        XCTAssertFalse(r.frame(at: 10).last)
        XCTAssertEqual(r.frame(at: 10.24).frame, big)
        XCTAssertTrue(r.frame(at: 10.24).last)
        XCTAssertEqual(r.frame(at: 99).frame, big, "a late step still lands on the target")
        XCTAssertEqual(r.frame(at: 9).frame, small, "a clock before the start holds the origin")
    }

    /// Reduced motion and a window already there: one step, straight to the target.
    func testNoDurationIsOneStep() {
        let r = LockstepResize(from: small, to: big, start: 5, duration: 0)
        XCTAssertEqual(r.frame(at: 5).frame, big)
        XCTAssertTrue(r.frame(at: 5).last)
    }

    /// Progress is TIME: a step taken late jumps ahead rather than stretching the animation.
    func testProgressIsTimeNotSteps() {
        let r = LockstepResize(from: small, to: big, start: 0, duration: 0.24)
        let halfway = r.frame(at: 0.12).frame
        XCTAssertEqual(halfway.width, ((small.width + big.width) / 2).rounded(), accuracy: 1)
    }

    /// Every edge moves one way only, in whole points, for both directions — the top edge included,
    /// which rounding origin and size separately can make step back by a point.
    func testEveryEdgeIsMonotonicAndWhole() {
        for (a, b) in [(small, big), (big, small)] {
            let r = LockstepResize(from: a, to: b, start: 0, duration: 0.24)
            var previous = a
            for ms in stride(from: 0.0, through: 240, by: 0.5) {
                let f = r.frame(at: ms / 1000).frame
                for (edge, p, c, target) in [("minX", previous.minX, f.minX, b.minX), ("maxX", previous.maxX, f.maxX, b.maxX),
                                             ("minY", previous.minY, f.minY, b.minY), ("maxY", previous.maxY, f.maxY, b.maxY)] {
                    XCTAssertEqual(c, c.rounded(), "\(edge) is a whole point")
                    if target >= p { XCTAssertGreaterThanOrEqual(c, p, "\(edge) at \(ms) ms") }
                    else { XCTAssertLessThanOrEqual(c, p, "\(edge) at \(ms) ms") }
                }
                previous = f
            }
            XCTAssertEqual(previous, b)
        }
    }

    func testTheEaseIsCoreAnimationsEaseInEaseOut() {
        XCTAssertEqual(LockstepResize.ease(0), 0)
        XCTAssertEqual(LockstepResize.ease(1), 1)
        XCTAssertEqual(LockstepResize.ease(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LockstepResize.ease(0.25) + LockstepResize.ease(0.75), 1, accuracy: 1e-9, "symmetric")
        XCTAssertLessThan(LockstepResize.ease(0.1), 0.1, "eases in")
        var previous = 0.0
        for i in 1...1000 {
            let e = LockstepResize.ease(Double(i) / 1000)
            XCTAssertGreaterThanOrEqual(e, previous)
            previous = e
        }
    }

    /// With the clip released the page lays out at the target in every direction; without it, a shrinking
    /// dimension waits for the window (never smaller than what is shown), a growing one goes first.
    func testTheWebViewIsSizedBeforeTheWindow() {
        let shown = CGSize(width: 1000, height: 700)
        let grow = CGSize(width: 1100, height: 760), shrink = CGSize(width: 900, height: 650)
        let mixed = CGSize(width: 1100, height: 650)
        XCTAssertEqual(LockstepResize.webSize(showing: shown, target: grow, overflows: true), grow)
        XCTAssertEqual(LockstepResize.webSize(showing: shown, target: shrink, overflows: true), shrink)
        XCTAssertEqual(LockstepResize.webSize(showing: shown, target: grow, overflows: false), grow)
        XCTAssertEqual(LockstepResize.webSize(showing: shown, target: shrink, overflows: false), shown)
        XCTAssertEqual(LockstepResize.webSize(showing: shown, target: mixed, overflows: false), CGSize(width: 1100, height: 700))
    }
}
