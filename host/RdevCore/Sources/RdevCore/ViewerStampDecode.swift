import Foundation

/// Reads the host's glass-to-glass timecode out of a decoded frame's LUMA plane.
///
/// Port of `web/src/lib/probe.ts`'s `sampleTimecodeBits`, keeping its self-calibration: the cell
/// width is derived from the frame rather than assumed, which is what makes the stamp survive
/// WebRTC's rescaling. One simplification — plane 0 of any 420 biplanar CVPixelBuffer already IS
/// luma, so the browser's RGBA→luma step has no counterpart here.
///
/// Keep in lock-step with `probe.ts` and `LatencyProbeStamp`.
public enum ViewerStampDecode {

    /// Minimum contrast between the black reference and the brightest cell for a stamp to be
    /// considered present. Same value as probe.ts.
    public static let minimumContrast: Double = 20

    /// Returns the stamped value, or nil when no valid stamp is present. Nil covers "unstamped"
    /// and "truncated" alike: both must be counted as a missing reading, never sampled.
    public static func read(luma: [UInt8], width: Int, height: Int, rowBytes: Int) -> UInt32? {
        // Only the row at y = min(2, height-1) is ever read, so the buffer only needs to cover
        // rows 0...y (i.e. min(height, 3) rows) — a caller that copies just the top of the plane
        // is not penalized for it.
        guard width > 0, height > 0, rowBytes >= width, luma.count >= rowBytes * min(height, 3) else {
            return nil
        }

        // Row near the very top, so a vertically downscaled frame still lands inside cell height.
        let y = min(2, height - 1)
        let row = y * rowBytes
        func L(_ x: Int) -> Double { Double(luma[row + x]) }

        // Black reference from the corner (cell 0); brightest cell in the left 60%.
        let blackRef0 = (L(0) + (width > 1 ? L(1) : L(0)) + (width > 2 ? L(2) : L(0))) / 3
        let searchEnd = max(1, Int(Double(width) * 0.6))
        var maxL = -Double.infinity
        for x in 0 ..< searchEnd where L(x) > maxL { maxL = L(x) }
        guard maxL - blackRef0 >= minimumContrast else { return nil }

        // Cell width from the cell0→cell1 dark→light boundary.
        let crossing = (blackRef0 + maxL) / 2
        var edge = -1
        for x in 1 ..< width where L(x) >= crossing {
            edge = x
            break
        }
        guard edge >= 2 else { return nil }
        let cellW = edge

        func centerX(_ i: Int) -> Int { Int(((Double(i) + 0.5) * Double(cellW)).rounded()) }

        // The whole stamp must fit. A truncated stamp decodes as a plausible wrong value.
        guard centerX(LatencyProbeStamp.cellCount - 1) < width else { return nil }

        let blackRef = L(centerX(0))
        let whiteRef = L(centerX(1))
        let threshold = (blackRef + whiteRef) / 2

        // End finders: cell bitCount+2 is WHITE, cell bitCount+3 is BLACK.
        guard L(centerX(LatencyTimecode.bitCount + 2)) >= threshold,
              L(centerX(LatencyTimecode.bitCount + 3)) < threshold else { return nil }

        var bits = [Bool]()
        bits.reserveCapacity(LatencyTimecode.bitCount)
        for i in 0 ..< LatencyTimecode.bitCount {
            bits.append(L(centerX(2 + i)) >= threshold)
        }
        return LatencyTimecode.decode(bits)
    }
}

// MARK: - The two-row input stamp

extension ViewerStampDecode {

