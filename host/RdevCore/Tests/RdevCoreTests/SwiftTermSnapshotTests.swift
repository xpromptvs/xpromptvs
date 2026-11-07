import XCTest
@testable import RdevCore

/// SwiftTerm fed hand-built streams → the model says what the stream did. The last test is the
/// Swift-side round trip: snapshot → emit → a FRESH SwiftTerm → snapshot must be equal. (The
/// xterm.js side of the same property is web/test/term-snapshot-fidelity.test.ts.)
final class SwiftTermSnapshotTests: XCTestCase {
    private func snap(_ s: String, cols: Int = 20, rows: Int = 5) -> TermSnapshot {
        let t = Terminal(cols: cols, rows: rows)
        _ = t.feed(Array(s.utf8))
        return t.snapshot()
    }
    private func text(_ l: TermLine) -> String { l.cells.map { $0.text.isEmpty ? " " : $0.text }.joined().trimmingCharacters(in: .whitespaces) }

    func testCellsCarryTextAndAttributes() {
        let s = snap("\u{1b}[1;38;5;174ma\u{1b}[0mb")
        let cells = s.screen[0].cells
        XCTAssertEqual(cells[0].text, "a")
        XCTAssertTrue(cells[0].attrs.bold)
        XCTAssertEqual(cells[0].attrs.fg, .palette(174))
        XCTAssertEqual(cells[1].attrs, TermAttrs())
        XCTAssertEqual(cells.count, 2, "the never-written tail is trimmed")
    }

    /// A line's trailing cells that are erased AND carry nothing (default attributes) are trimmed, so
    /// a never-written line is `[]` — exactly `TermSnapshot.blank`'s — and two captures of the same
    /// screen compare equal whatever their source padded to. A written space, and an erased cell with
    /// a background, are content and stay.
    func testTrailingEmptyCellsAreTrimmedSoABlankLineIsTheModelsBlankLine() {
        let s = snap("")
        XCTAssertEqual(s.normal.lines, TermSnapshot.blank(cols: 20, rows: 5).normal.lines)
        XCTAssertEqual(snap("ab\u{1b}[31m\u{1b}[K").screen[0].cells.count, 2, "EL with a default background leaves nothing")
        XCTAssertEqual(snap("ab  ").screen[0].cells.count, 4, "written spaces are content")
        XCTAssertEqual(snap("ab\u{1b}[44m\u{1b}[K").screen[0].cells.count, 20, "an erased background is content")
        XCTAssertEqual(snap("a\u{1b}[5C\u{1b}[44m\u{1b}[X\u{1b}[0m").screen[0].cells.count, 7, "trimming stops at the last content")
    }

    /// Trimming changes the MODEL, never what the emitter writes: every stream emits the same bytes
    /// from its trimmed capture as from the capture padded back out to `cols` with empty cells.
    func testTrimmingDoesNotChangeTheEmittedBytes() {
        func padded(_ b: TermBufferState, cols: Int) -> TermBufferState {
            var b = b
            b.lines = b.lines.map { l in
                TermLine(cells: l.cells + Array(repeating: TermCell(text: "", width: 1, attrs: TermAttrs()), count: max(0, cols - l.width)),
                         wrapped: l.wrapped)
            }
            return b
        }
        let streams = [
            "",
            "plain\r\nlines\r\n\r\n",
            String(repeating: "x", count: 19) + "中",                                       // the wide glyph did not fit
            String(repeating: "Z", count: 20) + "\u{1b}[31m\u{1b}[1K",                    // pending wrap over an erased row
            "\r\n" + String(repeating: "p", count: 20),
            "abc\u{1b}[?1049h\u{1b}[Hx\u{1b}[3;5Hy",
        ]
        for (i, stream) in streams.enumerated() {
            let a = snap(stream)
            var p = a
            p.normal = padded(a.normal, cols: a.cols)
            p.alt = a.alt.map { padded($0, cols: a.cols) }
            XCTAssertNotEqual(p, a, "stream \(i): the padding must be a real difference")
            XCTAssertEqual(TermSnapshotEmitter.emit(a), TermSnapshotEmitter.emit(p), "stream \(i)")
        }
    }

