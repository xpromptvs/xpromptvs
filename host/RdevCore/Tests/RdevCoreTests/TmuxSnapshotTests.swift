import XCTest
@testable import RdevCore

final class TmuxSnapshotTests: XCTestCase {
    /// pane cx cy w h alt cursor keypad-cursor mouse-std mouse-btn mouse-all mouse-sgr hist-size hist-limit
    /// region-upper region-lower origin sync bracket
    private let primary = TmuxPaneState.parse("%3 4 2 20 3 0 1 1 0 1 0 1 2 2000 0 2 0 0 1")!
    private let onAlt = TmuxPaneState.parse("%3 0 0 20 3 1 0 0 0 0 0 0 0 2000 1 2 1 1 0")!
    private func text(_ l: TermLine) -> String { l.cells.map(\.text).joined() }
    private let plain = TmuxSnapshot.Extra(insert: false, keypad: false, wraparound: true)

    func testSGRRunsBecomeCells() {
        let c = TmuxSnapshot.cells("\u{1b}[1m\u{1b}[38;5;174mab\u{1b}[0mc")
        XCTAssertEqual(c.map(\.text), ["a", "b", "c"])
        var want = TermAttrs(); want.bold = true; want.fg = .palette(174)
        XCTAssertEqual(c[0].attrs, want); XCTAssertEqual(c[1].attrs, want)
        XCTAssertEqual(c[2].attrs, TermAttrs())
    }

    func testTruecolorColonFormsAndResets() {
        let c = TmuxSnapshot.cells("\u{1b}[38;2;1;2;3mx\u{1b}[48:5:9my\u{1b}[4:3;58;5;7mz\u{1b}[22;24;39;49;59mw")
        XCTAssertEqual(c[0].attrs.fg, .rgb(1, 2, 3))
        XCTAssertEqual(c[1].attrs.bg, .palette(9))
        XCTAssertEqual(c[2].attrs.underline, 3); XCTAssertEqual(c[2].attrs.underlineColor, .palette(7))
        XCTAssertEqual(c[3].attrs, TermAttrs())
    }

    /// ITU T.416's colon form with the colour-space id (`38:2::r:g:b`, what tmux writes for an
    /// underline colour on some builds) and without it (`38:2:r:g:b`).
    func testColonTruecolorWithAndWithoutTheColourSpace() {
        let c = TmuxSnapshot.cells("\u{1b}[38:2::10:20:30mx\u{1b}[48:2:4:5:6my\u{1b}[58:2::7:8:9mz")
        XCTAssertEqual(c[0].attrs.fg, .rgb(10, 20, 30))
        XCTAssertEqual(c[1].attrs.bg, .rgb(4, 5, 6))
        XCTAssertEqual(c[2].attrs.underlineColor, .rgb(7, 8, 9))
    }

    func testEveryFlagAndItsOff() {
        let on = TmuxSnapshot.cells("\u{1b}[1;2;3;5;7;8;9;21mx")[0].attrs
        XCTAssertTrue(on.bold && on.dim && on.italic && on.blink && on.inverse && on.invisible && on.strikethrough)
        XCTAssertEqual(on.underline, 2)
        let off = TmuxSnapshot.cells("\u{1b}[1;2;3;4;5;7;8;9m\u{1b}[22;23;24;25;27;28;29mx")[0].attrs
        XCTAssertEqual(off, TermAttrs())
        let bright = TmuxSnapshot.cells("\u{1b}[97;101mx")[0].attrs
        XCTAssertEqual([bright.fg, bright.bg], [.palette(15), .palette(9)])
        XCTAssertEqual(TmuxSnapshot.cells("\u{1b}[31m\u{1b}[mx")[0].attrs, TermAttrs(), "an empty SGR is a reset")
    }

    func testAWideGlyphIsOneCellOfWidthTwo() {
        XCTAssertEqual(TmuxSnapshot.cells("中a").map(\.width), [2, 1])
        XCTAssertEqual(TmuxSnapshot.cells("e\u{301}").map(\.width), [1])
    }