    /// Reads BOTH rows of the stamp `tools/InputLatencyTarget` paints: the wall clock (row 0, which
    /// is `LatencyProbeStamp` verbatim, so every existing decoder still reads it) and the ordinal of
    /// the input that caused the repaint (row 1, identical geometry directly beneath it).
    ///
    ///     native y  0 ..< 24   row 0 — epoch ms, low 32 bits
    ///     native y 24 ..< 48   row 1 — input ordinal, UInt32
    ///
    /// THE GEOMETRY LIVED ONLY IN A COMMENT UNTIL THIS EXISTED. `read` above is hardcoded to row 0
    /// and `web/src/lib/probe.ts` likewise reads one row, so the rule below was prose in
    /// `InputLatencyTarget`'s header and the only thing that had ever executed it was a throwaway
    /// script. It is here, next to the decoder it extends and under test, so the next reader does
    /// not transcribe a paragraph into a shell pipeline.
    ///
    /// ROW 1 IS LOCATED BY THE SAME SELF-CALIBRATION THAT MAKES THE STAMP SURVIVE RESCALING, and
    /// therefore needs no new constant. With `cellW'` the calibrated cell width of the DECODED frame
    /// and `s = cellW' / LatencyProbeStamp.cellW`, row 1's mid-line is
    ///
    ///     y' = round(36 * s) = round(2.25 * cellW')      // 36 = 24 + 24/2
    ///
    /// (36 at native scale, 18 at half scale — both mid-band, with ±12·s rows of margin.) Capture is
    /// ONE uniform scale, which is what lets a horizontally-derived cell width place a vertical row.
    ///
    /// BOTH ROWS OR NEITHER. A frame that decodes a timecode but not an ordinal returns nil, rather
    /// than a timecode plus some caller-chosen default. An invented ordinal pairs cleanly in
    /// `InputToDecode` and yields an entirely believable latency for an input that never happened —
    /// the exact class of plausible-wrong number this instrument exists to avoid producing.
    ///
    /// **THE STREAM MUST RUN AT A SCALE WHERE `16 * s` IS AN INTEGER — 1.0 is the simple answer.**
    /// `read`'s cell width is the INTEGER x of the first dark→light edge, so at a fractional true
    /// cell width the sampling point drifts by `36 × error` across the row and the end finders
    /// reject it. Measured across a rescale sweep: 2.0, 1.5, 1.25, 1.0 and 0.5 decode; 0.8, 0.75,
    /// 0.7, 0.6, 0.4 and 0.3 do not. This is PRE-EXISTING and affects row 0 identically — feeding
    /// the true fractional cell width decodes both rows at every scale — so it is a property of that
    /// estimate, not of row 1, and fixing it (deriving the width from the END finder over all 36
    /// cells) is C1 instrument scope, deliberately not done here. NOTE that rdev's `Auto` resolution
    /// aligns emitted width to a multiple of 16, which is NOT the same constraint and will land on
    /// undecodable scales.
    ///
    /// LOCK-STEP, AND BE PRECISE ABOUT WHAT IS AND IS NOT PINNED. `read` is not restructured to
    /// share one implementation, so `calibratedCellWidth` + `decodeRow` between them re-implement
    /// essentially the WHOLE of `read` — its head and its tail, ~25 lines, not just the calibration.
    /// Two tests in `InputStampDecodeTests` hold the copies together, and each catches a different
    /// half of the drift:
    ///
    ///  * `testRowZeroThroughBothPathsAgrees` decodes row 0 through THESE helpers and compares the
    ///    value to `read`'s. Note what does NOT work: comparing `readInputStamp`'s `timecodeMs` to
    ///    `read` is vacuous, because `readInputStamp` obtains it by calling `read` — both sides are
    ///    the same call. An earlier version of this comment claimed that vacuous test as the
    ///    mitigation.
    ///  * `testBothPathsAgreeAtAFractionalCellWidth` covers the change this file explicitly
    ///    anticipates — fixing the estimate to derive the width from the END finder. At the integral
    ///    cell widths the value test uses, the old and fixed estimates return the SAME integer, so
    ///    that test alone would pass green through exactly the edit it is supposed to catch. Only a
    ///    fractional scale separates them.
    ///
    /// If you change `read`, run both. If you are changing the estimate deliberately, the correct
    /// move is to change it HERE too, in the same commit — or to collapse the two into one shared
    /// calibration, which is the real fix and was left out of scope only because `read` is C1's.
    public static func readInputStamp(luma: [UInt8], width: Int, height: Int, rowBytes: Int)
        -> (timecodeMs: UInt32, ordinal: UInt32)? {
        // Row 0 through the existing, tested entry point: it carries the presence, contrast and
        // truncation guards, so anything it rejects is rejected here too.
        guard let timecodeMs = read(luma: luma, width: width, height: height, rowBytes: rowBytes),
              let cellW = calibratedCellWidth(luma: luma, width: width, height: height,
                                              rowBytes: rowBytes)
        else { return nil }

        let y = Int((2.25 * Double(cellW)).rounded())
        // The WHOLE of row 1 must be present — native y 24..<48, i.e. 48·s = 3·cellW rows — which is
        // the rule as `InputLatencyTarget`'s header states it. Deliberately stricter than sampling
        // needs (only y' is read, and y' sits mid-band), because one statement of the geometry that
        // code and prose both satisfy is worth more than the marginal frames it refuses; a frame
        // cropped between 2.25·cellW and 3·cellW reads as no ordinal, which is loud, not silent.
        guard height >= 3 * cellW, luma.count >= rowBytes * (y + 1) else { return nil }

        guard let ordinal = decodeRow(luma: luma, width: width, rowBytes: rowBytes,
                                      y: y, cellW: cellW)
        else { return nil }
        return (timecodeMs, ordinal)
    }

