import XCTest
@testable import ShellstormCore

final class NativeScrollGestureTests: XCTestCase {
    func testReleaseSendsOneVelocityAndDropsTheLocalMomentumTail() {
        var gesture = NativeScrollGesture()
        XCTAssertEqual(gesture.handle(.init(time: 1, dx: 0, dy: 0, phase: .mayBegin)), [.begin])
        XCTAssertEqual(gesture.handle(.init(time: 1.01, dx: 0, dy: -10, phase: .began)), [.scroll(dx: 0, dy: 10, precise: true)])
        XCTAssertEqual(gesture.handle(.init(time: 1.03, dx: 0, dy: -10, phase: .changed)), [.scroll(dx: 0, dy: 10, precise: true)])
        let release = gesture.handle(.init(time: 1.04, dx: 0, dy: 0, phase: .ended))
        guard case .end(let vx, let vy) = release.first else { return XCTFail("No release") }
        XCTAssertEqual(release.count, 1); XCTAssertEqual(vx, 0); XCTAssertEqual(vy, 500, accuracy: 0.001)
        XCTAssertEqual(gesture.handle(.init(time: 1.05, dx: 0, dy: -20, momentum: true)), [])
        XCTAssertEqual(gesture.handle(.init(time: 1.06, dx: 0, dy: 0, phase: .ended)), [])
    }
    func testRestingBeforeReleaseDoesNotFling() {
        var gesture = NativeScrollGesture()
        _ = gesture.handle(.init(time: 1, dx: 0, dy: -10, phase: .began))
        _ = gesture.handle(.init(time: 1.02, dx: 0, dy: -10, phase: .changed))
        XCTAssertEqual(gesture.handle(.init(time: 1.2, dx: 0, dy: 0, phase: .ended)), [.end(vx: 0, vy: 0)])
    }
    func testCancellationDoesNotFlingAndANewContactBeginsImmediately() {
        var gesture = NativeScrollGesture()
        _ = gesture.handle(.init(time: 1, dx: 0, dy: -20, phase: .began))
        XCTAssertEqual(gesture.handle(.init(time: 1.01, dx: 0, dy: 0, phase: .cancelled)), [.cancel])
        XCTAssertEqual(gesture.handle(.init(time: 1.02, dx: 0, dy: 0, phase: .mayBegin)), [.begin])
        XCTAssertEqual(gesture.cancel(), [.cancel]); XCTAssertEqual(gesture.cancel(), [])
    }
    func testPhaseLessWheelsKeepTheirUnitsAndFractionalDeltas() {
        var gesture = NativeScrollGesture()
        XCTAssertEqual(gesture.handle(.init(time: 1, dx: 0.25, dy: -0.4)), [.scroll(dx: -0.25, dy: 0.4, precise: true)])
        XCTAssertEqual(gesture.handle(.init(time: 2, dx: 1, dy: -3, precise: false)), [.scroll(dx: -1, dy: 3, precise: false)])
    }
    func testDiagonalReleaseUsesMovementTimeRatherThanTheZeroEndEvent() {
        var gesture = NativeScrollGesture()
        _ = gesture.handle(.init(time: 1, dx: -4, dy: 8, phase: .began))
        _ = gesture.handle(.init(time: 1.02, dx: -4, dy: 8, phase: .changed))
        let out = gesture.handle(.init(time: 1.03, dx: 0, dy: 0, phase: .ended))
        guard case .end(let vx, let vy) = out.first else { return XCTFail("No release") }
        XCTAssertEqual(vx, 200, accuracy: 0.001); XCTAssertEqual(vy, -400, accuracy: 0.001)
    }
    func testInvalidSamplesCannotPoisonTheNextGesture() {
        var gesture = NativeScrollGesture()
        XCTAssertEqual(gesture.handle(.init(time: 1, dx: .nan, dy: 1, phase: .began)), [])
        XCTAssertEqual(gesture.handle(.init(time: 2, dx: 0, dy: -1, phase: .began)), [.begin, .scroll(dx: 0, dy: 1, precise: true)])
    }
}
