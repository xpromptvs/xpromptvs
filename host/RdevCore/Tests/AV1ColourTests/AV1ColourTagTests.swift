import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import LLVCore
import RdevCore
import VideoToolbox
import XCTest

/// **THE COLOUR BUG THIS EXISTS FOR IS INVISIBLE ON ANY LARGE WINDOW.**
///
/// libaom writes CICP `2/2/2` — "unspecified" — into the AV1 sequence header unless it is told
/// otherwise, and a decoder handed "unspecified" GUESSES. VideoToolbox's guess is keyed on
/// RESOLUTION: BT.601 below roughly 720px wide, BT.709 above. rdev converts BGRA with the BT.709
/// matrix (`ColorConvert`), and rdev's `Auto` resolution mode lives on BOTH SIDES of that line, so
/// an untagged stream's colour SHIFTS as the streamed resolution changes — while looking perfect
/// on any window big enough to notice it on.
///
/// The commit that first fixed this for the VideoToolbox encoder (`b4ca5b9`) measured the
/// signature as worst-channel error out of 255: **24 at 320x180 and 640x360, 2 at 816x538,
/// 1280x720 and 1920x1080.** Adopting LLV's libaom encoder reintroduced it, because that path set
/// no colour information at all.
///
/// **REPRODUCED FOR libaom AV1, 2026-08-17**, by removing the three control calls from
/// `CAOMBridge.c` and running this file: **640x360 went 2 → 23, and 1280x720 stayed at 2.** So
/// the shape is the same as `b4ca5b9`'s to within a unit, for a different encoder and a different
/// codec — the heuristic belongs to the decoder, not to the encoder that failed to tag.
///
/// **WHY THE SUITE HAS CONTROL ARMS — there are exactly TWO, and the count matters.** Every test
/// here that asserts the FIX would also pass if VideoToolbox stopped guessing, or if the round trip
/// were somehow too lossy to resolve a matrix error, or if the sample points were wrong.
/// `testUntaggedSmallFrameIsVisiblyWrong` and `testUntaggedSequenceHeaderCarriesNoColourDescription`
/// encode the identical picture with `AV1ColorConfiguration.unspecified` and assert the result is
/// visibly WRONG — so the suite demonstrates its own power to fail on every run, rather than on the
/// day somebody remembered to comment three lines out. If either goes green, these tests have
/// stopped measuring anything and the threshold assertions are worthless until somebody works out
/// why.
///
/// **`testLargeFrameRoundTripsWithinCodecNoise` IS NOT A CONTROL ARM**, though it was counted as
/// one when this landed. It passes with AND without the fix — that is its whole point — so it
/// documents where the bug is invisible and discriminates nothing. A non-discriminating test
/// counted as a control arm is coverage that does not exist.
///
/// **WHY IT IS ITS OWN TARGET AND NOT PART OF `RdevCoreTests`.** It is not a test of RdevCore: it
/// drives LLV's libaom encoder and a real `VTDecompressionSession`, so it links libaom and needs a
/// working AV1 decoder. `RdevCoreTests` is 488 fast, pure, portable tests and is deliberately not
/// made to link an encoder. It lives HERE rather than beside the engine because the engine's own
/// `Tests/` tree is frozen (gate G1), and beside `RdevHostKit` it would have to link pion and
/// AppKit to say the same thing. What it does use from RdevCore is exactly what rdev contributes
/// to the colour path: `ColorConvert`'s BT.709 conversion and `AV1Bitstream`'s sequence-header
/// parse.
final class AV1ColourTagTests: XCTestCase {
    /// The threshold for "codec noise, not a colour bug". `b4ca5b9` measured 2/255 on a correctly
    /// tagged round trip and 24/255 on an untagged one; anything in between is neither.
    private static let noiseCeiling = 5

    // MARK: - the round trip

    func testSmallFrameRoundTripsWithinCodecNoise() throws {
        let error = try worstChannelError(width: 640, height: 360, color: .bt709)
        XCTAssertLessThanOrEqual(
            error, Self.noiseCeiling,
            "untagged AV1 makes the decoder guess the matrix from the resolution; b4ca5b9 "
                + "measured 24/255 here, and this size is where the bug lives")
    }

