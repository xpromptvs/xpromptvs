import XCTest
@testable import RdevCore

/// THE SEND BUFFER NEVER HOLDS ANYTHING THAT COULD BE A QUERY (docs/terminal.md, "The send buffer").
/// `web/test/term-reply-handlers.test.ts` walks every handler xterm.js 6 registers and records which
/// ever answer — on an instance with every `windowOptions` on, so an option change cannot reopen the
/// hole — into `protocol/fixtures/term-reply-handlers.json`. The scanner must flag (`scan` returns a
/// hit, which the send buffer never holds) every sequence those handlers dispatch, for EVERY parameter
/// the walk drove them with: a query neither measured set recognises can then still not be held ≤ 8 ms
/// and lose its answer to a pause or a switch. And it must not flag every sequence: the guard below.
final class TermReplyHandlersFixtureTests: XCTestCase {
    private struct Side<T: Decodable>: Decodable { let answer: [T]; let silent: [T] }
    private struct Fixture: Decodable {
        let csiParams: [String]
        let csi: Side<String>, esc: Side<String>, dcs: Side<String>, osc: Side<Int>
    }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/term-reply-handlers.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private let E = "\u{1b}"
    private func flagged(_ q: String) -> Bool {
        var s = StreamingQueryStripper()
        return s.detectsQuery(Array("a\(q)b\u{1b}[m".utf8))
    }
    /// `prefix`, `intermediates`, `final` of an xterm.js handler identifier.
    private func split(_ id: String) -> (String, String, String) {
        var head = String(id.dropLast())
        var prefix = ""
        if let f = head.unicodeScalars.first, (0x3c...0x3f).contains(f.value) { prefix = String(f); head.removeFirst() }
        return (prefix, head, String(id.last!))
    }

    func testTheFixtureIsNotVacuous() {
        XCTAssertTrue(Self.fx.csi.answer.contains("c") && Self.fx.csi.answer.contains("t"))
        XCTAssertEqual(Self.fx.dcs.answer, ["$q"])
        XCTAssertEqual(Self.fx.osc.answer, [4, 10, 11, 12])
        XCTAssertGreaterThan(Self.fx.csi.silent.count, 30)
    }

    /// Every CSI handler xterm.js can answer is flagged with every parameter the walk drove it with —
    /// with 7-bit and with 8-bit (C1) introducers alike, since xterm.js dispatches both to one handler.
    func testEveryCSIHandlerThatCanAnswerIsNeverHeld() {
        for id in Self.fx.csi.answer {
            let (prefix, inter, final) = split(id)
            for p in Self.fx.csiParams {
                XCTAssertTrue(flagged("\(E)[\(prefix)\(p)\(inter)\(final)"), "CSI \(prefix)\(p)\(inter)\(final)")
                XCTAssertTrue(flagged("\u{9b}\(prefix)\(p)\(inter)\(final)"), "C1 CSI \(prefix)\(p)\(inter)\(final)")
            }
        }
    }

    /// Every DCS is flagged — any data, ended by ST or by the next sequence — and every OSC whose body
    /// asks with a `?` slot, for every OSC handler that can answer.
    func testEveryDCSAndEveryAskingOSCIsNeverHeld() {
        for id in Self.fx.dcs.answer + Self.fx.dcs.silent + ["q", "1;2x", "+q"] {
            for d in ["", "m", "xyz", "#0;2;0;0;0#0~~@@"] {
                XCTAssertTrue(flagged("\(E)P\(id)\(d)\(E)\\"), "DCS \(id)\(d)")
                XCTAssertTrue(flagged("\u{90}\(id)\(d)\u{9c}"), "C1 DCS \(id)\(d)")
            }
        }
        for id in Self.fx.osc.answer {
            for d in [";?", ";1;?", ";?;?", ";1;?;2;?"] {
                XCTAssertTrue(flagged("\(E)]\(id)\(d)\u{07}"), "OSC \(id)\(d)")
                XCTAssertTrue(flagged("\u{9d}\(id)\(d)\u{9c}"), "C1 OSC \(id)\(d)")
            }
        }
        // Beyond xterm.js's own: an OSC NEITHER emulator answers that asks all the same (xterm's OSC 52
        // clipboard read, OSC 5/17/19) — a `?` slot, or a body ending in `?`.
        for q in ["\(E)]52;c;?\u{07}", "\(E)]5;1;?\u{07}", "\(E)]17;?\(E)\\", "\(E)]777;x?\u{07}"] {
            XCTAssertTrue(flagged(q), q.debugDescription)
        }
    }

    /// No ESC sequence answers, so none is flagged; and the rule is not "every sequence": the silent CSI
    /// handlers other than the query finals (c, n, t, `$ p`) and SwiftTerm's own (`? u`, `> q`, `* y`)
    /// are held like any output, as are titles, colours and hyperlinks.
    func testSequencesThatCannotAskAreStillHeld() {
        XCTAssertEqual(Self.fx.esc.answer, [])
        for id in Self.fx.esc.silent { XCTAssertFalse(flagged("\(E)\(id)"), "ESC \(id)") }
        var checked = 0
        for id in Self.fx.csi.silent {
            let (prefix, inter, final) = split(id)
            if ["c", "n", "t"].contains(final) || (final == "p" && inter.contains("$")) { continue }
            for p in ["", "1", "31", "2004"] {
                XCTAssertFalse(flagged("\(E)[\(prefix)\(p)\(inter)\(final)"), "CSI \(prefix)\(p)\(inter)\(final)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30)
        for q in ["\(E)]0;title\u{07}", "\(E)]11;rgb:00/00/00\u{07}", "\(E)]8;;http://x?y=1\(E)\\", "\(E)]104\u{07}"] {
            XCTAssertFalse(flagged(q), q.debugDescription)
        }
    }
}
