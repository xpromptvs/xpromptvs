import XCTest
@testable import RdevCore

final class CropRectTests: XCTestCase {

    /// THE DEFAULT MUST COST NOTHING. Every source starts full, and a full crop has to take exactly
    /// today's code path — not a mask that happens to cover everything.
    func testAFullRectIsNoMaskAtAll() {
        XCTAssertTrue(CropRect.full.isFull)
        XCTAssertNil(CropRect.full.pixels(frameWidth: 3200, frameHeight: 1800))
    }

    /// ROUNDING IS OUTWARD ON ALL FOUR EDGES. Rounding inward would mask a strip the viewer can
    /// actually see — checkerboard INSIDE the viewport, which is the one failure this feature must
    /// never produce. Outward can only ever encode a sliver more than needed.
    ///
    /// 100x100 frame, x=0.115 -> 11.5 -> floor to even 10; right edge 0.445 -> 44.5 -> ceil to even 46.
    func testEdgesRoundOutwardToEven() {
        let c = CropRect(x: 0.115, y: 0.115, w: 0.33, h: 0.33)
        let px = c.pixels(frameWidth: 100, frameHeight: 100)
        XCTAssertEqual(px, CropPixels(x: 10, y: 10, w: 36, h: 36))
    }

    /// A crop that rounds out to cover the frame is NO MASK — there is nothing left to paint, and a
    /// zero-area checkerboard is a pointless repaint on every frame that touches it.
    func testARectThatRoundsOutToTheWholeFrameIsNoMask() {
        let c = CropRect(x: 0.001, y: 0.001, w: 0.998, h: 0.998)
        XCTAssertNil(c.pixels(frameWidth: 100, frameHeight: 100))
    }

    /// Degenerate input must degrade to "no mask", never to a zero-width crop that would blank the
    /// entire picture. The client cannot send these today; a future one might.
    func testDegenerateRectsAreNoMask() {
        for c in [CropRect(x: 0, y: 0, w: 0, h: 0.5),
                  CropRect(x: 0, y: 0, w: 0.5, h: 0),
                  CropRect(x: 0.5, y: 0.5, w: -0.2, h: 0.2),
                  CropRect(x: 2, y: 2, w: 0.5, h: 0.5)] {
            XCTAssertNil(c.pixels(frameWidth: 100, frameHeight: 100), "\(c) should be no mask")
        }
    }

    /// A crop reaching past an edge is clamped to the frame rather than refused: the client computes
    /// it from a live layout and a half-pixel overhang is not an error.
    func testARectOverhangingTheFrameIsClamped() {
        let c = CropRect(x: 0.8, y: 0.8, w: 0.5, h: 0.5)
        let px = c.pixels(frameWidth: 100, frameHeight: 100)
        XCTAssertEqual(px, CropPixels(x: 80, y: 80, w: 20, h: 20))
    }

    /// The realistic case, on a real frame size.
    func testATypicalPhoneViewportOnARetinaWindow() {
        let c = CropRect(x: 0.2, y: 0.1, w: 0.3, h: 0.4)
        XCTAssertEqual(c.pixels(frameWidth: 3200, frameHeight: 1800),
                       CropPixels(x: 640, y: 180, w: 960, h: 720))
    }

    /// THE CHROMA ROW IS HALVED AND THE COLUMN IS NOT. NV12's CbCr plane has one row per two luma
    /// rows but one BYTE per luma column (interleaved Cb,Cr per two columns), so the row offset
    /// halves and the column offset does not. Getting this wrong shears the colour off the picture
    /// while the luma stays correct — which reads as a tinting bug, not an offset bug.
    func testPlaneOffsetsHalveTheChromaROWOnly() {
        let px = CropPixels(x: 10, y: 10, w: 36, h: 36)
        let o = px.offsets(srcStride: 400, yStride: 128, cStride: 128)
        XCTAssertEqual(o.srcByteOffset, 10 * 400 + 10 * 4)   // BGRA is 4 bytes per pixel
        XCTAssertEqual(o.yByteOffset, 10 * 128 + 10)
        XCTAssertEqual(o.cbCrByteOffset, 5 * 128 + 10)       // row halved, column NOT
        XCTAssertEqual(o.width, 36)
        XCTAssertEqual(o.height, 36)
    }
}
