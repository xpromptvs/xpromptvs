import XCTest
@testable import RdevCore

/// The device-query residuals closed on 2026-09-27 (docs/terminal.md, "Who answers" and "tmux answers
/// device queries itself"): a colour query longer than the 4 KB hold keeps its SHAPE; a left-in query
/// whose terminator is still held is not "reached" until that terminator goes out; a stripped query never
/// takes the ESC that ends what came before it; a payload is measured as the client's `TextDecoder`
/// decodes it; and a C1 DECRQM/DECRQSS is answered as xterm.js answers it.
final class TermQueryResidualsTests: XCTestCase {
    private let E = "\u{1b}"
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func text(_ a: [UInt8]) -> String { String(decoding: a, as: UTF8.self) }

    // MARK: 1 — a colour query longer than the hold keeps its shape

    /// Split every way around the hold: one hit, with an EQUIVALENT query whose host answer is exactly
    /// the answer to the whole long query (parsed from its bytes, `TermHostReplies`), from the palette.
    func testALongColourQueryKeepsWhatItAsks() throws {
        let junk = String(repeating: "x;", count: 2100)
        let pairs = (0..<800).map { "\(($0 * 7) % 256);?" }.joined(separator: ";")
        let queries = ["\(E)]4;\(junk)1;?;2;?\u{07}", "\(E)]4;\(pairs)\u{07}", "\(E)]10;\(String(repeating: "x", count: 5000));?\u{07}",
                       "\(E)]12;?;\(String(repeating: "y", count: 5000))\u{07}", "\u{9d}11;\(String(repeating: "z", count: 5000));?\u{9c}",
                       "\(E)]10;?;\(String(repeating: "w", count: 5000));?\(E)\\", "\(E)]4;\(junk)0001;?\(E)[m"]
        for q in queries {
            let bytes = b("a\(q)b")
            XCTAssertGreaterThan(bytes.count, 4096)
            // The whole query as the parsers end it (an ST's `\` and a next sequence are not part of it).
            let walked = try XCTUnwrap(StreamingQueryStripper.walk(b(q)).first { ($0.replies ?? 0) > 0 })
            let whole = try XCTUnwrap(TermHostReplies.colourAnswer(Array(b(q)[walked.start..<walked.feedEnd]), palette: .xtermDefault))
            XCTAssertFalse(whole.isEmpty)
            for chunk in [1, 7, 1000, 4096, 4097, 5000, bytes.count] {
                var s = StreamingQueryStripper()
                var got: [UInt8] = [], hits = 0, i = 0
                while i < bytes.count {
                    for h in s.scan(Array(bytes[i..<min(i + chunk, bytes.count)])) where h.clientReplies > 0 {
                        hits += 1
                        got += try XCTUnwrap(h.query.flatMap { TermHostReplies.colourAnswer($0, palette: .xtermDefault) },
                                             "\(q.prefix(12).debugDescription) chunk \(chunk)")
                    }
                    i += chunk
                }
                XCTAssertEqual(hits, 1, "chunk \(chunk)")
                XCTAssertEqual(text(got), text(whole), "\(q.prefix(12).debugDescription) chunk \(chunk)")
            }
        }
    }

    /// xterm.js answers every `index;?` pair — millions, up to its payload limit. The shape keeps
    /// `StringBody.maxReports` of them: the count is still every answer, the equivalent query the first
    /// `maxReports`, in order.
    func testTheShapeIsBounded() throws {
        let n = StringBody.maxReports + 1000
        let q = b("\(E)]4;" + (0..<n).map { "\($0 % 256);?" }.joined(separator: ";") + "\u{07}")
        var s = StreamingQueryStripper()
        var hits: [TermQueryHit] = []
        var i = 0
        while i < q.count { hits += s.scan(Array(q[i..<min(i + 4097, q.count)])); i += 4097 }
        XCTAssertEqual(hits.map(\.clientReplies), [n])
        let eq = try XCTUnwrap(hits.first?.query)
        let answer = text(try XCTUnwrap(TermHostReplies.colourAnswer(eq, palette: .xtermDefault)))
        XCTAssertEqual(answer.components(separatedBy: "rgb:").count - 1, StringBody.maxReports)
        XCTAssertTrue(answer.hasPrefix("\(E)]4;0;rgb:"))
    }

    // MARK: 2 — L1: a left-in query is reached only when its terminator is sent

