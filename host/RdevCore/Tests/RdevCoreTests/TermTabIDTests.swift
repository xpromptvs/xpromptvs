import XCTest
@testable import RdevCore

final class TermTabIDTests: XCTestCase {
    func testRoundTrips() {
        XCTAssertEqual(TermTabID(wire: "pty:3"), .pty(3))
        XCTAssertEqual(TermTabID(wire: "tmux:$12"), .tmux("$12"))
        XCTAssertEqual(TermTabID.pty(3).wire, "pty:3")
        XCTAssertEqual(TermTabID.tmux("$12").wire, "tmux:$12")
        XCTAssertEqual(TermTabID.tmux("$12").tmuxSession, "$12")
        XCTAssertNil(TermTabID.pty(1).tmuxSession)
    }

    /// The PREFIX is the kind. A missing or unknown one is malformed — never defaulted to a kind,
    /// because a default is exactly how a keystroke gets delivered to a tab nobody named.
    func testMalformedIdsAreRejected() {
        for bad in ["3", "", "pty:", "pty:0", "pty:-1", "pty:x", "pty:3x", "tmux:", "tmux:3", "tmux:$",
                    "tmux:$x", "win:3", "PTY:3", " pty:3", "pty:٣"] {
            XCTAssertNil(TermTabID(wire: bad), bad)
        }
    }
}
