import XCTest
@testable import ShellstormCore

/// The tab bar's empty stretch as a native grip: used only at the width the page measured it at.
final class ChromeGapTests: XCTestCase {
    private func grip(_ gap: ChromeGap, _ width: Double) -> [Double]? {
        gap.grip(windowWidth: width, leftGrip: 92, rightGrip: 12).map { [$0.start, $0.end] }
    }

    func testAGapIsAGripAtTheWidthItWasMeasuredAt() {
        XCTAssertEqual(grip(ChromeGap(left: 138, right: 1157, width: 1280), 1280), [138, 1157])
    }

    /// The lockstep zoom's order: the page measures at the width the window is ABOUT to reach. The report is
    /// kept, unused, until the window gets there — then it is right, with nothing re-sent.
    func testAReportAheadOfTheWindowWaitsForIt() {
        let ahead = ChromeGap(left: 138, right: 1389, width: 1512)
        XCTAssertNil(grip(ahead, 1450), "measured for a window this one is not yet")
        XCTAssertEqual(grip(ahead, 1512), [138, 1389], "and used once it is")
    }

    func testAStaleGapIsNoGrip() {
        XCTAssertNil(grip(ChromeGap(left: 138, right: 1157, width: 1280), 600), "never a grip across tabs that moved")
    }

    func testFractionalWindowWidthsMatchThePagesWholePixels() {
        XCTAssertNotNil(grip(ChromeGap(left: 138, right: 500, width: 600), 600.5))
    }

    func testNothingOrNothingLeftIsNoGrip() {
        XCTAssertNil(grip(.none, 1280))
        XCTAssertNil(grip(ChromeGap(left: 0, right: 0, width: 1280), 1280), "the page found no gap")
        XCTAssertNil(grip(ChromeGap(left: 60, right: 90, width: 1280), 1280), "entirely under the left grip")
        XCTAssertEqual(grip(ChromeGap(left: 60, right: 1300, width: 1280), 1280), [92, 1268], "clamped to the fixed grips")
    }
}
