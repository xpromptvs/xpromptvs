import Foundation

/// The sub-rectangle of a source the viewer can actually see, as the client asks for it: fractions
/// of the source's own size, so it survives every resolution change without renegotiation.
///
/// WHY A CROP EXISTS AT ALL. At 3.4x zoom on a phone the viewer sees about a tenth of the window and
/// the encoder pays full price for the other nine tenths. Masking the rest does not shrink the
/// stream — the bitrate target is unchanged — it MOVES those bits to the part being looked at.
///
/// THE ENCODED FRAME'S GEOMETRY NEVER CHANGES. It always represents the whole window; only what is
/// drawn inside it varies. That is forced rather than chosen: `metadataExtensionID == 0` on every
/// browser session (Chrome drops `urn:llv:rtp-frame-metadata:1`), so there is no frame-accurate
/// channel to tell the client which crop a frame carries. See
/// `docs/superpowers/specs/2026-09-07-crop-aware-encoding-design.md`.
public struct CropRect: Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    /// The whole source, and the DEFAULT for anything nothing has ever told. A client that never
    /// sends a crop therefore keeps exactly today's behaviour.
    public static let full = CropRect(x: 0, y: 0, w: 1, h: 1)

    public var isFull: Bool { x <= 0 && y <= 0 && x + w >= 1 && y + h >= 1 }

    /// The crop in FRAME pixels, or nil for "no mask at all".
    ///
    /// ROUNDING IS OUTWARD ON ALL FOUR EDGES, and to EVEN. 4:2:0 has no chroma sample for an odd row
    /// or column, so the rect must be even-aligned; and rounding inward would mask a strip the viewer
    /// can see, putting checkerboard INSIDE the viewport. Outward can only ever encode a sliver more.
    ///
    /// NIL RATHER THAN A FULL-COVERING RECT is what keeps the normal path exactly today's code: the
    /// caller branches on nil and never paints, never offsets, never pays anything.
    public func pixels(frameWidth: Int, frameHeight: Int) -> CropPixels? {
        guard frameWidth > 0, frameHeight > 0, w > 0, h > 0 else { return nil }
        let x0 = Int((x * Double(frameWidth)).rounded(.down)) & ~1
        let y0 = Int((y * Double(frameHeight)).rounded(.down)) & ~1
        let x1 = (Int(((x + w) * Double(frameWidth)).rounded(.up)) + 1) & ~1
        let y1 = (Int(((y + h) * Double(frameHeight)).rounded(.up)) + 1) & ~1
        let cx = min(max(0, x0), frameWidth), cy = min(max(0, y0), frameHeight)
        let cw = min(max(0, x1), frameWidth) - cx, ch = min(max(0, y1), frameHeight) - cy
        guard cw > 0, ch > 0 else { return nil }
        // Covers the frame: nothing to mask, so say so rather than returning a crop the caller would
        // paint a zero-area border around.
        if cx == 0, cy == 0, cw == frameWidth, ch == frameHeight { return nil }
        return CropPixels(x: cx, y: cy, w: cw, h: ch)
    }
}

/// A crop resolved against a frame: even-aligned, clamped, guaranteed non-empty and never the whole
/// frame (`CropRect.pixels` returns nil for both of those).
public struct CropPixels: Equatable {
    public var x: Int, y: Int, w: Int, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }

    /// Byte offsets to the crop's top-left corner in a BGRA source and in an NV12 destination pair.
    ///
    /// THE CHROMA ROW HALVES AND THE COLUMN DOES NOT. NV12's CbCr plane carries one row per TWO luma
    /// rows, but one byte per luma COLUMN (a Cb,Cr pair covers two columns). Halving the column too
    /// is the natural mistake and it shears the colour off the picture while the luma stays right —
    /// which reads as a tinting bug rather than an offset bug, and is why this is its own function
    /// with its own test.
    public func offsets(srcStride: Int, yStride: Int, cStride: Int) -> CropOffsets {
        CropOffsets(srcByteOffset: y * srcStride + x * 4,
                    yByteOffset: y * yStride + x,
                    cbCrByteOffset: (y / 2) * cStride + x,
                    width: w, height: h)
    }
}

public struct CropOffsets: Equatable {
    public var srcByteOffset: Int
    public var yByteOffset: Int
    public var cbCrByteOffset: Int
    public var width: Int
    public var height: Int
}
