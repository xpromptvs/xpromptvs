import Accelerate
import XCTest
@testable import RdevCore

final class ColorConvertTests: XCTestCase {
    func testSolidBlueToI420ChannelOrder() {
        let w = 16, h = 16, stride = w * 4
        var bgra = [UInt8](repeating: 0, count: stride * h)
        // BGRA solid blue: B=255, G=0, R=0, A=255
        for p in 0 ..< (w * h) {
            bgra[p * 4 + 0] = 255 // B
            bgra[p * 4 + 1] = 0   // G
            bgra[p * 4 + 2] = 0   // R
            bgra[p * 4 + 3] = 255 // A
        }
        let out = bgra.withUnsafeBufferPointer {
            ColorConvert.bgraToI420($0.baseAddress!, width: w, height: h, srcStride: stride)
        }
        XCTAssertEqual(out.width, w)
        XCTAssertEqual(out.height, h)
        XCTAssertEqual(out.y.count, out.yStride * h)
        XCTAssertEqual(out.cb.count, out.cStride * (h / 2))
        // Pure blue (BT.709 video range): low luma, high Cb, moderate/low Cr.
        let yMid = Int(out.y[out.yStride * (h / 2) + w / 2])
        let cbMid = Int(out.cb[out.cStride * (h / 4) + w / 4])
        let crMid = Int(out.cr[out.cStride * (h / 4) + w / 4])
        XCTAssertLessThan(yMid, 80, "blue luma should be low, got \(yMid)")
        XCTAssertGreaterThan(cbMid, 180, "blue Cb should be high, got \(cbMid)")
        XCTAssertLessThan(crMid, 160, "blue Cr should not be high, got \(crMid)")
    }

    /// Pins the conversion to BT.709. Pure red's video-range luma is 16 + 219*0.2126 ≈ 63 under 709 and
    /// 16 + 219*0.299 ≈ 82 under 601 — nearly 20 apart, so this test tells the two matrices apart. It
    /// matters because an untagged/mismatched stream makes the decoder guess by RESOLUTION, which is how
    /// colour ends up shifting as the scale changes mid-session (the bug fixed on the VideoToolbox path).
    func testRedLumaPinsBT709() {
        let w = 16, h = 16, stride = w * 4
        var bgra = [UInt8](repeating: 0, count: stride * h)
        for p in 0 ..< (w * h) {
            bgra[p * 4 + 0] = 0   // B
            bgra[p * 4 + 1] = 0   // G
            bgra[p * 4 + 2] = 255 // R
            bgra[p * 4 + 3] = 255 // A
        }
        let out = bgra.withUnsafeBufferPointer {
            ColorConvert.bgraToI420($0.baseAddress!, width: w, height: h, srcStride: stride)
        }
        let yMid = Int(out.y[out.yStride * (h / 2) + w / 2])
        XCTAssertEqual(yMid, 63, accuracy: 2, "BT.709 red luma should be ~63 (BT.601 would be ~82), got \(yMid)")
    }

