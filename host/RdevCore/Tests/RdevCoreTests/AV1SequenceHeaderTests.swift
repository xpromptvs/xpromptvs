import XCTest
@testable import RdevCore

/// The AV1 sequence-header parse, which is what gives VideoToolbox its `width`/`height` and the
/// report its `sourceWidth`/`sourceHeight`.
///
/// A WRONG ANSWER HERE IS SILENT: the decoder is configured at the wrong size, decodes anyway
/// (VideoToolbox scales to the format description), and the report states a resolution that was
/// never measured. So the cases below are chosen to be the ones where a plausible wrong answer
/// is reachable — every field that only matters because its WIDTH positions the two numbers we
/// actually want.
final class AV1SequenceHeaderTests: XCTestCase {

    // MARK: - a bit writer, deliberately independent of the reader

    /// Written from the spec's field list (§5.5.1) rather than by mirroring `BitReader`, so a
    /// misreading shared by both would have to be made twice, in two different directions.
    private struct BitWriter {
        private var bits: [UInt8] = []
        mutating func f(_ value: UInt64, _ n: Int) {
            for i in stride(from: n - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> UInt64(i)) & 1))
            }
        }
        /// Zero-padded to a byte boundary, as `trailing_bits()` effectively leaves it.
        func bytes() -> [UInt8] {
            var out = [UInt8]()
            var accumulator: UInt8 = 0
            var count = 0
            for bit in bits {
                accumulator = (accumulator << 1) | bit
                count += 1
                if count == 8 { out.append(accumulator); accumulator = 0; count = 0 }
            }
            if count > 0 { out.append(accumulator << UInt8(8 - count)) }
            return out
        }
    }

    /// The ordinary shape libaom and SVT-AV1 emit: no timing info, no decoder model, one
    /// operating point.
    private static func simpleSequenceHeaderPayload(width: Int, height: Int) -> [UInt8] {
        var w = BitWriter()
        w.f(0, 3)                  // seq_profile
        w.f(0, 1)                  // still_picture
        w.f(0, 1)                  // reduced_still_picture_header
        w.f(0, 1)                  // timing_info_present_flag
        w.f(0, 1)                  // initial_display_delay_present_flag
        w.f(0, 5)                  // operating_points_cnt_minus_1
        w.f(0, 12)                 // operating_point_idc[0]
        w.f(0, 5)                  // seq_level_idx[0] (<= 7, so no seq_tier)
        w.f(10, 4)                 // frame_width_bits_minus_1  -> 11 bits
        w.f(9, 4)                  // frame_height_bits_minus_1 -> 10 bits
        w.f(UInt64(width - 1), 11)
        w.f(UInt64(height - 1), 10)
        return w.bytes()
    }

    /// An OBU with `obu_has_size_field = 1`, which is what an RTP-delivered access unit carries.
    private static func obu(type: UInt8, payload: [UInt8]) -> [UInt8] {
        let header = UInt8((type << 3) | 0b10)          // has_size_field, no extension
        return [header] + leb128(UInt64(payload.count)) + payload
    }

    private static func leb128(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var out = [UInt8]()
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining != 0
        return out
    }

    // MARK: - the writer itself, cross-checked against bytes computed by hand

    /// If the writer were wrong, every test below would be testing the reader against a
    /// matching mistake. These ten bytes were laid out bit by bit against the spec on paper for
    /// a 1280x720 header, so they anchor the writer to something that is not code.
    func testWriterMatchesHandComputedBytes() {
        let payload = Self.simpleSequenceHeaderPayload(width: 1280, height: 720)
        XCTAssertEqual(payload, [0x00, 0x00, 0x00, 0x05, 0x4C, 0xFF, 0xB3, 0xC0])
        XCTAssertEqual(Self.obu(type: 1, payload: payload).prefix(2).map { $0 }, [0x0A, 0x08])
    }

    // MARK: - the parse

    func testReadsTheCodedSizeFromAnOrdinarySequenceHeader() throws {
        let unit = Self.obu(type: 2, payload: [])                 // temporal delimiter, skipped
            + Self.obu(type: 1, payload: Self.simpleSequenceHeaderPayload(width: 1280, height: 720))
            + Self.obu(type: 6, payload: [0xde, 0xad, 0xbe, 0xef]) // frame OBU, ignored
        let header = try XCTUnwrap(AV1Bitstream.sequenceHeader(in: unit))
        XCTAssertEqual(header.maxFrameWidth, 1280)
        XCTAssertEqual(header.maxFrameHeight, 720)
        XCTAssertEqual(header.seqProfile, 0)
    }

    /// The returned `obu` is what an `av1C` record carries, so it must be the WHOLE OBU —
    /// header byte and size field included — and must stop before the next one. A slice that
    /// ran on into the frame OBU would still produce a format description; it would just
    /// describe a stream that does not exist.
    func testReturnedOBUIsExactlyTheSequenceHeaderOBU() throws {
        let payload = Self.simpleSequenceHeaderPayload(width: 640, height: 360)
        let sequenceOBU = Self.obu(type: 1, payload: payload)
        let unit = Self.obu(type: 2, payload: []) + sequenceOBU
            + Self.obu(type: 6, payload: [0x01, 0x02, 0x03])
        let header = try XCTUnwrap(AV1Bitstream.sequenceHeader(in: unit))
        XCTAssertEqual(header.obu, sequenceOBU)
        XCTAssertEqual(AV1Bitstream.configurationRecord(for: header),
                       [0x81, 0x09, 0x0c, 0x00] + sequenceOBU)
    }

    /// The OBU extension byte (temporal/spatial id) is present on every OBU of a temporally
    /// scalable stream — which is exactly what `llv capture-host --scalability-mode L1T2/L1T3`
    /// produces. Skipping it costs one byte; NOT skipping it shifts the whole payload by one
    /// and the parse reads plausible garbage.
    func testSkipsTheOBUExtensionByte() throws {
        let payload = Self.simpleSequenceHeaderPayload(width: 976, height: 454)
        let header = UInt8((1 << 3) | 0b110)              // type 1, extension flag, size field
        let unit = [header, 0b0010_0000] + Self.leb128(UInt64(payload.count)) + payload
        let parsed = try XCTUnwrap(AV1Bitstream.sequenceHeader(in: unit))
        XCTAssertEqual(parsed.maxFrameWidth, 976)
        XCTAssertEqual(parsed.maxFrameHeight, 454)
    }

    /// Three operating points, as a temporally scalable stream declares, with `seq_level_idx > 7`
    /// on two of them so the conditional `seq_tier` bit is actually present. Each operating
    /// point is 17 or 18 bits; miscounting even one shifts `frame_width_bits_minus_1` and the
    /// size comes out wrong but well-formed.
    func testHandlesSeveralOperatingPointsAndTheConditionalSeqTier() throws {
        var w = BitWriter()
        w.f(0, 3); w.f(0, 1); w.f(0, 1)   // profile, still_picture, reduced_still_picture_header
        w.f(0, 1)                          // timing_info_present_flag
        w.f(0, 1)                          // initial_display_delay_present_flag
        w.f(2, 5)                          // operating_points_cnt_minus_1 -> three points
        w.f(0, 12); w.f(8, 5); w.f(0, 1)   // idc, seq_level_idx 8 (> 7) -> seq_tier
        w.f(0, 12); w.f(0, 5)              // idc, seq_level_idx 0 (<= 7) -> no seq_tier
        w.f(0, 12); w.f(9, 5); w.f(1, 1)   // idc, seq_level_idx 9 (> 7) -> seq_tier
        w.f(7, 4); w.f(7, 4)               // width/height bits minus 1 -> 8 bits each
        w.f(63, 8); w.f(47, 8)             // 64 x 48
        let parsed = try XCTUnwrap(
            AV1Bitstream.sequenceHeader(in: Self.obu(type: 1, payload: w.bytes())))
        XCTAssertEqual(parsed.maxFrameWidth, 64)
        XCTAssertEqual(parsed.maxFrameHeight, 48)
    }

    /// `initial_display_delay_present_flag` adds a per-operating-point bit, and a second one
    /// when it is set. Both are read purely for their width.
    func testHandlesInitialDisplayDelay() throws {
        var w = BitWriter()
        w.f(0, 3); w.f(0, 1); w.f(0, 1)
        w.f(0, 1)                          // timing_info_present_flag
        w.f(1, 1)                          // initial_display_delay_present_flag
        w.f(1, 5)                          // two operating points
        w.f(0, 12); w.f(0, 5); w.f(1, 1); w.f(3, 4)   // op0: present, delay_minus_1 = 3
        w.f(0, 12); w.f(0, 5); w.f(0, 1)              // op1: absent
        w.f(10, 4); w.f(9, 4)
        w.f(1279, 11); w.f(719, 10)
        let parsed = try XCTUnwrap(
            AV1Bitstream.sequenceHeader(in: Self.obu(type: 1, payload: w.bytes())))
        XCTAssertEqual(parsed.maxFrameWidth, 1280)
        XCTAssertEqual(parsed.maxFrameHeight, 720)
    }

    /// `timing_info()` plus `decoder_model_info()` is the longest optional run in the header,
    /// and the only place a `uvlc()` appears. Getting `buffer_delay_length` wrong shifts
    /// everything after it.
    func testHandlesTimingInfoAndDecoderModel() throws {
        var w = BitWriter()
        w.f(0, 3); w.f(0, 1); w.f(0, 1)
        w.f(1, 1)                          // timing_info_present_flag
        w.f(1_000_000, 32)                 // num_units_in_display_tick
        w.f(60_000_000, 32)                // time_scale
        w.f(1, 1)                          // equal_picture_interval
        w.f(0b010, 3)                      // uvlc: one leading zero, then 1, then one bit -> 1
        w.f(1, 1)                          // decoder_model_info_present_flag
        w.f(9, 5)                          // buffer_delay_length_minus_1 -> 10 bits
        w.f(1_000, 32)                     // num_units_in_decoding_tick
        w.f(0, 5); w.f(0, 5)               // buffer_removal / frame_presentation lengths
        w.f(0, 1)                          // initial_display_delay_present_flag
        w.f(0, 5)                          // one operating point
        w.f(0, 12); w.f(0, 5)              // idc, seq_level_idx 0
        w.f(1, 1)                          // decoder_model_present_for_this_op
        w.f(0, 10); w.f(0, 10); w.f(0, 1)  // decoder/encoder buffer delay, low_delay_mode_flag
        w.f(10, 4); w.f(9, 4)
        w.f(1279, 11); w.f(719, 10)
        let parsed = try XCTUnwrap(
            AV1Bitstream.sequenceHeader(in: Self.obu(type: 1, payload: w.bytes())))
        XCTAssertEqual(parsed.maxFrameWidth, 1280)
        XCTAssertEqual(parsed.maxFrameHeight, 720)
    }

    func testReducedStillPictureHeader() throws {
        var w = BitWriter()
        w.f(0, 3); w.f(1, 1); w.f(1, 1)    // profile, still_picture, reduced_still_picture_header
        w.f(0, 5)                          // seq_level_idx[0]
        w.f(10, 4); w.f(9, 4)
        w.f(1279, 11); w.f(719, 10)
        let parsed = try XCTUnwrap(
            AV1Bitstream.sequenceHeader(in: Self.obu(type: 1, payload: w.bytes())))
        XCTAssertEqual(parsed.maxFrameWidth, 1280)
        XCTAssertEqual(parsed.maxFrameHeight, 720)
    }

    /// A REAL sequence header, captured off the wire from `llv capture-host --codec av1 --width
    /// 976 --height 454` (libaom, 2026-08-13) and pasted verbatim.
    ///
    /// Every other case in this file is built by the `BitWriter` above, so a misreading shared
    /// by the writer and the reader would pass all of them. These twelve bytes were produced by
    /// an encoder that has never seen this code, and their layout was checked by hand against
    /// the spec: type 1, size 10, `seq_level_idx = 5` (≤ 7, so no `seq_tier`),
    /// `frame_width_bits_minus_1 = 9` → 10 bits, `frame_height_bits_minus_1 = 8` → 9 bits,
    /// `max_frame_width_minus_1 = 0b1111001111 = 975`, `max_frame_height_minus_1 =
    /// 0b111000101 = 453`.
    func testParsesARealLibaomSequenceHeader() throws {
        let bytes: [UInt8] = [0x0a, 0x0a, 0x00, 0x00, 0x00, 0x2c,
                              0xc7, 0x9f, 0xc5, 0x00, 0x68, 0x02]
        let header = try XCTUnwrap(AV1Bitstream.sequenceHeader(in: bytes))
        XCTAssertEqual(header.maxFrameWidth, 976)
        XCTAssertEqual(header.maxFrameHeight, 454)
        XCTAssertEqual(header.seqProfile, 0)
        XCTAssertEqual(header.obu, bytes, "the whole OBU is what an av1C record carries")
    }

    // MARK: - nil, which means "ask for a keyframe"

    /// The ordinary case: an inter frame carries no sequence header. Nil here is not a failure,
    /// it is how the decoder learns it cannot start yet.
    func testNoSequenceHeaderReturnsNil() {
        let unit = Self.obu(type: 2, payload: []) + Self.obu(type: 6, payload: [0x01, 0x02])
        XCTAssertNil(AV1Bitstream.sequenceHeader(in: unit))
    }

    /// A truncated header must decode to NOTHING rather than to a plausible size — the same
    /// rule `ViewerStampDecode` follows for a truncated stamp, and for the same reason.
    func testTruncatedSequenceHeaderReturnsNil() {
        let payload = Self.simpleSequenceHeaderPayload(width: 1280, height: 720)
        let full = Self.obu(type: 1, payload: payload)
        for cut in 1 ... 4 {
            XCTAssertNil(AV1Bitstream.sequenceHeader(in: Array(full.dropLast(cut))),
                          "dropping \(cut) trailing byte(s) must not still parse")
        }
    }

    /// THE BIT READER IS BOUNDED BY THE OBU, NOT BY THE ACCESS UNIT — and this is the case that
    /// shows why. A sequence-header OBU whose declared size is too short to hold the header is
    /// followed here by a frame OBU with plenty of bytes: a reader bounded by the buffer would
    /// keep going, read the FRAME's payload as sequence-header bits, and return a perfectly
    /// well-formed wrong resolution. Truncating the whole buffer instead (the test above) does
    /// NOT distinguish the two bounds, because both shrink together.
    ///
    /// Found by mutation: replacing the OBU bound with the buffer bound left every other test
    /// in this file green.
    func testDoesNotReadPastTheSequenceHeaderOBUIntoTheNextOne() {
        let payload = Self.simpleSequenceHeaderPayload(width: 1280, height: 720)
        let short = Array(payload.prefix(4))          // half a header, honestly declared
        let unit = Self.obu(type: 1, payload: short)
            + Self.obu(type: 6, payload: [UInt8](repeating: 0xFF, count: 64))
        XCTAssertNil(AV1Bitstream.sequenceHeader(in: unit),
                      "a short sequence header must not be completed from the next OBU")
    }

    /// A size field claiming more bytes than the access unit holds is a malformed unit, not a
    /// short read to be tolerated.
    func testSizeFieldBeyondTheBufferReturnsNil() {
        let payload = Self.simpleSequenceHeaderPayload(width: 1280, height: 720)
        var unit = Self.obu(type: 1, payload: payload)
        unit[1] = 0x40                     // claim 64 payload bytes; only 8 are present
        XCTAssertNil(AV1Bitstream.sequenceHeader(in: unit))
    }

    /// `obu_forbidden_bit` set means these bytes are not an OBU stream. Walking on would read
    /// noise as structure.
    func testForbiddenBitReturnsNil() {
        var unit = Self.obu(type: 1, payload: Self.simpleSequenceHeaderPayload(width: 64, height: 64))
        unit[0] |= 0x80
        XCTAssertNil(AV1Bitstream.sequenceHeader(in: unit))
    }

    func testEmptyAccessUnitReturnsNil() {
        XCTAssertNil(AV1Bitstream.sequenceHeader(in: []))
    }

    // MARK: - BitReader's own bound

    /// `BitReader` DOCUMENTS that it returns nil past the end rather than trapping — "a truncated
    /// sequence header must fail the parse, not the process". That was true only because the one
    /// caller checks `size <= accessUnit.count - offset` before constructing one, i.e. it was a
    /// property of the CALLER, and a second caller (or that check moving) turned the documented
    /// nil into an index-out-of-range trap. These two cases construct a reader whose window
    /// exceeds the buffer, which is exactly what that caller-side check prevents.
    ///
    /// A failure here is a CRASH, not a red assertion — which is the point: the whole difference
    /// between the two implementations is process death versus nil.
    func testBitReaderClampsToTheBufferWhenTheWindowOverruns() {
        var reader = AV1Bitstream.BitReader([0xff, 0x00], from: 0, count: 64)
        XCTAssertEqual(reader.f(8), 0xff)
        XCTAssertEqual(reader.f(8), 0x00)
        XCTAssertNil(reader.f(1), "past the buffer must be nil, not a trap")
    }

    /// The same overrun reached through `uvlc()`, which loops on `f(1)` until it sees a 1 bit —
    /// an all-zero tail runs it straight off the end.
    func testBitReaderUvlcStopsAtTheBufferEnd() {
        var reader = AV1Bitstream.BitReader([0x00], from: 0, count: 32)
        XCTAssertNil(reader.uvlc())
    }

    /// A start offset entirely outside the buffer is still nil rather than a trap.
    func testBitReaderStartingPastTheBufferReturnsNil() {
        var reader = AV1Bitstream.BitReader([0x01], from: 4, count: 4)
        XCTAssertNil(reader.f(1))
    }
}