    /// The size at which the bug is INVISIBLE, asserted so the suite records that too. **This
    /// passes with and without the fix — measured, not assumed: worst-channel error 2 either
    /// way.** That is the point. A check that only ever looked at a large window would have called
    /// the broken encoder correct, and every casual look at rdev is at a window this size.
    func testLargeFrameRoundTripsWithinCodecNoise() throws {
        let error = try worstChannelError(width: 1280, height: 720, color: .bt709)
        XCTAssertLessThanOrEqual(error, Self.noiseCeiling)
    }

    /// THE CONTROL ARM. Same picture, same encoder, same decoder — only the colour description is
    /// withheld. See the type comment for why a suite like this is worth nothing without it.
    func testUntaggedSmallFrameIsVisiblyWrong() throws {
        let error = try worstChannelError(width: 640, height: 360, color: .unspecified)
        XCTAssertGreaterThan(
            error, Self.noiseCeiling * 2,
            "the untagged control decoded as accurately as the tagged one. Either VideoToolbox "
                + "stopped applying its resolution heuristic, or this harness is no longer "
                + "measuring colour — in which case the assertions in the other tests here are "
                + "measuring nothing either.")
    }

    // MARK: - the bitstream itself

    /// The DIRECT check, and the only readback that exists. libaom publishes no GET control for
    /// its colour settings (its whole `AV1E_GET_*`/`AOME_GET_*` set is the quantizer, loop-filter
    /// level, active map, sequence-level indices, operating-point count, GF interval/info, CDEF
    /// strength and the high-motion screen flag) — but the CICP is written into the sequence
    /// header, so it can be read straight back out of the encoded bytes. This one cannot be fooled
    /// by a decoder's behaviour, and it is what keeps the round-trip tests above honest.
    func testSequenceHeaderCarriesBT709CICP() throws {
        let colour = try sequenceHeaderColour(width: 640, height: 360, color: .bt709)
        XCTAssertTrue(colour.descriptionPresent, "no color_description_present_flag in the header")
        XCTAssertEqual(colour.colorPrimaries, 1, "color_primaries should be CICP 1 (BT.709)")
        XCTAssertEqual(colour.transferCharacteristics, 1,
                       "transfer_characteristics should be CICP 1 (BT.709)")
        XCTAssertEqual(colour.matrixCoefficients, 1,
                       "matrix_coefficients should be CICP 1 (BT.709)")
        XCTAssertEqual(colour.colorRange, 0, "color_range should be studio/limited")
    }

    /// The control arm for the parse, which is also what proves the parse is aligned: withholding
    /// the colour description has to be VISIBLE in the same bits, or the reader above is finding
    /// `1`s somewhere that is not `color_primaries`.
    func testUntaggedSequenceHeaderCarriesNoColourDescription() throws {
        let colour = try sequenceHeaderColour(width: 640, height: 360, color: .unspecified)
        XCTAssertFalse(colour.descriptionPresent)
        XCTAssertEqual(colour.colorPrimaries, 2, "CICP 2 is 'unspecified' — the decoder guesses")
        XCTAssertEqual(colour.transferCharacteristics, 2)
        XCTAssertEqual(colour.matrixCoefficients, 2)
    }

    // MARK: - cpu-used is a real parameter

    /// `cpu-used` was pinned inside `LibaomTuningProfile` and unreachable from a caller, which is
    /// why rdev's preset ladder went inert when the encoder was swapped. It is a parameter now.
    ///
    /// **Driven through `RealtimeVideoEncoder`, which is the layer that gained the argument** —
    /// `LibaomTuningProfile.replacing(cpuUsed:)` already existed and testing that would prove
    /// nothing about the new plumbing. rdev's own `LLVEncoderAdapter` is `internal` to
    /// `RdevHostKit` and is a one-line passthrough of the same argument.
    ///
    /// **THE DEFAULT MUST STAY 12** — anything else means today's behaviour changed silently, and
    /// this task's whole contract is that it did not.
    func testCpuUsedDefaultsToTwelveAndIsSettable() throws {
        XCTAssertEqual(RealtimeVideoEncoder.defaultCpuUsed, 12)

        let defaulted = try Self.makeRealtimeEncoder(cpuUsed: nil)
        XCTAssertEqual(defaulted.acceptedSettings.cpuUsed, 12,
                       "the default must reach libaom, not merely exist as a constant")

        let pinned = try Self.makeRealtimeEncoder(cpuUsed: 8)
        XCTAssertEqual(pinned.acceptedSettings.cpuUsed, 8, "a caller's value must reach libaom")
    }

