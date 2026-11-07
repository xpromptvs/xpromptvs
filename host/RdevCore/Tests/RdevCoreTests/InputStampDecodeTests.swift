import XCTest
@testable import RdevCore

/// `ViewerStampDecode.readInputStamp` — the two-row stamp `tools/InputLatencyTarget` paints.
///
/// EVERY BUFFER HERE IS PAINTED THE WAY THE TARGET PAINTS, NOT THE WAY THIS DECODER READS.
/// `paintTwoRowStamp` is a transcription of `InputLatencyTarget.drawStamp`: the same
/// `LatencyProbeStamp.cellIsWhite(i, bits:)` call, the same `originX + i*cellW` by
/// `originY + row*cellH` rectangles, row 0 then row 1. A helper written by inverting the decoder
/// would only ever prove that the decoder agrees with itself, which is the failure mode this whole
/// scope addition exists to close — the geometry lived in a comment, and nothing executed it.
final class InputStampDecodeTests: XCTestCase {

    /// Row 0 = timecode, row 1 = ordinal, both `cellH` tall, corner-anchored — verbatim from
    /// `InputLatencyTarget.draw`. `row1Rows` narrows row 1 to specific scanlines so a test can pin
    /// WHICH row the decoder samples; by default it fills the whole band, as the target does.
    private func paintTwoRowStamp(timecode: UInt32, ordinal: UInt32,
                                  cellW: Int, cellH: Int,
                                  width: Int, height: Int,
                                  row1Rows: Range<Int>? = nil) -> [UInt8] {
        var luma = [UInt8](repeating: 128, count: width * height)   // mid-grey background
        func paintRow(_ value: UInt32, rows: Range<Int>) {
            let bits = LatencyTimecode.encode(value)
            for i in 0 ..< LatencyProbeStamp.cellCount {
                guard let white = LatencyProbeStamp.cellIsWhite(i, bits: bits) else { continue }
                let v: UInt8 = white ? 235 : 16
                let x0 = LatencyProbeStamp.originX + i * cellW
                for x in x0 ..< (x0 + cellW) where x < width {
                    for y in rows where y >= 0 && y < height { luma[y * width + x] = v }
                }
            }
        }
        let row0 = LatencyProbeStamp.originY
        paintRow(timecode, rows: row0 ..< (row0 + cellH))
        paintRow(ordinal, rows: row1Rows ?? ((row0 + cellH) ..< (row0 + 2 * cellH)))
        return luma
    }

