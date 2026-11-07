import Foundation

/// The AV1 sequence header found in an access unit, parsed far enough to give the coded frame
/// size — which is the one thing `CMVideoFormatDescriptionCreate` needs and the AV1 bitstream
/// does not hand over for free.
///
/// WHY THIS EXISTS AT ALL. VideoToolbox's AV1 format description takes `width`/`height` as
/// arguments (unlike H.264/HEVC, whose `…CreateFromParameterSets` reads them out of the SPS),
/// so a decoder either asks its caller for the dimensions or reads them itself. Asking is what
/// LLV's own `VideoDecoder` does, and it is wrong for an INSTRUMENT: a viewer told the wrong
/// size decodes at the wrong size and reports `sourceWidth`/`sourceHeight` that were never
/// measured, only asserted. Reading them makes the report self-describing and lets the same
/// binary point at a sender whose resolution it was never told.
public struct AV1SequenceHeader: Equatable, Sendable {
    /// The sequence-header OBU VERBATIM — header byte, optional extension byte, size field and
    /// payload — i.e. exactly the bytes that follow an `av1C` record's four fixed bytes.
    public let obu: [UInt8]
    public let maxFrameWidth: Int
    public let maxFrameHeight: Int
    public let seqProfile: UInt8

    public init(obu: [UInt8], maxFrameWidth: Int, maxFrameHeight: Int, seqProfile: UInt8) {
        self.obu = obu
        self.maxFrameWidth = maxFrameWidth
        self.maxFrameHeight = maxFrameHeight
        self.seqProfile = seqProfile
    }
}

/// Just enough of the AV1 low-overhead bitstream format to find and read a sequence header.
///
/// Deliberately NOT a general OBU parser: it walks the access unit's OBUs, and it bit-parses
/// `sequence_header_obu()` only as far as `max_frame_height_minus_1`. Everything after that
/// (colour config, superblock size, the CDEF/loop-restoration flags) is left to the decoder,
/// which is the component that actually needs it.
public enum AV1Bitstream {
    /// `OBU_SEQUENCE_HEADER` (AV1 spec §6.2.2).
    public static let sequenceHeaderOBUType: UInt8 = 1

    /// The first sequence-header OBU in `accessUnit`, or nil when the access unit carries none
    /// or is malformed.
    ///
    /// NIL IS THE WHOLE CONTRACT HERE. A frame with no sequence header is the ordinary case —
    /// only keyframes carry one — and a caller that has not yet seen one cannot decode. Nil
    /// therefore means "ask for a keyframe", never "give up", and it must not be confused with
    /// a parse that succeeded and produced a plausible wrong size.
    public static func sequenceHeader(in accessUnit: [UInt8]) -> AV1SequenceHeader? {
        var offset = 0
        while offset < accessUnit.count {
            let obuStart = offset
            let header = accessUnit[offset]
            // obu_forbidden_bit must be 0. A 1 here means these bytes are not an OBU stream at
            // all, so walking further would be reading noise as structure.
            if header & 0x80 != 0 { return nil }
            let type = (header >> 3) & 0x0f
            let hasExtension = (header >> 2) & 1 == 1
            let hasSizeField = (header >> 1) & 1 == 1
            offset += 1
            if hasExtension {
                guard offset < accessUnit.count else { return nil }
                offset += 1
            }

            let payloadStart: Int
            let payloadCount: Int
            if hasSizeField {
                guard let size = readLEB128(accessUnit, offset: &offset) else { return nil }
                payloadStart = offset
                guard size <= UInt64(accessUnit.count - offset) else { return nil }
                payloadCount = Int(size)
            } else {
                // obu_has_size_field == 0 is legal only for the LAST OBU in the unit, whose
                // size is "the rest". Accepting it anywhere else would mis-slice the stream;
                // accepting it here costs nothing because the loop ends after it either way.
                payloadStart = offset
                payloadCount = accessUnit.count - offset
            }
            offset = payloadStart + payloadCount

            if type == sequenceHeaderOBUType {
                guard let parsed = parseSequenceHeaderPayload(
                    accessUnit, from: payloadStart, count: payloadCount) else { return nil }
                return AV1SequenceHeader(
                    obu: Array(accessUnit[obuStart ..< offset]),
                    maxFrameWidth: parsed.width, maxFrameHeight: parsed.height,
                    seqProfile: parsed.profile)
            }
        }
        return nil
    }

    /// The `av1C` (AV1CodecConfigurationRecord) atom VideoToolbox wants in a
    /// `CMVideoFormatDescription`.
    ///
    /// The four leading bytes are the reference's, byte for byte
    /// (`LLVCore/AV1OBU.codecConfigurationRecord`): `marker=1 version=1`, then
    /// `seq_profile=0 seq_level_idx_0=9`, then 4:2:0 8-bit chroma, then a zero
    /// `initial_presentation_delay` byte. THEY ARE NOT DERIVED FROM THE PARSE ON PURPOSE —
    /// the real parameters are in the sequence-header OBU appended right after, which the
    /// decoder reads; the fixed prefix is what the reference receiver hands VideoToolbox, and
    /// this instrument must not differ from it in a way that could itself change decode
    /// behaviour. Deriving these bytes would be a change to the thing being measured.
    public static func configurationRecord(for header: AV1SequenceHeader) -> [UInt8] {
        [0x81, 0x09, 0x0c, 0x00] + header.obu
    }

