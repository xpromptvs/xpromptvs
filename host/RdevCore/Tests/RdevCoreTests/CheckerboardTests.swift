import XCTest
@testable import RdevCore

final class CheckerboardTests: XCTestCase {
    /// Paint into over-wide planes so the stride is genuinely larger than the width, and pre-fill
    /// with a sentinel so a row-overrun is visible.
    private func paint(width: Int, height: Int, yStride: Int, cStride: Int)
        -> (y: [UInt8], cbCr: [UInt8]) {
        var y = [UInt8](repeating: 0xAA, count: yStride * height)
        var cbCr = [UInt8](repeating: 0xAA, count: cStride * (height / 2))
        y.withUnsafeMutableBytes { yb in
            cbCr.withUnsafeMutableBytes { cb in
                Checkerboard.paintNV12(y: yb.baseAddress!, yStride: yStride,
                                       cbCr: cb.baseAddress!, cStride: cStride,
                                       width: width, height: height)
            }
        }
        return (y, cbCr)
    }

    func testSquaresAlternateOnBothAxes() {
        let s = Checkerboard.squarePx
        let (y, _) = paint(width: s * 4, height: s * 2, yStride: s * 4, cStride: s * 4)
        let at = { (col: Int, row: Int) in y[row * s * 4 + col] }
        XCTAssertEqual(at(0, 0), Checkerboard.darkY)
        XCTAssertEqual(at(s, 0), Checkerboard.lightY)          // next square across
        XCTAssertEqual(at(s * 2, 0), Checkerboard.darkY)       // and back
        XCTAssertEqual(at(0, s), Checkerboard.lightY)          // next square down flips the parity
        XCTAssertEqual(at(s, s), Checkerboard.darkY)
    }

    /// THE PATTERN IS LOW-CONTRAST AND DARK ON PURPOSE. It is re-encoded in EVERY keyframe, and rdev
    /// runs an infinite GOP with keyframes driven by receiver requests — so the cost is unbounded and
    /// irregular rather than periodic. It only has to read as "nothing here yet".
    func testThePatternIsDarkAndLowContrast() {
        XCTAssertLessThan(Int(Checkerboard.lightY), 64)
        XCTAssertLessThan(Int(Checkerboard.lightY) - Int(Checkerboard.darkY), 32)
        // Video range starts at 16; below it is illegal luma, not "darker".
        XCTAssertGreaterThanOrEqual(Int(Checkerboard.darkY), 16)
    }

    func testChromaIsNeutralEverywhere() {
        let (_, cbCr) = paint(width: 128, height: 64, yStride: 128, cStride: 128)
        for row in 0 ..< 32 {
            for col in 0 ..< 128 {
                XCTAssertEqual(cbCr[row * 128 + col], Checkerboard.neutralChroma,
                               "chroma at \(col),\(row) must be neutral or the mask is tinted")
            }
        }
    }

    /// STRIDE IS NOT WIDTH. CoreVideo pads plane rows to its own alignment, so writing `width` bytes
    /// per row into a buffer whose `bytesPerRow` is larger shears the image diagonally — the same
    /// trap `ColorConvert.bgraToNV12` documents. The sentinel past the width must survive.
    func testItRespectsStrideAndNeverWritesPastTheWidth() {
        let width = 128, height = 64, yStride = 200, cStride = 200
        let (y, cbCr) = paint(width: width, height: height, yStride: yStride, cStride: cStride)
        for row in 0 ..< height {
            XCTAssertEqual(y[row * yStride + width], 0xAA, "luma row \(row) overran its width")
        }
        for row in 0 ..< (height / 2) {
            XCTAssertEqual(cbCr[row * cStride + width], 0xAA, "chroma row \(row) overran its width")
        }
    }
}
