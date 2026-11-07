import XCTest
@testable import RdevCore

/// Two things the query scanner used to get wrong (docs/terminal.md, "Who answers"):
///
/// 8-BIT C1. xterm.js 6 reads the CODE POINTS its UTF-8 decoder gives it, and U+009B / U+009D /
/// U+0090 / U+009C (bytes C2 9B, C2 9D, C2 90, C2 9C) are CSI, OSC, DCS and ST in EVERY state — so
/// `C2 9B 6 n` is a DSR it answers (measured, `term-client-queries.json`). tmux 3.7c reads bytes and
/// answers none of them (measured), so the tmux stripper leaves every query a C1 code point
/// introduces or ends for xterm.js to answer, once.
///
/// A STRING LONGER THAN THE 4 KB HOLD. Its bytes are released, but its KIND is kept, so an OSC or DCS
/// query split across reads past the cap is still recognised — exactly once, on the read that ends it.
final class TermQueryC1AndLongTests: XCTestCase {
    private let E = "\u{1b}"
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: 8-bit C1

    func testC1IntroducersAndTheC1STAreReadAsXtermJsReadsThem() {
        let cases: [(String, Int)] = [
            ("\u{9b}6n", 1), ("\u{9b}c", 1), ("\u{9b}?25$p", 1), ("\(E)\u{9b}6n", 1), ("\(E)[\u{9b}6n", 1),
            ("\u{9d}11;?\u{07}", 1), ("\u{9d}11;?\u{9c}", 1), ("\(E)]11;?\u{9c}", 1), ("\u{90}$qm\u{9c}", 1),
            ("\(E)P$qm\u{9c}", 1), ("\u{90}$qm\(E)\\", 1),
            // Any other C1 code point inside a string drops it (no answer); an introducer then starts
            // the next sequence, which is answered.
            ("\(E)]11;?\u{85}", 0), ("\(E)]11;?\u{9b}", 0), ("\(E)]11;?\u{9d}11;?\u{07}", 1), ("\(E)]0;t\u{9b}6n", 1),
            ("\(E)P$qm\u{85}\(E)\\", 0), ("\(E)P$qm\u{9b}6n", 1), ("\(E)[6\u{85}n", 0), ("\u{9e}\u{9b}6n", 1),
        ]
        for (q, n) in cases {
            var s = StreamingQueryStripper()
            XCTAssertEqual(s.countQueries(b("a\(q)b\(E)[m")), n, q.debugDescription)
            var t = StreamingQueryStripper()
            var total = 0
            for byte in b("a\(q)b\(E)[m") { total += t.countQueries([byte]) }
            XCTAssertEqual(total, n, "a byte at a time: \(q.debugDescription)")
        }
    }