    func testErasedCellsCarryOnlyTheirBackground() {
        let s = snap("\u{1b}[1;31;44mx\u{1b}[K")
        XCTAssertEqual(s.screen[0].cells[1], TermCell(text: "", width: 1, attrs: TermAttrs(bg: .palette(4))))
    }

    func testHistoryThenScreenOldestFirst() {
        let s = snap((1...9).map { "L\($0)" }.joined(separator: "\r\n"))
        XCTAssertEqual(s.normal.lines.count, 9)
        XCTAssertEqual(text(s.normal.lines[0]), "L1")
        XCTAssertEqual(s.screen.map(text), ["L5", "L6", "L7", "L8", "L9"])
    }

    func testWrapFlagsAndWideGlyphs() {
        let s = snap(String(repeating: "x", count: 19) + "中", cols: 20, rows: 3)
        XCTAssertEqual(s.normal.lines[0].width, 19, "the wide glyph did not fit (its empty cell is trimmed)")
        XCTAssertTrue(s.normal.lines[1].wrapped)
        XCTAssertEqual(s.normal.lines[1].cells.first, TermCell(text: "中", width: 2, attrs: TermAttrs()))
    }

    func testAltScreenRegionOriginAndSavedCursor() {
        let s = snap("hist\u{1b}[31m\u{1b}[?1049h\u{1b}[0m\u{1b}[2;4r\u{1b}[?6h\u{1b}[2;3H\u{1b}7")
        XCTAssertNotNil(s.alt)
        XCTAssertEqual(s.alt?.scrollTop, 1); XCTAssertEqual(s.alt?.scrollBottom, 3)
        XCTAssertTrue(s.modes.origin)
        XCTAssertEqual(s.normal.savedCursor.attrs.fg, .palette(1), "?1049h saved the red pen into the normal slot")
        XCTAssertEqual(s.alt?.savedCursor.x, 2)
        XCTAssertEqual(s.alt?.savedCursor.y, 2, "origin row 2 of region 2-4 is absolute row 2 (0-based)")
    }

    func testModesPenCharsetsAndCursor() {
        let s = snap("\u{1b}[?1h\u{1b}=\u{1b}[4h\u{1b}[?45h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?25l\u{1b}[5 q\u{1b})0\u{0e}\u{1b}[1m")
        XCTAssertTrue(s.modes.applicationCursor); XCTAssertTrue(s.modes.applicationKeypad); XCTAssertTrue(s.modes.insert)
        XCTAssertTrue(s.modes.reverseWraparound); XCTAssertTrue(s.modes.bracketedPaste); XCTAssertTrue(s.modes.focusReporting)
        XCTAssertEqual(s.modes.mouse, .buttonEvent); XCTAssertEqual(s.modes.mouseEncoding, .sgr)
        XCTAssertFalse(s.cursor.visible); XCTAssertEqual(s.cursor.style, .blinkBar)
        XCTAssertEqual(s.charsets, TermCharsets(g: [nil, UInt8(ascii: "0"), nil, nil], gl: 1))
        XCTAssertTrue(s.pen.bold)
    }

    func testPendingWrapIsXEqualToCols() {
        let s = snap("\r\n" + String(repeating: "z", count: 20), cols: 20, rows: 3)
        XCTAssertEqual(s.cursor.x, 20)
        XCTAssertEqual(s.cursor.y, 1)
    }

    /// DECSC in pending wrap saves x == cols in both emulators (xterm.js restores it as a pending wrap
    /// too); the capture must not clamp it to the last column.
    func testASavedCursorInPendingWrapKeepsXEqualToCols() {
        let s = snap("top\r\n" + String(repeating: "y", count: 20) + "\u{1b}7\u{1b}[4;1Hmoved", cols: 20, rows: 5)
        XCTAssertEqual(s.normal.savedCursor.x, 20)
        XCTAssertEqual(s.normal.savedCursor.y, 1)
        let a = snap("\u{1b}[?1049h\u{1b}[3;1H" + String(repeating: "q", count: 20) + "\u{1b}7\u{1b}[H", cols: 20, rows: 5)
        XCTAssertEqual(a.alt?.savedCursor.x, 20)
        XCTAssertEqual(a.alt?.savedCursor.y, 2)
    }