    // MARK: - internals

    static func readLEB128(_ bytes: [UInt8], offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0 ..< 8 {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    /// A big-endian MSB-first bit reader over a byte slice. Returns nil past the end rather
    /// than trapping: a truncated sequence header must fail the parse, not the process.
    struct BitReader {
        let bytes: [UInt8]
        let end: Int
        var bitOffset: Int

        init(_ bytes: [UInt8], from start: Int, count: Int) {
            self.bytes = bytes
            // CLAMPED TO THE BUFFER, so the promise above is unconditional. `f` bounds against
            // `end` alone, so an `end` past the array is an index-out-of-range TRAP rather than
            // the nil this struct documents. It has never fired: the one caller checks
            // `size <= accessUnit.count - offset` before constructing one. That makes the
            // guarantee a property of the CALLER, which is not what the doc comment claims and
            // not what survives a second caller or a moved check — a truncated sequence header
            // must fail the parse, not the process.
            self.end = min(start + count, bytes.count)
            self.bitOffset = start * 8
        }

        mutating func f(_ n: Int) -> UInt64? {
            guard n >= 0, n <= 64 else { return nil }
            var value: UInt64 = 0
            for _ in 0 ..< n {
                let byteIndex = bitOffset >> 3
                guard byteIndex < end else { return nil }
                let bit = (bytes[byteIndex] >> (7 - UInt8(bitOffset & 7))) & 1
                value = (value << 1) | UInt64(bit)
                bitOffset += 1
            }
            return value
        }

        /// `uvlc()` — AV1 spec §4.10.3. Used once, for `num_ticks_per_picture_minus_1`.
        mutating func uvlc() -> UInt64? {
            var leadingZeros = 0
            while true {
                guard let bit = f(1) else { return nil }
                if bit == 1 { break }
                leadingZeros += 1
                if leadingZeros >= 32 { return UInt64(UInt32.max) }
            }
            guard let value = f(leadingZeros) else { return nil }
            return value + (1 << UInt64(leadingZeros)) - 1
        }
    }

    /// `sequence_header_obu()` (AV1 spec §5.5.1), read as far as the max frame size. Every
    /// branch below is the spec's; the fields that are read and discarded are read because
    /// their WIDTH is what positions the two numbers we want.
    static func parseSequenceHeaderPayload(
        _ bytes: [UInt8], from start: Int, count: Int
    ) -> (width: Int, height: Int, profile: UInt8)? {
        var r = BitReader(bytes, from: start, count: count)
        guard let seqProfile = r.f(3),
              r.f(1) != nil,                                   // still_picture
              let reducedStillPicture = r.f(1) else { return nil }

        var decoderModelInfoPresent = false
        var bufferDelayLength = 0
        if reducedStillPicture == 1 {
            guard r.f(5) != nil else { return nil }            // seq_level_idx[0]
        } else {
            guard let timingInfoPresent = r.f(1) else { return nil }
            if timingInfoPresent == 1 {
                guard r.f(32) != nil,                          // num_units_in_display_tick
                      r.f(32) != nil,                          // time_scale
                      let equalPictureInterval = r.f(1) else { return nil }
                if equalPictureInterval == 1 {
                    guard r.uvlc() != nil else { return nil }  // num_ticks_per_picture_minus_1
                }
                guard let present = r.f(1) else { return nil }
                decoderModelInfoPresent = present == 1
                if decoderModelInfoPresent {
                    guard let bufferDelayLengthMinus1 = r.f(5),
                          r.f(32) != nil,                      // num_units_in_decoding_tick
                          r.f(5) != nil,                       // buffer_removal_time_length_minus_1
                          r.f(5) != nil else { return nil }    // frame_presentation_time_length_minus_1
                    bufferDelayLength = Int(bufferDelayLengthMinus1) + 1
                }
            }
            guard let initialDisplayDelayPresent = r.f(1),
                  let operatingPointsCountMinus1 = r.f(5) else { return nil }
            for _ in 0 ... Int(operatingPointsCountMinus1) {
                guard r.f(12) != nil,                          // operating_point_idc[i]
                      let seqLevelIdx = r.f(5) else { return nil }
                if seqLevelIdx > 7 {
                    guard r.f(1) != nil else { return nil }    // seq_tier[i]
                }
                if decoderModelInfoPresent {
                    guard let opPresent = r.f(1) else { return nil }
                    if opPresent == 1 {
                        guard r.f(bufferDelayLength) != nil,   // decoder_buffer_delay[i]
                              r.f(bufferDelayLength) != nil,   // encoder_buffer_delay[i]
                              r.f(1) != nil else { return nil } // low_delay_mode_flag[i]
                    }
                }
                if initialDisplayDelayPresent == 1 {
                    guard let opPresent = r.f(1) else { return nil }
                    if opPresent == 1 {
                        guard r.f(4) != nil else { return nil } // initial_display_delay_minus_1
                    }
                }
            }
        }

        guard let widthBitsMinus1 = r.f(4), let heightBitsMinus1 = r.f(4),
              let widthMinus1 = r.f(Int(widthBitsMinus1) + 1),
              let heightMinus1 = r.f(Int(heightBitsMinus1) + 1) else { return nil }
        let width = Int(widthMinus1) + 1
        let height = Int(heightMinus1) + 1
        guard width > 0, height > 0 else { return nil }
        return (width, height, UInt8(truncatingIfNeeded: seqProfile))
    }
}
