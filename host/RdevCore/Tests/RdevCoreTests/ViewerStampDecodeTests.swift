import XCTest
@testable import RdevCore

final class ViewerStampDecodeTests: XCTestCase {

    /// Paint a stamp into a luma plane exactly as the host would, at a given cell width.
    private func paint(value: UInt32, cellW: Int, width: Int, height: Int) -> [UInt8] {
        var luma = [UInt8](repeating: 128, count: width * height)   // mid-grey background
        let bits = LatencyTimecode.encode(value)
        for i in 0 ..< LatencyProbeStamp.cellCount {
            guard let white = LatencyProbeStamp.cellIsWhite(i, bits: bits) else { continue }
            let v: UInt8 = white ? 235 : 16
            for x in (i * cellW) ..< ((i + 1) * cellW) where x < width {
                for y in 0 ..< min(LatencyProbeStamp.cellH, height) {
                    luma[y * width + x] = v
                }
            }
        }
        return luma
    }

    func testRoundTripsAtNativeCellWidth() {
        let w = LatencyProbeStamp.cellCount * 16 + 40
        let luma = paint(value: 0xDEAD_BEEF, cellW: 16, width: w, height: 40)
        XCTAssertEqual(ViewerStampDecode.read(luma: luma, width: w, height: 40, rowBytes: w), 0xDEAD_BEEF)
    }

    /// The decoder self-calibrates cell width, which is what makes it survive WebRTC rescaling.
    func testRoundTripsAtRescaledCellWidths() {
        for cellW in [4, 7, 8, 11, 16, 24] {
            let w = LatencyProbeStamp.cellCount * cellW + 20
            let luma = paint(value: 0x0123_4567, cellW: cellW, width: w, height: 40)
            XCTAssertEqual(ViewerStampDecode.read(luma: luma, width: w, height: 40, rowBytes: w),
                           0x0123_4567, "cellW=\(cellW)")
        }
    }

    func testZeroAndMaxValues() {
        let w = LatencyProbeStamp.cellCount * 16 + 40
        for v: UInt32 in [0, 1, 0xFFFF_FFFF] {
            let luma = paint(value: v, cellW: 16, width: w, height: 40)
            XCTAssertEqual(ViewerStampDecode.read(luma: luma, width: w, height: 40, rowBytes: w), v)
        }
    }

    func testUnstampedFrameReturnsNil() {
        let luma = [UInt8](repeating: 128, count: 640 * 40)
        XCTAssertNil(ViewerStampDecode.read(luma: luma, width: 640, height: 40, rowBytes: 640))
    }

    /// LOAD-BEARING. LatencyProbeStamp.fits documents that a partial stamp decodes as a
    /// PLAUSIBLE WRONG timestamp, which is worse than no reading. A truncated frame must
    /// therefore be rejected, not sampled — i.e. `read()` must honour the DECLARED `width`
    /// and never read cell geometry past it, no matter what bytes happen to sit there.
    ///
    /// This must discriminate a removed guard, not merely happen to pass with one. A single
    /// hand-picked (value, width) can pass by accident: e.g. at cellW=16 with rowBytes==width
    /// (no padding), an out-of-range read wraps into a LATER ROW of the row-major buffer, and
    /// for some values that wrapped read happens to still fail the end-finder check even with
    /// the guard gone — which is exactly how the original version of this test passed against
    /// a decoder with the guard deleted. To close that hole for good, the buffer here is
    /// padded (`rowBytes == full`, well past every truncated `width` tried) with the COMPLETE,
    /// correctly painted stamp — so an out-of-range read is never wraparound noise, it is
    /// always well-defined data for the very value under test (the realistic version of this:
    /// a reused `CVPixelBufferPool` whose padding still holds a previous, larger frame's
    /// stamp). With the `fits` guard in place `width` alone must reject every one of these
    /// regardless of what lives past it; with the guard removed, decode succeeds and returns
    /// the fully-painted value EVERY time, for every value and every width below — no accident
    /// of any single case can rescue the assertion.
    func testTruncatedStampReturnsNil() {
        let cellW = 16
        let full = LatencyProbeStamp.cellCount * cellW
        let height = 40
        let values: [UInt32] = [0xDEAD_BEEF, 0x0002_0000, 0, 0xFFFF_FFFF, 0x1234_5678, 0x8000_0001]
        // Several truncation widths, each still wide enough for calibration to see both the
        // black (cell 0) and white (cell 1) reference cells, but too narrow for the CENTER of
        // the last cell (index cellCount-1) — i.e. genuinely below the guard's own boundary.
        // (The boundary is centerX(cellCount-1) == ((cellCount-0.5)*cellW).rounded() == 568 for
        // cellCount=36/cellW=16: only widths <= 568 are truly truncated by `fits`'s own math —
        // a width of, say, 575 legitimately still "fits" since only cell centers are sampled.)
        let boundary = Int(((Double(LatencyProbeStamp.cellCount) - 0.5) * Double(cellW)).rounded())
        let truncatedWidths = [cellW * 2 + 1, cellW * 3, full / 2, full - cellW, boundary]
        for value in values {
            // The FULL, correctly painted stamp — rowBytes covers it even though `width` (below)
            // claims less.
            let luma = paint(value: value, cellW: cellW, width: full, height: height)
            for w in truncatedWidths {
                XCTAssertNil(
                    ViewerStampDecode.read(luma: luma, width: w, height: height, rowBytes: full),
                    "value=0x\(String(value, radix: 16)) width=\(w) (full=\(full)) must be rejected as truncated"
                )
            }
        }
    }

    func testRowBytesPaddingIsHonoured() {
        let w = LatencyProbeStamp.cellCount * 16 + 40
        let rowBytes = w + 64                                  // CVPixelBuffer padding
        var padded = [UInt8](repeating: 0, count: rowBytes * 40)
        let luma = paint(value: 0x1234_5678, cellW: 16, width: w, height: 40)
        for y in 0 ..< 40 {
            for x in 0 ..< w { padded[y * rowBytes + x] = luma[y * w + x] }
        }
        XCTAssertEqual(ViewerStampDecode.read(luma: padded, width: w, height: 40, rowBytes: rowBytes),
                       0x1234_5678)
    }

    func testDegenerateInputs() {
        XCTAssertNil(ViewerStampDecode.read(luma: [], width: 0, height: 0, rowBytes: 0))
        XCTAssertNil(ViewerStampDecode.read(luma: [1, 2, 3], width: 3, height: 1, rowBytes: 3))
    }
}