    /// Native geometry, straight out of `LatencyProbeStamp`: 36 cells of 16 px, two 24 px rows.
    func testReadsBothRowsAtNativeGeometry() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW   // 576
        let h = LatencyProbeStamp.cellH * 2                             // 48
        let luma = paintTwoRowStamp(timecode: 0xDEAD_BEEF, ordinal: 4_242,
                                    cellW: LatencyProbeStamp.cellW, cellH: LatencyProbeStamp.cellH,
                                    width: w, height: h)
        let got = ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w)
        XCTAssertEqual(got?.timecodeMs, 0xDEAD_BEEF)
        XCTAssertEqual(got?.ordinal, 4_242)
    }

    /// THE GEOMETRY ITSELF, taken from the target's header rather than from this decoder:
    ///
    ///     y' = round(36 * s) = round(2.25 * cellW')      // row 1's mid-line
    ///
    /// At native scale that is exactly 36. Only scanline 36 carries row 1 here, so the decoder can
    /// only succeed by sampling that one row — any other lands on mid-grey and fails the contrast
    /// guard. The negative control paints 35 instead, which must NOT decode: without it, "passes
    /// when only y=36 is painted" would not distinguish a decoder that samples 36 from one that
    /// happened to be lucky.
    func testRowOneIsSampledAtTheDocumentedMidLine() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH * 2
        func attempt(row1: Int) -> (timecodeMs: UInt32, ordinal: UInt32)? {
            let luma = paintTwoRowStamp(timecode: 1_000, ordinal: 7,
                                        cellW: LatencyProbeStamp.cellW,
                                        cellH: LatencyProbeStamp.cellH,
                                        width: w, height: h, row1Rows: row1 ..< (row1 + 1))
            return ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w)
        }
        XCTAssertEqual(attempt(row1: 36)?.ordinal, 7, "row 1 must be sampled at y = round(2.25*16) = 36")
        XCTAssertNil(attempt(row1: 35), "sampling anywhere but y=36 must fail — the check discriminates")
    }

    /// The same formula at half scale: cellW' = 8, so y' = round(2.25*8) = 18. Derived from the
    /// header's rule, not from a constant in the decoder. (Half scale is one of the scales the
    /// header's own sweep records as decodable, because 16*s = 8 is an integer.)
    func testRowOneMidLineFollowsTheCalibratedCellWidth() {
        let cellW = 8, cellH = 12                                       // s = 0.5
        let w = LatencyProbeStamp.cellCount * cellW                     // 288
        let h = cellH * 2                                               // 24
        func attempt(row1: Int) -> (timecodeMs: UInt32, ordinal: UInt32)? {
            let luma = paintTwoRowStamp(timecode: 99, ordinal: 12_345, cellW: cellW, cellH: cellH,
                                        width: w, height: h, row1Rows: row1 ..< (row1 + 1))
            return ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w)
        }
        XCTAssertEqual(attempt(row1: 18)?.ordinal, 12_345, "y = round(2.25*8) = 18")
        XCTAssertNil(attempt(row1: 17))
    }

    /// A frame that carries only row 0 has lost the ordinal. It must read as NO ordinal rather than
    /// as a timecode with a fabricated one — the target's header states the rule as "a frame shorter
    /// than 48*s rows must read as no ordinal", and a caller must never record a decode whose
    /// ordinal it invented.
    func testAFrameWithOnlyRowZeroYieldsNoOrdinal() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH                                  // 24 — row 0 only
        let luma = paintTwoRowStamp(timecode: 0x1234_5678, ordinal: 5,
                                    cellW: LatencyProbeStamp.cellW, cellH: LatencyProbeStamp.cellH,
                                    width: w, height: h)
        // Row 0 alone still decodes through the existing single-row entry point...
        XCTAssertEqual(ViewerStampDecode.read(luma: luma, width: w, height: h, rowBytes: w),
                       0x1234_5678)
        // ...but the two-row read must refuse, both or neither.
        XCTAssertNil(ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w))
    }

    /// THE "48*s ROWS" RULE, isolated. This frame is one row short of carrying the whole of row 1
    /// (height 47 against 3*cellW = 48) yet the mid-line at y=36 is present and would decode — so
    /// only the band guard can reject it, and the buffer-bound guard cannot mask the assertion.
    /// It is deliberately stricter than sampling requires: the header states the rule as "a frame
    /// shorter than 48*s rows must read as no ordinal", and code and prose stating one geometry is
    /// worth more than the marginal frames it refuses. Change the rule and change this test with it.
    func testAFrameShortOfTheFullRowOneBandIsRefused() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let full = LatencyProbeStamp.cellH * 2                           // 48 = 3 * cellW
        for h in [full, full - 1] {
            let luma = paintTwoRowStamp(timecode: 11, ordinal: 22,
                                        cellW: LatencyProbeStamp.cellW,
                                        cellH: LatencyProbeStamp.cellH, width: w, height: h)
            let got = ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w)
            if h == full {
                XCTAssertEqual(got?.ordinal, 22, "the full band must decode")
            } else {
                XCTAssertNil(got, "height \(h) < 3*cellW must read as no ordinal")
            }
        }
    }

    /// A caller that copied only the top of the plane (which `read` explicitly permits) must not be
    /// read past — the buffer bound is checked, not assumed from the declared height.
    func testATruncatedBufferYieldsNoOrdinal() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH * 2
        let full = paintTwoRowStamp(timecode: 7, ordinal: 8,
                                    cellW: LatencyProbeStamp.cellW, cellH: LatencyProbeStamp.cellH,
                                    width: w, height: h)
        let topThreeRows = Array(full.prefix(w * 3))
        XCTAssertNil(ViewerStampDecode.readInputStamp(luma: topThreeRows, width: w, height: h,
                                                      rowBytes: w))
    }

    /// Row 1's own finder cells must be checked, or a frame whose second band is CONTENT rather
    /// than a stamp returns a plausible wrong ordinal — which pairs cleanly and produces an
    /// entirely believable latency for an input that never happened.
    func testRowOneWithBrokenFindersIsRefused() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH * 2
        var luma = paintTwoRowStamp(timecode: 1, ordinal: 2,
                                    cellW: LatencyProbeStamp.cellW, cellH: LatencyProbeStamp.cellH,
                                    width: w, height: h)
        XCTAssertNotNil(ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w))
        // Invert the END finders on row 1 only (cells 34 white->black, 35 black->white).
        let end0 = LatencyTimecode.bitCount + 2, end1 = LatencyTimecode.bitCount + 3
        for cell in [end0, end1] {
            let v: UInt8 = cell == end0 ? 16 : 235
            for x in (cell * 16) ..< ((cell + 1) * 16) {
                for y in 24 ..< 48 { luma[y * w + x] = v }
            }
        }
        XCTAssertNil(ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w))
        // Row 0 is untouched and must still read — this test broke row 1, nothing else.
        XCTAssertEqual(ViewerStampDecode.read(luma: luma, width: w, height: h, rowBytes: w), 1)
    }

    /// A band of FLAT content where row 1 should be must be refused. (It is the end finders that
    /// reject this one — a flat band cannot satisfy "cell 34 light, cell 35 dark" — not the contrast
    /// guard, which the next test isolates. Both cases are worth holding.)
    func testRowOneOfFlatContentIsRefused() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH * 2
        var luma = paintTwoRowStamp(timecode: 3, ordinal: 4,
                                    cellW: LatencyProbeStamp.cellW, cellH: LatencyProbeStamp.cellH,
                                    width: w, height: h)
        for y in 24 ..< 48 { for x in 0 ..< w { luma[y * w + x] = 90 } }
        XCTAssertNil(ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w))
    }

    /// THE CONTRAST GUARD, isolated — and the only case in this file where dropping it changes an
    /// answer. A row 1 that is correctly SHAPED but washed out (black 100, white 110) satisfies both
    /// end finders and every bit threshold, because all of them are relative to the row's own
    /// references: without a floor on the reference separation it decodes to a real-looking ordinal
    /// out of what is effectively noise. `read` applies the same floor to row 0 for the same reason.
    ///
    /// The positive control is the identical pattern at full contrast, so this cannot pass merely
    /// because the painting is wrong.
    func testRowOneWithoutEnoughContrastIsRefused() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH * 2
        func attempt(dark: UInt8, light: UInt8) -> (timecodeMs: UInt32, ordinal: UInt32)? {
            var luma = paintTwoRowStamp(timecode: 5, ordinal: 6,
                                        cellW: LatencyProbeStamp.cellW,
                                        cellH: LatencyProbeStamp.cellH, width: w, height: h)
            let bits = LatencyTimecode.encode(6)
            for i in 0 ..< LatencyProbeStamp.cellCount {
                guard let white = LatencyProbeStamp.cellIsWhite(i, bits: bits) else { continue }
                let v = white ? light : dark
                for x in (i * 16) ..< ((i + 1) * 16) { for y in 24 ..< 48 { luma[y * w + x] = v } }
            }
            return ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w)
        }
        XCTAssertEqual(attempt(dark: 16, light: 235)?.ordinal, 6, "full contrast must decode")
        XCTAssertNil(attempt(dark: 100, light: 110),
                     "a correctly shaped but washed-out row 1 must not decode to a plausible ordinal")
    }

    /// ORDINAL 0 IS A VALUE, not an absence: the target reserves it for "no input observed yet", and
    /// a frame carrying it is a real frame that predates the run. Reading it as nil would make a
    /// warm-up frame indistinguishable from a failed decode.
    func testOrdinalZeroAndMaxRoundTrip() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH * 2
        for ordinal: UInt32 in [0, 1, 0xFFFF_FFFF] {
            let luma = paintTwoRowStamp(timecode: 0xABCD_0123, ordinal: ordinal,
                                        cellW: LatencyProbeStamp.cellW,
                                        cellH: LatencyProbeStamp.cellH, width: w, height: h)
            let got = ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w)
            XCTAssertEqual(got?.ordinal, ordinal, "ordinal=\(ordinal)")
            XCTAssertEqual(got?.timecodeMs, 0xABCD_0123, "ordinal=\(ordinal)")
        }
    }

    /// Row 0 decoded through the NEW path's two helpers, exactly as `readInputStamp` decodes row 1:
    /// calibrate, then `decodeRow` at row 0's own y. Nil if either step refuses.
    ///
    /// This is the whole point of the lock-step tests below, so it must not be written in terms of
    /// `readInputStamp` — that function obtains its timecode by CALLING `read`, so any assertion
    /// phrased against it compares `read` to itself and can only ever fail on nil. (An earlier
    /// version of this file did exactly that and claimed it as the anti-drift mitigation.)
    private func rowZeroViaNewPath(luma: [UInt8], width: Int, height: Int, rowBytes: Int) -> UInt32? {
        guard let cellW = ViewerStampDecode.calibratedCellWidth(luma: luma, width: width,
                                                                height: height, rowBytes: rowBytes)
        else { return nil }
        return ViewerStampDecode.decodeRow(luma: luma, width: width, rowBytes: rowBytes,
                                           y: min(2, height - 1), cellW: cellW)
    }

    /// LOCK-STEP, HALF 1 — the VALUE. `readInputStamp` re-implements essentially all of `read`
    /// (`calibratedCellWidth` is its head, `decodeRow` its tail), so the two copies must be pinned.
    /// Row 0 decoded through the new helpers must equal row 0 decoded by the original, at every cell
    /// width. A divergence in either copy fails here rather than in a live run.
    func testRowZeroThroughBothPathsAgrees() {
        for cellW in [4, 8, 16, 24, 32] {
            let cellH = cellW * LatencyProbeStamp.cellH / LatencyProbeStamp.cellW   // 1.5 * cellW
            let w = LatencyProbeStamp.cellCount * cellW
            let h = cellH * 2
            let luma = paintTwoRowStamp(timecode: 0x0BAD_F00D, ordinal: 606,
                                        cellW: cellW, cellH: cellH, width: w, height: h)
            let single = ViewerStampDecode.read(luma: luma, width: w, height: h, rowBytes: w)
            let viaNew = rowZeroViaNewPath(luma: luma, width: w, height: h, rowBytes: w)
            let both = ViewerStampDecode.readInputStamp(luma: luma, width: w, height: h, rowBytes: w)
            XCTAssertEqual(single, 0x0BAD_F00D, "cellW=\(cellW)")
            XCTAssertEqual(viaNew, single, "cellW=\(cellW): the duplicated head+tail must agree with read")
            XCTAssertEqual(both?.timecodeMs, single, "cellW=\(cellW)")
            XCTAssertEqual(both?.ordinal, 606, "cellW=\(cellW)")
        }
    }

    /// LOCK-STEP, HALF 2 — THE CHANGE THE SOURCE ACTUALLY ANTICIPATES, which half 1 cannot see.
    ///
    /// `ViewerStampDecode`'s doc names the expected future fix: derive the cell width from the END
    /// finder over all 36 cells instead of from the first dark→light edge. At every INTEGRAL cell
    /// width — which is all half 1 uses — the old estimate and the fixed one return the SAME
    /// integer, so half 1 would pass green straight through that edit while `readInputStamp` was
    /// left on the old estimate. Only a FRACTIONAL true cell width separates them.
    ///
    /// The capture is rescaled by nearest-neighbour and the assertion is simply that the two paths
    /// AGREE — on the value where they decode, and on refusing where they do not. MEASURED, so that
    /// nobody has to guess which is which:
    ///
    ///     scale 0.8  -> true cell width 12.8 -> both refuse
    ///     scale 0.75 -> true cell width 12.0 -> both DECODE
    ///     scale 0.7  -> true cell width 11.2 -> both refuse
    ///     scale 0.6  -> true cell width  9.6 -> both refuse
    ///
    /// NOTE 0.75, because it contradicts the header's sweep, which records 0.75 as NOT decoding.
    /// Both are right: nearest-neighbour on a synthetic buffer lands on an EXACT cell width of 12,
    /// whereas the header's figure came from a real capture through a real resampler, which blurs
    /// the cell edges and moves the first-crossing estimate. So this file must not be read as
    /// reproducing that sweep — it is a lock-step check, and 0.75 earns its place by covering
    /// agreement-on-ACCEPT alongside three cases of agreement-on-refuse.
    ///
    /// VERIFIED TO DISCRIMINATE: giving `read` a fractional estimate (`width / cellCount`, which is
    /// what an end-finder derivation recovers) and leaving `readInputStamp` on the old one fails
    /// this test at 0.8, 0.7 and 0.6 — `read` returns the painted 0x51502020 while the duplicated
    /// estimate still refuses — while `testRowZeroThroughBothPathsAgrees` passes green throughout.
    /// That asymmetry is the whole reason this second test exists.
    func testBothPathsAgreeAtAFractionalCellWidth() {
        let nativeCellW = LatencyProbeStamp.cellW, nativeCellH = LatencyProbeStamp.cellH
        let nw = LatencyProbeStamp.cellCount * nativeCellW      // 576
        let nh = nativeCellH * 2                                // 48
        let native = paintTwoRowStamp(timecode: 0x5150_2020, ordinal: 314,
                                      cellW: nativeCellW, cellH: nativeCellH, width: nw, height: nh)
        for scale in [0.8, 0.75, 0.7, 0.6] {                    // 16*s = 12.8, 12, 11.2, 9.6
            let w = Int(Double(nw) * scale), h = Int(Double(nh) * scale)
            var scaled = [UInt8](repeating: 0, count: w * h)
            for y in 0 ..< h {
                let sy = min(nh - 1, Int(Double(y) / scale))
                for x in 0 ..< w {
                    scaled[y * w + x] = native[sy * nw + min(nw - 1, Int(Double(x) / scale))]
                }
            }
            let single = ViewerStampDecode.read(luma: scaled, width: w, height: h, rowBytes: w)
            let viaNew = rowZeroViaNewPath(luma: scaled, width: w, height: h, rowBytes: w)
            let both = ViewerStampDecode.readInputStamp(luma: scaled, width: w, height: h, rowBytes: w)
            XCTAssertEqual(viaNew, single,
                           "scale=\(scale): read and the duplicated estimate must agree, including on refusing")
            // Both-or-neither still holds at a scale the estimate cannot handle.
            if single == nil { XCTAssertNil(both, "scale=\(scale)") }
        }
    }

    /// `CVPixelBuffer` padding: `rowBytes` is what strides rows, and row 1 lives many rows down, so
    /// this is where confusing the two is caught.
    func testRowBytesPaddingIsHonouredForBothRows() {
        let w = LatencyProbeStamp.cellCount * LatencyProbeStamp.cellW
        let h = LatencyProbeStamp.cellH * 2
        let rowBytes = w + 64
        let luma = paintTwoRowStamp(timecode: 0x2222_3333, ordinal: 909,
                                    cellW: LatencyProbeStamp.cellW, cellH: LatencyProbeStamp.cellH,
                                    width: w, height: h)
        var padded = [UInt8](repeating: 0, count: rowBytes * h)
        for y in 0 ..< h { for x in 0 ..< w { padded[y * rowBytes + x] = luma[y * w + x] } }
        let got = ViewerStampDecode.readInputStamp(luma: padded, width: w, height: h,
                                                   rowBytes: rowBytes)
        XCTAssertEqual(got?.timecodeMs, 0x2222_3333)
        XCTAssertEqual(got?.ordinal, 909)
    }

    func testUnstampedAndDegenerateInputsYieldNil() {
        XCTAssertNil(ViewerStampDecode.readInputStamp(luma: [UInt8](repeating: 128, count: 640 * 48),
                                                      width: 640, height: 48, rowBytes: 640))
        XCTAssertNil(ViewerStampDecode.readInputStamp(luma: [], width: 0, height: 0, rowBytes: 0))
    }
}