    /// `cpuUsed: nil` exercises the DEFAULT ARGUMENT rather than passing 12 by hand — passing it
    /// would test that 12 equals 12 and would survive the default being changed to anything.
    private static func makeRealtimeEncoder(cpuUsed: Int?) throws -> RealtimeVideoEncoder {
        if let cpuUsed {
            return try RealtimeVideoEncoder(
                codec: .av1, width: 640, height: 360, fps: 60, bitrate: 2_000_000,
                temporalCompression: true, scalabilityMode: .l1t1,
                screenDetectionMode: .antialiasingAware, cpuUsed: cpuUsed,
                av1ObservationHandler: { _ in }, outputHandler: { _ in })
        }
        return try RealtimeVideoEncoder(
            codec: .av1, width: 640, height: 360, fps: 60, bitrate: 2_000_000,
            temporalCompression: true, scalabilityMode: .l1t1,
            screenDetectionMode: .antialiasingAware,
            av1ObservationHandler: { _ in }, outputHandler: { _ in })
    }

    // MARK: - encode

    /// R, G, B as horizontal bands. Saturated primaries are where a wrong YCbCr matrix shows up;
    /// grey is the control that does not, because it has no chroma for a matrix to get wrong.
    private static let bands: [(name: String, r: UInt8, g: UInt8, b: UInt8)] = [
        ("red", 255, 0, 0), ("green", 0, 255, 0), ("blue", 0, 0, 255),
        ("magenta", 255, 0, 255), ("grey", 128, 128, 128),
    ]

    private static func makeEncoder(
        width: Int, height: Int, color: AV1ColorConfiguration,
        sink: @escaping @Sendable (Result<EncodedAccessUnit, Error>) -> Void
    ) throws -> AV1Encoder {
        try AV1Encoder(
            width: width, height: height, fps: 60,
            // High enough that quantisation cannot be mistaken for a matrix error: `b4ca5b9`
            // measured 2/255 of pure codec noise on a correct round trip and this has to be able
            // to resolve that against 24.
            bitrate: 20_000_000,
            temporalCompression: true,
            scalabilityMode: .l1t1,
            tuningProfile: .currentControl,
            colorConfiguration: color,
            observationHandler: { _ in },
            outputHandler: sink
        )
    }

    /// Encodes the test card and returns every access unit in order. The picture is static, so the
    /// later frames are nearly free and rate control has converged by the end — which is why the
    /// round trip samples the LAST decoded frame rather than the keyframe.
    private func encodeTestCard(
        width: Int, height: Int, color: AV1ColorConfiguration, frames: Int = 20
    ) throws -> [EncodedAccessUnit] {
        let collected = UnitBox()
        let encoder = try Self.makeEncoder(width: width, height: height, color: color) { result in
            switch result {
            case .success(let unit): collected.append(unit)
            case .failure(let error): collected.fail(error)
            }
        }
        let source = try Self.makeNV12TestCard(width: width, height: height)
        for index in 0 ..< frames {
            try encoder.encode(pixelBuffer: source, frameID: UInt64(index),
                               inputSequence: UInt64(index), forceKeyframe: index == 0)
        }
        if let error = collected.error { throw error }
        let units = collected.units
        XCTAssertEqual(units.count, frames, "libaom is one-in/one-out at lag 0")
        return units
    }

    // MARK: - decode

