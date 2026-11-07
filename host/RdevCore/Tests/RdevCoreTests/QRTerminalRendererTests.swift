import XCTest
@testable import RdevCore

final class QRTerminalRendererTests: XCTestCase {
    private let d = QRTerminalRenderer.darkCellSGR   // black-background cell
    private let l = QRTerminalRenderer.lightCellSGR  // white-background cell
    private let r = QRTerminalRenderer.resetSGR

    // Modules are background-colored spaces (no glyphs), one module per row, run-length coalesced.
    func testBackgroundColoredSpacesOneRowPerModule() {
        let out = QRTerminalRenderer.render([[true, false], [false, true]], quietZone: 0, moduleWidth: 1)
        XCTAssertEqual(out, "\(d) \(l) \(r)\n\(l) \(d) \(r)\n")
    }

    // moduleWidth: 2 -> two spaces per module (near-square in a ~1:2 terminal cell).
    func testModuleWidthTwoDoublesEachModule() {
        let out = QRTerminalRenderer.render([[true, false]], quietZone: 0, moduleWidth: 2)
        XCTAssertEqual(out, "\(d)  \(l)  \(r)\n")
    }

    // Quiet zone = light rows top/bottom + light padding each side (a single coalesced light run).
    func testQuietZoneFramesWithLightBackground() {
        let out = QRTerminalRenderer.render([[true]], quietZone: 1, moduleWidth: 1)
        let blank = "\(l)   \(r)\n"                    // 3 modules wide, one light run
        XCTAssertEqual(out, blank + "\(l) \(d) \(l) \(r)\n" + blank)
    }

    // The width picker chooses 2-wide when it fits maxColumns, else falls back to 1-wide.
    func testMaxColumnsPicksTwoWideWhenItFitsElseOne() {
        let m = [[true, false]]                                   // 2 modules, quietZone 0
        XCTAssertEqual(QRTerminalRenderer.render(m, quietZone: 0, maxColumns: 4), "\(d)  \(l)  \(r)\n")
        XCTAssertEqual(QRTerminalRenderer.render(m, quietZone: 0, maxColumns: 3), "\(d) \(l) \(r)\n")
    }

    // Contrast is theme-proof: 24-bit true black/white backgrounds, not ANSI 40/47.
    func testUsesTruecolorBackgroundsForThemeProofContrast() {
        XCTAssertEqual(QRTerminalRenderer.darkCellSGR, "\u{1b}[48;2;0;0;0m")
        XCTAssertEqual(QRTerminalRenderer.lightCellSGR, "\u{1b}[48;2;255;255;255m")
    }

    func testEmptyMatrixRendersEmptyString() {
        XCTAssertEqual(QRTerminalRenderer.render([], moduleWidth: 2), "")
        XCTAssertEqual(QRTerminalRenderer.render([], maxColumns: 80), "")
    }
}
