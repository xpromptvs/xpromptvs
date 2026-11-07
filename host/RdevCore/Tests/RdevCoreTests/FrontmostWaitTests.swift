import XCTest
@testable import RdevCore

/// The bounded wait a paste's ⌘V makes for its window's application to be the FRONT one — keys go to the front
/// application, so a ⌘V posted before a raise has taken effect goes to whatever was in front before it.
final class FrontmostWaitTests: XCTestCase {
    /// A fake clock that `sleep` advances, and a log of when the probe was asked.
    private final class Clock {
        var t = 100.0
        var slept: [Double] = []
        var asked: [Double] = []
    }

    private func wait(_ c: Clock, bound: Double = 1.0, every: Double = 0.01, frontFrom: Double?) -> Double? {
        FrontmostWait.wait(bound: bound, every: every, now: { c.t }, sleep: { c.slept.append($0); c.t += $0 }) {
            c.asked.append(c.t)
            return frontFrom.map { c.t >= $0 } ?? false
        }
    }

    func testAnApplicationAlreadyInFrontIsNotWaitedFor() {
        let c = Clock()
        XCTAssertEqual(wait(c, frontFrom: 0), 0)
        XCTAssertEqual(c.slept, [], "nothing slept")
        XCTAssertEqual(c.asked.count, 1)
    }

    func testItAnswersHowLongTheRaiseTookToTakeEffect() throws {
        let c = Clock()
        let took = try XCTUnwrap(wait(c, every: 0.01, frontFrom: 100.035))
        XCTAssertEqual(took, 0.04, accuracy: 1e-9, "the first ask at or after the activation, at the interval's grain")
        XCTAssertEqual(c.slept.count, 4)
    }

    /// NEVER IN FRONT: nil, and only after the WHOLE bound — the last ask is AT the deadline, so an activation
    /// that lands exactly then still counts, and the last sleep is cut to end there rather than overshoot it.
    func testAnApplicationThatNeverComesToTheFrontIsNilAfterTheWholeBound() {
        let c = Clock()
        XCTAssertNil(wait(c, bound: 0.25, every: 0.1, frontFrom: nil))
        XCTAssertEqual(c.slept.count, 3)
        XCTAssertEqual(c.slept.reduce(0, +), 0.25, accuracy: 1e-9, "waited exactly the bound")
        XCTAssertEqual(c.asked.last ?? 0, 100.25, accuracy: 1e-9, "asked once more AT the deadline")

        let d = Clock()
        XCTAssertEqual(wait(d, bound: 0.25, every: 0.1, frontFrom: 100.25) ?? -1, 0.25, accuracy: 1e-9,
                       "in front exactly at the deadline is in front")
    }

    // MARK: whose front a ⌘V may go to

    private let own: Int32 = 500, target: Int32 = 700, other: Int32 = 900

    /// A WINDOW's paste goes only into the window's own application — never another's, never an unknown front.
    func testAWindowsPasteGoesOnlyIntoItsOwnApplication() {
        XCTAssertTrue(FrontmostWait.accepts(front: target, windowOwner: target, ownPID: own))
        XCTAssertFalse(FrontmostWait.accepts(front: other, windowOwner: target, ownPID: own))
        XCTAssertFalse(FrontmostWait.accepts(front: own, windowOwner: target, ownPID: own))
        XCTAssertFalse(FrontmostWait.accepts(front: nil, windowOwner: target, ownPID: own))
    }

    /// A DISPLAY's paste goes to whatever is in front on it — but NEVER into this host itself: the display's raise
    /// hides the host app only ASYNCHRONOUSLY (`OwnWindows`), and while it is still the front one a ⌘V lands in it
    /// (the This Mac terminal, the dashboard) — a window the display's picture never even shows (`SelfCapture`).
    func testADisplaysPasteGoesToWhateverIsInFrontButNeverThisHost() {
        XCTAssertTrue(FrontmostWait.accepts(front: other, windowOwner: nil, ownPID: own))
        XCTAssertTrue(FrontmostWait.accepts(front: nil, windowOwner: nil, ownPID: own), "unknown is not this host")
        XCTAssertFalse(FrontmostWait.accepts(front: own, windowOwner: nil, ownPID: own))
    }

    /// ...and the bounded wait waits that out: the host's hide taking effect lets the ⌘V go, and a host still in
    /// front at the deadline posts nothing.
    func testADisplaysPasteWaitsForThisHostToLeaveTheFront() throws {
        let c = Clock()
        let took = try XCTUnwrap(FrontmostWait.wait(bound: 1, every: 0.01, now: { c.t }, sleep: { c.t += $0 }) {
            FrontmostWait.accepts(front: c.t >= 100.2 ? self.other : self.own, windowOwner: nil, ownPID: self.own)
        })
        XCTAssertEqual(took, 0.2, accuracy: 1e-6)
        let d = Clock()
        XCTAssertNil(FrontmostWait.wait(bound: 1, every: 0.01, now: { d.t }, sleep: { d.t += $0 }) {
            FrontmostWait.accepts(front: self.own, windowOwner: nil, ownPID: self.own)
        })
    }

    /// A non-zero guard: a probe that never answers true must not be asked forever, nor never.
    func testTheProbeIsAskedOncePerIntervalAndNoMore() {
        let c = Clock()
        XCTAssertNil(wait(c, bound: 1.0, every: 0.01, frontFrom: nil))
        XCTAssertEqual(c.asked.count, 101, "at 0, every 10 ms, and at the deadline")
    }
}