    /// Encode → decode → compare RGB, returning the worst per-channel error out of 255 across the
    /// band centres. **The decode is what makes this a colour test at all**: VideoToolbox converts
    /// YCbCr to BGRA using the matrix the bitstream declares, or — when it declares none — the one
    /// its own resolution heuristic picks.
    private func worstChannelError(
        width: Int, height: Int, color: AV1ColorConfiguration
    ) throws -> Int {
        let units = try encodeTestCard(width: width, height: height, color: color)
        let header = try XCTUnwrap(AV1Bitstream.sequenceHeader(in: [UInt8](units[0].data)))
        let signalled = try XCTUnwrap(Self.parseColourConfig(header.obu))
        let decoded = try Self.decodeLast(units, width: width, height: height, signalled: signalled)
        var worst = 0
        var detail: [String] = []
        for (index, band) in Self.bands.enumerated() {
            let (r, g, b) = Self.sample(decoded, band: index, width: width, height: height)
            let e = max(abs(Int(r) - Int(band.r)),
                        max(abs(Int(g) - Int(band.g)), abs(Int(b) - Int(band.b))))
            worst = max(worst, e)
            detail.append("\(band.name) want(\(band.r),\(band.g),\(band.b)) "
                + "got(\(r),\(g),\(b)) err \(e)")
        }
        // Printed unconditionally: the NUMBER is the finding here, and a green run that reports
        // nothing leaves the next person re-deriving it.
        print("[av1-colour] \(width)x\(height) primaries="
            + "\(color.colorPrimaries.map(String.init) ?? "unset") worst=\(worst) "
            + detail.joined(separator: " | "))
        return worst
    }

