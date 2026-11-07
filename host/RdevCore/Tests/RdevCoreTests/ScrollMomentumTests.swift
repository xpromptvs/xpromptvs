import XCTest
@testable import RdevCore

final class ScrollMomentumTests: XCTestCase {
    /// Run a glide to completion on a fixed tick and report every step.
    private func glide(velocityX vx: Double, velocityY vy: Double,
                       tick: Double = 1.0 / 120, start: Double = 1000,
                       limit: Int = 10_000) -> [ScrollMomentum.Step] {
        var m = ScrollMomentum()
        guard m.launch(velocityX: vx, velocityY: vy, now: start) else { return [] }
        var steps: [ScrollMomentum.Step] = []
        var t = start
        while steps.count < limit {
            t += tick
            guard let step = m.tick(now: t) else { break }
            steps.append(step)
            if step.phase == .end { break }
        }
        return steps
    }

    // MARK: - launching

    /// A lift too slow to be a flick starts NOTHING, and says so — the caller needs to tell that from
    /// a glide of zero length, because one owes the app an `end` event and the other does not.
    func testASlowLiftIsNotAFlick() {
        var m = ScrollMomentum()
        XCTAssertFalse(m.launch(velocityX: 0, velocityY: ScrollMomentum.minimumLaunchSpeed - 1, now: 0))
        XCTAssertFalse(m.isRunning)
        XCTAssertNil(m.tick(now: 1))
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: ScrollMomentum.minimumLaunchSpeed, now: 0))
        XCTAssertTrue(m.isRunning)
    }

    /// The floor is on the SPEED, not on either axis: a diagonal flick that is slow on both axes
    /// separately can still be a real flick.
    func testTheLaunchFloorIsOnTheSpeedNotOnEitherAxis() {
        var m = ScrollMomentum()
        let each = ScrollMomentum.minimumLaunchSpeed * 0.8   // 0.8 each, 1.13 combined
        XCTAssertTrue(m.launch(velocityX: each, velocityY: each, now: 0))
    }

    /// A hostile or broken client must not be able to throw the host's scroll to infinity. The cap is
    /// on the VECTOR so the direction of the flick survives it.
    func testAnAbsurdVelocityIsCappedWithItsDirectionIntact() {
        let steps = glide(velocityX: 3_000_000, velocityY: 6_000_000)
        let dx = steps.reduce(0) { $0 + $1.dx }
        let dy = steps.reduce(0) { $0 + $1.dy }
        XCTAssertEqual(dy / dx, 2, accuracy: 0.001, "the 1:2 direction of the flick was not preserved")
        let travelled = (dx * dx + dy * dy).squareRoot()
        XCTAssertEqual(travelled, ScrollMomentum.maximumLaunchSpeed * ScrollMomentum.timeConstant,
                       accuracy: 20, "the capped glide travelled further than the cap allows")
    }

    func testANonFiniteVelocityIsRefused() {
        var m = ScrollMomentum()
        XCTAssertFalse(m.launch(velocityX: .nan, velocityY: 500, now: 0))
        XCTAssertFalse(m.launch(velocityX: 500, velocityY: .infinity, now: 0))
    }

    // MARK: - the curve

    /// THE DISTANCE IS THE INTEGRAL, so it must not depend on the tick rate. This is the property a
    /// per-tick decay factor (`v *= 0.95` every frame) silently fails: at a different tick rate the
    /// same flick throws a different distance, and a stalled queue throws further than a healthy one.
    func testTheDistanceIsIndependentOfTheTickRate() {
        let travel = { (tick: Double) -> Double in
            self.glide(velocityX: 0, velocityY: 2000, tick: tick).reduce(0) { $0 + $1.dy }
        }
        let fast = travel(1.0 / 240)
        let slow = travel(1.0 / 30)
        XCTAssertEqual(fast, slow, accuracy: fast * 0.02,
                       "\(fast) at 240Hz vs \(slow) at 30Hz — the curve depends on the timer")
    }

    /// The whole glide is `speed * timeConstant` long, which is the one number that decides how far a
    /// flick throws. Pinned so that changing the feel is a deliberate edit rather than a drift.
    func testAFlickThrowsSpeedTimesTheTimeConstant() {
        let travelled = glide(velocityX: 0, velocityY: 1200).reduce(0) { $0 + $1.dy }
        // The tolerance is the tail the stop threshold discards: a glide abandoned at `stopSpeed`
        // leaves `stopSpeed * timeConstant` points untravelled, about 8.
        XCTAssertEqual(travelled, 1200 * ScrollMomentum.timeConstant, accuracy: 10)
    }

    /// Monotonic decay: every step is shorter than the one before it, which is what makes it read as
    /// a glide slowing down rather than as a stream of deltas that happens to stop.
    func testEveryStepIsShorterThanTheOneBefore() {
        let steps = glide(velocityX: 0, velocityY: 2000)
        XCTAssertGreaterThan(steps.count, 10)
        for (a, b) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThan(b.dy, a.dy, "the glide sped up between two steps")
        }
    }

    func testTheGlideRunsInTheDirectionItWasLaunched() {
        let up = glide(velocityX: 0, velocityY: -900).reduce(0) { $0 + $1.dy }
        let left = glide(velocityX: -900, velocityY: 0).reduce(0) { $0 + $1.dx }
        XCTAssertLessThan(up, 0)
        XCTAssertLessThan(left, 0)
    }

    // MARK: - phases

    /// EXACTLY ONE `begin`, EXACTLY ONE `end`, AND THE `end` LAST. An app reads this trio to decide a
    /// rubber-band may release; a missing `end` leaves it believing the glide never stopped.
    func testAGlideBeginsOnceAndEndsOnce() {
        let steps = glide(velocityX: 0, velocityY: 2000)
        XCTAssertEqual(steps.filter { $0.phase == .begin }.count, 1)
        XCTAssertEqual(steps.filter { $0.phase == .end }.count, 1)
        XCTAssertEqual(steps.first?.phase, .begin)
        XCTAssertEqual(steps.last?.phase, .end)
        XCTAssertTrue(steps.dropFirst().dropLast().allSatisfy { $0.phase == .continuing })
    }

    /// A tick that arrives long after the launch decays the whole glide at once. It must still emit
    /// the `begin` before the `end` — an app that sees an `end` for a momentum it never saw begin is
    /// the failure this ordering exists to prevent.
    func testAVeryLateFirstTickStillBeginsBeforeItEnds() {
        var m = ScrollMomentum()
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 4000, now: 0))
        let first = m.tick(now: 10)
        XCTAssertEqual(first?.phase, .begin)
        XCTAssertEqual(m.tick(now: 10.01)?.phase, .end)
        XCTAssertNil(m.tick(now: 10.02), "the glide kept running past its end")
    }

    /// A late tick delivers the distance it owes ONCE and then stops. The integral converges, so
    /// nothing needs to clamp the interval — which is why there is no clamp to get wrong.
    func testALateTickDeliversTheRemainingDistanceExactlyOnce() {
        var m = ScrollMomentum()
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 1000, now: 0))
        let all = (m.tick(now: 60)?.dy ?? 0) + (m.tick(now: 60.01)?.dy ?? 0)
        XCTAssertEqual(all, 1000 * ScrollMomentum.timeConstant, accuracy: 0.5)
    }

    func testTickReportsNothingWhenNoGlideIsRunning() {
        var m = ScrollMomentum()
        XCTAssertNil(m.tick(now: 1))
    }

    // MARK: - cancelling

    /// Cancelling a RUNNING glide owes the app an `end`; cancelling one that never emitted its
    /// `begin` owes nothing. Posting an `end` that was never begun reads to an app that rubber-bands
    /// as a second release.
    func testCancelOwesAnEndOnlyOnceTheGlideHasBegun() {
        var m = ScrollMomentum()
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 2000, now: 0))
        XCTAssertFalse(m.cancel(), "an end was owed for a glide that had posted nothing")

        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 2000, now: 0))
        _ = m.tick(now: 0.008)
        XCTAssertTrue(m.cancel())
        XCTAssertFalse(m.isRunning)
        XCTAssertFalse(m.cancel(), "a second cancel owed a second end")
        XCTAssertNil(m.tick(now: 0.02))
    }

    /// A glide that ran to its own `end` owes nothing more.
    func testCancelAfterANaturalEndOwesNothing() {
        var m = ScrollMomentum()
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 200, now: 0))
        XCTAssertEqual(m.tick(now: 0.1)?.phase, .begin)
        XCTAssertEqual(m.tick(now: 1.0)?.phase, .end)
        XCTAssertFalse(m.cancel())
    }

    /// `reset` is the focus-change route: forget the glide and owe NOTHING, because the target that
    /// would receive the `end` is no longer the target that saw the flick.
    func testResetForgetsTheGlideWithoutOwingAnEnd() {
        var m = ScrollMomentum()
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 2000, now: 0))
        _ = m.tick(now: 0.008)
        m.reset()
        XCTAssertFalse(m.isRunning)
        XCTAssertFalse(m.cancel())
        XCTAssertNil(m.tick(now: 0.02))
    }

    /// A fresh flick REPLACES a running glide rather than adding to it — two flicks in a row must not
    /// compound into one that outruns the cap.
    func testANewLaunchReplacesTheGlideInFlight() {
        var m = ScrollMomentum()
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 4000, now: 0))
        _ = m.tick(now: 0.008)
        XCTAssertTrue(m.launch(velocityX: 0, velocityY: 500, now: 0.008))
        guard let first = m.tick(now: 0.016) else { return XCTFail("the replacement glide produced no step") }
        XCTAssertEqual(first.phase, .begin, "the replacement glide did not begin afresh")
        XCTAssertLessThan(first.dy, 5, "the replacement glide carried the speed of the one it replaced")
    }

    // MARK: - the wire values

    /// The CG constants, pinned: begin 1, continue 2, end 3. They are not exposed as Swift constants,
    /// so the only thing standing between a typo here and a silently wrong field is this test.
    func testTheMomentumPhaseValuesAreTheCoreGraphicsOnes() {
        XCTAssertEqual(MomentumPhase.begin.cgValue, 1)
        XCTAssertEqual(MomentumPhase.continuing.cgValue, 2)
        XCTAssertEqual(MomentumPhase.end.cgValue, 3)
    }
}
