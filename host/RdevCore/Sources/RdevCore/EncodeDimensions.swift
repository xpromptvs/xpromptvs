/// Fit a captured frame's dimensions into what an encoder will actually accept.
///
/// WHY THIS EXISTS: libaom refuses anything outside 72…3840 × 64…2160 (and anything odd), and
/// `LLVCore.AV1Encoder` turns a refusal into a thrown error at CREATE time. Without a fit step an
/// oversized source streams **zero frames indefinitely** after one log line — and that is not a
/// hypothetical size: rdev's own auto-resolution gate records a 1658×1084 pt retina window, which is
/// **3316×2168 native — 8 px over on height**. SVT-AV1 had no such ceiling, so this is a real
/// regression introduced by the encoder swap, and downscaling is the maintainer's decision for it:
/// a source slightly reduced in resolution is strictly better than a source with no picture.
///
/// It fits the model rdev already has. `Auto` resolution varies the streamed size continuously, the
/// encoder recreates on a size change either way, and the client never derives layout from the video
/// size — so a clamp is one more resolution change, not a new class of event.
///
/// The limits are PARAMETERS, not constants. They belong to whichever encoder is being fed, and
/// RdevCore must not learn about LLVCore to know them — the caller passes
/// `RealtimeVideoDimensions.minimum/maximum*` straight through.
public enum EncodeDimensions {
    /// The largest even size within the limits that preserves `width`:`height` as closely as integer
    /// rounding allows. Returns the input unchanged when it already fits, which is the overwhelmingly
    /// common case and must cost nothing downstream (the caller keys "am I scaling?" off equality).
    ///
    /// ASPECT IS PRESERVED WHEN SHRINKING, AND DELIBERATELY SACRIFICED AT THE FLOOR. One uniform
    /// scale factor handles the ceiling, because that is what a viewer sees as "the same picture,
    /// smaller". A frame so extreme that the uniform scale drives the OTHER axis under the minimum
    /// (a 20000×100 strip) then has its short axis raised, distorting it — the alternative there is
    /// no video at all, and a window of that shape is degenerate to begin with.
    public static func fit(width: Int, height: Int,
                           minWidth: Int, maxWidth: Int,
                           minHeight: Int, maxHeight: Int) -> (width: Int, height: Int) {
        // Round the bounds themselves to even INWARD first, so every later `max`/`min` against them
        // preserves evenness. A caller passing an odd bound is not expected, but silently emitting an
        // odd dimension from a function whose whole job is producing an acceptable one would be the
        // worst possible failure here.
        let loW = (minWidth + 1) & ~1, hiW = maxWidth & ~1
        let loH = (minHeight + 1) & ~1, hiH = maxHeight & ~1
        guard width > 0, height > 0, hiW >= loW, hiH >= loH else { return (loW, loH) }

        // Shrink only. `1.0` when the frame already fits, which is what makes the common path exact
        // rather than merely close — an identity scale must not perturb a size that was already legal.
        let scale = min(1.0, Double(hiW) / Double(width), Double(hiH) / Double(height))
        // Round DOWN, never to nearest: rounding up at the ceiling would re-cross the very bound this
        // exists to respect.
        var w = Int((Double(width) * scale).rounded(.down)) & ~1
        var h = Int((Double(height) * scale).rounded(.down)) & ~1

        w = min(hiW, max(loW, w))
        h = min(hiH, max(loH, h))
        return (w, h)
    }
}
