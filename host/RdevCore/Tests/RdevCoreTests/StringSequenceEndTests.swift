import XCTest
@testable import RdevCore

/// Where an OSC / DCS ENDS, as both real parsers end it (xterm.js `EscapeSequenceParser`, SwiftTerm's):
/// at BEL (OSC only — inside a DCS a BEL is data), at ST, at ANY ESC — which then begins the next
/// sequence and must not be swallowed — and at CAN/SUB (an abort: no answer). The stripper, the stream
/// carry and the query scanner all use this one rule; ending only at BEL or ST held a stray `ESC ]`'s
/// following output for up to 4 KB, replayed it after a restart, and missed queries after it.
final class StringSequenceEndTests: XCTestCase {
    private let E = "\u{1b}"
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// tmux: a stray `ESC ]` does not hold back later output — the next ESC ends it.
    func testTheStripperReleasesOutputAfterAStrayOSC() {
        var st = StreamingQueryStripper()
        var out = st.feed(b("\(E)]8;;http"))
        out += st.feed(b("\(E)[31mprompt$ \(E)[0m"))
        out += st.feed(b("ls\r\n"))
        XCTAssertEqual(out, b("\(E)]8;;http\(E)[31mprompt$ \(E)[0mls\r\n"))
    }

    /// …and a query ended by an ESC is removed, the ESC's own sequence kept.
    func testTheStripperRemovesAQueryEndedByTheNextSequence() {
        var st = StreamingQueryStripper()
        XCTAssertEqual(st.feed(b("a\(E)]11;?\(E)[mb")), b("a\(E)[mb"))
    }

    /// tmux: after a stray OSC and ordinary output, the carried tail is only what is really unfinished
    /// — the restart does not re-paint output the snapshot already has.
    func testTheCarryDoesNotReplayOutputAfterAStrayOSC() {
        var c = PaneStreamCarry()
        _ = c.forward(b("\(E)]8;;http"))
        _ = c.forward(b("\(E)[31mprompt$ \(E)[0mls\r\nfile1 file2\r\n"))
        XCTAssertEqual(c.tail, [])
        c.restart()
        XCTAssertEqual(c.forward(b("x")), b("x"))
    }

    /// pty: a query right after a string that the next ESC ends is seen — and answered once.
    func testTheScannerSeesQueriesAfterAStringEndedByAnESC() {
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.countQueries(b("\(E)]0;t\(E)[6n")), 1, "the DSR after the title")
        XCTAssertEqual(s.countQueries(b("\(E)]11;?\(E)[m")), 1, "OSC 11 ended by the SGR's ESC")
        XCTAssertEqual(s.countQueries(b("\(E)]0;t")), 0)
        XCTAssertEqual(s.countQueries(b("\(E)[6n")), 1, "a stray OSC in an EARLIER read")
    }

    /// The query ends AT the ESC that ends it — where both parsers dispatch it — so the host's feed is cut
    /// right after that ESC and SwiftTerm's answer is attributed to it.
    func testAStringEndedByAnESCEndsJustAfterIt() {
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.scan(b("x\(E)]11;?\(E)[m")).map(\.end), [8])
        var t = StreamingQueryStripper()
        XCTAssertEqual(t.scan(b("x\(E)]11;?")).map(\.end), [])
        XCTAssertEqual(t.scan(b("\(E)")).map(\.end), [1], "known at the ESC itself: no lookahead")
    }

    /// The ESC state and sequence bodies as xterm.js 6 parses them (fix round 3): an ESC restarts the
    /// sequence, a C0 byte is executed in place — never taken as a final byte or a parameter — and
    /// dropped from an OSC body or a DCS header, and a byte >= 0x80 aborts a CSI.
    func testTheEscapeStateAndBodiesFollowTheParser() {
        for q in ["\(E)\(E)[6n", "\(E)(\(E)[6n", "\(E)\r[6n", "\(E)[\r6n", "\(E)[?\r6n", "\(E)P\n$qm\(E)\\",
                  "\(E)]11;\n?\u{07}", "\(E)[6\u{7f}n"] {
            var s = StreamingQueryStripper()
            XCTAssertEqual(s.countQueries(b(q)), 1, q.debugDescription)
        }
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.countQueries(b("\(E)[é6n")), 0, "the é aborts the CSI; `6n` is text")
    }

    /// tmux: a query's executed C0 bytes survive its removal; a CSI aborted by a non-ASCII byte is not
    /// stripped, and `ESC [` followed by CJK text is released at once rather than held.
    func testTheStripperKeepsExecutedBytesAndReleasesAbortedCSIs() {
        var a = StreamingQueryStripper()
        XCTAssertEqual(a.feed(b("x\(E)\r[6ny")), b("x\ry"))
        var c = StreamingQueryStripper()
        XCTAssertEqual(c.feed(b("\(E)[é6n")), b("\(E)[é6n"))
        var d = StreamingQueryStripper()
        XCTAssertEqual(d.feed(b("\(E)[漢字")), b("\(E)[漢字"))
    }

    /// CAN / SUB abort a string: nothing is answered. A DCS runs on past a BEL (data) to the next ESC.
    func testCancelAbortsAndBELIsDataInsideADCS() {
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.countQueries(b("\(E)]11;?\u{18}")), 0)
        XCTAssertEqual(s.countQueries(b("\(E)P$qm\u{1a}")), 0)
        XCTAssertEqual(s.countQueries(b("\(E)P$qm\u{07}xx")), 0, "still open")
        XCTAssertEqual(s.countQueries(b("\(E)[m")), 1, "ended — and answered — by the next ESC")
    }
}
