import XCTest
@testable import RdevCore

/// DTUHID carries ONE gesture of one or two contacts (`pointOne`/`pointTwo`) through start → position → end. The
/// tracker turns the client's `sim-touch` phases into that, and repairs a stream the client garbled rather than
/// leaving a contact down in the simulator.
final class SimTouchTrackerTests: XCTestCase {
    private let a = SimPoint(x: 0.2, y: 0.3), b = SimPoint(x: 0.6, y: 0.7), c = SimPoint(x: 0.25, y: 0.35)

    func testOneFinger() {
        var t = SimTouchTracker()
        XCTAssertEqual(t.apply(phase: "down", points: [a]), [.start([a])])
        XCTAssertEqual(t.apply(phase: "move", points: [c]), [.move([c])])
        XCTAssertEqual(t.apply(phase: "up", points: [c]), [.end([c])])
        XCTAssertEqual(t.apply(phase: "up", points: [c]), [], "nothing is down")
    }

    func testTwoFingers() {
        var t = SimTouchTracker()
        XCTAssertEqual(t.apply(phase: "down", points: [a, b]), [.start([a, b])])
        XCTAssertEqual(t.apply(phase: "move", points: [c, b]), [.move([c, b])])
        XCTAssertEqual(t.apply(phase: "up", points: [c, b]), [.end([c, b])])
    }

    /// A DOWN while a gesture is open ends that gesture first, where its contacts LAST were.
    func testADownEndsAnOpenGestureFirst() {
        var t = SimTouchTracker()
        _ = t.apply(phase: "down", points: [a])
        _ = t.apply(phase: "move", points: [c])
        XCTAssertEqual(t.apply(phase: "down", points: [a, b]), [.end([c]), .start([a, b])])
    }

    /// A MOVE whose contact count changed is a new gesture: end the old one, start the new one.
    func testAMoveThatChangesTheCountRestarts() {
        var t = SimTouchTracker()
        _ = t.apply(phase: "down", points: [a, b])
        XCTAssertEqual(t.apply(phase: "move", points: [c]), [.end([a, b]), .start([c])])
    }

    func testAMoveWithNothingDownStarts() {
        var t = SimTouchTracker()
        XCTAssertEqual(t.apply(phase: "move", points: [a]), [.start([a])])
    }

    /// An up with a different count ends the gesture where it LAST was.
    func testAnUpWithADifferentCountEndsWhereItWas() {
        var t = SimTouchTracker()
        _ = t.apply(phase: "down", points: [a, b])
        XCTAssertEqual(t.apply(phase: "up", points: [c]), [.end([a, b])])
    }

    func testMalformedIsIgnored() {
        var t = SimTouchTracker()
        XCTAssertEqual(t.apply(phase: "down", points: []), [])
        XCTAssertEqual(t.apply(phase: "down", points: [a, b, c]), [])
        XCTAssertEqual(t.apply(phase: "hover", points: [a]), [])
    }

    /// Releasing everything (a lost client, a focus change) ends whatever is down.
    func testCancelEndsTheOpenGesture() {
        var t = SimTouchTracker()
        _ = t.apply(phase: "down", points: [a])
        XCTAssertEqual(t.cancel(), [.end([a])])
        XCTAssertEqual(t.cancel(), [])
    }
}