    /// A left-in OSC (tmux does not answer OSC 4) ended by an ESC that is the LAST byte of a read: the
    /// stripper holds that ESC (it begins the next sequence), so xterm.js has not seen the end of the
    /// query — no credit, no `left` yet. The read that releases the ESC decides it, forwarded or not.
    func testALeftInQueryWhoseTerminatorIsHeldIsDecidedWhenItIsReleased() {
        let q = b("\(E)]4;1;?")
        // Forwarded: the credit and `left` come with the read that carries the ESC out.
        var f = StreamingQueryStripper()
        let first = f.feedCounting(q + [0x1b])
        XCTAssertEqual(first.out, q)
        XCTAssertEqual(first.clientReplies, 0, "its terminator is still held")
        XCTAssertEqual(first.left, [])
        XCTAssertTrue(first.mayAsk)
        let second = f.feedCounting(b("[m"))
        XCTAssertEqual(second.out, b("\(E)[m"))
        XCTAssertEqual(second.clientReplies, 1)
        XCTAssertEqual(second.left, [q + [0x1b]])
        XCTAssertTrue(second.mayAsk, "the bytes carrying its terminator are never held")
        // Withheld next: the same `left` (the caller answers it — nothing reached a client).
        var w = StreamingQueryStripper()
        _ = w.feedCounting(q + [0x1b])
        XCTAssertEqual(w.withhold(b("[m")), [q + [0x1b]])
        // Still unfinished after the next read: still waiting.
        var u = StreamingQueryStripper()
        _ = u.feedCounting(q + [0x1b])
        XCTAssertEqual(u.feedCounting(b("[")).left, [])
        XCTAssertEqual(u.feedCounting(b("1m")).left, [q + [0x1b]])
        // Discarded with the ESC still held (a snapshot, a `%pause`): handed over, once.
        var d = StreamingQueryStripper()
        _ = d.feedCounting(q + [0x1b])
        XCTAssertEqual(d.takePending(), [q + [0x1b]])
        XCTAssertEqual(d.takePending(), [])
        // A query tmux answers is stripped as before, and a string that asks nothing is nobody's.
        var t = StreamingQueryStripper()
        XCTAssertEqual(t.feedCounting(b("\(E)]0;t") + [0x1b]).out, b("\(E)]0;t"))
        XCTAssertEqual(t.takePending(), [])
    }

    /// The same for a left-in query LONGER than the hold, ended by a bare ESC at a read's end.
    func testALongLeftInQueryWhoseTerminatorIsHeldWaitsToo() {
        let body = b("\(E)]4;" + String(repeating: "x;", count: 2100) + "1;?")
        XCTAssertGreaterThan(body.count, 4200)
        var s = StreamingQueryStripper()
        var out = s.feedCounting(Array(body[..<4200])).out              // open past the hold: long
        let r = s.feedCounting(Array(body[4200...]) + [0x1b])
        out += r.out
        XCTAssertEqual(out, body)
        XCTAssertEqual(r.clientReplies, 0)
        XCTAssertEqual(r.left, [])
        let next = s.feedCounting(b("[m"))
        XCTAssertEqual(next.clientReplies, 1)
        XCTAssertEqual(next.left, [b("\(E)]4;1;?\u{07}")], "the equivalent query")
    }

    /// A query tmux answers (stripped) whose ESC ENDS the sequence before it keeps that ESC, as a no-op
    /// `ESC \`: without it the client never saw the earlier sequence end — a left-in colour query ran on
    /// into what followed and nobody answered it; a title swallowed the text after it.
    func testAStrippedQueryKeepsTheESCThatEndsWhatCameBefore() {
        let cases: [(String, String, Int)] = [
            ("\(E)]4;1;?\(E)[cX", "\(E)]4;1;?\(E)\\X", 1),
            ("\(E)]0;title\(E)[6nX", "\(E)]0;title\(E)\\X", 0),
            ("\(E)[1\(E)[cX", "\(E)[1\(E)\\X", 0),
            ("\(E)\(E)[5nX", "\(E)\(E)\\X", 0),
            ("a\(E)[cX", "aX", 0),                                         // nothing before it to end
            ("\(E)]0;t\(E)\\\(E)[cX", "\(E)]0;t\(E)\\X", 0),                // ended by its own ST already
        ]
        for (input, expected, replies) in cases {
            var s = StreamingQueryStripper()
            let r = s.feedCounting(b(input))
            XCTAssertEqual(text(r.out), expected, input.debugDescription)
            XCTAssertEqual(r.clientReplies, replies, input.debugDescription)
            // Split before the stripped query: the ESC is held, then released as `ESC \`.
            var t = StreamingQueryStripper()
            let bytes = b(input)
            var out: [UInt8] = []
            for byte in bytes { out += t.feedCounting([byte]).out }
            XCTAssertEqual(text(out), expected, "a byte at a time: \(input.debugDescription)")
        }
    }

