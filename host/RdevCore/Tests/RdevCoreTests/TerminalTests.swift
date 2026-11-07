import XCTest
@testable import RdevCore

/// `Terminal` feeds SwiftTerm; what it holds is read back through `snapshot()`, the only view of it
/// that leaves the host.
final class TerminalTests: XCTestCase {
    private func row(_ t: Terminal, _ r: Int) -> String {
        t.snapshot().screen[r].cells.map { $0.text.isEmpty ? " " : $0.text }.joined()
    }

    /// What an agent's activity is read from: the screen's last rows, as text.
    func testScreenRowsReadTheBottomOfWhatItShows() {
        let t = Terminal(cols: 20, rows: 4)
        t.feed(Array("one\r\ntwo\r\nthree".utf8))
        XCTAssertEqual(t.screenRows(last: 2).map { $0.trimmingCharacters(in: .whitespaces) }, ["three", ""])
        XCTAssertEqual(t.screenRows(last: 9).count, 4, "never more than the screen")
        t.feed(Array("\u{1b}[?1049h\u{1b}[Hfull screen".utf8))     // the alternate screen: what it shows now
        XCTAssertEqual(t.screenRows(last: 4).first?.trimmingCharacters(in: .whitespaces), "full screen")
    }

    func testFeedPrintableWritesGridAndMovesCursor() {
        let t = Terminal(cols: 4, rows: 2)
        t.feed(Array("Hi".utf8))
        XCTAssertEqual(row(t, 0), "Hi")
        XCTAssertEqual(t.cursorLocation().col, 2)
    }

    func testSGRColorIsParsed() {
        let t = Terminal(cols: 8, rows: 2)
        t.feed(Array("\u{1b}[31mA\u{1b}[0mB".utf8))                // red foreground 'A', then a default 'B'
        let cells = t.snapshot().screen[0].cells
        XCTAssertEqual(cells[0].text, "A")
        XCTAssertEqual(cells[0].attrs.fg, .palette(1))
        XCTAssertEqual(cells[1].attrs.fg, .default)
    }

    func testCarriageReturnOverwrites() {
        let t = Terminal(cols: 4, rows: 2)
        t.feed(Array("Hi".utf8))
        t.feed([0x0d])                                            // \r -> col 0
        XCTAssertEqual(t.cursorLocation().col, 0)
        t.feed(Array("x".utf8))
        XCTAssertEqual(row(t, 0), "xi")
    }

    func testNewlineMovesRow() {
        let t = Terminal(cols: 4, rows: 2)
        t.feed([0x0a])                                            // \n
        XCTAssertEqual(t.cursorLocation().row, 1)
    }

    func testResizeUpdatesGeometryAndSnapshot() {
        let t = Terminal(cols: 80, rows: 24)
        t.resize(cols: 120, rows: 40)
        XCTAssertEqual(t.cols, 120)
        XCTAssertEqual(t.rows, 40)
        let s = t.snapshot()
        XCTAssertEqual(s.cols, 120)
        XCTAssertEqual(s.rows, 40)
        XCTAssertEqual(s.screen.count, 40)
    }

    /// The host keeps as much history as the client's xterm.js (`scrollback: 5000`): a snapshot is
    /// capped by what the host HOLDS, and 500 (SwiftTerm's default) would lose 4500 lines a client
    /// that was watching still has.
    func testScrollbackHoldsTheClientsCap() {
        let t = Terminal(cols: 20, rows: 4)
        t.feed(Array((0..<6000).map { "l\($0)\r\n" }.joined().utf8))
        XCTAssertEqual(Terminal.scrollbackLines, 5000)
        XCTAssertEqual(t.snapshot().normal.lines.count, 5000 + 4)
    }
}
