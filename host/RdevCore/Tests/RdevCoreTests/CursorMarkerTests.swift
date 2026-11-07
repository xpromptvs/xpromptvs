import XCTest
@testable import RdevCore

final class CursorMarkerTests: XCTestCase {
    func testCenterOfFrame() {
        // 48px square centred in 100x100 -> 26..74 on both axes.
        let r = CursorMarker.rect(normX: 0.5, normY: 0.5, width: 100, height: 100)
        XCTAssertEqual(r?.x0, 26); XCTAssertEqual(r?.y0, 26)
        XCTAssertEqual(r?.x1, 74); XCTAssertEqual(r?.y1, 74)
    }

    func testClampedAtTopLeft() {
        // CLIPPED, not shifted: half a square at the edge is the honest rendering of the
        // true position. Shifting it inward would misreport where the pointer is.
        let r = CursorMarker.rect(normX: 0, normY: 0, width: 100, height: 100)
        XCTAssertEqual(r?.x0, 0); XCTAssertEqual(r?.y0, 0)
        XCTAssertEqual(r?.x1, 24); XCTAssertEqual(r?.y1, 24)
    }

    func testClampedAtBottomRight() {
        // 75, not 76: norm 1.0 is the LAST PIXEL (99), not one past the end. The centre clamps to
        // width-1, so the rect is 99-24 .. 100. Getting this wrong by one would put the marker
        // half a pixel off at the edges — invisible by eye, and exactly the kind of drift a
        // position instrument must not have.
        let r = CursorMarker.rect(normX: 1, normY: 1, width: 100, height: 100)
        XCTAssertEqual(r?.x0, 75); XCTAssertEqual(r?.y0, 75)
        XCTAssertEqual(r?.x1, 100); XCTAssertEqual(r?.y1, 100)
    }

    func testNormalizedOutOfRangeIsClamped() {
        let over = CursorMarker.rect(normX: 1.5, normY: -0.5, width: 100, height: 100)
        let edge = CursorMarker.rect(normX: 1.0, normY: 0.0, width: 100, height: 100)
        XCTAssertEqual(over?.x0, edge?.x0); XCTAssertEqual(over?.y0, edge?.y0)
        XCTAssertEqual(over?.x1, edge?.x1); XCTAssertEqual(over?.y1, edge?.y1)
    }

    func testFrameSmallerThanMarkerCoversWholeFrame() {
        let r = CursorMarker.rect(normX: 0.5, normY: 0.5, width: 10, height: 10)
        XCTAssertEqual(r?.x0, 0); XCTAssertEqual(r?.y0, 0)
        XCTAssertEqual(r?.x1, 10); XCTAssertEqual(r?.y1, 10)
    }

    func testDegenerateFrameReturnsNil() {
        XCTAssertNil(CursorMarker.rect(normX: 0.5, normY: 0.5, width: 0, height: 10))
        XCTAssertNil(CursorMarker.rect(normX: 0.5, normY: 0.5, width: 10, height: 0))
    }

    func testPressedAndNormalColoursDifferInLuma() {
        // LOAD-BEARING property, not decoration. Chroma is 4:2:0-subsampled and heavily
        // quantized at 2 Mbps, so two colours separated only by HUE can smear together at
        // exactly the transition the instrument exists to show.
        let luma = { (c: (b: UInt8, g: UInt8, r: UInt8)) -> Double in
            0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)
        }
        let normal = CursorMarker.colorBGRA(pressed: false)
        let pressed = CursorMarker.colorBGRA(pressed: true)
        XCTAssertEqual(normal.r, 255); XCTAssertEqual(normal.g, 0); XCTAssertEqual(normal.b, 0)
        XCTAssertEqual(pressed.g, 255); XCTAssertEqual(pressed.r, 0); XCTAssertEqual(pressed.b, 0)
        XCTAssertGreaterThan(abs(luma(pressed) - luma(normal)), 50)
    }
}