    // MARK: 5 — the payload is measured as the client's TextDecoder decodes it

    /// xterm.js's payload limit counts UTF-16 units of the DECODED text, and the client decodes with a
    /// non-fatal `TextDecoder`: each invalid subpart is ONE U+FFFD. Ten million lone continuation bytes
    /// are ten million units (the scanner counted none of them: an answer xterm.js does not give);
    /// `F0 41` is two (U+FFFD, `A` — the scanner counted three: no answer where xterm.js gives one).
    func testThePayloadIsCountedAsTheClientDecodesIt() {
        let limit = StringBody.payloadLimit
        func replies(_ payload: [UInt8]) -> Int {
            var s = StreamingQueryStripper()
            return s.countQueries(b("\(E)]11;") + payload + b(";?\u{07}"))
        }
        XCTAssertEqual(replies([UInt8](repeating: 0x80, count: limit - 2)), 1, "exactly the limit")
        XCTAssertEqual(replies([UInt8](repeating: 0x80, count: limit - 1)), 0, "one unit past it")
        let pairs = (limit - 2) / 2
        XCTAssertEqual(replies(Array([[UInt8]](repeating: [0xF0, 0x41], count: pairs).joined())), 1)
        // A character cut by the terminator is one more unit (the decoder flushes it before the BEL).
        XCTAssertEqual(replies([UInt8](repeating: 0x41, count: limit - 3) + [0xE2]), 1)
        XCTAssertEqual(replies([UInt8](repeating: 0x41, count: limit - 2) + [0xE2, 0x82]), 0)
        // A C0 byte inside the payload (dropped from an OSC by xterm.js) still ENDS a partial character in
        // the decoder: `E2 LF 82 AC` is U+FFFD, LF, U+FFFD, U+FFFD — three units, not a € (measured).
        XCTAssertEqual(replies([UInt8](repeating: 0x41, count: limit - 4) + [0xE2, 0x0A, 0x82, 0xAC]), 0)
        XCTAssertEqual(replies([UInt8](repeating: 0x41, count: limit - 6) + [0xE2, 0x0A, 0x82, 0xAC]), 1)
        // A valid astral character is two units, as before.
        XCTAssertEqual(replies([UInt8](repeating: 0x41, count: limit - 4) + [0xF0, 0x9F, 0x98, 0x80]), 1)
        XCTAssertEqual(replies([UInt8](repeating: 0x41, count: limit - 3) + [0xF0, 0x9F, 0x98, 0x80]), 0)
    }

    /// The decoder model itself, against the Encoding Standard's maximal-subpart rule.
    func testTheDecoderModelCountsReplacementsAsTheEncodingStandardDoes() {
        func units(_ bytes: [UInt8]) -> Int {
            var d = UTF8Units()
            return bytes.reduce(0) { $0 + d.units($1) } + d.pending
        }
        let cases: [([UInt8], String)] = [
            ([0x41], "A"), ([0xC3, 0xA9], "é"), ([0xF0, 0x9F, 0x98, 0x80], "😀"), ([0x80], "\u{FFFD}"),
            ([0xC0, 0xAF], "\u{FFFD}\u{FFFD}"), ([0xE0, 0x80, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}"),
            ([0xED, 0xA0, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}"), ([0xF0, 0x9F, 0x41], "\u{FFFD}A"), ([0xF4, 0x90, 0x80, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"),
            ([0xE2, 0x82], "\u{FFFD}"), ([0xF5, 0xFF, 0xFE], "\u{FFFD}\u{FFFD}\u{FFFD}"), ([0xC2, 0xC2, 0xA7], "\u{FFFD}§"),
        ]
        for (bytes, decoded) in cases {
            XCTAssertEqual(units(bytes), decoded.utf16.count, bytes.map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), decoded, "Swift's decoder agrees on the text")
        }
    }

    // MARK: 4 — C1 DECRQM and DECRQSS, answered as xterm.js answers them

