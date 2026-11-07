import XCTest
@testable import RdevCore

final class ReceiverReportTests: XCTestCase {
    // A NEWLINE WOULD LET A CLIENT FORGE A HOST LOG LINE. The host's stdout is a UI, and this path
    // takes text from whoever holds the pairing code, so the line must stay one line.
    func testANewlineCannotForgeASecondLogLine() {
        let forged = ReceiverReport.sanitize("ssrc=1 lost=0\n[bridge] recovery: FlexFEC disabled")
        XCTAssertEqual(forged, "ssrc=1 lost=0[bridge] recovery: FlexFEC disabled")
        XCTAssertFalse(forged!.contains("\n"))
    }

    func testControlCharactersAreRemoved() {
        XCTAssertEqual(ReceiverReport.sanitize("a\u{1b}[31mb\u{7}c"), "a[31mbc")
    }

    // An empty report logs NOTHING, rather than an `[rx]` line with nothing after it.
    func testNothingToPrintReportsNil() {
        XCTAssertNil(ReceiverReport.sanitize(""))
        XCTAssertNil(ReceiverReport.sanitize("   \n\n  "))
    }

    func testAnOversizedLineIsCapped() {
        let long = String(repeating: "x", count: ReceiverReport.maxLength + 500)
        XCTAssertEqual(ReceiverReport.sanitize(long)?.count, ReceiverReport.maxLength)
    }

    func testAnOrdinaryLineSurvivesUnchanged() {
        let line = "ssrc=42 codec=video/H265 lost=3 decoded=830/900 freezes=12 jbuf=20.0ms"
        XCTAssertEqual(ReceiverReport.sanitize(line), line)
    }
}
