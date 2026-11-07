import XCTest
@testable import RdevCore

/// The host's answers to the device queries tmux leaves for the client's xterm.js (OSC 4, OSC 12,
/// multi-colour OSC 10/11, DECDSR, C1 forms), for when their bytes reach NO client (docs/terminal.md,
/// "tmux answers device queries itself"): byte for byte what xterm.js 6 would answer. The format is
/// checked against a REAL xterm.js's answers in `TermClientQueriesFixtureTests`; these pin the parsing.
final class TermHostRepliesTests: XCTestCase {
    private let E = "\u{1b}"
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func answer(_ q: String, _ p: TermPalette = .xtermDefault, cursor: (row: Int, col: Int)? = nil) -> String? {
        TermHostReplies.answer(b(q), palette: p, cursor: cursor).map { String(decoding: $0, as: UTF8.self) }
    }

    func testColourQueriesAnswerFromThePalette() {
        XCTAssertEqual(answer("\(E)]4;1;?\u{07}"), "\(E)]4;1;rgb:cccc/0000/0000\(E)\\")
        XCTAssertEqual(answer("\(E)]4;1;?;0002;?\(E)"), "\(E)]4;1;rgb:cccc/0000/0000\(E)\\\(E)]4;2;rgb:4e4e/9a9a/0606\(E)\\")
        XCTAssertEqual(answer("\(E)]4;16;?;231;?;232;?;255;?\u{07}"),
                       "\(E)]4;16;rgb:0000/0000/0000\(E)\\\(E)]4;231;rgb:ffff/ffff/ffff\(E)\\"
                       + "\(E)]4;232;rgb:0808/0808/0808\(E)\\\(E)]4;255;rgb:eeee/eeee/eeee\(E)\\")
        XCTAssertEqual(answer("\(E)]4;256;?;x;?;1;#ff0000\u{07}"), "", "invalid indices and sets answer nothing")
        XCTAssertEqual(answer("\(E)]12;?\u{07}"), "\(E)]12;rgb:ffff/ffff/ffff\(E)\\")
        XCTAssertEqual(answer("\(E)]10;?;?\u{07}"), "\(E)]10;rgb:ffff/ffff/ffff\(E)\\\(E)]11;rgb:0000/0000/0000\(E)\\")
        XCTAssertEqual(answer("\(E)]11;?;?;?\u{07}"), "\(E)]11;rgb:0000/0000/0000\(E)\\\(E)]12;rgb:ffff/ffff/ffff\(E)\\")
        XCTAssertEqual(answer("\u{9d}11;\n?\u{9c}"), "\(E)]11;rgb:0000/0000/0000\(E)\\", "C1, and C0 dropped from the body")
    }

    func testTheClientsPaletteIsUsed() {
        var p = TermPalette.xtermDefault
        p.foreground = .init(r: 0xec, g: 0xec, b: 0xec)
        p.ansi[1] = .init(r: 0xc8, g: 0x1e, b: 0x10)
        XCTAssertEqual(answer("\(E)]4;1;?\u{07}", p), "\(E)]4;1;rgb:c8c8/1e1e/1010\(E)\\")
        XCTAssertEqual(answer("\(E)]10;?\u{07}", p), "\(E)]10;rgb:ecec/ecec/ecec\(E)\\")
    }

    func testCursorReportsAreOneBased() {
        XCTAssertEqual(answer("\(E)[?6n", cursor: (row: 0, col: 0)), "\(E)[?1;1R")
        XCTAssertEqual(answer("\u{9b}6n", cursor: (row: 4, col: 79)), "\(E)[5;80R")
        XCTAssertEqual(answer("\(E)[6;9n", cursor: (row: 1, col: 2)), "\(E)[2;3R")
        XCTAssertNil(answer("\(E)[?6n"), "no cursor, no answer")
        XCTAssertTrue(TermHostReplies.needsCursor(b("\(E)[?6n")))
        XCTAssertTrue(TermHostReplies.needsCursor(b("\u{9b}6n")))
        XCTAssertFalse(TermHostReplies.needsCursor(b("\(E)[5n")))
        XCTAssertFalse(TermHostReplies.needsCursor(b("\(E)]4;1;?\u{07}")))
    }

