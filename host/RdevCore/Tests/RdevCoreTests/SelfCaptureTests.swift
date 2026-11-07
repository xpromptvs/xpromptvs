import XCTest
@testable import RdevCore

/// The predicate that keeps the pairing QR out of every path to a client.
///
/// The NEGATIVE arms are the point: a predicate that matches everything hides the user's whole
/// desktop, and one that matches nothing reinstates the disclosure this exists to stop. BOTH fail
/// silently in the product — the stream keeps running and looks plausible either way — so neither is
/// observable without these.
final class SelfCaptureTests: XCTestCase {
    private let mine: Int32 = 4242
    private let theirs: Int32 = 99

    func testOurOwnWindowIsAlwaysDenied() {
        XCTAssertTrue(SelfCapture.isOwnWindow(ownerPID: mine, selfPID: mine))
    }

    /// NEGATIVE CONTROL: a foreign window must never be denied. Over-matching blanks the user's real
    /// content, which reads as "capture is broken" rather than as a security control.
    func testForeignWindowIsNeverDenied() {
        XCTAssertFalse(SelfCapture.isOwnWindow(ownerPID: theirs, selfPID: mine))
    }

    /// FAIL CLOSED. ScreenCaptureKit does not always attribute a window to an application. Treating
    /// "unknown" as "not ours" would open the hole again for exactly the windows whose provenance
    /// could not be established.
    func testUnknownOwnerIsDeniedNotAllowed() {
        XCTAssertTrue(SelfCapture.isOwnWindow(ownerPID: nil, selfPID: mine))
    }

    // MARK: - the display filter decision

    func testExcludesWhenOurApplicationResolves() {
        XCTAssertEqual(SelfCapture.displayFilterDecision(ownApplicationResolved: true), .exclude)
    }

    /// THE ARM THAT MATTERS. An empty exclusion list excludes nothing and captures happily, so an
    /// unresolvable application must REFUSE rather than produce a stream that looks protected.
    func testRefusesWhenOurApplicationCannotBeResolved() {
        XCTAssertEqual(SelfCapture.displayFilterDecision(ownApplicationResolved: false), .refuse)
    }

    /// REGRESSION ARM. A previous version took current window visibility as an input and returned
    /// "exclude nothing" when the host happened to have no windows open — which reopened the
    /// window-appears-later exposure, because the app keeps sharing with every window closed and
    /// `reconfigure()` never refreshes the filter. The decision must not depend on visibility at all,
    /// so there is no visibility parameter to pass and this test asserts the shape that makes the
    /// mistake unexpressible.
    func testDecisionDoesNotDependOnCurrentWindowVisibility() {
        // Same answer regardless of what is on screen, because on-screen state is not an input.
        XCTAssertEqual(SelfCapture.displayFilterDecision(ownApplicationResolved: true), .exclude)
        XCTAssertEqual(SelfCapture.displayFilterDecision(ownApplicationResolved: false), .refuse)
    }

    // MARK: - displayExclusion: the resolution has a memory

    /// A snapshot that names us is used as-is. The baseline, and the case that must not regress.
    func testCurrentResolutionIsUsedWhenPresent() {
        XCTAssertEqual(SelfCapture.displayExclusion(current: [7], remembered: [3]), [7])
    }

    /// THE BUG THIS EXISTS FOR. ScreenCaptureKit names an application only while it HAS shareable
    /// windows, so a host whose windows are all closed vanishes from `SCShareableContent` — and the
    /// product goes on sharing with every window closed. Refusing there is safe and also breaks
    /// display capture outright, which is what `gate-capture-boundary.sh` measured: zero frames, and
    /// "REFUSING display 1: own application unresolved" in the host log.
    func testAnOmittedSnapshotFallsBackToWhatWasResolvedBefore() {
        XCTAssertEqual(SelfCapture.displayExclusion(current: [], remembered: [3]), [3])
    }

    /// STILL FAIL-CLOSED where it must be. Never resolvable means nothing to hand SCK, and an empty
    /// exclusion excludes nothing while capturing happily — the invisible fail-open this whole
    /// predicate exists to prevent. Memory softens "not right now"; it must not soften "never".
    func testNeverResolvedStillRefuses() {
        XCTAssertNil(SelfCapture.displayExclusion(current: [Int](), remembered: []))
    }

    /// The NEGATIVE CONTROL for the fallback: memory must not OVERRIDE a live resolution. Returning
    /// the remembered list unconditionally would pass both tests above while pinning the exclusion to
    /// a stale object forever, which no later run could correct.
    func testAFreshResolutionWinsOverMemory() {
        let out = SelfCapture.displayExclusion(current: [9], remembered: [3])
        XCTAssertEqual(out, [9])
        XCTAssertNotEqual(out, [3])
    }
}