    /// Every C1 DECRQM/DECRQSS the fixture measured against a real xterm.js whose answer depends only on
    /// modes the stream tracker follows (the region and `?2026` are TMUX's, `TerminalManagerTmuxTests`
    /// holds those): the host's answer from a tracker fed the same bytes is xterm.js's, byte for byte —
    /// but DECSCA's `" q`, which nothing the host keeps can say, is xterm.js's "not supported".
    func testC1ModeAndSettingQueriesAreAnsweredAsXtermJsAnswers() throws {
        struct Case: Decodable { let q: String; let replies: Int; let answers: String; let hex: String? }
        struct Fixture: Decodable { let cases: [Case] }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/term-client-queries.json")
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        var checked = 0
        for c in fx.cases where c.hex == nil && (c.q.contains("\u{9b}") && c.q.contains("$p") || c.q.contains("\u{90}$q")) {
            let bytes = b("a\(c.q)b\(E)[m")
            let walked = StreamingQueryStripper.walk(bytes).filter { ($0.replies ?? 0) > 0 }
            XCTAssertFalse(walked.isEmpty, c.q.debugDescription)
            // Each query answered from the modes where it ENDS — a later sequence changes nothing for it.
            var tracker = TermModeTracker()
            let modes = tracker.modes(feeding: bytes, at: walked.map(\.feedEnd))
            var got = ""
            for (f, m) in zip(walked, modes) {
                var state = TermHostState(tracked: m)
                state.scrollTop = 0; state.scrollBottom = 23; state.synchronizedOutput = c.q.contains("?2026h")
                if c.q.hasPrefix("\(E)[3;10r") { state.scrollTop = 2; state.scrollBottom = 9 }
                got += text(try XCTUnwrap(TermHostReplies.answer(Array(bytes[f.start..<f.feedEnd]), palette: .xtermDefault, cursor: nil, state: state)))
            }
            if c.q.contains("$q\"q") {
                XCTAssertEqual(got, "\(E)P0$r\(E)\\", "DECSCA: not kept — answered as xterm.js answers what it does not support")
                XCTAssertNotEqual(got, c.answers, "the documented difference, still there")
            } else {
                XCTAssertEqual(got, c.answers, c.q.debugDescription)
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 60)
        // Without state (a pty tab's path never asks), still no answer.
        XCTAssertNil(TermHostReplies.answer(b("\u{9b}?1$p"), palette: .xtermDefault, cursor: nil))
    }

    /// The tracker answers AS OF each mark: a mode set after a query in the same bytes does not reach it.
    func testTheTrackerReportsTheModesAtEachQuery() {
        var t = TermModeTracker()
        let bytes = b("\(E)[?1h\u{9b}?1$p\(E)[?1l\u{9b}?1$p\(E)[4h")
        let ends = StreamingQueryStripper.walk(bytes).filter { ($0.replies ?? 0) > 0 }.map(\.feedEnd)
        XCTAssertEqual(ends.count, 2)
        let m = t.modes(feeding: bytes, at: ends)
        XCTAssertEqual(m.map(\.applicationCursor), [true, false])
        XCTAssertEqual(m.map(\.insert), [false, false])
        XCTAssertTrue(t.modes.insert, "and on to the end of the bytes")
    }

    /// The stripper says where each left-in query ENDS in the bytes it was given — a query begun in an
    /// earlier call, one ended by a held ESC released now, and a long one.
    func testLeftInQueriesCarryWhereTheyEnd() {
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.feedLocating(b("ab\u{9b}?1$pcd\(E)]4;1;?\u{07}")).left.map(\.end), [8, 18])
        XCTAssertEqual(s.feedLocating(b("\u{9b}?1")).left.map(\.end), [])
        XCTAssertEqual(s.feedLocating(b("$pX")).left.map(\.end), [2], "begun in the earlier call")
        XCTAssertEqual(s.feedLocating(b("\(E)]4;1;?") + [0x1b]).left.map(\.end), [])
        XCTAssertEqual(s.feedLocating(b("[m")).left.map(\.end), [0], "its ESC was the held byte: it ends before these")
        var w = StreamingQueryStripper()
        _ = w.withholdLocating(b("\(E)]4;" + String(repeating: "x;", count: 2500)))
        XCTAssertEqual(w.withholdLocating(b("1;?\u{07}zz")).map(\.end), [4])
    }

    /// The `display` line: the cursor, the region and `?2026`; an older tmux's empty field is unknown.
    func testTheDisplayLineParses() throws {
        let (cursor, s) = TermHostState.parse("5 7 2 9 1", tracked: TermModes())
        XCTAssertEqual(cursor?.row, 5); XCTAssertEqual(cursor?.col, 7)
        XCTAssertEqual(s.scrollTop, 2); XCTAssertEqual(s.scrollBottom, 9); XCTAssertEqual(s.synchronizedOutput, true)
        let (_, old) = TermHostState.parse("5 7 0 23 ", tracked: TermModes())
        XCTAssertNil(old.synchronizedOutput)
        XCTAssertEqual(text(try XCTUnwrap(TermHostReplies.answer(b("\u{9b}?2026$p"), palette: .xtermDefault, cursor: nil, state: old))),
                       "\(E)[?2026;0$y", "unknown: not recognised, never a guess")
        XCTAssertNil(TermHostState.parse("", tracked: TermModes()).cursor)
    }
}