    /// A C1 query is never held by the send buffer either — it is found, hit and all.
    func testAC1QueryIsFound() {
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.scan(b("x\u{9b}5n")).map(\.end), [5])
        XCTAssertEqual(s.scan([0xc2]), [], "a lone lead byte: maybe a C1 introducer — held")
        XCTAssertEqual(s.scan([0x9b, 0x36, 0x6e]).map(\.clientReplies), [1], "completed on the next read")
    }

    /// Every hit says where its sequence BEGAN, as an offset into the whole stream fed so far — a query
    /// begun in an earlier call included (the manager answers a query begun before its tab's last
    /// snapshot itself: the client's new instance saw only its tail).
    func testAHitCarriesTheStreamOffsetItsSequenceBeganAt() {
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.scan(b("ab\(E)[5n")).map(\.start), [2])
        XCTAssertEqual(s.fed, 6)
        XCTAssertEqual(s.scan(b("xy\(E)[")), [])
        XCTAssertEqual(s.scan(b("6n")).map(\.start), [8], "begun in the earlier call")
        XCTAssertEqual(s.scan(b("\(E)]0;t\(E)[6n")).map(\.start), [17], "an ESC ending a string starts the next")
        // A string longer than the hold, whose bytes were released long ago.
        var t = StreamingQueryStripper()
        _ = t.scan(b("zz"))
        _ = t.scan(b("\(E)]4;1;?;") + Array(repeating: 0x20, count: 5000))
        XCTAssertEqual(t.scan(b("\u{07}")).map(\.start), [2])
        // A C1 introducer whose lead byte came alone.
        var u = StreamingQueryStripper()
        _ = u.scan(b("q"))
        XCTAssertEqual(u.scan([0xc2]), [])
        XCTAssertEqual(u.scan([0x9b, 0x36, 0x6e]).map(\.start), [1])
    }

    /// tmux answers no C1 query (measured), so none is stripped: xterm.js answers it, once. A 7-bit
    /// query is stripped as before, and a C1 control that ENDS a 7-bit query also leaves it in.
    func testTheTmuxStripperLeavesC1QueriesForTheClient() {
        for q in ["\u{9b}6n", "\(E)\u{9b}6n", "\u{9d}11;?\u{07}", "\(E)]11;?\u{9c}", "\u{90}$qm\u{9c}", "\(E)]0;t\u{9b}6n"] {
            var st = StreamingQueryStripper()
            XCTAssertEqual(st.feed(b("a\(q)b")), b("a\(q)b"), q.debugDescription)
        }
        var st = StreamingQueryStripper()
        XCTAssertEqual(st.feed(b("a\(E)[6nb\u{9b}6nc")), b("ab\u{9b}6nc"))
    }

    /// The CSI grammar as xterm.js 6's table has it: a private marker only FIRST, digits clamped, not
    /// wrapped; a malformed CSI is ignored, not dispatched. And an OSC identifier is digits only.
    func testMalformedSequencesAreNotAnswered() {
        for q in ["\(E)[6?n", "\(E)[?6?n", "\(E)[99999999999999999999c", "\(E)]+11;?\u{07}", "\(E)P?$qm\(E)\\", "\(E)[$1p"] {
            var s = StreamingQueryStripper()
            XCTAssertEqual(s.countQueries(b("a\(q)b\(E)[m")), 0, q.debugDescription)
        }
        for q in ["\(E)P1$qm\(E)\\", "\(E)]4;0001;?\u{07}", "\(E)[1$p", "\(E)[6:1n"] {
            var s = StreamingQueryStripper()
            XCTAssertEqual(s.countQueries(b("a\(q)b\(E)[m")), 1, q.debugDescription)
        }
    }

    // MARK: strings longer than the hold

    private let big = String(repeating: "x", count: 6000)

    /// A DECRQSS longer than 4 KB, split across reads: ONE hit, one answer, on the read that ends it.
    func testALongDECRQSSSplitAcrossReadsIsRecognisedOnce() {
        let q = b("pre\(E)P$q\(big)\(E)\\post")
        for chunk in [1, 7, 1000, 4096, 4097, 5000] {
            var s = StreamingQueryStripper()
            var hits: [(Int, TermQueryHit)] = []
            var i = 0
            while i < q.count {
                let piece = Array(q[i..<min(i + chunk, q.count)])
                for h in s.scan(piece) { hits.append((i + h.end, h)) }
                i += chunk
            }
            XCTAssertEqual(hits.map(\.1.clientReplies), [1], "chunk \(chunk)")
            XCTAssertEqual(hits.first?.0, 3 + 4 + 6000 + 1, "just past the ESC that ends it, chunk \(chunk)")
        }
    }

    /// An OSC 4 asking more colours than fit in 4 KB counts every one of them, once.
    func testALongColourQueryCountsEveryAnswer() {
        let pairs = (0..<1500).map { "\($0 % 256);?" }.joined(separator: ";")
        let q = b("\(E)]4;\(pairs)\u{07}")
        XCTAssertGreaterThan(q.count, 4096)
        for chunk in [1, 999, 4096] {
            var s = StreamingQueryStripper()
            var total = 0, n = 0, i = 0
            while i < q.count { let h = s.scan(Array(q[i..<min(i + chunk, q.count)])); total += h.map(\.clientReplies).reduce(0, +); n += h.count; i += chunk }
            XCTAssertEqual(total, 1500, "chunk \(chunk)")
            XCTAssertEqual(n, 1)
        }
    }

    /// The same string, then a query right after it in the same read, and one C1-introduced long
    /// string: all found, in order.
    func testWhatFollowsALongStringIsScannedAsUsual() {
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.scan(b("\(E)]0;\(big)")), [])
        XCTAssertEqual(s.scan(b("tail\u{07}\(E)[6n")).map { [$0.end, $0.clientReplies] }, [[9, 1]], "the title asks nothing; the DSR after it")
        var t = StreamingQueryStripper()
        XCTAssertEqual(t.scan(b("\u{90}$q\(big)")), [])
        XCTAssertEqual(t.scan([0xc2]), [], "the ST's lead byte")
        XCTAssertEqual(t.scan([0x9c, 0x41]).map { [$0.end, $0.clientReplies] }, [[1, 1]])
    }

    /// tmux: a long string's bytes are released as they come, but a long QUERY tmux answers (DECRQSS) is ENDED by
    /// CAN instead of its terminator, so xterm.js aborts it rather than answering a second time. A
    /// long string that asks nothing — a title, a sixel image — passes through untouched.
    func testTheTmuxStripperNeutralisesALongQuery() {
        var d = StreamingQueryStripper()
        var out = d.feed(b("\(E)P$q\(big)"))
        out += d.feed(b("m\(E)\\c"))
        XCTAssertEqual(out, b("\(E)P$q\(big)m\u{18}\(E)\\c"), "CAN before the ESC that ends it")
        // …and a long colour query tmux does NOT answer (OSC 4, an OSC 11 asking several colours —
        // measured) is left whole for xterm.js.
        let pairs = (0..<1500).map { "\($0 % 256);?" }.joined(separator: ";")
        for q in ["\(E)]0;\(big)\u{07}z", "\(E)P0;1;0q\(big)\(E)\\z", "\u{9d}11;?;\(big)\u{9c}z",
                  "\(E)]11;?;\(big);?\u{07}z", "\(E)]4;\(pairs)\u{07}z", "\(E)]4;\(pairs)\(E)\\z"] {
            var p = StreamingQueryStripper()
            let bytes = b(q)
            let half = bytes.count / 2
            XCTAssertEqual(p.feed(Array(bytes[..<half])) + p.feed(Array(bytes[half...])), bytes, "untouched")
        }
    }

    /// A long CSI is still released unclassified (no real stream carries one); a long OSC body that
    /// ends in a stray lead byte keeps it for the next read.
    func testTheCapStillReleasesAnythingButAString() {
        var st = StreamingQueryStripper()
        let csi = b("\(E)[" + String(repeating: "1;", count: 3000))
        XCTAssertEqual(st.feed(csi), csi)
        var s = StreamingQueryStripper()
        XCTAssertEqual(s.feed(b("\(E)]0;\(big)") + [0xc2]), b("\(E)]0;\(big)"), "the lead byte waits")
        XCTAssertEqual(s.feed([0xa7, 0x07]), [0xc2, 0xa7, 0x07])
    }

    // MARK: withheld bytes are classified exactly as forwarded ones

    /// `withhold` runs the stripper WITHOUT building its output (nothing is forwarded). Its `left` — and
    /// the state it leaves (held bytes, an open long string, the stream offset) — must be exactly what
    /// `feedCounting` would give: two strippers fed one fuzzed stream in the same random chunks, one
    /// withholding where the other forwards, agree on every chunk's `left` and on every later forward.
    func testWithholdClassifiesExactlyAsFeedCounting() {
        var rng = SplitMix(seed: 0x5eed_2026_0927)
        let atoms: [[UInt8]] = [
            [0x1b], [0x1b, 0x5b], [0x1b, 0x5d], [0x1b, 0x50], [0x1b, 0x5c], [0x07], [0xc2, 0x9b], [0xc2, 0x9d],
            [0xc2, 0x90], [0xc2, 0x9c], [0xc2], [0x9c], [0x85], [0x18], [0x0d], [0x0a],
            b("6n"), b("?6n"), b("5n"), b("c"), b(">c"), b("?25$p"), b("$qm"), b("+q"), b("?u"), b("14t"),
            b("4;1;?"), b("4;0001;?;2;?"), b("10;?;?"), b("11;?"), b("12;?"), b("0;title"), b(";"), b("?"),
            b("abc"), b("\u{2500}"), [0xe2, 0x94], [0x80], b("m"), b("0;31m"),
        ]
        for round in 0..<300 {
            var stream: [UInt8] = []
            for _ in 0..<(40 + Int(rng.next() % 200)) {
                if rng.next() % 97 == 0 { stream += [UInt8](repeating: 0x41, count: 3000 + Int(rng.next() % 3000)) }
                stream += atoms[Int(rng.next() % UInt64(atoms.count))]
            }
            var a = StreamingQueryStripper(), f = StreamingQueryStripper()
            var i = 0
            while i < stream.count {
                let n = 1 + Int(rng.next() % 64)
                let chunk = Array(stream[i..<min(i + n, stream.count)])
                i += n
                if rng.next() % 2 == 0 {
                    XCTAssertEqual(a.withhold(chunk), f.feedCounting(chunk).left, "round \(round) at \(i)")
                } else {
                    let x = a.feedCounting(chunk), y = f.feedCounting(chunk)
                    XCTAssertTrue(x.out == y.out && x.clientReplies == y.clientReplies && x.mayAsk == y.mayAsk && x.left == y.left,
                                  "round \(round) at \(i)")
                }
                XCTAssertEqual(a.fed, f.fed)
            }
        }
    }
}

/// A seeded generator, so a failure names a reproducible stream.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
