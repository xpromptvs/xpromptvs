import XCTest
@testable import RdevCore

/// The emitter's BYTES, pinned. Whether xterm.js turns them back into the same state is the
/// differential check (web/test/term-snapshot-fidelity.test.ts); these pin the ordering decisions
/// that check depends on, so a reorder is a deliberate edit here too.
final class TermSnapshotEmitterTests: XCTestCase {
    private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
    private func line(_ text: String, _ attrs: TermAttrs = TermAttrs(), wrapped: Bool = false) -> TermLine {
        TermLine(cells: text.map { TermCell(text: String($0), width: 1, attrs: attrs) }, wrapped: wrapped)
    }
    private var red: TermAttrs { var a = TermAttrs(); a.fg = .palette(1); return a }

    func testStartsWithASoftResetAndAutowrap() {
        XCTAssertTrue(s(TermSnapshotEmitter.emit(.blank(cols: 10, rows: 3))).hasPrefix("\u{1b}[!p\u{1b}[?7h"))
    }

    func testLinesAreCRLFSeparatedTrimmedAndTheLastHasNoCRLF() {
        var snap = TermSnapshot.blank(cols: 10, rows: 3)
        snap.normal.lines = [line("ab"), line(""), line("c")]
        let out = s(TermSnapshotEmitter.emit(snap))
        XCTAssertTrue(out.contains("ab\r\n\r\nc\u{1b}["), out.debugDescription)
        XCTAssertFalse(out.contains("c\r\n"))
    }

