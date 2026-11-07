import XCTest
@testable import RdevCore

final class TerminalResizeTests: XCTestCase {
    func testResizeToSameSizeIsHarmless() {
        let t = Terminal(cols: 80, rows: 24)
        t.resize(cols: 80, rows: 24)
        XCTAssertEqual(t.cols, 80)
        XCTAssertEqual(t.rows, 24)
    }
}