    func testConstantAnswers() {
        XCTAssertEqual(answer("\u{9b}c"), "\(E)[?1;2c")
        XCTAssertEqual(answer("\u{9b}>c"), "\(E)[>0;276;0c")
        XCTAssertEqual(answer("\u{9b}5n"), "\(E)[0n")
        XCTAssertEqual(answer("\u{9b}1c"), "", "xterm.js answers no DA with a parameter")
    }

    /// What needs state the host does not keep for a tmux tab is NOT answered — nil, never a guess.
    func testStatefulQueriesAreNotAnswered() {
        XCTAssertNil(answer("\u{9b}?25$p"))
        XCTAssertNil(answer("\u{90}$qm\u{9c}"))
    }

    /// The tmux stripper hands back the queries it LEFT IN, whole, in order — a query split across calls
    /// once, on the call that completes it; one tmux answers (stripped) never; one xterm.js answers
    /// nothing to (`CSI 1 c`) never.
    func testTheStripperReturnsTheQueriesItLeftIn() {
        var s = StreamingQueryStripper()
        let r1 = s.feedCounting(b("x\(E)[6n\(E)]4;1;?\u{07}\u{9b}1c\(E)]12"))
        XCTAssertEqual(r1.left, [b("\(E)]4;1;?\u{07}")])
        let r2 = s.feedCounting(b(";?\(E)\\\(E)[?6n"))
        XCTAssertEqual(r2.left, [b("\(E)]12;?\(E)"), b("\(E)[?6n")])
        XCTAssertEqual(r2.clientReplies, 2)
    }

    func testThePaletteParsesFromTheWire() throws {
        let ansi = (0..<16).map { String(format: "#%02x%02x%02x", $0, 0, 255 - $0) }
        let p = try XCTUnwrap(TermPalette(wire: ["fg": "#ececec", "bg": "#000000", "cursor": "#ECECEC", "ansi": ansi]))
        XCTAssertEqual(p.cursor, .init(r: 0xec, g: 0xec, b: 0xec))
        XCTAssertEqual(p.color(3), .init(r: 3, g: 0, b: 252))
        XCTAssertEqual(p.color(196), .init(r: 0xff, g: 0, b: 0), "past the 16: xterm.js's fixed cube")
        XCTAssertNil(TermPalette(wire: ["fg": "#ececec", "bg": "#000000", "cursor": "#ececec", "ansi": Array(ansi.prefix(15))]))
        XCTAssertNil(TermPalette(wire: ["fg": "ececec", "bg": "#000000", "cursor": "#ececec", "ansi": ansi]))
        XCTAssertNil(TermPalette(wire: ["fg": "#ececec", "bg": "#00000g", "cursor": "#ececec", "ansi": ansi]))
    }

    /// `ext`: the 16-255 slots the client's THEME replaces (`extendedAnsi`) — Claude Code's diff
    /// backgrounds on the dark theme — so the host answers OSC 4 for them as that xterm.js does. Absent
    /// is none; a present one must be exactly an object of "16"…"255" → `#rrggbb`, or the palette is
    /// malformed like any other bad field.
    func testThePalettesReplacedSlotsParseFromTheWire() throws {
        let ansi = (0..<16).map { String(format: "#%02x%02x%02x", $0, 0, 255 - $0) }
        let base: [String: Any] = ["fg": "#ececec", "bg": "#000000", "cursor": "#ececec", "ansi": ansi]
        var w = base; w["ext"] = ["22": "#394634", "88": "#7D484C"]
        let p = try XCTUnwrap(TermPalette(wire: w))
        XCTAssertEqual(p.color(22), .init(r: 0x39, g: 0x46, b: 0x34))
        XCTAssertEqual(p.color(88), .init(r: 0x7d, g: 0x48, b: 0x4c))
        XCTAssertEqual(p.color(23), .init(r: 0x00, g: 0x5f, b: 0x5f), "an unreplaced slot is still the cube")
        XCTAssertEqual(p.color(3), .init(r: 3, g: 0, b: 252))
        XCTAssertEqual(try XCTUnwrap(TermPalette(wire: base)).color(22), .init(r: 0, g: 0x5f, b: 0), "absent is none")
        for bad: Any in [["15": "#394634"], ["256": "#394634"], ["x": "#394634"], ["22": "394634"], ["22": 1], "22"] {
            var m = base; m["ext"] = bad
            XCTAssertNil(TermPalette(wire: m), "malformed ext \(bad)")
        }
    }
}