    func testAWrappedLineIsWrittenToExactlyColsWithNoCRLF() {
        var snap = TermSnapshot.blank(cols: 4, rows: 2)
        snap.normal.lines = [line("abcd"), line("ef", wrapped: true)]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("abcdef"))
    }

    func testAWideGlyphIsWrittenOnceAndItsOverflowCellIsLeftToXterm() {
        var snap = TermSnapshot.blank(cols: 3, rows: 2)
        snap.normal.lines = [
            TermLine(cells: [TermCell(text: "a", width: 1, attrs: TermAttrs()), TermCell(text: "b", width: 1, attrs: TermAttrs()),
                             TermCell(text: "", width: 1, attrs: TermAttrs())]),
            TermLine(cells: [TermCell(text: "中", width: 2, attrs: TermAttrs()), TermCell(text: "", width: 1, attrs: TermAttrs())], wrapped: true),
        ]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("ab中"), "no space written into the overflow cell")
    }

    func testTrailingErasedCellsWithABackgroundAreErasedNotWritten() {
        var snap = TermSnapshot.blank(cols: 6, rows: 1)
        let blue = TermAttrs(bg: .palette(4))
        snap.normal.lines = [TermLine(cells: [TermCell(text: "x", width: 1, attrs: TermAttrs())]
                                      + Array(repeating: TermCell(text: "", width: 1, attrs: blue), count: 5))]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("x\u{1b}[44m\u{1b}[5X"))
    }

    func testAGapOfNeverWrittenCellsIsSkippedWithCUF() {
        var snap = TermSnapshot.blank(cols: 10, rows: 1)
        snap.normal.lines = [TermLine(cells: [TermCell(text: "a", width: 1, attrs: TermAttrs())]
                                      + Array(repeating: TermCell(text: "", width: 1, attrs: TermAttrs()), count: 3)
                                      + [TermCell(text: "b", width: 1, attrs: TermAttrs())])]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("a\u{1b}[3Cb"))
    }

    func testSGRDeltasAreMinimalAndATurnOffRestatesFully() {
        var bold = red; bold.bold = true
        XCTAssertEqual(TermSnapshotEmitter.sgrDelta(from: red, to: bold), "1")
        XCTAssertEqual(TermSnapshotEmitter.sgrDelta(from: bold, to: red), "0;31")
        XCTAssertNil(TermSnapshotEmitter.sgrDelta(from: red, to: red))
        var c = TermAttrs(); c.fg = .palette(12); c.bg = .rgb(1, 2, 3); c.underline = 3; c.underlineColor = .palette(200)
        XCTAssertEqual(TermSnapshotEmitter.sgr(c), "0;4:3;94;48;2;1;2;3;58;5;200")
    }

    func testTheRegionComesAfterTheLinesAndTheAltScreenAfterTheNormalSavedCursor() {
        var snap = TermSnapshot.blank(cols: 10, rows: 5)
        snap.normal.lines = [line("n")] + Array(repeating: line(""), count: 4)
        snap.normal.scrollTop = 1; snap.normal.scrollBottom = 3
        snap.normal.savedCursor = TermSavedCursor(x: 2, y: 4, attrs: red, charset: nil)
        var alt = TermBufferState(lines: [line("A")] + Array(repeating: line(""), count: 4), scrollTop: 0, scrollBottom: 4,
                                  tabStops: TermSnapshot.defaultTabStops(cols: 10), savedCursor: TermSavedCursor())
        alt.scrollTop = 2
        snap.alt = alt
        let out = s(TermSnapshotEmitter.emit(snap))
        let region = try! XCTUnwrap(out.range(of: "\u{1b}[2;4r"))
        let stand = try! XCTUnwrap(out.range(of: "\u{1b}[5;3H"))
        let enter = try! XCTUnwrap(out.range(of: "\u{1b}[?1049h"))
        let altRow = try! XCTUnwrap(out.range(of: "\u{1b}[1;1HA"))
        let altRegion = try! XCTUnwrap(out.range(of: "\u{1b}[3;5r"))
        XCTAssertTrue(out.range(of: "n")!.lowerBound < region.lowerBound)
        XCTAssertTrue(region.lowerBound < stand.lowerBound && stand.lowerBound < enter.lowerBound)
        XCTAssertTrue(enter.lowerBound < altRow.lowerBound && altRow.lowerBound < altRegion.lowerBound)
    }

    func testModesAreStatedExplicitlyAndCUPIsRegionRelativeUnderOrigin() {
        var snap = TermSnapshot.blank(cols: 10, rows: 10)
        snap.normal.scrollTop = 2; snap.normal.scrollBottom = 7
        snap.modes.origin = true
        snap.modes.bracketedPaste = true
        snap.modes.mouse = .anyEvent; snap.modes.mouseEncoding = .sgr
        snap.cursor = TermCursor(x: 3, y: 5, visible: false, style: .steadyBar)
        let out = s(TermSnapshotEmitter.emit(snap))
        for piece in ["\u{1b}[?1l", "\u{1b}>", "\u{1b}[?45l", "\u{1b}[6 q", "\u{1b}[?25l", "\u{1b}[?2004h", "\u{1b}[?1004l",
                      "\u{1b}[?1003h", "\u{1b}[?1006h", "\u{1b}[?6h\u{1b}[4;4H", "\u{1b}[4l\u{1b}[?7h"] {
            XCTAssertTrue(out.contains(piece), "missing \(piece.debugDescription) in \(out.debugDescription)")
        }
        XCTAssertFalse(out.contains("\u{1b}[?2026h"))
    }

    /// SwiftTerm and xterm.js honour ?45 only while autowrap is on, so ?45 must be stated while ?7 is
    /// still on and the snapshot's real ?7 (here OFF) only afterwards.
    func testReverseWraparoundIsStatedWhileAutowrapIsOnAndTheRealAutowrapFollows() {
        var snap = TermSnapshot.blank(cols: 10, rows: 2)
        snap.modes.reverseWraparound = true
        snap.modes.wraparound = false
        let out = s(TermSnapshotEmitter.emit(snap))
        let on = try! XCTUnwrap(out.range(of: "\u{1b}[?7h"))
        let rev = try! XCTUnwrap(out.range(of: "\u{1b}[?45h"))
        let off = try! XCTUnwrap(out.range(of: "\u{1b}[?7l"))
        XCTAssertTrue(on.lowerBound < rev.lowerBound && rev.lowerBound < off.lowerBound, out.debugDescription)
        XCTAssertEqual(out.components(separatedBy: "\u{1b}[?7l").count, 2, "?7l exactly once, after ?45h")
    }

    func testPendingWrapRewritesTheLastCellAtTheLastColumn() {
        var snap = TermSnapshot.blank(cols: 3, rows: 2)
        snap.normal.lines = [line(""), line("xyz", red)]
        snap.cursor = TermCursor(x: 3, y: 1, visible: true, style: .blinkBlock)
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("\u{1b}[2;3H\u{1b}[31mz"))
    }

    func testSavedCursorCarriesItsCharsetAndTheRealDesignationsFollow() {
        var snap = TermSnapshot.blank(cols: 10, rows: 2)
        snap.normal.savedCursor = TermSavedCursor(x: 1, y: 1, attrs: TermAttrs(), charset: UInt8(ascii: "0"))
        snap.charsets = TermCharsets(g: [nil, UInt8(ascii: "0"), nil, nil], gl: 1)
        let out = s(TermSnapshotEmitter.emit(snap))
        let save = try! XCTUnwrap(out.range(of: "\u{1b}(0\u{0f}\u{1b}7"))
        let real = try! XCTUnwrap(out.range(of: "\u{1b}(B\u{1b})0\u{0e}"))
        XCTAssertTrue(save.lowerBound < real.lowerBound)
    }

    func testSynchronizedOutputIsLastAndOnlyWhenInProgress() {
        var snap = TermSnapshot.blank(cols: 4, rows: 2)
        snap.modes.synchronizedOutput = true
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).hasSuffix("\u{1b}[?2026h"))
    }

    // MARK: fix round 1 (review against xterm.js 6.0.0's InputHandler / BufferService)

    private func erased(_ n: Int, _ attrs: TermAttrs = TermAttrs()) -> [TermCell] {
        Array(repeating: TermCell(text: "", width: 1, attrs: attrs), count: n)
    }

    /// After the previous row's exact-width write xterm.js is in PENDING WRAP; CUF and ECH clamp x to
    /// cols-1 first, so a continuation that STARTS erased would land on the previous row's last glyph.
    /// A written space forces the wrap, CUB returns to it, ECH restores the erased state.
    func testAContinuationThatStartsErasedForcesTheWrapFirst() {
        var snap = TermSnapshot.blank(cols: 3, rows: 2)
        snap.normal.lines = [line("abc"), TermLine(cells: erased(2) + [TermCell(text: "z", width: 1, attrs: TermAttrs())], wrapped: true)]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("abc \u{1b}[D\u{1b}[2X\u{1b}[2Cz"))
    }

    func testAnEmptyContinuationStillWrapsInsteadOfBeingDropped() {
        var snap = TermSnapshot.blank(cols: 3, rows: 3)
        snap.normal.lines = [line("abc"), TermLine(cells: [], wrapped: true), line("d")]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("abc \u{1b}[D\u{1b}[1X\r\nd"))
    }

    func testAnAltContinuationThatStartsErasedForcesTheWrapToo() {
        var snap = TermSnapshot.blank(cols: 3, rows: 2)
        snap.alt = TermBufferState(lines: [line("abc"), TermLine(cells: erased(1) + [TermCell(text: "z", width: 1, attrs: TermAttrs())], wrapped: true)],
                                   scrollTop: 0, scrollBottom: 1, tabStops: TermSnapshot.defaultTabStops(cols: 3), savedCursor: TermSavedCursor())
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("\u{1b}[1;1Habc \u{1b}[D\u{1b}[1X\u{1b}[1Cz"))
    }

    /// The pending-wrap rewrite must not run under the SAVED cursor's charset: `ESC ( 0` would remap
    /// `a` to `▒`. G0 goes back to ASCII after each DECSC; `charsets` restores the real state last.
    func testThePendingWrapRewriteIsNotMappedByTheSavedCharset() throws {
        var snap = TermSnapshot.blank(cols: 3, rows: 2)
        snap.normal.lines = [line(""), line("xya")]
        snap.normal.savedCursor = TermSavedCursor(x: 0, y: 0, attrs: TermAttrs(), charset: UInt8(ascii: "0"))
        snap.cursor = TermCursor(x: 3, y: 1, visible: true, style: .blinkBlock)
        let out = s(TermSnapshotEmitter.emit(snap))
        let reset = try XCTUnwrap(out.range(of: "\u{1b}(0\u{0f}\u{1b}7\u{1b}(B\u{0f}"), out.debugDescription)
        let rewrite = try XCTUnwrap(out.range(of: "\u{1b}[2;3Ha"))
        XCTAssertTrue(reset.lowerBound < rewrite.lowerBound)
        XCTAssertFalse(out[reset.upperBound..<rewrite.lowerBound].contains("\u{1b}(0"))
    }

    /// `?1049h` fills the alt screen with the pen's background — the NORMAL saved cursor's, stood on
    /// just before. It is erased again with the default pen before any alt row is written.
    func testTheAltScreenIsErasedWithTheDefaultPenBeforeItsRows() {
        var snap = TermSnapshot.blank(cols: 4, rows: 2)
        snap.normal.savedCursor = TermSavedCursor(x: 0, y: 0, attrs: TermAttrs(bg: .palette(4)), charset: nil)
        snap.alt = TermBufferState(lines: [line("A"), line("")], scrollTop: 0, scrollBottom: 1,
                                   tabStops: TermSnapshot.defaultTabStops(cols: 4), savedCursor: TermSavedCursor())
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("\u{1b}[?1049h\u{1b}[0m\u{1b}(B\u{0f}\u{1b}[H\u{1b}[2J\u{1b}[1;1HA"))
    }

    /// A SHORT line followed by a continuation is padded to `cols` so xterm.js wraps, rather than gluing
    /// the continuation onto the same row.
    func testAShortLineBeforeAContinuationIsPaddedToCols() {
        var snap = TermSnapshot.blank(cols: 4, rows: 2)
        snap.normal.lines = [line("ab"), line("cd", wrapped: true)]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("ab  cd"))
    }

    /// A wrap that scrolls fills the new row with the pen's background at wrap time (the continuation's
    /// first glyph's); the rest of that row is erased again with the default pen.
    func testTheRowAContinuationWrapsIntoIsClearedOfTheWrapTimeBackground() {
        var snap = TermSnapshot.blank(cols: 3, rows: 1)
        snap.normal.lines = [line("abc"), line("z", TermAttrs(bg: .palette(4)), wrapped: true)]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("abc\u{1b}[44mz\u{1b}[0m\u{1b}[K"))
    }

    func testCustomTabStopsAreClearedAndSet() {
        var snap = TermSnapshot.blank(cols: 20, rows: 2)
        snap.normal.tabStops = [5, 13]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(snap)).contains("\u{1b}[3g\u{1b}[1;6H\u{1b}H\u{1b}[1;14H\u{1b}H"))
        XCTAssertFalse(s(TermSnapshotEmitter.emit(.blank(cols: 20, rows: 2))).contains("\u{1b}[3g"))
    }

    /// Two cells that would JOIN if written back to back — a mark or VS16 that stood alone in the
    /// original because a sequence came between (docs/terminal.md, "Glyph widths") — are kept apart
    /// with a NUL: both emulators execute it as nothing, and it ends a join in both.
    func testAGlyphThatWouldJoinThePreviousOneIsKeptApartWithANUL() {
        func cells(_ texts: [String]) -> TermLine {
            TermLine(cells: texts.map { TermCell(text: $0, width: 1, attrs: TermAttrs()) })
        }
        var snap = TermSnapshot.blank(cols: 10, rows: 2)
        snap.normal.lines = [cells(["e", "\u{301}", "\u{2764}", "\u{FE0F}", "a", "b"]), cells(["\u{1F469}\u{200D}", "\u{1F4BB}"])]
        let out = s(TermSnapshotEmitter.emit(snap))
        XCTAssertTrue(out.contains("e\u{0}\u{301}\u{2764}\u{0}\u{FE0F}ab\r\n"), out.debugDescription)
        XCTAssertTrue(out.contains("\u{1F469}\u{200D}\u{0}\u{1F4BB}"), "after a ZWJ, whatever Swift decides")
        // A zero-width scalar Swift would NOT join (ZWSP, LRM, a jamo vowel) is still folded into the
        // previous cell by the client (term-unicode.ts), so an orphan one needs the NUL too.
        var orphans = TermSnapshot.blank(cols: 10, rows: 1)
        orphans.normal.lines = [cells(["a", "\u{200B}", "X", "\u{200E}", "b", "\u{1161}"])]
        XCTAssertTrue(s(TermSnapshotEmitter.emit(orphans)).contains("a\u{0}\u{200B}X\u{0}\u{200E}b\u{0}\u{1161}"))
        var plain = TermSnapshot.blank(cols: 10, rows: 2)
        plain.normal.lines = [line("ab"), cells(["\u{1F469}", "\u{1F4BB}", "\u{4E2D}"])]
        XCTAssertFalse(s(TermSnapshotEmitter.emit(plain)).contains("\u{0}"), "no NUL where nothing joins")
    }
}
