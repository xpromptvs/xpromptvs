import XCTest
@testable import RdevCore

final class TerminalTitleTests: XCTestCase {

    func testOscTitleFiresOnTitle() {
        let term = Terminal(cols: 80, rows: 24)
        var got: [String] = []
        term.onTitle = { got.append($0) }
        // ESC ] 0 ; hello BEL   — set icon+window title
        let bytes: [UInt8] = [0x1b, 0x5d, 0x30, 0x3b] + Array("hello".utf8) + [0x07]
        _ = term.feed(bytes)
        XCTAssertEqual(got.last, "hello")
    }

    func testOsc2TitleFiresOnTitle() {
        let term = Terminal(cols: 80, rows: 24)
        var got: String?
        term.onTitle = { got = $0 }
        // ESC ] 2 ; ~/build BEL — set window title only
        let bytes: [UInt8] = [0x1b, 0x5d, 0x32, 0x3b] + Array("~/build".utf8) + [0x07]
        _ = term.feed(bytes)
        XCTAssertEqual(got, "~/build")
    }
}
