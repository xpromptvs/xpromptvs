import XCTest
@testable import ShellstormCore
final class HostUpdateStateTests: XCTestCase {
    func testAcceptedJobSurvivesDisconnectButCannotCommitAfterPolicyChanges() {
        var state = HostUpdateState()
        XCTAssertTrue(state.begin(id: "one", owner: "owner"))
        XCTAssertTrue(state.begin(id: "one", owner: "owner"))
        XCTAssertFalse(state.begin(id: "two", owner: "owner"))
        XCTAssertFalse(state.begin(id: "one", owner: "guest"))
        XCTAssertFalse(state.commit(allowed: false, authorized: true))
        XCTAssertEqual(state.phase, .cancelled)
    }
    func testCommittedJobCannotBeCancelledAndTerminalOutcomeIsStable() {
        var state = HostUpdateState()
        XCTAssertTrue(state.begin(id: "one", owner: "owner"))
        XCTAssertTrue(state.commit(allowed: true, authorized: true))
        state.cancel(); XCTAssertEqual(state.phase, .restarting)
        state.finish(.succeeded); state.finish(.failed)
        XCTAssertEqual(state.phase, .succeeded)
    }
}
