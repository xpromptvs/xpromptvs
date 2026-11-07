import Foundation

/// The "nothing here yet" fill for the part of a frame outside the viewer's crop.
///
/// WHY IT IS A PATTERN AND NOT BLACK. Black reads as a broken stream or a black window; a
/// checkerboard reads as absence, which is what it is. The viewer pans, the leading edge shows this
/// for about a second, and then it fills in.
///
/// COARSE, DARK AND LOW-CONTRAST ON PURPOSE. It is re-encoded in EVERY keyframe, and rdev runs an
/// infinite GOP whose keyframes are driven by receiver requests — so a fine or high-contrast pattern
/// costs an unbounded, irregular amount rather than a predictable one. Between keyframes it is
/// static and therefore free, which is the other half of why the masked area costs nothing.
///
/// PURE — pointers and strides, no CoreVideo. That is what lets it be tested against plain arrays.
public enum Checkerboard {
    /// Square size in luma pixels. Large enough that the pattern is cheap and unmistakably not content.
    public static let squarePx = 64
    /// Video-range luma: legal range starts at 16, and both values sit near the bottom of it.
    public static let darkY: UInt8 = 24
    public static let lightY: UInt8 = 40
    /// Neutral CbCr. Anything else tints the whole masked area.
    public static let neutralChroma: UInt8 = 128

    /// Fill an NV12 plane pair with the pattern. Writes EVERY pixel of both planes, including the
    /// area the crop will immediately overwrite — the caller converts the crop over the top in the
    /// same call, so no frame is ever emitted with the pattern on the visible region, and a painter
    /// with one job is a painter that can be tested.
    public static func paintNV12(y: UnsafeMutableRawPointer, yStride: Int,
                                 cbCr: UnsafeMutableRawPointer, cStride: Int,
                                 width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let yp = y.assumingMemoryBound(to: UInt8.self)
        for row in 0 ..< height {
            let band = (row / squarePx) & 1
            let base = yp + row * yStride
            for col in 0 ..< width {
                base[col] = ((col / squarePx) & 1) == band ? darkY : lightY
            }
        }
        // ONE CHROMA ROW PER TWO LUMA ROWS, one byte per luma COLUMN. `memset` rather than a loop:
        // the value is uniform, and this is the larger of the two writes on a wide frame.
        let cp = cbCr.assumingMemoryBound(to: UInt8.self)
        for row in 0 ..< (height / 2) {
            memset(cp + row * cStride, Int32(neutralChroma), width)
        }
    }
}
