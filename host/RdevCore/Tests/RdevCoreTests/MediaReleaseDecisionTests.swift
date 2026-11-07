import XCTest
@testable import RdevCore

final class MediaReleaseDecisionTests: XCTestCase {
    // Terminal states release — the whole point of the increment.
    func testFailedReleases() {
        XCTAssertTrue(shouldReleaseMedia(state: PeerConnectionState.failed, hasVideoSlots: true))
    }
    func testClosedReleases() {
        XCTAssertTrue(shouldReleaseMedia(state: PeerConnectionState.closed, hasVideoSlots: true))
    }

    // Disconnected is RECOVERABLE: ICE may return, and releasing here would tear down a stream that
    // was about to heal itself.
    func testDisconnectedDoesNotRelease() {
        XCTAssertFalse(shouldReleaseMedia(state: PeerConnectionState.disconnected, hasVideoSlots: true))
    }
    func testConnectedDoesNotRelease() {
        XCTAssertFalse(shouldReleaseMedia(state: PeerConnectionState.connected, hasVideoSlots: true))
    }

    // GUARD 1. SimManager's grace timer is GLOBAL, not per client, so arming it because a PASSIVE
    // peer failed would retire the ACTIVE client's sources. Passive clients never hold tracks.
    func testTerminalStateWithNoSlotsDoesNotRelease() {
        XCTAssertFalse(shouldReleaseMedia(state: PeerConnectionState.failed, hasVideoSlots: false))
    }

    // GUARD 2, structurally. A real close fires 5 THEN 6. The first release clears videoSlots, so the
    // second observation carries false and does not re-fire — which matters because onClientGone
    // CANCELS AND RE-ARMS its 10s timer, so a second call would silently EXTEND the window it starts.
    func testClosedAfterFailedDoesNotReleaseAgain() {
        XCTAssertTrue(shouldReleaseMedia(state: PeerConnectionState.failed, hasVideoSlots: true))
        // releaseMedia -> removeVideo cleared the slots, so the follow-up state carries false.
        XCTAssertFalse(shouldReleaseMedia(state: PeerConnectionState.closed, hasVideoSlots: false))
    }

    // GUARD 3. The client picks its resume mode from ITS view of its PC, which can disagree with
    // ours. Reusing a retained peer whose media we released resumes to a permanently black window;
    // a rebuild re-establishes video through the path that already works.
    func testIceResumeDowngradesToRebuildWhenMediaWasReleased() {
        XCTAssertEqual(resumeActionAfterMediaRelease(.restartICE, mediaReleased: true), .rebuild)
    }
    func testIceResumeIsUntouchedWhenMediaWasNotReleased() {
        XCTAssertEqual(resumeActionAfterMediaRelease(.restartICE, mediaReleased: false), .restartICE)
    }
    // GUARD 4. An offer whose answer was lost leaves the peer in `have-local-offer`, where pion
    // refuses an ICE restart's offer outright — measured, every such resume failed until the
    // client's own retry forced a rebuild.
    func testIceResumeDowngradesToRebuildWhenAnOfferIsUnanswered() {
        XCTAssertEqual(resumeActionAfterUnansweredOffer(.restartICE, awaitingAnswer: true), .rebuild)
        XCTAssertEqual(resumeActionAfterUnansweredOffer(.restartICE, awaitingAnswer: false), .restartICE)
        XCTAssertEqual(resumeActionAfterUnansweredOffer(.freshJoin, awaitingAnswer: true), .freshJoin)
        XCTAssertEqual(resumeActionAfterUnansweredOffer(.rebuild, awaitingAnswer: true), .rebuild)
    }
    func testOtherActionsAreUntouched() {
        XCTAssertEqual(resumeActionAfterMediaRelease(.rebuild, mediaReleased: true), .rebuild)
        XCTAssertEqual(resumeActionAfterMediaRelease(.freshJoin, mediaReleased: true), .freshJoin)
        XCTAssertEqual(resumeActionAfterMediaRelease(.teardown, mediaReleased: true), .teardown)
    }
}