    /// A tmux capture is segmented into TMUX's cells, by tmux's own widths and joins (docs/terminal.md,
    /// "tmux tabs count as tmux does") — never by Swift's graphemes or SwiftTerm's model.
    func testCellsAreTmuxsCells() {
        func seg(_ s: String, cols: Int = .max) -> [String] {
            var st = TmuxSnapshot.CaptureState()
            return TmuxSnapshot.cells(s, state: &st, cols: cols).map { "\($0.text):\($0.width)" }
        }
        XCTAssertEqual(seg("\u{1F44D}\u{1F3FD}X"), ["\u{1F44D}\u{1F3FD}:2", "X:1"], "a listed base takes the skin tone")
        XCTAssertEqual(seg("\u{261D}\u{1F3FD}X"), ["\u{261D}:2", "\u{1F3FD}:2", "X:1"], "☝ is not on tmux's list")
        XCTAssertEqual(seg("a\u{200D}\u{1F600}X"), ["a\u{200D}\u{1F600}:1", "X:1"], "anything non-ASCII joins after a ZWJ")
        XCTAssertEqual(seg("a\u{200D}bX"), ["a\u{200D}:1", "b:1", "X:1"], "ASCII never joins")
        XCTAssertEqual(seg("x\u{FE0F}"), ["x\u{FE0F}:2"])
        XCTAssertEqual(seg("\u{1F1FA}\u{1F1F8}\u{1F1EC}"), ["\u{1F1FA}\u{1F1F8}:2", "\u{1F1EC}:1"])
        XCTAssertEqual(seg("\u{1100}\u{1100}"), ["\u{1100}:2", "\u{1100}:2"])
        XCTAssertEqual(seg("a\u{3164}\u{302E}"), ["a\u{3164}:1", "\u{302E}:2"], "the filler is zero-width, the tone mark two")
        XCTAssertEqual(seg("\u{0301}a"), ["a:1"], "a zero-width scalar with no cell before it is dropped, as tmux drops it")
        let margin = seg(String(repeating: "a", count: 19) + "\u{2764}\u{FE0F}", cols: 20)
        XCTAssertEqual(margin.last, "\u{2764}\u{FE0F}:1", "a widening in the last column stays there, overhanging")
    }

    /// The user's tmux width options change the model (measured on tmux 3.7c, private server):
    /// `variation-selector-always-wide off` stops VS16 widening (x VS16 X: cursor 3 → 2), and
    /// `codepoint-widths` sets a scalar's width outright (☝X with U+261D=1: 3 → 2; a mark set to one
    /// column no longer joins).
    func testTheServersWidthOptionsChangeTheCells() {
        let off = TmuxGlyphOptions.parse(variationSelectorAlwaysWide: ["off"], codepointWidths: [])
        let widths = TmuxGlyphOptions.parse(variationSelectorAlwaysWide: ["on"],
                                            codepointWidths: ["U+261D=1", "U+1F600-U+1F602=1,U+0301=1"])
        XCTAssertTrue(TmuxGlyphOptions.parse(variationSelectorAlwaysWide: ["on"], codepointWidths: [""]).isDefault)
        XCTAssertTrue(TmuxGlyphOptions.parse(variationSelectorAlwaysWide: nil, codepointWidths: nil).isDefault,
                      "an older tmux without the options: its default model")
        func seg(_ s: String, _ o: TmuxGlyphOptions) -> [String] {
            var st = TmuxSnapshot.CaptureState()
            return TmuxSnapshot.cells(s, state: &st, glyphs: o).map { "\($0.text):\($0.width)" }
        }
        XCTAssertEqual(seg("x\u{FE0F}X", off), ["x\u{FE0F}:1", "X:1"])
        XCTAssertEqual(seg("x\u{FE0F}X", .default), ["x\u{FE0F}:2", "X:1"])
        XCTAssertEqual(seg("\u{261D}X", widths), ["\u{261D}:1", "X:1"])
        XCTAssertEqual(seg("\u{1F601}X", widths), ["\u{1F601}:1", "X:1"])
        XCTAssertEqual(seg("e\u{301}X", widths), ["e:1", "\u{301}:1", "X:1"], "a mark given a column no longer joins")
        XCTAssertEqual(widths.osc, "\u{1b}]9910;vs16wide=on;widths=U+261D=1,U+1F600-U+1F602=1,U+0301=1\u{07}")
        XCTAssertEqual(off.osc, "\u{1b}]9910;vs16wide=off;widths=\u{07}")
        XCTAssertEqual(TmuxGlyphOptions.default.osc, "", "the default model says nothing")
        let snap = TermSnapshot.blank(cols: 10, rows: 2)
        XCTAssertEqual(TmuxSnapshot.emit(snap, glyphs: .default), TermSnapshotEmitter.emit(snap))
        XCTAssertEqual(TmuxSnapshot.emit(snap, glyphs: off), Array(off.osc.utf8) + TermSnapshotEmitter.emit(snap),
                       "the options go FIRST, in band, so the instance counts the snapshot by them")
        XCTAssertEqual(Array(TmuxSnapshot.commands(session: "$1").suffix(3)),
                       ["display -p '#{version}'", "show-options -sv variation-selector-always-wide", "show-options -sv codepoint-widths"])
    }