    func testHistoryIsCappedAtTheClientsScrollback() {
        let s = snap((0..<6000).map { "l\($0)\r\n" }.joined(), cols: 10, rows: 4)
        XCTAssertEqual(s.normal.lines.count, TermSnapshot.historyCap + 4)
    }

    func testTitleIsTheLastOneSet() {
        XCTAssertNil(snap("plain").title)
        XCTAssertEqual(snap("\u{1b}]2;one\u{07}\u{1b}]0;two\u{07}x").title, "two")
    }

    /// snapshot → emit → fresh SwiftTerm → snapshot is the identity (titles aside).
    func testTheEmitterRoundTripsThroughSwiftTerm() {
        let streams = [
            "\u{1b}[1;38;2;1;2;3mrgb\u{1b}[0m plain \u{1b}[4:3mcurly\u{1b}[0m\r\n" + String(repeating: "w", count: 45) + "\r\nend",
            "top\u{1b}[3;4r\u{1b}[?6h" + (0..<9).map { "\r\nr\($0)" }.joined() + "\u{1b}[1;2H",
            "shell\u{1b}[1;33m\u{1b}[?1049h\u{1b}[0m\u{1b}[H\u{1b}[2Jalt\u{1b}[2;9Hx\u{1b}[?1000h\u{1b}[?1006h",
            "\u{1b}(0lqk\u{1b}(B\u{1b}7\u{1b})0\u{0e}\u{1b}[3g\u{1b}[1;4H\u{1b}H",
            "\r\n" + String(repeating: "p", count: 20),
            // a saved cursor in pending wrap, on the normal screen and (under a live alt screen) on both
            "top\r\n\u{1b}[33m" + String(repeating: "y", count: 20) + "\u{1b}7\u{1b}[0m\u{1b}[4;1Hmoved",
            // pending wrap over a row erased after the wrap-setting write: the emitter's fallback that
            // rewrites an EMPTY last cell (TermSnapshotEmitter.pendingWrap, no covering glyph)
            "top\r\n" + String(repeating: "Z", count: 20) + "\u{1b}[31m\u{1b}[1K",
            // ...erased with a background, and a SAVED cursor there (DECSC in that pending wrap)
            "top\r\n" + String(repeating: "Z", count: 20) + "\u{1b}[44m\u{1b}[1K\u{1b}7\u{1b}[0m\u{1b}[4;1Hmoved",
            "\u{1b}[44m" + String(repeating: "n", count: 20) + "\u{1b}[?1049h\u{1b}[0m\u{1b}[2;1H\u{1b}(0" + String(repeating: "q", count: 20) + "\u{1b}7\u{1b}(B\u{1b}[Hx",
        ]
        for (i, stream) in streams.enumerated() {
            let a = snap(stream)
            let t = Terminal(cols: a.cols, rows: a.rows)
            _ = t.feed(TermSnapshotEmitter.emit(a))
            var b = t.snapshot(); b.title = a.title
            XCTAssertEqual(b, a, "stream \(i) did not round-trip")
        }
    }

    /// A `pty:` tab's input filter reads SwiftTerm's own modes now (there is no stream tracker for it).
    func testInputModesComeFromTheEmulator() {
        let t = Terminal(cols: 20, rows: 5)
        _ = t.feed(Array("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[?1h\u{1b}[?2004h".utf8))
        let m = t.inputModes()
        XCTAssertEqual(m.mouse, .anyEvent); XCTAssertEqual(m.mouseEncoding, .sgr)
        XCTAssertTrue(m.focusReporting); XCTAssertTrue(m.applicationCursor); XCTAssertTrue(m.bracketedPaste)
    }
}
