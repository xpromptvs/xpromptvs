import XCTest
@testable import RdevAppHost

/// `E2EHost.shared`'s listing-change hook (`onListingChange`) — the seam the app uses to push its
/// state to the dashboard instead of the dashboard polling it.
///
/// **This drives `forgetListing()` directly, never `forget()`.** `E2EHost.shared` is a
/// process-global singleton, and `forget()`'s second half is `currentService()?.forget()`, which —
/// the moment ANYTHING in this binary has ever named a signalling base — reaches a real
/// `E2EIdentityService` over the DEFAULT `FileRecordStore`, i.e.
/// `~/Library/Application Support/dev.rdev.host/`: the developer's actual keys and trust record.
/// Nothing does that today (`base` starts nil and no test here calls `service(base:)`), but that
/// was, until this fix, enforced by a comment rather than by the code — a future test anywhere in
/// this target that named a base would have made `forget()` here delete a real installation.
/// `forgetListing()` (made `internal`, not `private`, for exactly this) touches only the in-memory
/// `ListingStore` and the (nil, in this target) watcher, never `E2EIdentityService`, so it is safe
/// to call directly no matter what else in the binary has or has not named a base. **Second layer**:
/// `host/RdevAppHost/BUILD.bazel` sets `RDEV_E2E_STORE=dev.rdev.test.rdevapphost` for this
/// `swift_test`, so even a future test that DOES call `service(base:)`/`listSessions`/`forget()`
/// still cannot reach the real store — belt and suspenders, not a substitute for the first layer.
///
/// **Why `landed` and `streamed` are not driven here at all.** Both are private and reached only
/// through `listSessions(base:refresh:)`, which calls `service(base:)` and so builds a real
/// `E2EIdentityService` over `E2EHostIdentity.live(signalingBase:)` — real filesystem state and, via
/// `retryRegistrationInBackground`, a real network call. There is no seam at the `E2EHost` level to
/// drive that without touching either, even with the store redirected. `landed`, `streamed` and
/// `forgetListing()` all funnel through the identical `notifyListing()` helper with the identical
/// "mutate `store`/`watcher`, unlock, then notify" shape, so the `forgetListing()` test below
/// exercises the mechanism all three share; the underlying `ListingStore` mutations themselves are
/// covered independently, with no lock and no hook involved, by `ListingStoreTests.swift`.
///
/// **Method names in this class are ordered ON PURPOSE, and that ordering is load-bearing.**
/// `E2EHost.shared` is one process-global singleton with one real `NSLock`, and this XCTest bundle
/// runs every test in one process — so if `testForgetListingCallsTheHookExactlyOnceAndOutsideTheLock`
/// ever DOES catch its targeted regression (the hook called while `lock` is held), the thread it
/// launched is left parked inside `NSLock.lock()` FOREVER: nothing ever unparks it, because the lock
/// it wants is the one its own call stack is still holding two frames up. That failure is caught and
/// reported promptly (see below), but the lock stays stuck for the rest of THIS PROCESS — so any test
/// that runs afterward and touches `E2EHost.shared` synchronously (no bounded wait of its own) would
/// hang instead of fail. Empirically (this toolchain, `bazelisk test`), XCTest runs a class's tests in
/// ALPHABETICAL order by selector name, which is why the harmless getter/setter test above is named
/// to sort first (`testAssigning…` < `testForget…`) — it must stay ordered before any test named
/// `testForget…` in this class. A new test added to this class that touches `E2EHost.shared` should
/// either sort before `testForget…` too, or wrap its own access in a bounded wait like the one below.
final class E2EHostTests: XCTestCase {

    /// Set when the hook-ordering test below detects a deadlock (the hook fired, or `forgetListing`
    /// returned, too late to be anything but the hook having been called while `lock` was still
    /// held). `tearDown` must not itself try to take `lock` in that case — the background thread from
    /// the failed test is presumably still parked inside `detail()` holding it forever, and resetting
    /// `onListingChange` there would hang every test that runs after this one instead of just failing
    /// this one.
    private var lockIsStuck = false

    override func tearDown() {
        if !lockIsStuck {
            E2EHost.shared.onListingChange = nil
        }
        super.tearDown()
    }

    func testAssigningOnListingChangeRoundTripsThroughItsGetterAndSetter() {
        XCTAssertNil(E2EHost.shared.onListingChange, "nothing was ever installed")
        let hook: @Sendable () -> Void = {}
        E2EHost.shared.onListingChange = hook
        XCTAssertNotNil(E2EHost.shared.onListingChange)
    }

    /// `forgetListing()` → `notifyListing()`. The hook fires, and it fires OUTSIDE `lock`: this
    /// test's callback calls `E2EHost.shared.detail()`, which itself takes `lock` on this (nil-`base`)
    /// path — if `notifyListing()` were called while `forgetListing()` still held the lock, that
    /// reentrant call would deadlock on `NSLock` (not reentrant), and neither the hook nor
    /// `forgetListing()` would ever return.
    ///
    /// Run `forgetListing()` on a background queue and read the wait's own `XCTWaiter.Result` rather
    /// than the test-case convenience `wait(for:timeout:)`, which records its own failure but gives
    /// this method no way to know a timeout happened and avoid touching `lock` again in `tearDown`.
    ///
    /// `assertForOverFulfill` makes "exactly once" a real assertion, not just a name: a regression
    /// that calls `notifyListing()` twice for one `forgetListing()` call fails this test on the
    /// second `fulfill()` (confirmed by temporarily duplicating the call and reverting — see the
    /// task report).
    func testForgetListingCallsTheHookExactlyOnceAndOutsideTheLock() {
        let fired = XCTestExpectation(description: "onListingChange fired")
        fired.assertForOverFulfill = true
        E2EHost.shared.onListingChange = {
            _ = E2EHost.shared.detail()   // reenters `lock` — deadlocks if called while still held
            fired.fulfill()
        }

        let returned = XCTestExpectation(description: "forgetListing() returned")
        DispatchQueue.global().async {
            E2EHost.shared.forgetListing()
            returned.fulfill()
        }

        let result = XCTWaiter().wait(for: [returned, fired], timeout: 2.0)
        guard result == .completed else {
            lockIsStuck = true
            XCTFail("""
                onListingChange did not fire (and forgetListing() did not return) within 2s — \
                consistent with the hook being called while `lock` was still held (waiter result: \
                \(result))
                """)
            return
        }
    }
}