    /// The into-caller-memory variant must agree with the array-returning one byte for byte — they share
    /// one implementation, and this is what keeps the existing conversion coverage meaningful for the
    /// AV1 path, which only ever calls the pointer form.
    func testIntoBufferMatchesArrayForm() {
        let w = 16, h = 16, stride = w * 4
        var bgra = [UInt8](repeating: 0, count: stride * h)
        for i in 0 ..< bgra.count { bgra[i] = UInt8((i * 7) & 0xff) }
        let expected = bgra.withUnsafeBufferPointer {
            ColorConvert.bgraToI420($0.baseAddress!, width: w, height: h, srcStride: stride)
        }
        let ySize = w * h, cSize = (w / 2) * (h / 2)
        let planes = UnsafeMutablePointer<UInt8>.allocate(capacity: ySize + 2 * cSize)
        defer { planes.deallocate() }
        bgra.withUnsafeBufferPointer {
            ColorConvert.bgraToI420($0.baseAddress!, width: w, height: h, srcStride: stride,
                                    y: planes, cb: planes + ySize, cr: planes + ySize + cSize)
        }
        XCTAssertEqual(Array(UnsafeBufferPointer(start: planes, count: ySize)), expected.y)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: planes + ySize, count: cSize)), expected.cb)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: planes + ySize + cSize, count: cSize)), expected.cr)
    }

    /// NV12 must agree with I420 on luma and carry the same chroma, just interleaved. The two use
    /// SEPARATE generated vImage conversions (the destination layout is baked into the conversion
    /// object), so nothing but a test proves the NV12 one was generated with the same matrix — and a
    /// wrong one is a silent colour shift, never a build error.
    func testNV12AgreesWithI420() {
        let w = 16, h = 16, stride = w * 4
        var bgra = [UInt8](repeating: 0, count: stride * h)
        for i in 0 ..< bgra.count { bgra[i] = UInt8((i * 7) & 0xff) }
        let expected = bgra.withUnsafeBufferPointer {
            ColorConvert.bgraToI420($0.baseAddress!, width: w, height: h, srcStride: stride)
        }
        var y = [UInt8](repeating: 0, count: w * h)
        var cbCr = [UInt8](repeating: 0, count: w * (h / 2))
        y.withUnsafeMutableBytes { yp in
        cbCr.withUnsafeMutableBytes { cp in
            bgra.withUnsafeBufferPointer {
                ColorConvert.bgraToNV12($0.baseAddress!, width: w, height: h, srcStride: stride,
                                        y: yp.baseAddress!, yStride: w,
                                        cbCr: cp.baseAddress!, cStride: w)
            }
        }}
        XCTAssertEqual(y, expected.y, "NV12 luma must match the I420 luma byte for byte")
        let cw = w / 2, ch = h / 2
        var cb = [UInt8](), cr = [UInt8]()
        for row in 0 ..< ch {
            for col in 0 ..< cw {
                cb.append(cbCr[row * w + col * 2])
                cr.append(cbCr[row * w + col * 2 + 1])
            }
        }
        XCTAssertEqual(cb, expected.cb, "NV12 even bytes must be Cb")
        XCTAssertEqual(cr, expected.cr, "NV12 odd bytes must be Cr")
    }

    /// The strides are honoured, not assumed tight. The NV12 destination is a `CVPixelBuffer` whose
    /// rows CoreVideo pads to its own alignment, so writing `width` bytes per row into a plane with a
    /// larger `bytesPerRow` shears the picture diagonally — visible as a skewed image, not a crash.
    func testNV12HonoursPaddedStrides() {
        let w = 16, h = 16, stride = w * 4
        var bgra = [UInt8](repeating: 0, count: stride * h)
        for i in 0 ..< bgra.count { bgra[i] = UInt8((i * 11) & 0xff) }
        let pad = 32
        let yStride = w + pad, cStride = w + pad
        var y = [UInt8](repeating: 0xAA, count: yStride * h)
        var cbCr = [UInt8](repeating: 0xAA, count: cStride * (h / 2))
        y.withUnsafeMutableBytes { yp in
        cbCr.withUnsafeMutableBytes { cp in
            bgra.withUnsafeBufferPointer {
                ColorConvert.bgraToNV12($0.baseAddress!, width: w, height: h, srcStride: stride,
                                        y: yp.baseAddress!, yStride: yStride,
                                        cbCr: cp.baseAddress!, cStride: cStride)
            }
        }}
        var tight = [UInt8](repeating: 0, count: w * h)
        var tightC = [UInt8](repeating: 0, count: w * (h / 2))
        tight.withUnsafeMutableBytes { yp in
        tightC.withUnsafeMutableBytes { cp in
            bgra.withUnsafeBufferPointer {
                ColorConvert.bgraToNV12($0.baseAddress!, width: w, height: h, srcStride: stride,
                                        y: yp.baseAddress!, yStride: w,
                                        cbCr: cp.baseAddress!, cStride: w)
            }
        }}
        for row in 0 ..< h {
            XCTAssertEqual(Array(y[row * yStride ..< row * yStride + w]),
                           Array(tight[row * w ..< row * w + w]), "luma row \(row)")
            // The padding must be untouched — a routine that ignored the stride would have written here.
            XCTAssertEqual(Array(y[row * yStride + w ..< (row + 1) * yStride]),
                           [UInt8](repeating: 0xAA, count: pad), "luma padding row \(row)")
        }
        for row in 0 ..< (h / 2) {
            XCTAssertEqual(Array(cbCr[row * cStride ..< row * cStride + w]),
                           Array(tightC[row * w ..< row * w + w]), "chroma row \(row)")
        }
    }

    /// Pins the NV12 path to BT.709 on its own, independent of the I420 comparison above: red's
    /// video-range luma is ~63 under 709 and ~82 under 601. If the two conversions were ever
    /// regenerated separately, this is the one that catches the NV12 half drifting.
    func testNV12RedLumaPinsBT709() {
        let w = 16, h = 16, stride = w * 4
        var bgra = [UInt8](repeating: 0, count: stride * h)
        for p in 0 ..< (w * h) {
            bgra[p * 4 + 2] = 255 // R
            bgra[p * 4 + 3] = 255 // A
        }
        var y = [UInt8](repeating: 0, count: w * h)
        var cbCr = [UInt8](repeating: 0, count: w * (h / 2))
        y.withUnsafeMutableBytes { yp in
        cbCr.withUnsafeMutableBytes { cp in
            bgra.withUnsafeBufferPointer {
                ColorConvert.bgraToNV12($0.baseAddress!, width: w, height: h, srcStride: stride,
                                        y: yp.baseAddress!, yStride: w,
                                        cbCr: cp.baseAddress!, cStride: w)
            }
        }}
        XCTAssertEqual(Int(y[w * (h / 2) + w / 2]), 63, accuracy: 2,
                       "BT.709 red luma should be ~63 (BT.601 would be ~82)")
    }

    /// The conversion REPORTS success or failure, and the caller is expected to act on it. A refused
    /// conversion writes nothing, and the encoder reuses one staging buffer per resolution — so a
    /// discarded status re-encodes the previous frame's pixels and the stream looks alive while being
    /// frozen. This pins the success value; the adapter's job is to check it.
    func testNV12ReturnsSuccessStatus() {
        let w = 16, h = 16, stride = w * 4
        let bgra = [UInt8](repeating: 128, count: stride * h)
        var y = [UInt8](repeating: 0, count: w * h)
        var cbCr = [UInt8](repeating: 0, count: w * (h / 2))
        var err: vImage_Error = -1
        y.withUnsafeMutableBytes { yp in
        cbCr.withUnsafeMutableBytes { cp in
            bgra.withUnsafeBufferPointer {
                err = ColorConvert.bgraToNV12($0.baseAddress!, width: w, height: h, srcStride: stride,
                                              y: yp.baseAddress!, yStride: w,
                                              cbCr: cp.baseAddress!, cStride: w)
            }
        }}
        XCTAssertEqual(err, kvImageNoError)
    }

    /// The downscale path that keeps an oversized window streaming at all (see `EncodeDimensions`).
    /// A flat field must survive a resample as the same flat field — which is the cheapest assertion
    /// that catches a wrong stride, a wrong channel count, or a buffer the routine refused to touch.
    func testScaleBGRAPreservesAFlatFieldAndReportsSuccess() {
        let sw = 64, sh = 64, sStride = sw * 4
        let dw = 32, dh = 32, dStride = dw * 4
        var src = [UInt8](repeating: 0, count: sStride * sh)
        for p in 0 ..< (sw * sh) {
            src[p * 4 + 0] = 10; src[p * 4 + 1] = 20; src[p * 4 + 2] = 30; src[p * 4 + 3] = 255
        }
        var dst = [UInt8](repeating: 0, count: dStride * dh)
        var err: vImage_Error = -1
        dst.withUnsafeMutableBytes { dp in
            src.withUnsafeBufferPointer {
                err = ColorConvert.scaleBGRA($0.baseAddress!, width: sw, height: sh, srcStride: sStride,
                                             dst: dp.baseAddress!, dstWidth: dw, dstHeight: dh,
                                             dstStride: dStride)
            }
        }
        XCTAssertEqual(err, kvImageNoError)
        // Interior pixels only: a resampler's edge kernel legitimately differs at the border.
        for row in 4 ..< (dh - 4) {
            for col in 4 ..< (dw - 4) {
                let p = row * dStride + col * 4
                XCTAssertEqual(Int(dst[p + 0]), 10, "B at \(col),\(row)")
                XCTAssertEqual(Int(dst[p + 1]), 20, "G at \(col),\(row)")
                XCTAssertEqual(Int(dst[p + 2]), 30, "R at \(col),\(row)")
            }
        }
    }

    /// Scale then convert is the full clamp path, and its output must still be BT.709 — a resample
    /// that dropped or reordered a channel would show up as a different luma, which the flat-field
    /// test above cannot see (it is grey-ish and every matrix agrees on grey).
    func testScaledThenConvertedRedStillPinsBT709() {
        let sw = 64, sh = 64, sStride = sw * 4
        let dw = 32, dh = 32, dStride = dw * 4
        var src = [UInt8](repeating: 0, count: sStride * sh)
        for p in 0 ..< (sw * sh) { src[p * 4 + 2] = 255; src[p * 4 + 3] = 255 }   // R, A
        var mid = [UInt8](repeating: 0, count: dStride * dh)
        mid.withUnsafeMutableBytes { dp in
            src.withUnsafeBufferPointer {
                ColorConvert.scaleBGRA($0.baseAddress!, width: sw, height: sh, srcStride: sStride,
                                       dst: dp.baseAddress!, dstWidth: dw, dstHeight: dh,
                                       dstStride: dStride)
            }
        }
        var y = [UInt8](repeating: 0, count: dw * dh)
        var cbCr = [UInt8](repeating: 0, count: dw * (dh / 2))
        y.withUnsafeMutableBytes { yp in
        cbCr.withUnsafeMutableBytes { cp in
            mid.withUnsafeBufferPointer {
                ColorConvert.bgraToNV12($0.baseAddress!, width: dw, height: dh, srcStride: dStride,
                                        y: yp.baseAddress!, yStride: dw,
                                        cbCr: cp.baseAddress!, cStride: dw)
            }
        }}
        XCTAssertEqual(Int(y[dw * (dh / 2) + dw / 2]), 63, accuracy: 2,
                       "scaled-then-converted red must still be BT.709 ~63")
    }
}
