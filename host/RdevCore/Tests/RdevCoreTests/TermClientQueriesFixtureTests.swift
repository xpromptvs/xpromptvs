import XCTest
@testable import RdevCore

/// The host's idea of which device queries the CLIENT answers — and how many answers each gets — must be
/// EXACTLY what the client's xterm.js answers as the product configures it. That list is MEASURED against
/// a real xterm.js by `web/test/term-client-queries.test.ts`, which also refuses a stale fixture; this
/// suite asserts the host's classifier (`StreamingQueryStripper.scan`) against the same file. A query the
/// host counts that xterm.js does not answer is a query NOBODY answers (and a credit nothing spends); one
/// xterm.js answers that the host does not count is answered TWICE (docs/terminal.md, "Who answers").
final class TermClientQueriesFixtureTests: XCTestCase {
    /// `hex`: a candidate given as BYTES (invalid UTF-8 around a query), which the web test measured
    /// through the client's own `TextDecoder`; `q` is then only its decoded text.
    private struct Case: Decodable {
        let q: String; let replies: Int; let answers: String; let hex: String?
        /// The stream exactly as the web test wrote it: `a`, the candidate, `b ESC [ m`.
        var bytes: [UInt8] {
            guard let hex else { return Array(TermClientQueriesFixtureTests.wrap(q).utf8) }
            let h = Array(hex.utf8)
            let raw = stride(from: 0, to: h.count, by: 2).map { UInt8(String(decoding: h[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
            return [0x61] + raw + [0x62, 0x1b, 0x5b, 0x6d]
        }
        var length: Int { hex.map { $0.utf8.count / 2 } ?? q.utf8.count }
    }
    private struct Palette: Decodable {
        let fg: String, bg: String, cursor: String, ansi: [String]
        /// The 16-255 slots the theme replaces — what the client sends as `term-palette.ext`.
        let ext: [String: String]
        var wire: [String: Any] { ["fg": fg, "bg": bg, "cursor": cursor, "ansi": ansi, "ext": ext] }
    }
    private struct Palettes: Decodable { let `default`: Palette, dark: Palette, light: Palette }
    private struct Fixture: Decodable { let cases: [Case]; let palettes: Palettes }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/term-client-queries.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    /// Exactly how the web test surrounds each candidate: text, then a closing `ESC [ m`, so a string
    /// left open (a DCS "ended" by BEL) is ended the way the real stream would end it.
    static func wrap(_ q: String) -> String { "a\(q)b\u{1b}[m" }

    func testTheFixtureIsNotVacuous() {
        XCTAssertGreaterThan(Self.fx.cases.count, 40)
        XCTAssertTrue(Self.fx.cases.contains { $0.replies == 0 } && Self.fx.cases.contains { $0.replies == 2 })
        XCTAssertGreaterThan(Self.fx.cases.filter { $0.hex != nil }.count, 15, "the invalid-UTF-8 candidates")
        XCTAssertGreaterThan(Self.fx.cases.filter { $0.q.utf8.count > 4096 }.count, 5, "the candidates longer than the hold")
    }

    /// Whole, inside surrounding text: the answers the host expects equal the answers xterm.js gives.
    func testTheHostCountsExactlyWhatXtermAnswers() {
        for c in Self.fx.cases {
            var s = StreamingQueryStripper()
            let hits = s.scan(c.bytes)
            XCTAssertEqual(hits.map(\.clientReplies).reduce(0, +), c.replies, "\(c.q.debugDescription)")
            // Within the candidate (an ST's `\` or the wrapper's closing ESC may follow the hit's end).
            for h in hits where h.clientReplies > 0 {
                XCTAssertLessThanOrEqual(h.end, 1 + c.length + 2, "\(c.q.debugDescription)")
            }
        }
    }

    /// A byte at a time: a query split across reads counts once, on the read that completes it.
    func testTheCountSurvivesAnySplit() {
        for c in Self.fx.cases {
            var s = StreamingQueryStripper()
            var total = 0
            for (i, b) in c.bytes.enumerated() {
                for h in s.scan([b]) { XCTAssertEqual(h.end, 1, "\(c.q.debugDescription) byte \(i)"); total += h.clientReplies }
            }
            XCTAssertEqual(total, c.replies, "\(c.q.debugDescription)")
        }
    }

    /// The HOST's answers (`TermHostReplies`, for a query a tmux tab leaves for the client whose bytes
    /// reach no client) are byte for byte what the real xterm.js answered: every query-like sequence in
    /// every candidate the host can answer (colours, CPR, DA, DSR 5 — not DECRQM or DECRQSS, which need
    /// state it does not keep), with the dark palette the fixture measured and the cursor the web test's
    /// stream leaves (after the leading `a`, or at column 0 once a CR has executed).
    func testTheHostsAnswersAreXtermJsAnswers() throws {
        let dark = try XCTUnwrap(TermPalette(wire: Self.fx.palettes.dark.wire))
        var checked = 0, colours = 0, cursors = 0
        // The byte candidates' cursor depends on the U+FFFD columns in front of the query: not these.
        for c in Self.fx.cases where c.hex == nil {
            let bytes = c.bytes
            let cursor = (row: 0, col: c.q.contains("\r") ? 0 : 1)
            var produced: [UInt8] = []
            var answerable = true
            for f in StreamingQueryStripper.walk(bytes) where (f.replies ?? 0) > 0 {
                guard let a = TermHostReplies.answer(Array(bytes[f.start..<f.feedEnd]), palette: dark, cursor: cursor) else {
                    answerable = false; break
                }
                produced += a
            }
            guard answerable, c.replies > 0 else { continue }
            XCTAssertEqual(String(decoding: produced, as: UTF8.self), c.answers, c.q.debugDescription)
            checked += 1
            if c.answers.contains("rgb:") { colours += 1 }
            if c.answers.hasSuffix("R") { cursors += 1 }
        }
        XCTAssertGreaterThan(checked, 40)
        XCTAssertGreaterThan(colours, 12)
        XCTAssertGreaterThan(cursors, 12)
    }

    /// A `pty:` tab's host answers to COLOUR queries: the scanner hands each hit's whole query back
    /// (`TermQueryHit.query`) even fed a byte at a time, and `colourAnswer` from the driver's palette
    /// is byte for byte what the real xterm.js answered with that palette.
    func testThePtyScannersColourAnswersAreXtermJsAnswers() throws {
        let dark = try XCTUnwrap(TermPalette(wire: Self.fx.palettes.dark.wire))
        var checked = 0
        for c in Self.fx.cases where c.answers.contains("rgb:") {
            let bytes = c.bytes
            let walked = StreamingQueryStripper.walk(bytes).filter { ($0.replies ?? 0) > 0 }
            guard walked.allSatisfy({ TermHostReplies.colourAnswer(Array(bytes[$0.start..<$0.feedEnd]), palette: dark) != nil })
            else { continue }
            for split in [bytes.count, 1] {
                var s = StreamingQueryStripper()
                var produced: [UInt8] = []
                var i = 0
                while i < bytes.count {
                    for h in s.scan(Array(bytes[i..<min(i + split, bytes.count)])) where h.clientReplies > 0 {
                        produced += try XCTUnwrap(h.query.flatMap { TermHostReplies.colourAnswer($0, palette: dark) }, c.q.debugDescription)
                    }
                    i += split
                }
                XCTAssertEqual(String(decoding: produced, as: UTF8.self), c.answers, "\(c.q.debugDescription) split \(split)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 12)
    }

    /// Until a client sends its palette the host answers with xterm.js's own defaults — measured.
    func testTheDefaultPaletteIsXtermJsDefault() throws {
        XCTAssertEqual(TermPalette.xtermDefault, try XCTUnwrap(TermPalette(wire: Self.fx.palettes.default.wire)))
        XCTAssertNotEqual(try XCTUnwrap(TermPalette(wire: Self.fx.palettes.light.wire)), TermPalette.xtermDefault)
    }
}
