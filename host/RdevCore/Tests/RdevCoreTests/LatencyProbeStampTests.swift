import XCTest
@testable import RdevCore

final class LatencyProbeStampTests: XCTestCase {
    private var bits: [Bool] { LatencyTimecode.encode(0xA5A5_5A5A) }

    func testWidthAndHeight() {
        XCTAssertEqual(LatencyProbeStamp.cellCount, LatencyTimecode.bitCount + 4)
        XCTAssertEqual(LatencyProbeStamp.widthPx, 576)
        XCTAssertEqual(LatencyProbeStamp.heightPx, 24)
    }

    func testFitsExactly() {
        XCTAssertTrue(LatencyProbeStamp.fits(width: 576, height: 24))
        XCTAssertTrue(LatencyProbeStamp.fits(width: 640, height: 480))
    }

    func testTooNarrowDoesNotFit() {
        XCTAssertFalse(LatencyProbeStamp.fits(width: 575, height: 24))
        // The default headless test pattern. This is exactly why RdevHostRuntime enlarges it
        // to 640x480 under RDEV_LATENCY_PROBE=1.
        XCTAssertFalse(LatencyProbeStamp.fits(width: 320, height: 240))
    }

    func testTooShortDoesNotFit() {
        XCTAssertFalse(LatencyProbeStamp.fits(width: 576, height: 23))
    }

    func testFinderCells() {
        XCTAssertEqual(LatencyProbeStamp.cellIsWhite(0, bits: bits), false)   // black ref + start
        XCTAssertEqual(LatencyProbeStamp.cellIsWhite(1, bits: bits), true)    // white ref + start
        XCTAssertEqual(LatencyProbeStamp.cellIsWhite(LatencyTimecode.bitCount + 2, bits: bits), true)
        XCTAssertEqual(LatencyProbeStamp.cellIsWhite(LatencyTimecode.bitCount + 3, bits: bits), false)
    }

    func testDataCellsMirrorBits() {
        for i in 0 ..< LatencyTimecode.bitCount {
            XCTAssertEqual(LatencyProbeStamp.cellIsWhite(2 + i, bits: bits), bits[i], "cell \(2 + i)")
        }
    }

    func testOutOfRangeCellIsNil() {
        XCTAssertNil(LatencyProbeStamp.cellIsWhite(-1, bits: bits))
        XCTAssertNil(LatencyProbeStamp.cellIsWhite(LatencyProbeStamp.cellCount, bits: bits))
    }
}