    /// Every measured sample that a capture can carry (no escape or control) lands the cursor where tmux
    /// put it: the sum of the cells on the last row, the rows the cells wrap into.
    func testMeasuredSamplesSegmentWhereTmuxPutTheCursor() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/tmux-glyphs.json")
        struct Sample: Decodable { let name: String; let text: String; let x: Int; let y: Int }
        struct Doc: Decodable { let tmux: String; let wide: [UInt32]; let zero: [UInt32]; let modifierBases: [UInt32]; let samples: [Sample] }
        let doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: fixture))
        XCTAssertEqual(TmuxGlyphs.wide, Set(doc.wide))
        XCTAssertEqual(TmuxGlyphs.zero, Set(doc.zero))
        XCTAssertEqual(TmuxGlyphs.modifierBases, Set(doc.modifierBases))
        XCTAssertEqual(TmuxGlyphs.measuredVersion, doc.tmux)
        var checked = 0
        for s in doc.samples where !s.text.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            let rows = TmuxSnapshot.historyRows([s.text], cols: 20, tabStops: [])
            let last = rows.last?.cells.reduce(0) { $0 + Int($1.width) } ?? 0
            XCTAssertEqual([last, rows.count - 1], [s.x, s.y], s.name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 40)
    }

    func testOSCSequencesAreSkipped() {
        XCTAssertEqual(TmuxSnapshot.cells("\u{1b}]8;;http://x\u{1b}\\link\u{1b}]8;;\u{1b}\\").map(\.text).joined(), "link")
        XCTAssertEqual(TmuxSnapshot.cells("\u{1b}]0;title\u{07}t").map(\.text).joined(), "t", "a BEL-terminated OSC too")
    }

    /// Ruling 3: tmux output rdev does not expect degrades to text with default attributes — it never
    /// traps, and a malformed sequence never eats a printable glyph that follows it.
    func testMalformedInputDegradesAndNeverTraps() {
        let cases: [(String, String)] = [
            ("ab\u{1b}", "ab"),                                         // a lone ESC at the end
            ("ab\u{1b}[", "ab"),                                        // a CSI cut before its final
            ("ab\u{1b}[31", "ab"),
            ("\u{1b}[31中x", "中x"),                                     // a CSI cut by a non-ASCII glyph
            ("\u{1b}]8;;unterminated", ""),                             // an OSC with no terminator
            ("\u{1b}Pq#0;1\u{1b}\\x", "x"),                             // a DCS
            ("\u{1b}(Bx\u{1b}#8y", "xy"),                               // ESC + intermediate + final
            ("\u{1b}=x\u{1b}>y", "xy"),                                 // a two-byte escape
            ("\u{1b}[?25hx\u{1b}[>4;2my", "xy"),                        // private CSIs, one ending in m
            ("a\tb\u{07}c\u{7f}d\u{85}e", "abcde"),                     // C0 / DEL / C1 are not glyphs
        ]
        for (line, want) in cases {
            XCTAssertEqual(TmuxSnapshot.cells(line).map(\.text).joined(), want, line.debugDescription)
            XCTAssertTrue(TmuxSnapshot.cells(line).allSatisfy { $0.attrs == TermAttrs() }, line.debugDescription)
        }
    }

    func testMalformedSGRParametersAreIgnoredOrClamped() {
        let a = { (s: String) in TmuxSnapshot.cells("\u{1b}[\(s)mx")[0].attrs }
        XCTAssertEqual(a("38;5"), TermAttrs(), "an extended colour with no index")
        XCTAssertEqual(a("38;2;1;2"), TermAttrs(), "truecolour short a component")
        XCTAssertEqual(a("38;7;1"), TermAttrs(), "an unknown colour space")
        XCTAssertEqual(a("38;5;999").fg, .palette(255), "an index past 255 clamps")
        XCTAssertEqual(a("38;2;300;0;5").fg, .rgb(255, 0, 5))
        XCTAssertEqual(a("38;2;1;-2;3"), TermAttrs(), "a minus sign is an intermediate byte: not an SGR at all")
        XCTAssertEqual(a("99999999999999999999999"), TermAttrs(), "overflow is not a number")
        XCTAssertEqual([a("1;99999999999999999999999;3").bold, a("1;99999999999999999999999;3").italic], [true, true],
                       "an unparseable number spoils only itself")
        XCTAssertEqual(a("1;<3"), TermAttrs(), "a parameter byte SGR does not use: not an SGR at all")
        XCTAssertEqual(a("4:9").underline, 0, "an unknown underline style is no underline")
        XCTAssertEqual(a("4:"), a("4"), "an empty sub-parameter is the plain form")
        XCTAssertEqual(a("73;1;64").bold, true, "unknown parameters are skipped")
        XCTAssertEqual(a(";1").bold, true, "an empty parameter is 0 — reset, then bold")
    }

    /// `capture-pane -e` is STATEFUL across the lines of one capture: tmux writes an SGR only where the
    /// attributes change, so a line inherits what the one above it left open (measured, tmux 3.7c).
    func testThePenCarriesAcrossTheLinesOfOneCapture() {
        var pen = TmuxSnapshot.CaptureState()
        let first = TmuxSnapshot.cells("\u{1b}[1mbold", state: &pen)
        let second = TmuxSnapshot.cells("still", state: &pen)
        let third = TmuxSnapshot.cells("\u{1b}[0mplain", state: &pen)
        XCTAssertTrue(first[0].attrs.bold); XCTAssertTrue(second[0].attrs.bold); XCTAssertFalse(third[0].attrs.bold)
        let s = TmuxSnapshot.build(state: primary, extra: plain, history: ["\u{1b}[31mh1", "h2\u{1b}[0m"],
                                   screen: ["\u{1b}[44mone", "two", "\u{1b}[49mthree"], savedNormal: nil, focusReporting: false)
        XCTAssertEqual(s.normal.lines[1].cells[0].attrs.fg, .palette(1), "history's second line is still red")
        XCTAssertEqual(s.normal.lines[3].cells[0].attrs.bg, .palette(4), "the screen's second line is still blue")
        XCTAssertEqual(s.normal.lines[2].cells[0].attrs.fg, .default, "each capture starts from the default pen")
    }

    func testExtraFlags() {
        XCTAssertEqual(TmuxSnapshot.Extra.parse("1 0 0"), TmuxSnapshot.Extra(insert: true, keypad: false, wraparound: false))
        XCTAssertNil(TmuxSnapshot.Extra.parse("1 0"))
        XCTAssertNil(TmuxSnapshot.Extra.parse("1 x 0"))
        XCTAssertNil(TmuxSnapshot.Extra.parse("1 0 0 4 5"))
        XCTAssertNil(TmuxSnapshot.Extra.parse("1 0 0 bar 1 4 5"))
        XCTAssertEqual(TmuxSnapshot.extraFormat, "#{insert_flag} #{keypad_flag} #{wrap_flag} #{cursor_shape} #{cursor_blinking} #{pane_tabs}",
                       "pane_tabs LAST: it may expand to nothing")
        XCTAssertEqual(TmuxSnapshot.Extra.parse("0 1 1 bar 1 4,12,29,60")?.tabStops, [4, 12, 29, 60])
        XCTAssertEqual(TmuxSnapshot.Extra.parse("0 1 1 bar 1 4,12,29,60")?.cursorStyle, .blinkBar)
        XCTAssertEqual(TmuxSnapshot.Extra.parse("0 1 1 block 0 ")?.tabStops, [], "every stop cleared (CSI 3g) expands to nothing")
        XCTAssertNil(TmuxSnapshot.Extra.parse("0 1 1 block 0 4,x")?.tabStops, "a malformed list is unknown, not empty")
        XCTAssertEqual(TmuxSnapshot.Extra.parse("0 1 1 block 0 4,x")?.cursorStyle, .steadyBlock)
        XCTAssertNil(TmuxSnapshot.Extra.parse("0 1 1   8")?.cursorStyle, "a tmux without the cursor formats: unknown")
        XCTAssertNil(TmuxSnapshot.Extra.parse("0 1 1 hexagon 1 8")?.cursorStyle, "an unknown shape: unknown")
        XCTAssertEqual(TmuxSnapshot.Extra.parse("0 1 1 hexagon x 4,x")?.keypad, true, "and spoils only itself")
    }

    /// `cursor_shape` / `cursor_blinking` → the model's style, exactly as SwiftTermSnapshot reads the same
    /// DECSCUSR. tmux's replies per `CSI n SP q` were measured (tmux 3.7c): 0 and none → `default 0`,
    /// 1 → `block 1`, 2 → `block 0`, 3 → `underline 1`, 4 → `underline 0`, 5 → `bar 1`, 6 → `bar 0`.
    func testTheCursorStyleMatchesSwiftTermForEveryDECSCUSR() {
        let tmuxSays: [(String, String)] = [("", "default 0"), ("0", "default 0"), ("1", "block 1"), ("2", "block 0"),
                                           ("3", "underline 1"), ("4", "underline 0"), ("5", "bar 1"), ("6", "bar 0")]
        for (n, reply) in tmuxSays {
            let t = Terminal(cols: 10, rows: 2)
            _ = t.feed(n.isEmpty ? [] : Array("\u{1b}[\(n) q".utf8))
            let extra = TmuxSnapshot.Extra.parse("0 0 1 \(reply) 8")!
            let s = TmuxSnapshot.build(state: primary, extra: extra, history: [], screen: [], savedNormal: nil, focusReporting: false)
            XCTAssertEqual(s.cursor.style, t.snapshot().cursor.style, "DECSCUSR \(n.isEmpty ? "none" : n) (tmux: \(reply))")
        }
        let unknown = TmuxSnapshot.build(state: primary, extra: plain, history: [], screen: [], savedNormal: nil, focusReporting: false)
        XCTAssertEqual(unknown.cursor.style, .blinkBlock, "unknown is the default")
    }

    /// With `cols` left unknown (`.max`) and explicit stops, a tab past the last stop must still END:
    /// it goes to the next multiple of 8, and no tab advances more than tmux's widest pane.
    func testATabWithUnknownColumnsTerminates() {
        var st = TmuxSnapshot.CaptureState()
        XCTAssertEqual(TmuxSnapshot.cells("a\tb\tc", state: &st, tabStops: [4]).map { $0.text.isEmpty ? "_" : $0.text }.joined(), "a___b___c")
        st = TmuxSnapshot.CaptureState()
        let far = TmuxSnapshot.cells("a\tb", state: &st, tabStops: [1_000_000_000_000])
        XCTAssertEqual(far.count, TmuxSnapshot.maxTabAdvance + 2)
        st = TmuxSnapshot.CaptureState()
        XCTAssertEqual(TmuxSnapshot.cells("a\tb", state: &st, cols: 1_000_000_000, tabStops: []).count, TmuxSnapshot.maxTabAdvance + 2)
    }

    /// tmux's tab stops (`pane_tabs`) are the snapshot's, in BOTH buffers (tmux keeps one set per pane);
    /// unknown means the defaults.
    func testTabStopsComeFromTmux() {
        var extra = plain
        extra.tabStops = [4, 12, 29, 60]
        let s = TmuxSnapshot.build(state: onAlt, extra: extra, history: [], screen: [], savedNormal: [], focusReporting: false)
        XCTAssertEqual(s.normal.tabStops, [4, 12])
        XCTAssertEqual(s.alt?.tabStops, [4, 12], "stops past the pane's width are dropped")
        let d = TmuxSnapshot.build(state: primary, extra: plain, history: [], screen: [], savedNormal: nil, focusReporting: false)
        XCTAssertEqual(d.normal.tabStops, [0, 8, 16])
    }

    /// tmux stores a TAB as one cell covering the gap and `capture-pane` prints it as `\t` (measured,
    /// tmux 3.7c: `a\tb` with stops 4,12). The gap is ERASED cells, as a tab leaves them in xterm.js.
    func testATabExpandsToTheNextStop() {
        var st = TmuxSnapshot.CaptureState()
        let c = TmuxSnapshot.cells("a\tb\tc\tz", state: &st, cols: 20, tabStops: [4, 12])
        XCTAssertEqual(c.map { $0.text.isEmpty ? "_" : $0.text }.joined(), "a___b_______c______z", "past the last stop: the last column")
        XCTAssertTrue(c.filter { $0.text.isEmpty }.allSatisfy { $0.attrs == TermAttrs() })
        XCTAssertEqual(TmuxSnapshot.cells("ab\tc").map { $0.text.isEmpty ? "_" : $0.text }.joined(), "ab______c", "default stops every 8")
        let state = TmuxPaneState.parse("%3 0 0 10 2 0 1 0 0 0 0 0 2 2000 0 1 0 0 0")!
        var extra = plain
        extra.tabStops = [4]
        let s = TmuxSnapshot.build(state: state, extra: extra, history: ["abcdefghijk\tx"], screen: ["\tA"], savedNormal: nil, focusReporting: false)
        XCTAssertEqual(s.normal.lines.map(\.wrapped), [false, true, false, false])
        XCTAssertEqual(s.normal.lines[1].cells.map { $0.text.isEmpty ? "_" : $0.text }.joined(), "k___x", "a tab on a continuation counts from the row's start")
        XCTAssertEqual(s.normal.lines[2].cells.map { $0.text.isEmpty ? "_" : $0.text }.joined(), "____A")
    }

    /// DEC special graphics: tmux keeps the ASCII byte and brackets the run with SO/SI in the capture
    /// (measured: `^Nlqqqk^O`), so the parser maps it as SwiftTerm and xterm.js do (`lqk` → `┌─┐`).
    func testTheACSRunBecomesLineDrawing() {
        for b in UInt8(ascii: "`")...UInt8(ascii: "~") {
            let t = Terminal(cols: 4, rows: 1)
            _ = t.feed([0x1b, 0x28, 0x30, b])
            XCTAssertEqual(TmuxSnapshot.decGraphics[b], t.snapshot().screen[0].cells.first?.text, "DEC graphics \(UnicodeScalar(b))")
        }
        XCTAssertEqual(TmuxSnapshot.cells("\u{0e}lqqqk\u{0f} ascii q").map(\.text).joined(), "┌───┐ ascii q")
        XCTAssertEqual(TmuxSnapshot.cells("\u{0e}x`a~\u{0f}").map(\.text).joined(), "│◆▒·")
        XCTAssertEqual(TmuxSnapshot.cells("\u{0e}AZ中\u{0f}").map(\.text).joined(), "AZ中", "outside the table: unchanged")
        var st = TmuxSnapshot.CaptureState()
        _ = TmuxSnapshot.cells("\u{0e}q", state: &st)
        XCTAssertEqual(TmuxSnapshot.cells("q\u{0f}q", state: &st).map(\.text).joined(), "─q", "SO carries to the next line until SI")
    }

    func testThePrimaryScreenIsHistoryThenScreen() {
        let s = TmuxSnapshot.build(state: primary, extra: .init(insert: false, keypad: true, wraparound: true),
                                   history: ["h1", "h2"], screen: ["one", "two", "three"], savedNormal: nil, focusReporting: true)
        XCTAssertEqual([s.cols, s.rows], [20, 3])
        XCTAssertNil(s.alt)
        XCTAssertEqual(s.normal.lines.map(text), ["h1", "h2", "one", "two", "three"])
        XCTAssertEqual([s.normal.scrollTop, s.normal.scrollBottom], [0, 2])
        XCTAssertEqual([s.cursor.x, s.cursor.y], [4, 2])
        XCTAssertTrue(s.modes.applicationCursor); XCTAssertTrue(s.modes.applicationKeypad)
        XCTAssertEqual(s.modes.mouse, .buttonEvent); XCTAssertEqual(s.modes.mouseEncoding, .sgr)
        XCTAssertTrue(s.modes.bracketedPaste)
        XCTAssertTrue(s.modes.focusReporting, "?1004 comes from the stream tracker, via the caller")
    }

    /// No history (`history_size` 0) means the history capture is IGNORED — tmux answers `-E -1` on an
    /// empty history with the screen's first row.
    func testAnEmptyHistoryIgnoresTheHistoryCapture() {
        let none = TmuxPaneState.parse("%3 0 0 20 3 0 1 0 0 0 0 0 0 2000 0 2 0 0 0")!
        let s = TmuxSnapshot.build(state: none, extra: plain, history: ["one"], screen: ["one", "", ""], savedNormal: nil, focusReporting: false)
        XCTAssertEqual(s.normal.lines.map(text), ["one", "", ""])
    }

    func testTheAltScreenKeepsTheSavedNormalScreenBelowIt() {
        let s = TmuxSnapshot.build(state: onAlt, extra: .init(insert: false, keypad: false, wraparound: true),
                                   history: ["ignored"], screen: ["vim"], savedNormal: ["$ vim"], focusReporting: false)
        XCTAssertEqual(s.normal.lines.map(text), ["$ vim", "", ""])
        XCTAssertEqual(s.alt?.lines.map(text), ["vim", "", ""])
        XCTAssertEqual([s.alt?.scrollTop, s.alt?.scrollBottom], [1, 2])
        XCTAssertTrue(s.modes.origin); XCTAssertTrue(s.modes.synchronizedOutput)
        XCTAssertFalse(s.cursor.visible)
    }

    /// tmux keeps the NORMAL screen's history while the alt screen is up (`history_size` still counts
    /// it and the `-J` capture returns it — measured), and so do SwiftTerm and xterm.js: a client that
    /// attaches under vim keeps the scrollback it would have had.
    func testTheAltScreenKeepsTheNormalHistory() {
        let altWithHistory = TmuxPaneState.parse("%3 0 0 20 3 1 1 0 0 0 0 0 2 2000 0 2 0 0 0")!
        let s = TmuxSnapshot.build(state: altWithHistory, extra: plain, history: ["h1", "h2"], screen: ["vim"],
                                   savedNormal: ["$ vim"], focusReporting: false)
        XCTAssertEqual(s.normal.lines.map(text), ["h1", "h2", "$ vim", "", ""])
        XCTAssertEqual(s.alt?.lines.map(text), ["vim", "", ""])
    }

    /// `-J` joins a wrapped line into one; the model's lines are ROWS, so it is split back at `cols`
    /// with the continuations marked wrapped — the reflow at the current width that xterm.js does. A
    /// wide glyph that does not fit in the last column starts the next row.
    func testAJoinedHistoryLineIsSplitIntoWrappedRows() {
        let state = TmuxPaneState.parse("%3 0 0 5 2 0 1 0 0 0 0 0 4 2000 0 1 0 0 0")!
        let s = TmuxSnapshot.build(state: state, extra: plain, history: ["abcdefghijkl", "abcd中x", ""], screen: ["s"],
                                   savedNormal: nil, focusReporting: false)
        XCTAssertEqual(s.normal.lines.map(text), ["abcde", "fghij", "kl", "abcd", "中x", "", "s", ""])
        XCTAssertEqual(s.normal.lines.map(\.wrapped), [false, true, true, false, true, false, false, false])
    }

    /// A screen line never wraps into the next (tmux does not report the flag), and one longer than the
    /// pane (never seen; defensive) is cut rather than allowed to move every row below it.
    func testScreenLinesAreCutNotSplit() {
        let state = TmuxPaneState.parse("%3 0 0 5 2 0 1 0 0 0 0 0 0 2000 0 1 0 0 0")!
        let s = TmuxSnapshot.build(state: state, extra: plain, history: [], screen: ["abcdefg", "中中中"], savedNormal: nil, focusReporting: false)
        XCTAssertEqual(s.normal.lines.map(text), ["abcde", "中中"])
        XCTAssertTrue(s.normal.lines.allSatisfy { !$0.wrapped })
    }

    /// The screen and `-a` captures use `-N` (keep trailing spaces), because without it tmux trims the
    /// spaces of an erase with a BACKGROUND (`CSI 44m CSI K`) and the coloured tail is lost (measured).
    /// The parser then drops trailing DEFAULT blanks, so a blank row is `TermSnapshot.blank`'s.
    func testTrailingDefaultBlanksAreTrimmedAndColouredOnesKept() {
        XCTAssertEqual(TmuxSnapshot.row("ab   ").map(\.text), ["a", "b"])
        XCTAssertEqual(TmuxSnapshot.row("      "), [])
        let bar = TmuxSnapshot.row("\u{1b}[44mx  \u{1b}[49m  ")
        XCTAssertEqual(bar.map(\.text), ["x", " ", " "])
        XCTAssertEqual(bar.last?.attrs.bg, .palette(4))
        let s = TmuxSnapshot.build(state: primary, extra: plain, history: [], screen: ["   ", "", "x"], savedNormal: nil, focusReporting: false)
        XCTAssertEqual(Array(s.normal.lines.prefix(2)), [TermLine(cells: []), TermLine(cells: [])])
    }

    /// tmux reports PENDING WRAP as `cursor_x == pane_width` (measured: 20 glyphs in a 20-column pane
    /// leave `cursor_x` 20), which is exactly the model's pending-wrap state; it must not be clamped.
    func testPendingWrapIsKept() {
        let state = TmuxPaneState.parse("%3 20 0 20 3 0 1 0 0 0 0 0 0 2000 0 2 0 0 0")!
        let s = TmuxSnapshot.build(state: state, extra: plain, history: [], screen: [String(repeating: "Z", count: 20)],
                                   savedNormal: nil, focusReporting: false)
        XCTAssertEqual(s.cursor.x, 20)
        let t = Terminal(cols: 20, rows: 3)
        _ = t.feed(TermSnapshotEmitter.emit(s))
        _ = t.feed(Array("!".utf8))
        XCTAssertEqual(t.snapshot().screen[1].cells.first?.text, "!", "the next glyph wraps")
        let wild = TmuxPaneState.parse("%3 99 99 20 3 0 1 0 0 0 0 0 0 2000 7 1 0 0 0")!
        let w = TmuxSnapshot.build(state: wild, extra: plain, history: [], screen: [], savedNormal: nil, focusReporting: false)
        XCTAssertEqual([w.cursor.x, w.cursor.y, w.normal.scrollTop, w.normal.scrollBottom], [20, 2, 2, 2], "out of range clamps")
    }

    /// An OFFER's screen captures no history (`TerminalManager.screenPreview`): the batch keeps its shape — every
    /// reply where `build` reads it — with the history capture shrunk to one line.
    func testAScreenOnlyBatchKeepsItsShapeAndCapturesALine() {
        let full = TmuxSnapshot.commands(session: "$7"), screen = TmuxSnapshot.commands(session: "$7", history: 0)
        XCTAssertEqual(screen.count, full.count)
        XCTAssertEqual(screen[2], "capture-pane -p -e -J -S -1 -E -1 -t $7")
        XCTAssertEqual(full[2], "capture-pane -p -e -J -S -\(TmuxSnapshot.historyLines) -E -1 -t $7")
        XCTAssertEqual(Array(screen.enumerated().filter { $0.offset != 2 }.map(\.element)),
                       Array(full.enumerated().filter { $0.offset != 2 }.map(\.element)))
    }

    func testTheCommandsAreOneBatchAgainstTheSession() {
        let c = TmuxSnapshot.commands(session: "$7")
        XCTAssertEqual(c.count, 9)
        XCTAssertTrue(c.prefix(6).allSatisfy { $0.contains("-t $7") }, "the last three ask the SERVER (version, width options)")
        XCTAssertTrue(c[0].contains(TmuxPaneState.format) && c[1].contains(TmuxSnapshot.extraFormat))
        XCTAssertTrue(c[2].contains("-J") && c[2].contains("-S -\(TmuxSnapshot.historyLines)") && c[2].contains("-E -1"))
        XCTAssertTrue(c[3].hasPrefix("capture-pane -p -e -N ") && !c[3].contains("-J"))
        XCTAssertTrue(c[4].contains("capture-pane -a") && c[4].contains("-N"))
        XCTAssertEqual(c[5], TmuxSnapshot.paneListCommand(session: "$7"))
        XCTAssertEqual(TmuxSnapshot.livePanes(["%1", "%23", "", "%", "%x", "junk"]), ["%1", "%23"])
    }

    /// Built → emitted → SwiftTerm: the rows read back as tmux captured them.
    func testTheSnapshotEmitsWhatTmuxShowed() {
        let s = TmuxSnapshot.build(state: primary, extra: .init(insert: false, keypad: false, wraparound: true),
                                   history: ["\u{1b}[31mold\u{1b}[0m"], screen: ["a\u{1b}[1mb", "中", ""], savedNormal: nil, focusReporting: false)
        let t = Terminal(cols: 20, rows: 3)
        _ = t.feed(TermSnapshotEmitter.emit(s))
        let back = t.snapshot()
        XCTAssertEqual(back.normal.lines.map { $0.cells.map { $0.text.isEmpty ? " " : $0.text }.joined().trimmingCharacters(in: .whitespaces) },
                       ["old", "ab", "中", ""])
        XCTAssertEqual([back.cursor.x, back.cursor.y], [4, 2])
    }
}
