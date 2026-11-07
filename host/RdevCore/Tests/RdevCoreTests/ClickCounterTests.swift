import XCTest
@testable import RdevCore

final class ClickCounterTests: XCTestCase {
    private let interval: TimeInterval = 0.5

    func testFirstPressIsOne() {
        var c = ClickCounter()
        XCTAssertEqual(c.down(button: .left, x: 10, y: 10, now: 0, interval: interval), 1)
        XCTAssertEqual(c.count, 1)
    }

    func testQuickPressesAtOnePlaceCountUp() {
        // Double- and triple-click: what `CGEvent` alone never produces (every down stamped 1).
        var c = ClickCounter()
        XCTAssertEqual(c.down(button: .left, x: 10, y: 10, now: 0.0, interval: interval), 1)
        XCTAssertEqual(c.down(button: .left, x: 10, y: 10, now: 0.2, interval: interval), 2)
        XCTAssertEqual(c.count, 2, "the drags and the release of the second press carry 2")
        XCTAssertEqual(c.down(button: .left, x: 10, y: 10, now: 0.4, interval: interval), 3)
    }

    func testIntervalIsMeasuredFromThePreviousPress() {
        var c = ClickCounter()
        _ = c.down(button: .left, x: 0, y: 0, now: 0.0, interval: interval)
        XCTAssertEqual(c.down(button: .left, x: 0, y: 0, now: 0.5, interval: interval), 2, "at the boundary")
        XCTAssertEqual(c.down(button: .left, x: 0, y: 0, now: 1.01, interval: interval), 1, "past it")
    }

    func testDistanceBreaksTheRun() {
        var c = ClickCounter()
        _ = c.down(button: .left, x: 0, y: 0, now: 0, interval: interval)
        XCTAssertEqual(c.down(button: .left, x: ClickCounter.slopPoints, y: 0, now: 0.1, interval: interval), 2)
        XCTAssertEqual(c.down(button: .left, x: 100, y: 0, now: 0.2, interval: interval), 1)
    }

    func testOtherButtonBreaksTheRun() {
        var c = ClickCounter()
        _ = c.down(button: .left, x: 0, y: 0, now: 0, interval: interval)
        XCTAssertEqual(c.down(button: .right, x: 0, y: 0, now: 0.1, interval: interval), 1)
        XCTAssertEqual(c.down(button: .right, x: 0, y: 0, now: 0.2, interval: interval), 2)
    }

    func testResetStartsOver() {
        var c = ClickCounter()
        _ = c.down(button: .left, x: 0, y: 0, now: 0, interval: interval)
        c.reset()
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.down(button: .left, x: 0, y: 0, now: 0.1, interval: interval), 1)
    }
}
