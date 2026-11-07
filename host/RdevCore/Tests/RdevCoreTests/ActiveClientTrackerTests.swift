import XCTest
@testable import RdevCore

final class ActiveClientTrackerTests: XCTestCase {

    func testFirstJoinerBecomesActive() {
        let t = ActiveClientTracker()
        XCTAssertEqual(t.join("a"), ActiveClientEffects(activate: "a", deactivate: nil, broadcastState: true))
        XCTAssertEqual(t.activeId, "a")
        XCTAssertTrue(t.isActive("a"))
    }

    func testSecondJoinerIsPassive() {
        let t = ActiveClientTracker()
        _ = t.join("a")
        XCTAssertEqual(t.join("b"), ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false))
        XCTAssertEqual(t.activeId, "a")
        XCTAssertEqual(t.clientCount, 2)
    }

    /// A client CONNECTING (its join carries the connect intent) takes control at once, as a "Move here"
    /// would: the driver it replaces goes passive. Decided here, on the host.
    func testAJoinWithTheConnectIntentTakesControl() {
        let t = ActiveClientTracker()
        _ = t.join("a")
        XCTAssertEqual(t.join("b", claim: true), ActiveClientEffects(activate: "b", deactivate: "a", broadcastState: true))
        XCTAssertEqual(t.activeId, "b")
        XCTAssertEqual(t.clientCount, 2)
    }

    /// With no driver, a connecting client is simply the driver — there is nobody to deactivate.
    func testAConnectingJoinWithNoDriverJustBecomesActive() {
        let t = ActiveClientTracker()
        XCTAssertEqual(t.join("a", claim: true), ActiveClientEffects(activate: "a", deactivate: nil, broadcastState: true))
        XCTAssertEqual(t.activeId, "a")
    }

    /// The driver itself joining again with the intent changes nothing.
    func testTheDriverRejoiningWithTheIntentIsANoop() {
        let t = ActiveClientTracker()
        _ = t.join("a")
        XCTAssertEqual(t.join("a", claim: true), ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false))
        XCTAssertEqual(t.activeId, "a")
    }

    func testClaimTransfersControl() {
        let t = ActiveClientTracker()
        _ = t.join("a"); _ = t.join("b")
        XCTAssertEqual(t.claim("b"), ActiveClientEffects(activate: "b", deactivate: "a", broadcastState: true))
        XCTAssertEqual(t.activeId, "b")
    }

    /// Moves nothing, but RE-STATES control: the page that pressed Move here believes it is passive.
    func testClaimByCurrentActiveReStatesTheState() {
        let t = ActiveClientTracker()
        _ = t.join("a")
        XCTAssertEqual(t.claim("a"), ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: true))
        XCTAssertEqual(t.activeId, "a")
    }

    func testClaimByUnknownIsNoop() {
        let t = ActiveClientTracker()
        _ = t.join("a")
        XCTAssertEqual(t.claim("ghost"), ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false))
        XCTAssertEqual(t.activeId, "a")
    }

    func testActiveLeavesWithOneRemainingAutoPromotes() {
        let t = ActiveClientTracker()
        _ = t.join("a"); _ = t.join("b")           // a active, b passive
        XCTAssertEqual(t.leave("a"), ActiveClientEffects(activate: "b", deactivate: nil, broadcastState: true))
        XCTAssertEqual(t.activeId, "b")
    }

    func testActiveLeavesWithMultipleRemainingLeavesUnowned() {
        let t = ActiveClientTracker()
        _ = t.join("a"); _ = t.join("b"); _ = t.join("c")   // a active; b,c passive
        XCTAssertEqual(t.leave("a"), ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: true))
        XCTAssertNil(t.activeId)
        XCTAssertEqual(t.clientCount, 2)
    }

    func testPassiveLeaveChangesNothing() {
        let t = ActiveClientTracker()
        _ = t.join("a"); _ = t.join("b")
        XCTAssertEqual(t.leave("b"), ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false))
        XCTAssertEqual(t.activeId, "a")
        XCTAssertEqual(t.clientCount, 1)
    }

    func testClaimAfterUnownedActivates() {
        let t = ActiveClientTracker()
        _ = t.join("a"); _ = t.join("b"); _ = t.join("c")
        _ = t.leave("a")                              // unowned, b & c remain
        XCTAssertEqual(t.claim("c"), ActiveClientEffects(activate: "c", deactivate: nil, broadcastState: true))
        XCTAssertEqual(t.activeId, "c")
    }
}
