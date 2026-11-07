import XCTest
@testable import RdevCore

final class KeyframeDebounceTests: XCTestCase {
    // A FRESH SUBSCRIBE MUST GET ITS KEYFRAME IMMEDIATELY, or the debounce trades a bitrate storm for
    // a black window — the client has nothing to decode until an IDR arrives.
    func testTheFirstRequestForASourceIsAlwaysServed() {
        var debounce = KeyframeDebounce(minimumInterval: 0.5)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 0), 0)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:2", now: 0), 0)
    }

    // The storm this exists for: 60 requests in fifteen seconds became 60 IDRs and 99% of the wire.
    func testRequestsInsideTheIntervalAreSuppressed() {
        var debounce = KeyframeDebounce(minimumInterval: 0.5)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 10.0), 0)
        XCTAssertGreaterThan(debounce.waitBeforeKeyframe(source: "win:1", now: 10.1), 0)
        XCTAssertGreaterThan(debounce.waitBeforeKeyframe(source: "win:1", now: 10.49), 0)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 10.5), 0)
    }

    // A SUPPRESSED REQUEST MUST NOT PUSH THE WINDOW OUT, or a receiver asking faster than the
    // interval would be starved indefinitely — the clock advances only when an IDR is actually sent.
    func testSuppressionDoesNotExtendTheWindow() {
        var debounce = KeyframeDebounce(minimumInterval: 0.5)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 0), 0)
        for tick in stride(from: 0.1, to: 0.5, by: 0.1) {
            XCTAssertGreaterThan(debounce.waitBeforeKeyframe(source: "win:1", now: tick), 0)
        }
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 0.5), 0, "the window must run from the last EMISSION, not the last request")
    }

    // PER SOURCE, NOT PER SESSION. rdev streams a window per track and they keyframe independently;
    // a session-wide clock would let a busy window starve a quiet one of its first IDR — the same
    // shape as the session-scoped NACK keyframe gate this project already had to fix.
    func testTheIntervalIsPerSource() {
        var debounce = KeyframeDebounce(minimumInterval: 0.5)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 0), 0)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:2", now: 0.1), 0)
        XCTAssertGreaterThan(debounce.waitBeforeKeyframe(source: "win:1", now: 0.1), 0)
    }

    // A re-subscribe builds a fresh encoder and needs an IDR at once; inheriting the old clock would
    // leave that window black for up to the interval.
    func testForgettingASourceServesItImmediatelyAgain() {
        var debounce = KeyframeDebounce(minimumInterval: 0.5)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 0), 0)
        XCTAssertGreaterThan(debounce.waitBeforeKeyframe(source: "win:1", now: 0.2), 0)
        debounce.forget(source: "win:1")
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 0.2), 0)
    }
}

extension KeyframeDebounceTests {
    // THE WAIT IS THE TIME REMAINING, NOT THE WHOLE INTERVAL. The caller defers by exactly this, so
    // returning the full interval would land every deferred IDR late by however long had already
    // elapsed — and a keyframe that arrives late is the stall this debounce exists to avoid.
    func testTheWaitIsWhatIsLeftOfTheInterval() {
        var debounce = KeyframeDebounce(minimumInterval: 0.5)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 100), 0)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 100.2), 0.3, accuracy: 0.001)
        XCTAssertEqual(debounce.waitBeforeKeyframe(source: "win:1", now: 100.45), 0.05, accuracy: 0.001)
    }
}

// MARK: - deferredKeyframeAction

/// WHY THIS EXISTS. Observed on a saturated encoder: after one burst of keyframes the host reported
/// `0 requested` for 40+ SECONDS while the receiver sent `pli=21-29` every window. Requests arrived,
/// were deferred, and the deferred IDR never reached the encoder — so the engine's age-aware responder,
/// which marks a keyframe response outstanding when it forwards a request and reopens only when one is
/// SENT, stopped forwarding the receiver's retries. The stream could not recover at all.
///
/// The hole was a guard that silently discarded any request while a pending entry existed. That is safe
/// only if the pending work ALWAYS runs; nothing guaranteed it.
final class DeferredKeyframeActionTests: XCTestCase {
    func testArmsWhenNothingIsPending() {
        XCTAssertEqual(deferredKeyframeAction(wait: 0.3, pendingDeadline: nil, now: 100), .arm(wait: 0.3))
    }

    func testAPendingIdrStillInTheFutureCoversTheRequest() {
        // The ordinary case: a retry arrives while the deferred IDR is still scheduled.
        XCTAssertEqual(deferredKeyframeAction(wait: 0.3, pendingDeadline: 100.4, now: 100), .alreadyArmed)
    }

    func testAPENDINGIDRPASTITSDEADLINEISREARMED() {
        // THE DEADLOCK. If the scheduled work never ran — a stalled queue, an encoder mid-rebuild —
        // the entry would otherwise sit there forever and every later request would be dropped
        // against it, with no keyframe ever produced and no log line anywhere.
        XCTAssertEqual(deferredKeyframeAction(wait: 0.3, pendingDeadline: 100.0, now: 103), .rearmStale(wait: 0.3))
    }

    func testTheGRACEPeriodTolerationsOrdinaryLateness() {
        // A work item a little late is normal under load and must NOT be treated as lost — re-arming
        // on every slightly-late fire would turn one keyframe into a storm.
        XCTAssertEqual(deferredKeyframeAction(wait: 0.3, pendingDeadline: 100.0, now: 100.5), .alreadyArmed)
    }
}
