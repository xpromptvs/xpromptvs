import XCTest
@testable import RdevCore

/// A tmux pane's byte stream across the boundaries where rdev stops forwarding it (a hidden driver,
/// the moments before an attach snapshot): tmux's own parser holds a half-read character there, so
/// its snapshot excludes it, and the first live bytes afterwards finish it.
final class PaneStreamCarryTests: XCTestCase {
    private let esc: UInt8 = 0x1b

    /// `─` is E2 94 80. Its lead bytes arrived while output was withheld; the snapshot's cursor is where
    /// the character belongs, so the first live chunk must carry the WHOLE character.
    func testACharacterSplitAcrossAWithheldStretchIsWholeAfterTheRestart() {
        var c = PaneStreamCarry()
        XCTAssertEqual(c.forward(Array("a".utf8)), Array("a".utf8))
        c.skip([0x62, 0xE2, 0x94])                                  // withheld
        c.restart()                                                 // the snapshot was delivered
        XCTAssertEqual(c.forward([0x80, 0x63]), [0xE2, 0x94, 0x80, 0x63])
        XCTAssertEqual(c.forward(Array("d".utf8)), Array("d".utf8), "the prefix goes once")
    }

    /// While forwarding, a chunk never ENDS mid-character: the lead bytes wait for the rest, so the
    /// client's decoder never holds a dangling half that a following payload would turn into U+FFFD.
    func testForwardedChunksEndOnACharacterBoundary() {
        var c = PaneStreamCarry()
        XCTAssertEqual(c.forward([0x61, 0xE2]), [0x61])
        XCTAssertEqual(c.forward([0x94]), [])
        XCTAssertEqual(c.forward([0x80, 0x62]), [0xE2, 0x94, 0x80, 0x62])
    }

    /// Lead bytes held back when forwarding stopped are stated after the restart exactly once.
    func testHeldLeadBytesSurviveAPause() {
        var c = PaneStreamCarry()
        XCTAssertEqual(c.forward([0x61, 0xE2, 0x94]), [0x61])
        c.restart()
        XCTAssertEqual(c.forward([0x80]), [0xE2, 0x94, 0x80])
    }

    /// tmux's parser is mid-ESCAPE-sequence just the same: without its start, the rest would paint as
    /// text ("8;5;174m").
    func testAnEscapeSequenceSplitAcrossAWithheldStretch() {
        var c = PaneStreamCarry()
        c.skip([0x78, esc, 0x5b, 0x33])                             // x ESC [ 3
        c.restart()
        XCTAssertEqual(c.forward(Array("8mY".utf8)), [esc, 0x5b, 0x33] + Array("8mY".utf8))
        c.skip([esc, 0x5d, 0x30, 0x3b, 0xE2])                       // an OSC title, mid-character
        c.restart()
        XCTAssertEqual(c.forward([0x9C, 0xB3, 0x07]), [esc, 0x5d, 0x30, 0x3b, 0xE2, 0x9C, 0xB3, 0x07])
    }

    /// Output rdev never RECEIVED (a tab whose client ran `no-output`, a `%pause`) leaves the tail
    /// unknown. A restart whose first bytes are continuation bytes then cannot be completed: the caller
    /// is told (nil) so it can take a fresh snapshot — once; a second in a row is sent as it is.
    func testAnOrphanAfterAnUnseenStretchAsksForOneSnapshot() {
        var c = PaneStreamCarry()
        c.skip([0x61, 0xE2, 0x94])
        c.reset()                                                   // output went off, then on
        c.restart()
        XCTAssertNil(c.forward([0x80, 0x62]))
        c.restart()
        XCTAssertEqual(c.forward([0x80, 0x62]), [0x80, 0x62], "a second orphan in a row is not a loop")
        c.restart()
        XCTAssertNil(c.forward([0x80]), "a successful forward re-arms the check")
    }

    /// Without a restart there is nothing to prepend and nothing to heal.
    func testContinuationBytesWithoutARestartPassThrough() {
        var c = PaneStreamCarry()
        XCTAssertEqual(c.forward([0x80, 0x61]), [0x80, 0x61])
    }

    /// Bytes that are not valid UTF-8 are not held — they are the app's, and xterm shows them as it would.
    func testInvalidBytesAreNotHeld() {
        var c = PaneStreamCarry()
        XCTAssertEqual(c.forward([0xFF, 0x61]), [0xFF, 0x61])
        XCTAssertEqual(c.forward([0xE2, 0x61]), [0xE2, 0x61])
        XCTAssertEqual(c.forward([0xF0, 0x9F, 0x98]), [], "a 4-byte character waits for its last byte")
        XCTAssertEqual(c.forward([0x80]), [0xF0, 0x9F, 0x98, 0x80])
    }

    /// A runaway unterminated sequence is not carried forever.
    func testARunawayTailIsDropped() {
        var c = PaneStreamCarry()
        c.skip([esc, 0x5d] + Array(repeating: 0x61, count: 5000))
        XCTAssertEqual(c.tail, [])
    }
    /// `ESC ( 0` (designate a charset) and every other ESC + intermediates + final sequence is
    /// unfinished until its FINAL byte (0x30-0x7E) arrives. Cut after the intermediate, the start was
    /// once dropped as "complete", and the orphan final `0` painted as text.
    func testAnEscapeWithAnIntermediateIsUnfinishedUntilItsFinal() {
        XCTAssertEqual(PaneStreamCarry.unfinishedTail([0x61, esc, 0x28]), [esc, 0x28])
        XCTAssertEqual(PaneStreamCarry.unfinishedTail([esc, 0x20, 0x23]), [esc, 0x20, 0x23], "two intermediates")
        XCTAssertEqual(PaneStreamCarry.unfinishedTail([esc, 0x28, 0x30]), [], "the final ends it")
        XCTAssertEqual(PaneStreamCarry.unfinishedTail([esc, 0x37]), [], "DECSC has no intermediate")
        var c = PaneStreamCarry()
        c.skip([0x78, esc, 0x28])                                   // x ESC (
        c.restart()
        XCTAssertEqual(c.forward(Array("0q".utf8)), [esc, 0x28] + Array("0q".utf8))
    }

    /// A tail that is too long to be an escape sequence any more is released — but a UTF-8 character
    /// that has not ended is still the end of the stream, and is still carried.
    func testARunawayEscapeStillCarriesAnUnfinishedCharacter() {
        var c = PaneStreamCarry()
        c.skip([esc, 0x5d] + Array(repeating: 0x61, count: 5000) + [0xE2, 0x94])
        XCTAssertEqual(c.tail, [0xE2, 0x94])
        c.restart()
        XCTAssertEqual(c.forward([0x80]), [0xE2, 0x94, 0x80])
    }
}
