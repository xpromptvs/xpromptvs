import XCTest
@testable import RdevCore

final class SimNativeScrollDragTests: XCTestCase {
    func testContactImmediatelyInterruptsInertiaButAStationaryReleaseCancels() {
        var drag = SimNativeScrollDrag(pointW: 400, pointH: 800)
        let p = SimPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(drag.begin(x: p.x, y: p.y), [.contact(p)])
        XCTAssertEqual(drag.end(moving: false), [.cancel(p)])
        XCTAssertEqual(drag.end(moving: true), [])
    }
    func testSubslopAndPausedReleaseCannotTapOrFling() {
        var drag = SimNativeScrollDrag(pointW: 400, pointH: 800)
        _ = drag.begin(x: 0.5, y: 0.5)
        _ = drag.move(dx: 0, dy: 3)
        XCTAssertEqual(drag.end(moving: true), [.cancel(SimPoint(x: 0.5, y: 0.5 - 3.0/800))])
        _ = drag.begin(x: 0.5, y: 0.5)
        _ = drag.move(dx: 0, dy: 40)
        XCTAssertEqual(drag.end(moving: false), [.cancel(SimPoint(x: 0.5, y: 0.45))])
    }
    func testMovingReleaseLeavesInertiaToUIKitAndRecontactCancelsHeldTouch() {
        var drag = SimNativeScrollDrag(pointW: 400, pointH: 800)
        _ = drag.begin(x: 0.5, y: 0.5)
        _ = drag.move(dx: 20, dy: 40)
        XCTAssertEqual(drag.end(moving: true), [.end(SimPoint(x: 0.45, y: 0.45))])
        _ = drag.begin(x: 0.5, y: 0.5)
        XCTAssertEqual(drag.begin(x: 0.6, y: 0.6), [.cancel(SimPoint(x: 0.5, y: 0.5)), .contact(SimPoint(x: 0.6, y: 0.6))])
    }
    func testStatusBarAndEdgeExclusionsAndEdgeCancellation() {
        var drag = SimNativeScrollDrag(pointW: 400, pointH: 800)
        XCTAssertEqual(drag.begin(x: 0, y: 0), [.contact(SimPoint(x: 0.075, y: 0.0875))])
        XCTAssertEqual(drag.move(dx: 100, dy: 100), [.cancel(SimPoint(x: 0, y: 0))])
        XCTAssertEqual(drag.move(dx: 1, dy: 1), [])
    }
}
