import ShellstormCore
import XCTest

final class AppLifecycleTests: XCTestCase {
    /// The statuses as `E2EStatusCode` numbers them (unenrolled 1, enrolling 2, interrupted 4, ready 5;
    /// 3 was §12.1's polled confirmation, gone with the courier).
    private let unenrolled = 1, enrolling = 2, interrupted = 4, ready = 5

    private func quits(sharing: Bool = false, clientWindows: Int = 0, pendingConnects: Int = 0, e2eStatus: Int = 1,
                       sessionTabs: Int = 0) -> Bool {
        AppLifecycle.quitsAfterLastWindowClosed(sharing: sharing, clientWindows: clientWindows,
                                                pendingConnects: pendingConnects, e2eStatus: e2eStatus,
                                                sessionTabs: sessionTabs)
    }

    func testQuitsOnlyWithNothingLeft() {
        XCTAssertTrue(quits())
        XCTAssertTrue(quits(e2eStatus: ready))
    }

    func testSharingKeepsTheAppAlive() {
        XCTAssertFalse(quits(sharing: true))
    }

    /// The pending connect's window is ORDERED OUT, which AppKit does not count — the case that quit.
    func testAnOrderedOutClientWindowKeepsTheAppAlive() {
        XCTAssertFalse(quits(clientWindows: 1))
    }

    /// `connectSession` resolves the listing BEFORE it opens a window: an attempt can be pending with
    /// no window yet.
    func testAPendingAttemptWithNoWindowYetKeepsTheAppAlive() {
        XCTAssertFalse(quits(pendingConnects: 1))
    }

    /// A passkey ceremony in flight — its prompt up, its grant being written — must not be quit under.
    func testACeremonyInFlightKeepsTheAppAlive() {
        XCTAssertFalse(quits(e2eStatus: enrolling))
        XCTAssertTrue(quits(e2eStatus: 3), "3 means nothing any more")
    }

    /// `interrupted` is a PERSISTED §9.2 operation this build cannot resume: nothing runs in this
    /// process for it, so it must not hold the app open forever.
    func testAnInterruptedEnrollmentDoesNotKeepTheAppAlive() {
        XCTAssertTrue(quits(e2eStatus: interrupted))
        XCTAssertTrue(quits(e2eStatus: unenrolled))
    }

    /// The re-ask when the ceremony SETTLES: leaving 2 for anything else, and only that.
    func testCeremonySettlesOnlyWhenItLeavesTheInFlightStatus() {
        XCTAssertTrue(AppLifecycle.ceremonySettled(from: enrolling, to: ready))
        XCTAssertTrue(AppLifecycle.ceremonySettled(from: enrolling, to: unenrolled))
        XCTAssertFalse(AppLifecycle.ceremonySettled(from: enrolling, to: enrolling))
        XCTAssertFalse(AppLifecycle.ceremonySettled(from: unenrolled, to: enrolling))
        XCTAssertFalse(AppLifecycle.ceremonySettled(from: ready, to: ready))
        XCTAssertFalse(AppLifecycle.ceremonySettled(from: nil, to: ready))
    }

    /// 2026-10-07: the Mac mini, added by code while sharing, was never listed — publishing started only at Share.
    /// The tick starts it on the move INTO ready, and only that.
    func testBecameReadyIsTheMoveIntoReadyOnly() {
        XCTAssertTrue(AppLifecycle.becameReady(from: unenrolled, to: ready))
        XCTAssertTrue(AppLifecycle.becameReady(from: enrolling, to: 7))
        XCTAssertFalse(AppLifecycle.becameReady(from: ready, to: ready))
        XCTAssertFalse(AppLifecycle.becameReady(from: ready, to: 8), "ready to ready is no news")
        XCTAssertFalse(AppLifecycle.becameReady(from: ready, to: unenrolled))
        XCTAssertFalse(AppLifecycle.becameReady(from: nil, to: ready), "launched ready: its Share lists it")
    }

    /// THE SESSION BELONGS TO THE APP (docs/desktop-app.md, "The local window"): shells open in This Mac
    /// keep running in the menu bar with every window closed, as sharing does. ⌘Q or the status item's
    /// Quit ends them.
    func testTheSessionsTabsKeepTheAppAlive() {
        XCTAssertFalse(quits(sessionTabs: 1))
        XCTAssertTrue(quits(sessionTabs: 0))
    }

    /// The last tab going — a shell exiting, a tmux session killed elsewhere — with no window open is the
    /// moment an app kept alive only by its tabs must ask the rule again.
    func testTheLastTabGoingReAsksTheRule() {
        XCTAssertTrue(AppLifecycle.sessionEmptied(from: 1, to: 0))
        XCTAssertTrue(AppLifecycle.sessionEmptied(from: 3, to: 0))
        XCTAssertFalse(AppLifecycle.sessionEmptied(from: nil, to: 0), "the first tick is not a change")
        XCTAssertFalse(AppLifecycle.sessionEmptied(from: 0, to: 0))
        XCTAssertFalse(AppLifecycle.sessionEmptied(from: 2, to: 1))
        XCTAssertFalse(AppLifecycle.sessionEmptied(from: 0, to: 1))
    }
}
