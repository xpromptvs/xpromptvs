import XCTest
@testable import ShellstormCore

/// A client window's macOS full screen, as its PAGE asks for it (`__rdevShell.setFullscreen`) and as
/// AppKit reports transitions. The rule under test: the window is the page's to give back ONLY if the
/// page put it there, and a transition the PERSON made is theirs.
final class FullScreenOwnershipTests: XCTestCase {
    private typealias L = FullScreenOwnership.Landing

    /// The page's own round trip: in, settle, out, settle.
    func testThePageAsksAndGivesBack() {
        var o = FullScreenOwnership()
        XCTAssertEqual(o.pageAsks(true, isFullScreen: false), .toggle)
        o.began()
        XCTAssertEqual(o.landed(isFullScreen: true, failed: false), L(pageLost: false, settle: true))
        XCTAssertEqual(o.settle(isFullScreen: true), .none)
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .toggle)
        o.began()
        XCTAssertEqual(o.landed(isFullScreen: false, failed: false), L(pageLost: false, settle: true),
                       "leaving by the page's own hand is not the page LOSING it")
        XCTAssertEqual(o.settle(isFullScreen: false), .none)
    }

    func testAFullScreenThePersonMadeIsNeverTheOnePageGivesBack() {
        var o = FullScreenOwnership()
        XCTAssertEqual(o.pageAsks(true, isFullScreen: true), .none)
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .none, "the person's full screen stays")
    }

    func testThePersonLeavingThePagesFullScreenTellsThePage() {
        var o = FullScreenOwnership()
        _ = o.pageAsks(true, isFullScreen: false); o.began()
        _ = o.landed(isFullScreen: true, failed: false); _ = o.settle(isFullScreen: true)
        o.began()                                           // the green button — nothing the page asked for
        XCTAssertEqual(o.landed(isFullScreen: false, failed: false), L(pageLost: true, settle: false))
        XCTAssertEqual(o.pageAsks(false, isFullScreen: false), .none, "nothing left to give back")
    }

    /// FOUND BY REVIEW: the page's mode over the PERSON's full screen, then the person leaving it. The
    /// window went straight back in, because the landing re-applied the page's wish.
    func testThePersonLeavingTheirOwnFullScreenUnderThePagesModeDoesNotBounceBack() {
        var o = FullScreenOwnership()
        XCTAssertEqual(o.pageAsks(true, isFullScreen: true), .none)
        o.began()
        XCTAssertEqual(o.landed(isFullScreen: false, failed: false), L(pageLost: true, settle: false))
        XCTAssertEqual(o.settle(isFullScreen: false), .none)
    }

    func testChangingItsMindMidTransitionIsAppliedOnceTheTransitionSettles() {
        var o = FullScreenOwnership()
        XCTAssertEqual(o.pageAsks(true, isFullScreen: false), .toggle)
        o.began()
        XCTAssertEqual(o.pageAsks(false, isFullScreen: false), .none, "AppKit ignores a toggle mid-transition")
        XCTAssertEqual(o.landed(isFullScreen: true, failed: false), L(pageLost: false, settle: true))
        XCTAssertEqual(o.settle(isFullScreen: true), .toggle, "taken back out once it has arrived")
        o.began()
        XCTAssertEqual(o.landed(isFullScreen: false, failed: false), L(pageLost: false, settle: true))
        XCTAssertEqual(o.settle(isFullScreen: false), .none)
    }

    /// FOUND BY REVIEW: the settle is decided when it RUNS, not when the landing queued it.
    func testChangingItsMindBackBeforeTheSettleRunsMovesNothing() {
        var o = FullScreenOwnership()
        _ = o.pageAsks(true, isFullScreen: false); o.began()
        _ = o.pageAsks(false, isFullScreen: false)
        _ = o.landed(isFullScreen: true, failed: false)
        XCTAssertEqual(o.pageAsks(true, isFullScreen: true), .none)
        XCTAssertEqual(o.settle(isFullScreen: true), .none, "still wanted: not out and back in")
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .toggle, "and still the page's to give back")
    }

    func testAskingDuringThePersonsOwnEntryOwnsNothing() {
        var o = FullScreenOwnership()
        o.began()
        XCTAssertEqual(o.pageAsks(true, isFullScreen: false), .none)
        XCTAssertEqual(o.landed(isFullScreen: true, failed: false), L(pageLost: false, settle: false))
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .none, "the person put it there")
    }

    func testAskingDuringThePersonsExitIsAppliedOnceItLands() {
        var o = FullScreenOwnership()
        o.began()                                           // the person leaving their own full screen
        XCTAssertEqual(o.pageAsks(true, isFullScreen: true), .none)
        XCTAssertEqual(o.landed(isFullScreen: false, failed: false), L(pageLost: false, settle: true),
                       "the page asked after the person began leaving: that is a fresh ask, not a loss")
        XCTAssertEqual(o.settle(isFullScreen: false), .toggle)
    }

    func testAFailedEntryIsNotThePageLosingItAndIsNotRetried() {
        var o = FullScreenOwnership()
        _ = o.pageAsks(true, isFullScreen: false); o.began()
        XCTAssertEqual(o.landed(isFullScreen: false, failed: true), L(pageLost: false, settle: false),
                       "the page keeps its own full screen when the window's could not start")
        o.began()                                           // some later transition of the person's
        XCTAssertEqual(o.landed(isFullScreen: false, failed: false), L(pageLost: false, settle: true))
        XCTAssertEqual(o.settle(isFullScreen: false), .none, "no cue to try again behind their back")
        XCTAssertEqual(o.pageAsks(false, isFullScreen: false), .none)
    }

    /// FOUND BY REVIEW: a failed EXIT left the window full screen and owned by nobody.
    func testAFailedExitLeavesItThePagesToGiveBackLater() {
        var o = FullScreenOwnership()
        _ = o.pageAsks(true, isFullScreen: false); o.began()
        _ = o.landed(isFullScreen: true, failed: false); _ = o.settle(isFullScreen: true)
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .toggle); o.began()
        XCTAssertEqual(o.landed(isFullScreen: true, failed: true), L(pageLost: false, settle: false),
                       "no retry loop against a failing AppKit")
        XCTAssertEqual(o.pageAsks(true, isFullScreen: true), .none)
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .toggle, "still the page's")
    }

    func testTheToggleItselfCountsAsTheTransitionUntilAppKitSaysSo() {
        var o = FullScreenOwnership()
        XCTAssertEqual(o.pageAsks(true, isFullScreen: false), .toggle)
        XCTAssertEqual(o.pageAsks(true, isFullScreen: false), .none, "a second toggle would cancel the first")
    }

    /// FOUND BY REVIEW: a toggle AppKit never started must not leave every later ask refused.
    func testAToggleAppKitIgnoredIsForgotten() {
        var o = FullScreenOwnership()
        XCTAssertEqual(o.pageAsks(true, isFullScreen: false), .toggle)
        let id = o.requestID
        o.toggleIgnored(id: id, isFullScreen: false)
        XCTAssertEqual(o.pageAsks(false, isFullScreen: false), .none, "never went in: nothing to give back")
        XCTAssertEqual(o.pageAsks(true, isFullScreen: false), .toggle, "and a new ask is heard")
    }

    func testAnIgnoredVerdictForAnOlderToggleChangesNothing() {
        var o = FullScreenOwnership()
        _ = o.pageAsks(true, isFullScreen: false)
        let old = o.requestID
        o.began(); _ = o.landed(isFullScreen: true, failed: false); _ = o.settle(isFullScreen: true)
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .toggle)
        o.toggleIgnored(id: old, isFullScreen: true)        // the FIRST toggle's watchdog, firing late
        XCTAssertEqual(o.pageAsks(false, isFullScreen: true), .none, "the second toggle is still in flight")
    }

    /// FOUND BY REVIEW: a page that goes (its web process died, it reloaded) leaves no one to press Exit.
    func testAPageThatGoesTakesItsFullScreenWithIt() {
        var o = FullScreenOwnership()
        _ = o.pageAsks(true, isFullScreen: false); o.began()
        _ = o.landed(isFullScreen: true, failed: false); _ = o.settle(isFullScreen: true)
        XCTAssertEqual(o.pageGone(isFullScreen: true), .toggle)
    }

    func testAPageThatGoesLeavesThePersonsFullScreenAlone() {
        var o = FullScreenOwnership()
        _ = o.pageAsks(true, isFullScreen: true)
        XCTAssertEqual(o.pageGone(isFullScreen: true), .none)
    }
}
