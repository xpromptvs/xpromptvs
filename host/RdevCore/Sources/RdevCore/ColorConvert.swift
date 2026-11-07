@preconcurrency import Accelerate

/// Planar I420 (YUV 4:2:0) output of a color conversion. Y is width×height; Cb/Cr are
/// (width/2)×(height/2). Strides may exceed the plane width (row padding).
public struct I420Buffers {
    public var y: [UInt8]
    public var cb: [UInt8]
    public var cr: [UInt8]
    public var yStride: Int
    public var cStride: Int
    public var width: Int
    public var height: Int
}

/// BGRA → YUV 4:2:0 conversion (Accelerate/vImage), BT.709 video range, in two plane layouts.
///
/// I420 (three planes) feeds the Go SVT-AV1 encoder; NV12 (two planes, interleaved CbCr) feeds
/// LLV's libaom encoder, which takes a `CVPixelBuffer` and accepts ONLY
/// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`. VideoToolbox took BGRA directly; neither
/// software encoder does, and rdev's capture is `kCVPixelFormatType_32BGRA` throughout
/// (`ScreenCaptureSource.makeConfig`, `FrameOverlaySink`, `TestPatternSource`).
public enum ColorConvert {
    // Build the ARGB→YpCbCr conversion once (video range, ITU-R 709 — matches what the VideoToolbox
    // path tags, so both codec paths signal the same colour). Reused across calls.
    nonisolated(unsafe) private static var info: vImage_ARGBToYpCbCr = {
        var i = vImage_ARGBToYpCbCr()
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        _ = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &pixelRange, &i,
            kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags))
        return i
    }()

    // The SAME matrix and pixel range, generated for the two-plane (NV12) output format. vImage keys
    // the generated conversion on the destination layout, so the I420 `info` above cannot be reused
    // here — passing it to the NV12 routine is not a compile error, which is exactly why this is a
    // separate stored value rather than a shared one.
    nonisolated(unsafe) private static var nv12Info: vImage_ARGBToYpCbCr = {
        var i = vImage_ARGBToYpCbCr()
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        _ = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &pixelRange, &i,
            kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        return i
    }()

    /// Convert a BGRA buffer into CALLER-OWNED NV12 planes: `y` is `height` rows of `width` bytes at
    /// `yStride`, `cbCr` is `height/2` rows of `width` bytes (w/2 interleaved Cb,Cr pairs) at `cStride`.
    /// `width` and `height` must be even. Returns vImage's status — `kvImageNoError` on success.
    ///
    /// **The status is RETURNED, not discarded.** A refused conversion writes nothing, and the caller
    /// reuses one staging buffer per resolution, so swallowing the error re-encodes the PREVIOUS
    /// frame's pixels — a stream that looks alive and is frozen, which is this codebase's signature
    /// failure. (`bgraToI420` above still discards its own; that is pre-existing on a path this
    /// encoder no longer uses.)
    ///
    /// Strides are parameters rather than assumed tight because the destination is a `CVPixelBuffer`
    /// the encoder owns, and CoreVideo pads plane rows to its own alignment — writing `width` bytes
    /// per row into a buffer whose `bytesPerRow` is larger shears the image diagonally.
    @discardableResult
    public static func bgraToNV12(_ bgra: UnsafePointer<UInt8>, width: Int, height: Int, srcStride: Int,
                                  y: UnsafeMutableRawPointer, yStride: Int,
                                  cbCr: UnsafeMutableRawPointer, cStride: Int) -> vImage_Error {
        // vImage reads ARGB; our source is BGRA. permuteMap maps ARGB channel positions to source
        // byte indices: A←3, R←2, G←1, B←0.
        let permuteMap: [UInt8] = [3, 2, 1, 0]
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bgra),
                                height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: srcStride)
        var yb = vImage_Buffer(data: y, height: vImagePixelCount(height),
                               width: vImagePixelCount(width), rowBytes: yStride)
        // MEASURED, not assumed: `vImageConvert_ARGB8888To420Yp8_CbCr8` IGNORES the CbCr buffer's
        // `width` field — passing `width` or `width/2` gives byte-identical output with no overrun,
        // so it derives the chroma extent from the source instead. `width` is passed because it is
        // the plane's extent in BYTES, which is the reading a later editor is most likely to need;
        // `rowBytes` is the field that actually matters and it is honoured.
        var cb = vImage_Buffer(data: cbCr, height: vImagePixelCount(height / 2),
                               width: vImagePixelCount(width), rowBytes: cStride)
        return vImageConvert_ARGB8888To420Yp8_CbCr8(&src, &yb, &cb, &nv12Info, permuteMap,
                                                    vImage_Flags(kvImageNoFlags))
    }

    /// Resample a BGRA buffer into a caller-owned BGRA buffer of a different size (Lanczos, vImage's
    /// default for `vImageScale_ARGB8888`). Channel-order agnostic — it moves 4-byte pixels around
    /// and never interprets them — so BGRA in gives BGRA out with no permute needed.
    ///
    /// Used ONLY when a frame does not fit the encoder's dimension limits, which is why it is a
    /// separate pass rather than folded into the conversion: the overwhelmingly common case must pay
    /// nothing for a clamp that is not happening.
    @discardableResult
    public static func scaleBGRA(_ src: UnsafePointer<UInt8>, width: Int, height: Int, srcStride: Int,
                                 dst: UnsafeMutableRawPointer, dstWidth: Int, dstHeight: Int,
                                 dstStride: Int) -> vImage_Error {
        var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src),
                              height: vImagePixelCount(height), width: vImagePixelCount(width),
                              rowBytes: srcStride)
        var d = vImage_Buffer(data: dst, height: vImagePixelCount(dstHeight),
                              width: vImagePixelCount(dstWidth), rowBytes: dstStride)
        return vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
    }

    /// Convert a BGRA buffer (`width`×`height`, `srcStride` bytes/row) to tightly-packed I420.
    /// `width` and `height` must be even.
    public static func bgraToI420(_ bgra: UnsafePointer<UInt8>, width: Int, height: Int, srcStride: Int) -> I420Buffers {
        let cw = width / 2, ch = height / 2
        var y = [UInt8](repeating: 0, count: width * height)
        var cb = [UInt8](repeating: 0, count: cw * ch)
        var cr = [UInt8](repeating: 0, count: cw * ch)
        y.withUnsafeMutableBufferPointer { yp in
        cb.withUnsafeMutableBufferPointer { cbp in
        cr.withUnsafeMutableBufferPointer { crp in
            bgraToI420(bgra, width: width, height: height, srcStride: srcStride,
                       y: yp.baseAddress!, cb: cbp.baseAddress!, cr: crp.baseAddress!)
        }}}
        return I420Buffers(y: y, cb: cb, cr: cr, yStride: width, cStride: cw, width: width, height: height)
    }

    /// Convert into CALLER-OWNED, tightly-packed planes: `y` is `width*height`, `cb`/`cr` are each
    /// `(width/2)*(height/2)`. `width` and `height` must be even.
    ///
    /// This exists so a per-frame encoder does not allocate. The array-returning form above builds three
    /// fresh `[UInt8]`s per call — malloc PLUS a zero-fill that vImage immediately overwrites, ~660 KB a
    /// frame at 816×538, i.e. ~40 MB/s of pointless writes at 60 fps. AV1Encoder keeps one buffer for the
    /// life of a resolution and calls this.
    public static func bgraToI420(_ bgra: UnsafePointer<UInt8>, width: Int, height: Int, srcStride: Int,
                                  y: UnsafeMutablePointer<UInt8>,
                                  cb: UnsafeMutablePointer<UInt8>,
                                  cr: UnsafeMutablePointer<UInt8>) {
        let cw = width / 2, ch = height / 2
        // vImage reads ARGB; our source is BGRA. permuteMap maps ARGB channel positions to source
        // byte indices: A←3, R←2, G←1, B←0.
        let permuteMap: [UInt8] = [3, 2, 1, 0]
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bgra),
                                height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: srcStride)
        var yb = vImage_Buffer(data: y, height: vImagePixelCount(height),
                               width: vImagePixelCount(width), rowBytes: width)
        var cbb = vImage_Buffer(data: cb, height: vImagePixelCount(ch),
                                width: vImagePixelCount(cw), rowBytes: cw)
        var crb = vImage_Buffer(data: cr, height: vImagePixelCount(ch),
                                width: vImagePixelCount(cw), rowBytes: cw)
        _ = vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&src, &yb, &cbb, &crb, &info, permuteMap,
                                                    vImage_Flags(kvImageNoFlags))
    }
}
