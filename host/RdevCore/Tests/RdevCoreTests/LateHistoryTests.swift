import XCTest
@testable import RdevCore

/// SCROLLBACK COMES AFTER THE SCREEN (docs/terminal.md): which captures split, and that the screen alone, emitted into a
/// FRESH terminal, is the capture's screen.
final class LateHistoryTests: XCTestCase {
    private func terminal(_ lines: Int, cols: Int = 20, rows: Int = 5, tail: String = "") -> Terminal {
        let t = Terminal(cols: cols, rows: rows)
        for i in 0..<lines { _ = t.feed(Array("line \(i)\r\n".utf8)) }
        _ = t.feed(Array(tail.utf8))
        return t
    }
    private func screenText(_ s: TermSnapshot) -> [String] {
        s.screen.map { $0.cells.map { $0.text.isEmpty ? " " : $0.text }.joined().trimmingCharacters(in: .whitespaces) }
    }

    func testASmallHistoryGoesWhole() {
        XCTAssertNil(terminal(TermSnapshot.lateHistoryLines - 10).snapshot().screenForLateHistory)
    }

    func testABigHistoryGoesAsItsScreenFirst() throws {
        let full = terminal(1000).snapshot()
        let screen = try XCTUnwrap(full.screenForLateHistory)
        XCTAssertEqual(screen.normal.lines, Array(full.normal.lines.suffix(full.rows)))
        XCTAssertEqual(screen.cursor, full.cursor)
        // The screen alone, written into a fresh terminal of the grid, IS the capture's screen.
        let fresh = Terminal(cols: full.cols, rows: full.rows)
        _ = fresh.feed(TermSnapshotEmitter.emit(screen))
        XCTAssertEqual(screenText(fresh.snapshot()), screenText(full))
        XCTAssertEqual(fresh.snapshot().cursor, full.cursor)
    }

    /// The screen's first row CONTINUES a history line (a long line wrapped across the boundary): written alone it is
    /// a row of its own, its text the same.
    func testAFirstRowThatContinuesHistoryStillShowsItsText() throws {
        let full = terminal(1000, tail: String(repeating: "x", count: 20 * 6) + "END").snapshot()
        XCTAssertTrue(full.normal.lines.suffix(full.rows).first?.wrapped ?? false, "precondition: the first screen row is a continuation")
        let screen = try XCTUnwrap(full.screenForLateHistory)
        let fresh = Terminal(cols: full.cols, rows: full.rows)
        _ = fresh.feed(TermSnapshotEmitter.emit(screen))
        XCTAssertEqual(screenText(fresh.snapshot()), screenText(full))
    }
}
