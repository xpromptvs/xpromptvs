import XCTest
@testable import RdevCore

/// **A SOCKET CLIENT'S ID IS RESERVED** (docs/sources-and-focus.md, "Window-less clients"): a relay peer
/// id is any non-empty string the relay accepts, so without the reservation a relay `peer-left` could
/// NAME the Mac's own local window and unregister it.
final class SocketClientIDTests: XCTestCase {
    func testASocketClientsIdIsPrefixedAndReserved() {
        XCTAssertEqual(SocketClientID.make("tab-1"), "sock:tab-1")
        XCTAssertTrue(SocketClientID.isReserved("sock:tab-1"))
        XCTAssertTrue(SocketClientID.isReserved("sock:"))
    }

    func testARelayClientsIdIsNotReserved() {
        for id in ["3f2a9c1e-0b7d-4e55-9a51-2f0e8c6d4b10", "tab-1", "", "SOCK:x", "socket:x", " sock:x"] {
            XCTAssertFalse(SocketClientID.isReserved(id), id)
        }
    }

    func testEveryEventThatNamesAPeerSaysWhich() {
        XCTAssertEqual(SignalingEvent.peerJoined("a").peerID, "a")
        XCTAssertEqual(SignalingEvent.peerLeft("b").peerID, "b")
        XCTAssertEqual(SignalingEvent.peerSuspended("c").peerID, "c")
        XCTAssertEqual(SignalingEvent.peerResumed("d", .ice).peerID, "d")
        XCTAssertEqual(SignalingEvent.answer("sdp", "e").peerID, "e")
        XCTAssertEqual(SignalingEvent.ice(nil, "f").peerID, "f")
        XCTAssertEqual(SignalingEvent.e2e(ct: "AA", peer: "g", mode: nil).peerID, "g")
    }

    func testEventsAboutNoPeerNameNone() {
        XCTAssertNil(SignalingEvent.pong.peerID)
        XCTAssertNil(SignalingEvent.offer("sdp").peerID)
        XCTAssertNil(SignalingEvent.error("x", nil).peerID)
        XCTAssertNil(SignalingEvent.ice(nil, nil).peerID)
        XCTAssertNil(SignalingEvent.e2e(ct: "AA", peer: nil, mode: nil).peerID)
    }

    /// The RELAY'S OWN WORDS, parsed: a `peer-left` naming a socket client's id is recognised as one.
    func testARoutedRelayMessageNamingASocketClientIsReserved() {
        let event = SignalingRouter.route(Data(#"{"t":"peer-left","peer":"sock:tab-1"}"#.utf8))
        XCTAssertEqual(event?.peerID.map(SocketClientID.isReserved), true)
    }
}
