import XCTest
@testable import RdevCore

/// A tmux snapshot that keeps timing out on a starved host must not restart its control client every
/// 5 s for good: each consecutive timeout doubles the next batch's timeout up to 40 s, and a snapshot
/// that succeeds starts again from 5 s.
final class TmuxSnapshotTimeoutTests: XCTestCase {
    func testDoublesPerConsecutiveTimeoutCapsAt40AndResetsOnSuccess() {
        var t = TmuxSnapshotTimeout()
        XCTAssertEqual(t.current, 5)
        var seen: [TimeInterval] = []
        for _ in 0..<6 { t.timedOut(); seen.append(t.current) }
        XCTAssertEqual(seen, [10, 20, 40, 40, 40, 40])
        t.succeeded()
        XCTAssertEqual(t.current, 5)
    }

    func testTheBaseIsInjectableAndTheCapStaysEightTimesIt() {
        var t = TmuxSnapshotTimeout(base: 0.25)
        for _ in 0..<5 { t.timedOut() }
        XCTAssertEqual(t.current, 2)
        t.succeeded()
        XCTAssertEqual(t.current, 0.25)
    }
}