    /// **VIDEOTOOLBOX'S AV1 PATH DOES NOT READ COLOUR OUT OF THE `av1C` SEQUENCE HEADER, AND THAT
    /// IS WHY THIS TAKES `signalled` RATHER THAN JUST THE BYTES.** For H.264 and HEVC,
    /// `CMVideoFormatDescriptionCreateFrom…ParameterSets` parses the VUI and populates the format
    /// description's colour extensions for you. For AV1 there is no such call: the caller builds
    /// the `CMVideoFormatDescription` by hand, and a description with no colour extensions gets
    /// CoreMedia's RESOLUTION-KEYED default regardless of what the bitstream says. Measured
    /// directly, 2026-08-17: an access unit carrying CICP 1/1/1 decoded at 640x360 through a
    /// description with no colour extensions gave worst-channel error **23** — byte-identical to
    /// the untagged control — and **2** once the extensions were attached.
    ///
    /// So this harness reads the colour description out of the sequence header and hands it to
    /// VideoToolbox, which is precisely what a decoder that honours CICP does for itself. That is
    /// what the browser's AV1 decoder (dav1d/libgav1) does, and it is the receiver rdev actually
    /// ships to. What it means for `tools/RdevViewer`, whose AV1 decode also builds its format
    /// description by hand, is a separate question that this test does not answer.
    ///
    /// An ABSENT colour description attaches NOTHING, on purpose: CICP 2 means "unspecified",
    /// whose only correct handling is to fall back to a guess. That is what makes the control arm
    /// a real control rather than a differently-configured decode.
    private static func decodeLast(
        _ units: [EncodedAccessUnit], width: Int, height: Int, signalled: SequenceColour
    ) throws -> CVPixelBuffer {
        let keyframe = try XCTUnwrap(units.first, "no access units to decode")
        let header = try XCTUnwrap(
            AV1Bitstream.sequenceHeader(in: [UInt8](keyframe.data)),
            "the first access unit carries no AV1 sequence header")
        XCTAssertEqual(header.maxFrameWidth, width)
        XCTAssertEqual(header.maxFrameHeight, height)

        let atoms: [String: Any] = ["av1C": Data(AV1Bitstream.configurationRecord(for: header))]
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms as CFDictionary,
        ]
        if signalled.descriptionPresent {
            if let primaries = Self.corePrimaries(signalled.colorPrimaries) {
                extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
            }
            if let transfer = Self.coreTransfer(signalled.transferCharacteristics) {
                extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
            }
            if let matrix = Self.coreMatrix(signalled.matrixCoefficients) {
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
            }
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = signalled.colorRange == 1
        }
        var format: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: Int32(width), height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format)
        let description = try XCTUnwrap(format, "CMVideoFormatDescriptionCreate: \(status)")

        // BGRA OUT IS THE WHOLE MECHANISM. Asking VideoToolbox for NV12 would hand back the coded
        // chroma untouched and the matrix would never be applied, so the test would pass whatever
        // the sequence header said.
        var session: VTDecompressionSession?
        status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        let decoder = try XCTUnwrap(session, "VTDecompressionSessionCreate(AV1): \(status)")
        defer { VTDecompressionSessionInvalidate(decoder) }

        let box = FrameBox()
        for (index, unit) in units.enumerated() {
            let sample = try Self.makeSampleBuffer(unit.data, format: description, index: index)
            status = VTDecompressionSessionDecodeFrame(
                decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil
            ) { decodeStatus, _, image, _, _ in
                if decodeStatus == noErr, let image { box.store(image) }
            }
            XCTAssertEqual(status, noErr, "VTDecompressionSessionDecodeFrame at \(index)")
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return try XCTUnwrap(box.image, "the AV1 decoder produced no frame")
    }

    /// CICP code point → the CoreMedia constant, for the three values this project can produce or
    /// be handed. An unmapped code point returns nil and the extension is simply left off, which
    /// degrades to the same guess an absent description gets — never to a WRONG assertion that
    /// some other primary is BT.709.
    private static func corePrimaries(_ cicp: Int) -> CFString? {
        switch cicp {
        case 1: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 5: kCMFormatDescriptionColorPrimaries_EBU_3213
        case 6: kCMFormatDescriptionColorPrimaries_SMPTE_C
        case 9: kCMFormatDescriptionColorPrimaries_ITU_R_2020
        default: nil
        }
    }

    private static func coreTransfer(_ cicp: Int) -> CFString? {
        switch cicp {
        case 1: kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 16: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 18: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: nil
        }
    }

    private static func coreMatrix(_ cicp: Int) -> CFString? {
        switch cicp {
        case 1: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 5, 6: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case 9: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: nil
        }
    }

    private static func makeSampleBuffer(
        _ data: Data, format: CMVideoFormatDescription, index: Int
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        let blockBuffer = try XCTUnwrap(block, "CMBlockBufferCreateWithMemoryBlock: \(status)")
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        XCTAssertEqual(status, noErr, "CMBlockBufferReplaceDataBytes")

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: Int64(index), timescale: 60),
            decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return try XCTUnwrap(sample, "CMSampleBufferCreateReady: \(status)")
    }

    // MARK: - the test card

    /// BGRA bands converted to NV12 with `ColorConvert` — i.e. by exactly the code rdev's encoder
    /// path uses, at BT.709 video range, which is what makes CICP 1/1/1 the CORRECT tag rather
    /// than merely a chosen one.
    private static func makeNV12TestCard(width: Int, height: Int) throws -> CVPixelBuffer {
        let stride = width * 4
        let bgra = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * height)
        defer { bgra.deallocate() }
        let bandHeight = height / bands.count
        for y in 0 ..< height {
            let band = bands[min(y / bandHeight, bands.count - 1)]
            for x in 0 ..< width {
                let p = bgra + y * stride + x * 4
                p[0] = band.b; p[1] = band.g; p[2] = band.r; p[3] = 255
            }
        }

        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &created)
        let buffer = try XCTUnwrap(created, "CVPixelBufferCreate(NV12): \(status)")
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let cbCr = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let error = ColorConvert.bgraToNV12(
            bgra, width: width, height: height, srcStride: stride,
            y: y, yStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
            cbCr: cbCr, cStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        XCTAssertEqual(error, kvImageNoError, "ColorConvert.bgraToNV12")
        return buffer
    }

    /// The centre pixel of a band, as (R, G, B). Centre rather than an average: a systematic
    /// matrix error is uniform across the band, so averaging would buy nothing and could mask a
    /// small one.
    private static func sample(
        _ buffer: CVPixelBuffer, band: Int, width: Int, height: Int
    ) -> (UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bandHeight = height / bands.count
        let p = base.assumingMemoryBound(to: UInt8.self)
            + (band * bandHeight + bandHeight / 2) * stride + (width / 2) * 4
        return (p[2], p[1], p[0])
    }

    // MARK: - reading color_config() out of the sequence header

    private struct SequenceColour {
        var descriptionPresent = false
        var colorPrimaries = 2
        var transferCharacteristics = 2
        var matrixCoefficients = 2
        var colorRange = 0
    }

    private func sequenceHeaderColour(
        width: Int, height: Int, color: AV1ColorConfiguration
    ) throws -> SequenceColour {
        let units = try encodeTestCard(width: width, height: height, color: color, frames: 1)
        let keyframe = try XCTUnwrap(units.first)
        let header = try XCTUnwrap(AV1Bitstream.sequenceHeader(in: [UInt8](keyframe.data)))
        return try XCTUnwrap(Self.parseColourConfig(header.obu),
                             "could not walk sequence_header_obu() as far as color_config()")
    }

    /// `sequence_header_obu()` (AV1 spec 5.5.1) walked to `color_config()` (5.5.2).
    ///
    /// A SECOND, INDEPENDENT WALK OF THE SAME BYTES `RdevCore.AV1Bitstream` already walks, kept
    /// here on purpose: RdevCore's parser stops at the max frame size because that is all the
    /// product needs, and growing it to reach `color_config()` would put ~60 lines of parser into
    /// the product to serve a test. Every field before the two the product cares about is
    /// therefore read twice, and the two agreeing on width and height (asserted in `decodeLast`)
    /// is a cheap cross-check on both.
    private static func parseColourConfig(_ obu: [UInt8]) -> SequenceColour? {
        // Skip the OBU header: type byte, optional extension byte, then the LEB128 size.
        var offset = 0
        guard obu.count > 1 else { return nil }
        let hasExtension = (obu[0] >> 2) & 1 == 1
        let hasSizeField = (obu[0] >> 1) & 1 == 1
        offset += 1
        if hasExtension { offset += 1 }
        if hasSizeField {
            while offset < obu.count, obu[offset] & 0x80 != 0 { offset += 1 }
            offset += 1
        }
        guard offset < obu.count else { return nil }

        var r = Bits(obu, from: offset)
        guard let seqProfile = r.f(3), r.f(1) != nil,
              let reducedStillPicture = r.f(1) else { return nil }
        var decoderModelInfoPresent = false
        var bufferDelayLength = 0
        if reducedStillPicture == 1 {
            guard r.f(5) != nil else { return nil }
        } else {
            guard let timingInfoPresent = r.f(1) else { return nil }
            if timingInfoPresent == 1 {
                guard r.f(32) != nil, r.f(32) != nil,
                      let equalPictureInterval = r.f(1) else { return nil }
                if equalPictureInterval == 1 {
                    guard r.uvlc() != nil else { return nil }
                }
                guard let present = r.f(1) else { return nil }
                decoderModelInfoPresent = present == 1
                if decoderModelInfoPresent {
                    guard let lengthMinus1 = r.f(5), r.f(32) != nil,
                          r.f(5) != nil, r.f(5) != nil else { return nil }
                    bufferDelayLength = Int(lengthMinus1) + 1
                }
            }
            guard let initialDisplayDelayPresent = r.f(1),
                  let operatingPointsCountMinus1 = r.f(5) else { return nil }
            for _ in 0 ... Int(operatingPointsCountMinus1) {
                guard r.f(12) != nil, let seqLevelIdx = r.f(5) else { return nil }
                if seqLevelIdx > 7 { guard r.f(1) != nil else { return nil } }
                if decoderModelInfoPresent {
                    guard let present = r.f(1) else { return nil }
                    if present == 1 {
                        guard r.f(bufferDelayLength) != nil, r.f(bufferDelayLength) != nil,
                              r.f(1) != nil else { return nil }
                    }
                }
                if initialDisplayDelayPresent == 1 {
                    guard let present = r.f(1) else { return nil }
                    if present == 1 { guard r.f(4) != nil else { return nil } }
                }
            }
        }

        guard let widthBitsMinus1 = r.f(4), let heightBitsMinus1 = r.f(4),
              r.f(Int(widthBitsMinus1) + 1) != nil,
              r.f(Int(heightBitsMinus1) + 1) != nil else { return nil }

        var frameIDNumbersPresent: UInt64 = 0
        if reducedStillPicture == 0 {
            guard let present = r.f(1) else { return nil }
            frameIDNumbersPresent = present
        }
        if frameIDNumbersPresent == 1 {
            guard r.f(4) != nil, r.f(3) != nil else { return nil }
        }
        guard r.f(1) != nil, r.f(1) != nil, r.f(1) != nil else { return nil }
        if reducedStillPicture == 0 {
            guard r.f(1) != nil, r.f(1) != nil, r.f(1) != nil, r.f(1) != nil,
                  let enableOrderHint = r.f(1) else { return nil }
            if enableOrderHint == 1 {
                guard r.f(1) != nil, r.f(1) != nil else { return nil }
            }
            guard let chooseScreenContentTools = r.f(1) else { return nil }
            var forceScreenContentTools: UInt64 = 2
            if chooseScreenContentTools == 0 {
                guard let forced = r.f(1) else { return nil }
                forceScreenContentTools = forced
            }
            if forceScreenContentTools > 0 {
                guard let chooseIntegerMV = r.f(1) else { return nil }
                if chooseIntegerMV == 0 { guard r.f(1) != nil else { return nil } }
            }
            if enableOrderHint == 1 { guard r.f(3) != nil else { return nil } }
        }
        guard r.f(1) != nil, r.f(1) != nil, r.f(1) != nil else { return nil }

        // color_config()
        var colour = SequenceColour()
        guard let highBitDepth = r.f(1) else { return nil }
        if seqProfile == 2, highBitDepth == 1 { guard r.f(1) != nil else { return nil } }
        var monochrome: UInt64 = 0
        if seqProfile != 1 {
            guard let mono = r.f(1) else { return nil }
            monochrome = mono
        }
        guard let descriptionPresent = r.f(1) else { return nil }
        colour.descriptionPresent = descriptionPresent == 1
        if descriptionPresent == 1 {
            guard let primaries = r.f(8), let transfer = r.f(8),
                  let matrix = r.f(8) else { return nil }
            colour.colorPrimaries = Int(primaries)
            colour.transferCharacteristics = Int(transfer)
            colour.matrixCoefficients = Int(matrix)
        }
        if monochrome == 1 {
            guard let range = r.f(1) else { return nil }
            colour.colorRange = Int(range)
            return colour
        }
        // The sRGB/identity shortcut, which implies full range and codes no color_range bit.
        if colour.colorPrimaries == 1, colour.transferCharacteristics == 13,
           colour.matrixCoefficients == 0 {
            colour.colorRange = 1
            return colour
        }
        guard let range = r.f(1) else { return nil }
        colour.colorRange = Int(range)
        return colour
    }

    private struct Bits {
        let bytes: [UInt8]
        var bitOffset: Int
        init(_ bytes: [UInt8], from byte: Int) { self.bytes = bytes; bitOffset = byte * 8 }
        mutating func f(_ n: Int) -> UInt64? {
            var value: UInt64 = 0
            for _ in 0 ..< n {
                let index = bitOffset >> 3
                guard index < bytes.count else { return nil }
                value = (value << 1) | UInt64((bytes[index] >> (7 - UInt8(bitOffset & 7))) & 1)
                bitOffset += 1
            }
            return value
        }
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
}

/// libaom's output handler fires SYNCHRONOUSLY inside `encode`, so no locking is needed for
/// correctness — but the closure is `@Sendable`, so the accumulator has to be a reference type
/// the compiler will accept it capturing.
private final class UnitBox: @unchecked Sendable {
    private(set) var units: [EncodedAccessUnit] = []
    private(set) var error: Error?
    func append(_ unit: EncodedAccessUnit) { units.append(unit) }
    func fail(_ error: Error) { if self.error == nil { self.error = error } }
}

/// Keeps the LAST decoded frame. VideoToolbox's per-frame handler is called on its own queue, so
/// this crosses a thread boundary; every read happens after
/// `VTDecompressionSessionWaitForAsynchronousFrames`.
private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CVPixelBuffer?
    var image: CVPixelBuffer? { lock.withLock { stored } }
    func store(_ buffer: CVPixelBuffer) { lock.withLock { stored = buffer } }
}
