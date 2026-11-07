import XCTest
import SwiftTerm

/// One test per accessor in rdev_snapshot_access.swift. They exist so a SwiftTerm upgrade that renames,
/// moves or re-privatises what the accessors read fails HERE, loudly, instead of the serializer quietly
/// reading defaults (host/RdevCore/Sources/RdevCore/SwiftTermSnapshot.swift).
final class SwiftTermAccessorTests: XCTestCase {
    private final class D: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
    private let delegate = D()
    private func term(cols: Int = 20, rows: Int = 5, scrollback: Int = 100) -> Terminal {
        let t = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        t.silentLog = true
        return t
    }
    private func feed(_ t: Terminal, _ s: String) { t.feed(text: s) }

    func testBuffersAndLines() {
        let t = term()
        feed(t, (1...9).map { "L\($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(t.rdevNormalBuffer === t.buffer)
        XCTAssertEqual(t.rdevNormalBuffer.rdevYBase, 4, "9 lines on 5 rows: 4 scrolled into history")
        XCTAssertGreaterThanOrEqual(t.rdevNormalBuffer.rdevLineCount, 9)
        XCTAssertEqual(t.getCharacter(for: t.rdevNormalBuffer.rdevLine(0)[1]), "1")
        feed(t, "\u{1b}[?1049h")
        XCTAssertTrue(t.rdevAltBuffer === t.buffer)
    }

    func testWrappedFlag() {
        let t = term()
        feed(t, String(repeating: "x", count: 25))
        XCTAssertFalse(t.rdevNormalBuffer.rdevLine(0).rdevIsWrapped)
        XCTAssertTrue(t.rdevNormalBuffer.rdevLine(1).rdevIsWrapped)
    }

    func testNullCell() {
        let t = term()
        feed(t, "a\u{1b}[3Cb")
        let l = t.rdevNormalBuffer.rdevLine(0)
        XCTAssertFalse(l[0].rdevIsNull)
        XCTAssertTrue(l[1].rdevIsNull, "a cell the cursor skipped was never written")
    }

    func testModes() {
        let t = term()
        XCTAssertFalse(t.rdevCursorHidden); feed(t, "\u{1b}[?25l"); XCTAssertTrue(t.rdevCursorHidden)
        XCTAssertFalse(t.rdevOriginMode); feed(t, "\u{1b}[?6h"); XCTAssertTrue(t.rdevOriginMode)
        XCTAssertTrue(t.rdevWraparound); feed(t, "\u{1b}[?7l"); XCTAssertFalse(t.rdevWraparound)
        // SwiftTerm honours ?45h only while DECAWM is on (Terminal.swift, "reverse wraparound can only be
        // enabled if Auto-wrap is enabled"), and the line above turned it off.
        feed(t, "\u{1b}[?7h")
        XCTAssertFalse(t.rdevReverseWraparound); feed(t, "\u{1b}[?45h"); XCTAssertTrue(t.rdevReverseWraparound)
        XCTAssertFalse(t.rdevInsertMode); feed(t, "\u{1b}[4h"); XCTAssertTrue(t.rdevInsertMode)
        XCTAssertFalse(t.rdevApplicationKeypad); feed(t, "\u{1b}="); XCTAssertTrue(t.rdevApplicationKeypad)
        XCTAssertFalse(t.rdevSendFocus); feed(t, "\u{1b}[?1004h"); XCTAssertTrue(t.rdevSendFocus)
        XCTAssertFalse(t.rdevSynchronizedOutput); feed(t, "\u{1b}[?2026h"); XCTAssertTrue(t.rdevSynchronizedOutput)
    }

    func testPen() {
        let t = term()
        feed(t, "\u{1b}[1;31m")
        XCTAssertTrue(t.rdevPen.style.contains(.bold))
        XCTAssertEqual(t.rdevPen.fg, .ansi256(code: 1))
    }

    func testMouseEncoding() {
        let t = term()
        XCTAssertEqual(t.rdevMouseEncoding, .x10)
        feed(t, "\u{1b}[?1006h"); XCTAssertEqual(t.rdevMouseEncoding, .sgr)
        feed(t, "\u{1b}[?1016h"); XCTAssertEqual(t.rdevMouseEncoding, .sgrPixel)
        feed(t, "\u{1b}[?1005h"); XCTAssertEqual(t.rdevMouseEncoding, .utf8)
        feed(t, "\u{1b}[?1015h"); XCTAssertEqual(t.rdevMouseEncoding, .urxvt)
        feed(t, "\u{1b}[?1015l"); XCTAssertEqual(t.rdevMouseEncoding, .x10)   // any reset goes back to X10
    }

    func testCharsets() {
        let t = term()
        XCTAssertEqual(t.rdevCharsetDesignations, [nil, nil, nil, nil])
        XCTAssertEqual(t.rdevGLevel, 0)
        feed(t, "\u{1b})0\u{0e}")
        XCTAssertEqual(t.rdevCharsetDesignations[1], UInt8(ascii: "0"))
        XCTAssertEqual(t.rdevGLevel, 1)
        feed(t, "\u{1b}7")                                     // DECSC while GL is DEC graphics
        XCTAssertEqual(t.rdevDesignation(of: t.buffer.savedCharset), UInt8(ascii: "0"))
    }

    /// `ESC ( B` designates US ASCII, which SwiftTerm stores as an EMPTY table rather than the nil a
    /// fresh G0 holds. Both mean US ASCII, so both must read back nil — or a round trip through the
    /// emitter (which always writes `ESC ( B`) reports a designation the original never had.
    func testUSASCIIDesignationIsNil() {
        let t = term()
        feed(t, "\u{1b})0\u{1b}(B\u{1b})B")
        XCTAssertEqual(t.rdevCharsetDesignations, [nil, nil, nil, nil])
        XCTAssertNil(t.rdevDesignation(of: [:]))
        XCTAssertNil(t.rdevDesignation(of: nil))
        feed(t, "\u{1b}7")
        XCTAssertNil(t.rdevDesignation(of: t.buffer.savedCharset))
    }

    func testTabStops() {
        let t = term()
        XCTAssertEqual(t.rdevNormalBuffer.rdevTabStops.enumerated().filter(\.element).map(\.offset), [0, 8, 16])
        feed(t, "\u{1b}[3g\u{1b}[1;6H\u{1b}H")
        XCTAssertEqual(t.rdevNormalBuffer.rdevTabStops.enumerated().filter(\.element).map(\.offset), [5])
    }

    // --- The one BEHAVIOUR change in rdev-snapshot-access.patch ------------------------------------
    // xterm.js 6 fills every inserted/deleted cell gap with its null cell — code 0 (ERASED, not a
    // written space) carrying the erase attribute (the pen's background). SwiftTerm's ICH/DCH already
    // did; its column operations (DECIC, DECDC, DECBI/DECFI) filled with `getNullCell`, a SPACE
    // (scalar 32), and DECIC/DECBI ignored the background too. The patch makes them match.

    private func erasedWithBlueBG(_ c: CharData, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(c.rdevIsNull, "\(what): the gap must be ERASED (code 0), not a written space", file: file, line: line)
        XCTAssertEqual(c.attribute.bg, .ansi256(code: 4), "\(what): the gap carries the erase background", file: file, line: line)
    }

    func testICHAndDCHLeaveErasedCellsWithTheEraseBackground() {
        let t = term()
        feed(t, "abcdef\u{1b}[44m\u{1b}[1;2H\u{1b}[2@")                  // ICH 2 at column 1
        erasedWithBlueBG(t.buffer.rdevLine(0)[1], "ICH"); erasedWithBlueBG(t.buffer.rdevLine(0)[2], "ICH")
        XCTAssertEqual(t.getCharacter(for: t.buffer.rdevLine(0)[3]), "b")
        let u = term()
        feed(u, "abcdef\u{1b}[44m\u{1b}[1;2H\u{1b}[2P")                  // DCH 2 at column 1
        erasedWithBlueBG(u.buffer.rdevLine(0)[19], "DCH"); erasedWithBlueBG(u.buffer.rdevLine(0)[18], "DCH")
        XCTAssertEqual(u.getCharacter(for: u.buffer.rdevLine(0)[1]), "d")
    }

    func testColumnInsertAndDeleteLeaveErasedCellsWithTheEraseBackground() {
        let t = term()
        feed(t, "abcdef\u{1b}[44m\u{1b}[1;2H\u{1b}[2'}")                 // DECIC 2 at column 1
        erasedWithBlueBG(t.buffer.rdevLine(0)[1], "DECIC"); erasedWithBlueBG(t.buffer.rdevLine(0)[2], "DECIC")
        XCTAssertEqual(t.getCharacter(for: t.buffer.rdevLine(0)[3]), "b")
        let u = term()
        feed(u, "abcdef\u{1b}[44m\u{1b}[1;2H\u{1b}[2'~")                 // DECDC 2 at column 1
        erasedWithBlueBG(u.buffer.rdevLine(0)[19], "DECDC"); erasedWithBlueBG(u.buffer.rdevLine(0)[18], "DECDC")
        XCTAssertEqual(u.getCharacter(for: u.buffer.rdevLine(0)[1]), "d")
        let v = term()
        feed(v, "abcdef\u{1b}[44m\u{1b}[1;1H\u{1b}6")                     // DECBI at the left margin
        erasedWithBlueBG(v.buffer.rdevLine(0)[0], "DECBI")
        XCTAssertEqual(v.getCharacter(for: v.buffer.rdevLine(0)[1]), "a")
        let w = term()
        feed(w, "abcdef\u{1b}[44m\u{1b}[1;20H\u{1b}9")                    // DECFI at the right margin
        erasedWithBlueBG(w.buffer.rdevLine(0)[19], "DECFI")
        XCTAssertEqual(w.getCharacter(for: w.buffer.rdevLine(0)[0]), "b")
    }

    // --- Tab stops on a width change, as xterm.js 6 sets them ----------------------------------------
    // SwiftTerm builds its buffers at 80 columns and RESIZES them to the requested width, appending
    // columns with no stops, so a 100-column terminal had none past 72; and a real resize trimmed the
    // stops past the new width and restarted the defaults from the OLD one. xterm.js keeps its stops
    // as a map that a shrink never trims, and after every resize restarts the defaults at the last
    // stop below the NEW width (BufferSet.resize → setupTabStops(newCols)). Values measured on
    // xterm.js 6.0.0.

    private func stops(_ b: Buffer) -> [Int] { b.rdevTabStops.enumerated().filter(\.element).map(\.offset) }

    func testAWideTerminalHasDefaultStopsAcrossItsWholeWidth() {
        let t = term(cols: 100)
        XCTAssertEqual(stops(t.rdevNormalBuffer), Array(stride(from: 0, to: 100, by: 8)))
        XCTAssertEqual(stops(t.rdevAltBuffer), Array(stride(from: 0, to: 100, by: 8)))
    }

    func testResizeSetsStopsAsXtermJsDoesIncludingShrinkThenGrow() {
        let t = term(cols: 80)
        feed(t, "\u{1b}[3g\u{1b}[1;6H\u{1b}H\u{1b}[1;61H\u{1b}H")           // only 5 and 60
        t.resize(cols: 40, rows: 5)
        XCTAssertEqual(stops(t.rdevNormalBuffer), [5, 13, 21, 29, 37, 60], "a shrink keeps 60 and restarts at 5")
        t.resize(cols: 100, rows: 5)
        XCTAssertEqual(stops(t.rdevNormalBuffer), [5, 13, 21, 29, 37, 60, 68, 76, 84, 92], "a grow restarts at 60")
        XCTAssertEqual(stops(t.rdevAltBuffer), [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96])
        feed(t, "\u{1b}c")                                                     // RIS: both buffers fresh
        XCTAssertEqual(stops(t.rdevNormalBuffer), Array(stride(from: 0, to: 100, by: 8)))
        XCTAssertEqual(stops(t.rdevAltBuffer), Array(stride(from: 0, to: 100, by: 8)))
    }

    // --- The alternate screen is filled with the erase attribute, as in xterm.js --------------------
    // xterm.js's ?47h, ?1047h and ?1049h all call activateAltBuffer(eraseAttr): the fresh alt screen's
    // cells are erased with the pen's background. SwiftTerm passed nil (default background).

    func testEnteringTheAltScreenFillsItWithTheEraseBackground() {
        for mode in [47, 1047, 1049] {
            let t = term()
            feed(t, "\u{1b}[44m\u{1b}[?\(mode)h")
            XCTAssertTrue(t.rdevAltBuffer === t.buffer, "?\(mode)")
            erasedWithBlueBG(t.buffer.rdevLine(0)[0], "?\(mode)h row 0")
            erasedWithBlueBG(t.buffer.rdevLine(4)[19], "?\(mode)h last cell")
        }
    }

    // --- Leaving the alternate screen, and cursor visibility, as in xterm.js ------------------------
    // xterm.js's ?47l, ?1047l and ?1049l all CLEAR the alt buffer (BufferSet.activateNormalBuffer),
    // and the clear restores its default tab stops (Buffer.clear → setupTabStops); no alt-screen
    // switch touches cursor visibility. SwiftTerm kept ?47's contents, kept the alt buffer's stops and
    // showed the cursor on every switch.

    func testLeavingTheAltScreenClearsItAndItsTabStops() {
        for mode in [47, 1047, 1049] {
            let t = term()
            feed(t, "\u{1b}[?\(mode)h\u{1b}[3g\u{1b}[1;6H\u{1b}Hleft behind\u{1b}[?\(mode)l\u{1b}[?\(mode)h")
            XCTAssertTrue(t.rdevAltBuffer === t.buffer, "?\(mode)")
            XCTAssertTrue(t.buffer.rdevLine(0)[5].rdevIsNull, "?\(mode)l cleared the alt screen")
            XCTAssertEqual(stops(t.rdevAltBuffer), [0, 8, 16], "?\(mode)l restored the alt buffer's default stops")
        }
        let r = term()                                                         // RIS while on the alt screen
        feed(r, "\u{1b}[?47hleft behind\u{1b}c\u{1b}[?47h")
        XCTAssertTrue(r.buffer.rdevLine(0)[0].rdevIsNull, "RIS gives a fresh alt buffer, as xterm.js's reset does")
    }

    func testAltScreenSwitchesLeaveCursorVisibilityAlone() {
        for mode in [47, 1047, 1049] {
            let t = term()
            feed(t, "\u{1b}[?25l\u{1b}[?\(mode)h")
            XCTAssertTrue(t.rdevCursorHidden, "?\(mode)h")
            feed(t, "\u{1b}[?\(mode)l")
            XCTAssertTrue(t.rdevCursorHidden, "?\(mode)l")
        }
    }

    // --- A recycled scrollback line, as in xterm.js ----------------------------------------------
    // Once scrollback is full, SwiftTerm RECYCLES the oldest line as the new bottom line and erased
    // its cells but KEPT its isWrapped (and renderMode): every line that was a continuation when it
    // was evicted planted a stale wrap flag on a fresh bottom line, so a snapshot joined two unrelated
    // lines. xterm.js copies its blank line (erase attribute, not wrapped) into the recycled one
    // (BufferService.scroll → recycle().copyFrom(newLine)).

    func testARecycledScrollbackLineIsAFreshUnwrappedLine() {
        let t = term(cols: 20, rows: 5, scrollback: 10)
        feed(t, String(repeating: "x", count: 25))                            // row 1 continues row 0
        XCTAssertTrue(t.rdevNormalBuffer.rdevLine(1).rdevIsWrapped)
        feed(t, "\u{1b}[44m" + (1...40).map { "\r\nl\($0)" }.joined())       // evicts both, many times over
        let b = t.rdevNormalBuffer
        let wrapped = (0..<b.rdevLineCount).filter { b.rdevLine($0).rdevIsWrapped }
        XCTAssertEqual(wrapped, [], "no line was ever written as a continuation after the first two")
        let last = b.rdevLine(b.rdevLineCount - 1)                              // the recycled bottom line
        XCTAssertEqual(t.getCharacter(for: last[0]), "l")
        erasedWithBlueBG(last[19], "the recycled line's tail is erased with the erase attribute")
    }

    // --- Grapheme widths, as xterm.js (rdev's provider) and tmux count them ----------------------
    // The snapshot places each cell at the column SwiftTerm put it; the client's xterm.js must count
    // the same columns (web/src/client/term-unicode.ts), and so must tmux for a tmux tab. MEASURED
    // 2026-09-27 (docs/terminal.md, "Glyph widths"): xterm.js with the graphemes addon and tmux 3.7c
    // give a lone regional indicator ONE column, widen ANY base to two under VS16 or a skin-tone
    // modifier, and never narrow under VS15. SwiftTerm gave a lone RI two, widened under VS16 only a
    // base on its own list, kept a modifier's base narrow and narrowed under VS15.

    /// Columns `s` takes after an "a" (the prefix keeps a leading joiner off column 0).
    private func columns(_ s: String) -> Int {
        let t = term(cols: 40)
        feed(t, "a" + s)
        return t.buffer.x - 1
    }

    func testAColumnWidthIsReadableForTheSharedTable() {
        XCTAssertEqual(Terminal.rdevColumnWidth(UnicodeScalar(0x61)!), 1)
        XCTAssertEqual(Terminal.rdevColumnWidth(UnicodeScalar(0x4E2D)!), 2)
        XCTAssertEqual(Terminal.rdevColumnWidth(UnicodeScalar(0x1FAE0)!), 2, "🫠, Unicode 14")
        XCTAssertEqual(Terminal.rdevColumnWidth(UnicodeScalar(0x301)!), 0)
        XCTAssertEqual(Terminal.rdevColumnWidth(UnicodeScalar(0x1F1FA)!), 1, "a lone regional indicator")
    }

    func testRegionalIndicatorsTakeOneColumnAloneAndTwoAsAPair() {
        XCTAssertEqual(columns("\u{1F1FA}"), 1)
        XCTAssertEqual(columns("\u{1F1FA}\u{1F1F8}"), 2)
        XCTAssertEqual(columns("\u{1F1FA}\u{1F1F8}\u{1F1EC}"), 3)
        XCTAssertEqual(columns("\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}"), 4)
        let t = term(cols: 40)
        feed(t, "\u{1F1FA}\u{1F1F8}x")
        let l = t.rdevNormalBuffer.rdevLine(0)
        XCTAssertEqual([Int(l[0].width), Int(l[1].width)], [2, 0], "the flag is ONE wide cell")
        XCTAssertEqual(String(t.getCharacter(for: l[0]).unicodeScalars.map { Character($0) }), "\u{1F1FA}\u{1F1F8}")
        XCTAssertEqual(t.getCharacter(for: l[2]), "x")
    }

    func testVS16WidensAnyBaseAndVS15NarrowsNone() {
        XCTAssertEqual(columns("\u{2764}\u{FE0F}"), 2)
        XCTAssertEqual(columns("x\u{FE0F}"), 2, "not an emoji base, and still two (xterm.js and tmux)")
        XCTAssertEqual(columns("\u{4E2D}\u{FE0F}"), 2)
        XCTAssertEqual(columns("\u{231A}\u{FE0E}"), 2, "VS15 does not narrow a wide glyph")
        XCTAssertEqual(columns("\u{2764}\u{FE0E}"), 1)
        let t = term(cols: 40)
        feed(t, "x\u{FE0F}")
        XCTAssertEqual(t.getCharacter(for: t.rdevNormalBuffer.rdevLine(0)[0]).unicodeScalars.map(\.value), [0x78, 0xFE0F],
                       "the selector is KEPT in the cell, as xterm.js keeps it")
    }

    func testASkinToneModifierWidensItsBase() {
        XCTAssertEqual(columns("\u{261D}\u{1F3FD}"), 2, "☝🏽: a text-default base")
        XCTAssertEqual(columns("\u{1F44D}\u{1F3FD}"), 2)
        XCTAssertEqual(columns("\u{1F3FD}"), 1, "after the prefix: \"a\" + modifier is one wide cell")
        XCTAssertEqual(columns("\u{1F9D1}\u{1F3FD}\u{200D}\u{1F4BB}"), 2)
    }

    func testAZWJSequenceKeepsItsBasesWidth() {
        XCTAssertEqual(columns("\u{1F469}\u{200D}\u{1F4BB}"), 2)
        XCTAssertEqual(columns("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), 2)
        XCTAssertEqual(columns("\u{2764}\u{200D}\u{1F525}"), 1, "no VS16: the base's one column (tmux agrees)")
        XCTAssertEqual(columns("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"), 2)
    }

    /// A widening at the right margin moves the glyph to the next row as xterm.js does
    /// (InputHandler.print: the joined cell is copied to column 0 of the next row, which is marked
    /// wrapped, and the old cell is erased with the pen). SwiftTerm left it one column wide in the last
    /// column, so the snapshot and the client disagreed on everything after it.
    func testAWideningAtTheMarginMovesTheGlyphToTheNextRow() {
        for (label, base, joiner) in [("VS16", "\u{2764}", "\u{FE0F}"), ("modifier", "\u{261D}", "\u{1F3FD}"), ("flag", "\u{1F1FA}", "\u{1F1F8}")] {
            let tail = base + joiner
            let t = term(cols: 20, rows: 5)
            // (No sequence between the base and its joiner: that would end the join — the next test.)
            feed(t, String(repeating: "a", count: 19) + "\u{1b}[44m" + base + joiner + "\u{1b}[0mz")
            let b = t.rdevNormalBuffer
            XCTAssertTrue(b.rdevLine(0)[19].rdevIsNull, "\(label): the margin cell is erased")
            XCTAssertEqual(b.rdevLine(0)[19].attribute.bg, .ansi256(code: 4), "\(label): with the pen")
            XCTAssertTrue(b.rdevLine(1).rdevIsWrapped, label)
            XCTAssertEqual(Int(b.rdevLine(1)[0].width), 2, label)
            XCTAssertEqual(b.rdevLine(1)[0].attribute.bg, .ansi256(code: 4), "\(label): the glyph keeps its attributes")
            XCTAssertEqual(t.getCharacter(for: b.rdevLine(1)[0]).unicodeScalars.map(\.value), tail.unicodeScalars.map(\.value), label)
            XCTAssertEqual(t.getCharacter(for: b.rdevLine(1)[2]), "z", label)
            XCTAssertEqual([t.buffer.x, t.buffer.y], [3, 1], label)
        }
    }

    /// Nothing joins a glyph across a control or an escape sequence: xterm.js resets its join state on
    /// every one (EscapeSequenceParser: EXECUTE, CSI, ESC, OSC and DCS all zero precedingJoinState).
    /// A joiner that joins nothing stands alone — one column, two for a skin-tone modifier — where
    /// SwiftTerm joined it to the last cell it wrote and dropped one it could not join.
    func testNothingJoinsAcrossAControlOrASequence() {
        XCTAssertEqual(columns("\u{2764}\u{1b}[31m\u{FE0F}"), 2, "❤ then an orphan VS16: one column each")
        XCTAssertEqual(columns("\u{1F44D}\u{1b}[44m\u{1F3FD}"), 4, "👍 then a modifier that stands alone")
        XCTAssertEqual(columns("\u{1F1FA}\u{1b}[31m\u{1F1F8}"), 2)
        XCTAssertEqual(columns("\u{1F469}\u{1b}[31m\u{200D}\u{1F4BB}"), 5, "👩, an orphan ZWJ, 💻")
        XCTAssertEqual(columns("\u{7}\u{301}"), 1, "a mark after BEL")
        XCTAssertEqual(columns("\u{1b}]0;t\u{7}\u{301}"), 1, "a mark after an OSC")
        XCTAssertEqual(columns("\u{200B}"), 0, "ZWSP right after a glyph is dropped (xterm.js keeps it at no width)")
        let t = term(cols: 40)
        feed(t, "e\u{1b}[1m\u{301}")
        let l = t.rdevNormalBuffer.rdevLine(0)
        XCTAssertEqual(t.getCharacter(for: l[0]), "e")
        XCTAssertEqual(t.getCharacter(for: l[1]).unicodeScalars.map(\.value), [0x301], "the mark is its own cell")
        XCTAssertEqual(Int(l[1].width), 1)
        feed(t, "\r\n\u{1b}[m\u{301}\u{301}x")
        XCTAssertEqual(t.buffer.x, 2, "the second mark joins the first — nothing came between them")
    }

    /// Seventh fix: a DECRQSS whose data is not ASCII is answered "invalid" (`DCS 0 $ r ST`, as xterm.js
    /// answers it) instead of CRASHING the process on a force-unwrap. Any program in a `pty:` tab could
    /// do it: `printf '\eP$q\xc3\xa9\e\\'`, or a DECRQSS ended by U+009C — SwiftTerm reads bytes, so the
    /// C1 ST's lead byte 0xC2 lands in the data (found measuring 8-bit C1, docs/terminal.md).
    func testADECRQSSWithNonASCIIDataIsAnsweredNotACrash() {
        final class Rec: TerminalDelegate {
            var sent: [UInt8] = []
            func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
        }
        for q in ["\u{1b}P$q\u{e9}\u{1b}\\", "\u{1b}P$qm\u{9c}"] {
            let r = Rec()
            let t = Terminal(delegate: r, options: TerminalOptions(cols: 20, rows: 5, scrollback: 10))
            t.silentLog = true
            t.feed(byteArray: Array(q.utf8))
            XCTAssertEqual(String(decoding: r.sent, as: UTF8.self), "\u{1b}P0$r\u{1b}\\", q.debugDescription)
        }
    }

    /// Feeds `s` on another thread and fails — rather than blocking the suite — if it does not return
    /// within `seconds`. Returns what the terminal sent back, and the terminal.
    private func feedGuarded(_ s: String, seconds: Double = 5) -> (sent: [UInt8], term: Terminal)? {
        final class Rec: TerminalDelegate, @unchecked Sendable {
            var sent: [UInt8] = []
            func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
        }
        let r = Rec()
        let t = Terminal(delegate: r, options: TerminalOptions(cols: 20, rows: 5, scrollback: 10))
        t.silentLog = true
        let done = expectation(description: s.debugDescription)
        let bytes = Array(s.utf8)
        nonisolated(unsafe) let term = t
        Thread.detachNewThread { term.feed(byteArray: bytes); done.fulfill() }
        guard XCTWaiter().wait(for: [done], timeout: seconds) == .completed else {
            XCTFail("feeding \(s.debugDescription) did not return within \(seconds) s")
            return nil
        }
        return (r.sent, t)
    }

    /// Eighth fix: SwiftTerm's SIXEL decoder is never reached. The client's xterm.js loads no image
    /// addon, so the host has nothing to decode — and the decoder wrote past its pixel buffer on an
    /// image whose last run had no `$`/`-` (`\eP q#0~~\e\\` CRASHED the process), trapped on an
    /// overflowing colour number and allocated 24·n bytes for `!n`. The DCS is consumed and ignored,
    /// as xterm.js ignores it; the text after it prints where it would have.
    func testASixelImageIsIgnoredNotDecoded() {
        for q in ["\u{1b}P q#0~~\u{1b}\\", "\u{1b}P q#99999999999999999999~-\u{1b}\\",
                  "\u{1b}Pq!2000000000~-\u{1b}\\", "\u{1b}P0;1;0q\"1;1;4;4#0;2;100;0;0#0~~~~\u{1b}\\"] {
            guard let (sent, t) = feedGuarded("a\(q)b") else { continue }
            XCTAssertEqual(sent, [], q.debugDescription)
            XCTAssertEqual(t.buffer.x, 2, "a and b side by side: \(q.debugDescription)")
        }
    }

    /// Tenth fix: an OSC or DECRQSS body is capped at xterm.js 6's PAYLOAD_LIMIT (10 000 000). Past it
    /// the sequence is consumed and DROPPED — no title set, no answer — as xterm.js drops it, and
    /// SwiftTerm stops growing the body (a runaway OSC grew the host's memory without bound). Under the
    /// cap nothing changes.
    func testAnOSCOrDCSBodyPastThePayloadLimitIsDropped() {
        let big = String(repeating: "x", count: 10_000_001)
        guard let (sent, t) = feedGuarded("a\u{1b}]11;?\(big)\u{07}\u{1b}]11;?\u{07}b", seconds: 60) else { return }
        XCTAssertEqual(sent.count > 0, true, "the colour query after it is still answered")
        XCTAssertEqual(String(decoding: sent, as: UTF8.self).components(separatedBy: "]11;").count - 1, 1,
                       "the oversized one is not answered")
        XCTAssertEqual(t.buffer.x, 2)
        XCTAssertTrue(t.rdevOscBodyIsEmptyForTests, "nothing of the oversized body is held after it")
        guard let (dsent, _) = feedGuarded("\u{1b}P$q\(big)\u{1b}\\\u{1b}P$qm\u{1b}\\", seconds: 60) else { return }
        XCTAssertEqual(String(decoding: dsent, as: UTF8.self), "\u{1b}P1$r0m\u{1b}\\", "only the DECRQSS under the cap")
        guard let (tsent, title) = feedGuarded("\u{1b}]0;\(String(repeating: "t", count: 9_999_990))\u{07}", seconds: 60) else { return }
        XCTAssertEqual(tsent, [])
        XCTAssertEqual(title.buffer.x, 0)
    }

    /// Resident footprint of this process, bytes (for fix 11's memory bound).
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Eleventh fix: an UNTERMINATED CSI no longer grows the parser without bound. `ESC [` and then an
    /// endless run of `;` (or intermediates) appended an Int per separator forever — 50 MB of `;` held
    /// 923 MB (measured, review of 2026-09-27). Parameters are capped as xterm.js 6 caps them (32 + 32
    /// sub-parameters, flattened: 64) and intermediates at 4; past the cap separators and digits are
    /// ignored and the sequence still dispatches on its final.
    func testAnEndlessCSIDoesNotGrowMemory() {
        // 50 MB of `;` in 1 MB feeds (the input itself costs 1 MB), as a pty delivers it.
        let t = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5, scrollback: 10))
        t.silentLog = true
        let chunk = [UInt8](repeating: 0x3b, count: 1_000_000)
        t.feed(byteArray: Array("a\u{1b}[".utf8))
        let before = footprint()
        let done = expectation(description: "50 MB of ;")
        nonisolated(unsafe) let term = t
        Thread.detachNewThread { for _ in 0..<50 { term.feed(byteArray: chunk) }; done.fulfill() }
        guard XCTWaiter().wait(for: [done], timeout: 60) == .completed else { return XCTFail("did not return") }
        let grown = footprint() - before
        let held = t.rdevParserHeldForTests
        XCTAssertLessThanOrEqual(held.pars, 64)
        XCTAssertLessThanOrEqual(held.parsTxt, 64)
        XCTAssertLessThan(grown, 20_000_000, "50 MB of `;` must not grow the parser (was ~900 MB)")
        guard let (_, u) = feedGuarded("\u{1b}\(String(repeating: " ", count: 5_000_000))", seconds: 60) else { return }
        XCTAssertLessThanOrEqual(u.rdevParserHeldForTests.collect, 4)
        // Past the cap the final still dispatches, and what follows is parsed as usual.
        guard let (_, v) = feedGuarded("\u{1b}[31\(String(repeating: ";", count: 100))mX\u{1b}[1;2HY", seconds: 10) else { return }
        XCTAssertEqual(v.buffer.x, 2, "CUP 1;2 still dispatched after an over-long SGR")
    }

    /// Ninth fix: SwiftTerm's KITTY GRAPHICS (APC `G`) is never reached. A truncated zlib payload
    /// (`o=z`) looped FOREVER in its decompressor — on the host that holds the tab's serial lock and the
    /// terminal manager's lock, so every tab and all input froze. A query is not answered either,
    /// which is what xterm.js does with it.
    func testKittyGraphicsIsIgnoredNotDecoded() {
        for q in ["\u{1b}_Ga=T,f=32,s=1,v=1,o=z;AAAA\u{1b}\\", "\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\",
                  "\u{1b}_Ga=T,f=100;iVBORw0KGgo=\u{1b}\\"] {
            guard let (sent, t) = feedGuarded("a\(q)b") else { continue }
            XCTAssertEqual(sent, [], q.debugDescription)
            XCTAssertEqual(t.buffer.x, 2, q.debugDescription)
        }
    }

    // --- A program's interface below the cursor survives a shrink (fix 12) -------------------------
    // Upstream popped every line below the cursor on a shrink. An agent keeps its cursor in its input
    // box with its rule and footer under it (Claude Code, measured 2026-10-06: the cursor 4 rows from
    // the bottom of an 18-row pane) and repaints from where they were — so it erased conversation lines.

    /// Screen row `r` of the normal buffer as text.
    private func row(_ t: Terminal, _ r: Int) -> String {
        let b = t.rdevNormalBuffer
        return b.rdevLine(b.rdevYBase + r).translateToString(trimRight: true)
    }
    private let live = [String(repeating: "─", count: 30), "❯ ", String(repeating: "─", count: 30), "  footer", "  update", ""]
    /// The agent's layout: 40 lines of conversation, its live region under them, the cursor in its input.
    private func agent(rows: Int) -> Terminal {
        let t = term(cols: 30, rows: rows)
        feed(t, (0..<40).map { "talk \($0)" }.joined(separator: "\r\n") + "\r\n" + live.joined(separator: "\r\n") + "\u{1b}[4A\r\u{1b}[2C")
        return t
    }

    func testAProgramsInterfaceBelowTheCursorSurvivesAShrinkAndItsRepaintErasesNoConversation() {
        let t = agent(rows: 18)
        XCTAssertEqual([t.getCursorLocation().y, t.rdevNormalBuffer.rdevYBase], [13, 28], "the layout as measured")
        t.resize(cols: 30, rows: 10)
        XCTAssertEqual(t.getCursorLocation().y, 5, "the top scrolled into history; the cursor kept its line")
        XCTAssertEqual((4...9).map { row(t, $0) }, [live[0], "❯ ", live[2], "  footer", "  update", ""],
                       "every row below the cursor kept, the trailing blank one too")
        XCTAssertEqual(row(t, 3), "talk 39")
        // The agent's repaint on SIGWINCH: back down to where its output ended, erase its 6 lines upward, draw them.
        feed(t, "\u{1b}[4B\r\u{1b}[2K" + String(repeating: "\u{1b}[1A\u{1b}[2K", count: 5) + live.joined(separator: "\r\n") + "\u{1b}[4A\r\u{1b}[2C")
        XCTAssertEqual(row(t, 3), "talk 39", "the repaint erased no conversation line (upstream lost talk 36…39)")
        XCTAssertEqual(row(t, 5), "❯ ")
    }

    func testAShrinkStillDropsOnlyBlankRowsBelowAPromptAndScrollsAPromptAtTheBottom() {
        let fresh = term(cols: 30, rows: 18)
        feed(fresh, "banner\r\n$ ")                                           // a fresh shell: blank rows below
        fresh.resize(cols: 30, rows: 10)
        XCTAssertEqual([fresh.getCursorLocation().y, fresh.rdevNormalBuffer.rdevYBase], [1, 0], "the prompt did not move")
        XCTAssertEqual(row(fresh, 0), "banner")
        let busy = term(cols: 30, rows: 18)
        feed(busy, (0..<40).map { "out \($0)" }.joined(separator: "\r\n") + "\r\n$ ")   // the prompt on the last row
        busy.resize(cols: 30, rows: 10)
        XCTAssertEqual([busy.getCursorLocation().y, busy.rdevNormalBuffer.rdevYBase], [9, 31], "as upstream: bottom-aligned")
        XCTAssertEqual(row(busy, 8), "out 39")
    }

    func testTheCursorNeverLeavesTheScreenTheBottomGoesWhenItReachesTheTop() {
        let t = term(cols: 30, rows: 18)
        feed(t, "top\r\n$ " + "\u{1b}[18;1Hstatus" + "\u{1b}[2;3H")              // the cursor on row 1, a status on the last row
        t.resize(cols: 30, rows: 10)
        XCTAssertEqual(t.getCursorLocation().y, 0, "one row scrolled; the cursor reached the top row")
        XCTAssertEqual(row(t, 0), "$ ")
        XCTAssertEqual(t.rdevNormalBuffer.rdevYBase, 1)
    }

}
