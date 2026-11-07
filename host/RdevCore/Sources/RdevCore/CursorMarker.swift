// host/RdevCore/Sources/RdevCore/CursorMarker.swift

/// Geometry and colour for the debug cursor rectangle (`RDEV_CURSOR_OVERLAY=1`), composited into
/// the video just before encode by `FrameOverlaySink`.
///
/// Pure so it can be tested: RdevHostKit has no test target, and this is the part that is easy to
/// get subtly wrong (edge clamping, and which colour means what).
public enum CursorMarker {
    /// Side length in EMITTED-FRAME pixels — not half-extent. Under `Auto` resolution the emitted
    /// frame tracks what the window paints, so this lands at roughly a constant ~24 CSS px on
    /// screen; pin the resolution to 25% and it appears four times larger.
    public static let sizePx = 48

    /// BGRA fill. Red normally, green while pressed. The two differ in LUMA (76 vs 150), not only
    /// in hue — chroma is 4:2:0-subsampled and heavily quantized at 2 Mbps, so a hue-only
    /// difference could smear away at exactly the transition being measured.
    public static func colorBGRA(pressed: Bool) -> (b: UInt8, g: UInt8, r: UInt8) {
        pressed ? (0, 255, 0) : (0, 0, 255)
    }

    /// The half-open pixel rect `[x0, x1) x [y0, y1)` to fill for a normalized position, CLIPPED to
    /// the frame. nil when the frame is degenerate.
    ///
    /// Clipped rather than shifted: half a square at the edge is the honest rendering of a pointer
    /// at the edge. Shifting it inward would draw the marker somewhere the pointer is not, on an
    /// instrument whose entire job is reporting position faithfully.
    public static func rect(normX: Double, normY: Double, width: Int, height: Int)
        -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        guard width > 0, height > 0 else { return nil }
        let nx = min(max(normX, 0), 1), ny = min(max(normY, 0), 1)
        let cx = min(max(Int(nx * Double(width)), 0), width - 1)
        let cy = min(max(Int(ny * Double(height)), 0), height - 1)
        let half = sizePx / 2
        let x0 = max(0, cx - half), x1 = min(width, cx + half)
        let y0 = max(0, cy - half), y1 = min(height, cy + half)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1, y1)
    }
}