    /// The cell width `read` derives, re-derived so row 1 can be located. Kept identical to the
    /// corresponding lines of `read` — see the lock-step note above.
    ///
    /// `internal` rather than `private` ONLY so `InputStampDecodeTests` can decode row 0 through
    /// this path and compare it to `read`'s answer. That comparison is the entire mitigation for the
    /// duplication, and it cannot be written against the public surface: `readInputStamp` gets its
    /// timecode by calling `read`, so any assertion phrased in terms of it compares `read` to
    /// itself. Not part of the public API, and nothing outside this file's tests calls it.
    static func calibratedCellWidth(luma: [UInt8], width: Int, height: Int,
                                    rowBytes: Int) -> Int? {
        guard width > 0, height > 0, rowBytes >= width,
              luma.count >= rowBytes * min(height, 3) else { return nil }
        let y = min(2, height - 1)
        let row = y * rowBytes
        func L(_ x: Int) -> Double { Double(luma[row + x]) }

        let blackRef0 = (L(0) + (width > 1 ? L(1) : L(0)) + (width > 2 ? L(2) : L(0))) / 3
        let searchEnd = max(1, Int(Double(width) * 0.6))
        var maxL = -Double.infinity
        for x in 0 ..< searchEnd where L(x) > maxL { maxL = L(x) }
        guard maxL - blackRef0 >= minimumContrast else { return nil }

        let crossing = (blackRef0 + maxL) / 2
        for x in 1 ..< width where L(x) >= crossing { return x >= 2 ? x : nil }
        return nil
    }

    /// Decodes one already-located stamp row at a KNOWN cell width, taking its black and white
    /// references from its own finder cells.
    ///
    /// The contrast check is on this row's OWN references, not on row 0's: a frame whose second band
    /// is picture content rather than a stamp has no meaningful threshold, and thresholding cells
    /// against noise is how a wrong-but-plausible ordinal gets returned. The end finders are the
    /// second, independent rejection — the same reason row 0 has them.
    ///
    /// `internal` rather than `private` for the same single reason as `calibratedCellWidth` above:
    /// the lock-step test decodes row 0 through it. It is row-agnostic by construction, which is
    /// what makes that test meaningful rather than contrived.
    static func decodeRow(luma: [UInt8], width: Int, rowBytes: Int,
                          y: Int, cellW: Int) -> UInt32? {
        let row = y * rowBytes
        func L(_ x: Int) -> Double { Double(luma[row + x]) }
        func centerX(_ i: Int) -> Int { Int(((Double(i) + 0.5) * Double(cellW)).rounded()) }

        // The whole row must fit — a truncated row decodes as a plausible wrong value. NOTE this is
        // UNREACHABLE from `readInputStamp` and no test can falsify it: `read` has already applied
        // the identical bound, at the identical calibrated `cellW`, before this is called. It stays
        // because this function indexes `luma` directly, so it must be safe on its own terms rather
        // than on its caller's; mutation-testing it will correctly report that nothing fails.
        guard centerX(LatencyProbeStamp.cellCount - 1) < width else { return nil }

        let blackRef = L(centerX(0))
        let whiteRef = L(centerX(1))
        guard whiteRef - blackRef >= minimumContrast else { return nil }
        let threshold = (blackRef + whiteRef) / 2

        guard L(centerX(LatencyTimecode.bitCount + 2)) >= threshold,
              L(centerX(LatencyTimecode.bitCount + 3)) < threshold else { return nil }

        var bits = [Bool]()
        bits.reserveCapacity(LatencyTimecode.bitCount)
        for i in 0 ..< LatencyTimecode.bitCount {
            bits.append(L(centerX(2 + i)) >= threshold)
        }
        return LatencyTimecode.decode(bits)
    }
}
