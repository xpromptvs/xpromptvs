import Foundation
import XCTest

import CoreVideo
import LLVCore
import RdevCore
@testable import RdevHostKit

/// `RdevHostKit` had no test target until 2026-08-19, and AGENTS.md said to verify host changes with
/// `bazelisk build` plus the smokes. That is not adequate for `LLVEncoderAdapter`'s delivery
/// contract: a threading change is invisible to a build, and the smokes cannot construct a non-AV1
/// encoder at all. Kept deliberately small — pure, derivable logic still belongs in RdevCore.
final class LLVEncoderAdapterTests: XCTestCase {
    func testAdapterReportsItsCodec() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "test")
        XCTAssertEqual(adapter.codec, .av1)
    }

    /// A frame must reach the sinks even when the encoder delivers its access unit AFTER `encode`
    /// has returned. The previous design read the unit out of a field on the line after
    /// `enc.encode(...)`, so an asynchronous backend silently dropped every frame — the exact
    /// failure H.264/H.265 would have hit.
    func testDeliveryDoesNotRequireSynchronousOutput() {
        let sink = RecordingTrackSink()
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "test")
        adapter.addSink(sink)

        // Delivered the way an off-thread backend would: no `encode` in flight, no lock held.
        adapter.deliverForTest(.success(EncodedAccessUnit(
            frameID: 1, inputSequence: 1, isKeyframe: true,
            encodeNanoseconds: 1_000_000, data: Data([0xAA, 0xBB])
        )))

        XCTAssertEqual(sink.writes.count, 1)
        XCTAssertEqual(sink.writes.first?.keyframe, true)
        XCTAssertEqual(sink.writes.first?.bytes, [0xAA, 0xBB])
    }

    func testAdapterDefaultsToAV1() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "test")
        XCTAssertEqual(adapter.codec, .av1, "nothing passes a codec yet; the default must not move")
    }

    /// `SimManager.ensureEncoder` compares this against the freshly negotiated codec to decide
    /// whether a pooled encoder can be reused. A wrong value silently reuses an AV1 encoder on a
    /// track that negotiated H.265 — RTP flows, every state reads healthy, nothing decodes.
    func testAdapterReportsTheCodecItWasBuiltWith() {
        for codec in NegotiatedCodec.allCases {
            let adapter = LLVEncoderAdapter(
                fps: 60, bitrateBps: 2_000_000, label: "test", codec: codec
            )
            XCTAssertEqual(adapter.codec, codec)
        }
    }

    /// The 72…3840 x 64…2160 clamp is LIBAOM's. Applying it to VideoToolbox would announce a
    /// downscale nothing required.
    func testDimensionBoundsFollowTheBackend() {
        let av1 = LLVEncoderAdapter.dimensionBounds(for: .av1)
        XCTAssertEqual(av1.maxWidth, RealtimeVideoDimensions.maximumWidth)
        XCTAssertEqual(av1.maxHeight, RealtimeVideoDimensions.maximumHeight)

        for codec in [NegotiatedCodec.h264, .h265] {
            let vt = LLVEncoderAdapter.dimensionBounds(for: codec)
            XCTAssertGreaterThan(vt.maxWidth, av1.maxWidth, "\(codec)")
            XCTAssertGreaterThan(vt.maxHeight, av1.maxHeight, "\(codec)")
        }
    }

    /// END TO END THROUGH THE REAL VIDEOTOOLBOX BACKEND: a BGRA frame in, an access unit out.
    /// Everything else here asserts plumbing; this is what would catch the backend refusing to run.
    ///
    /// It WAITS rather than reading immediately, because VideoToolbox delivers asynchronously —
    /// which is the whole reason delivery moved into `receive`. A synchronous read would pass
    /// against libaom and fail here, which is exactly the bug being guarded.
    func testVideoToolboxAdapterEncodesAFrame() throws {
        for codec in [NegotiatedCodec.h264, .h265] {
            let sink = RecordingTrackSink()
            let adapter = LLVEncoderAdapter(
                fps: 60, bitrateBps: 2_000_000, label: "test", codec: codec
            )
            adapter.addSink(sink)
            adapter.requestKeyframe()

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            let buffer = try XCTUnwrap(pixelBuffer)
            adapter.encode(buffer, ptsNs: 12_345)

            let deadline = Date().addingTimeInterval(5)
            while sink.writes.isEmpty && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertFalse(sink.writes.isEmpty, "\(codec): VideoToolbox delivered no access unit")
            XCTAssertEqual(sink.writes.first?.keyframe, true, "\(codec)")
            XCTAssertEqual(sink.writes.first?.ptsNs, 12_345, "\(codec): pts lost across the handoff")
            adapter.invalidate()
        }
    }

    /// A STANDING CONSTRAINT, PINNED SO IT FAILS HERE RATHER THAN IN THE FIELD.
    ///
    /// `repeatLastFrame` is how a cadence controller re-sends the last picture without re-encoding.
    /// The VideoToolbox backend cannot do it and throws; libaom can. rdev calls it from NOWHERE
    /// today (grep across host/RdevHostKit, host/RdevCore and tools), which is the only reason
    /// H.264/H.265 are viable at all — a future caller would break them, and would break them
    /// SILENTLY if the throw were ever swallowed at the call site.
    ///
    /// This asserts the asymmetry rather than assuming it, so the day someone wires a repeat path
    /// they get a red test naming the constraint instead of a codec that mysteriously stalls.
    func testRepeatLastFrameIsLibaomOnly() throws {
        for codec in [LLVCore.VideoCodec.h264, .hevc] {
            let encoder = try RealtimeVideoEncoder(
                codec: codec, width: 640, height: 360, fps: 60, bitrate: 2_000_000,
                scalabilityMode: .l1t1,
                av1ObservationHandler: { _ in },
                outputHandler: { _ in }
            )
            XCTAssertThrowsError(
                try encoder.repeatLastFrame(frameID: 1, inputSequence: 1, forceKeyframe: false),
                "\(codec): must refuse rather than silently emit nothing"
            )
        }
    }

    /// H.264/H.265 MUST NOT SHIP UNTAGGED COLOUR. Untagged, the decoder guesses from RESOLUTION, so
    /// colour shifts as Auto changes the scale mid-session — measured on rdev's earlier VideoToolbox
    /// path at 24/255 worst-channel error at 640x360 against 2/255 tagged, and invisible above
    /// ~720px wide.
    ///
    /// This also proves VideoToolbox ACCEPTED all three: `set` throws on a refused property, so a
    /// constructed encoder is itself the evidence. A refused property would otherwise encode
    /// perfectly and read exactly like an applied one.
    func testVideoToolboxEncoderTagsBT709() throws {
        for codec in [LLVCore.VideoCodec.h264, .hevc] {
            let encoder = try LLVCore.VideoEncoder(
                codec: codec, width: 640, height: 360, fps: 60, bitrate: 2_000_000,
                temporalCompression: true, outputHandler: { _ in }
            )
            XCTAssertEqual(encoder.acceptedSettings.colorPrimaries, "ITU_R_709_2", "\(codec)")
            XCTAssertEqual(encoder.acceptedSettings.transferFunction, "ITU_R_709_2", "\(codec)")
            XCTAssertEqual(encoder.acceptedSettings.yCbCrMatrix, "ITU_R_709_2", "\(codec)")
        }
    }

    /// A PERIODIC IDR IS A LARGE FRACTION OF A SECOND'S BUDGET. This encoder set
    /// MaxKeyFrameInterval to `fps` — one keyframe per second at 60fps — and measured on a real
    /// iPad session at 1.9 Mbit/s that was 26-54% of the wire, with the picture starved to pay for
    /// it. rdev forces a keyframe on connect and on every PLI, so a timer-driven one buys nothing.
    ///
    /// Read back off the session, never restated from the request — `set` succeeding proves it was
    /// accepted, but not what value the session actually holds. Deleting the interval `set` fails
    /// this test with `Optional(60)`, i.e. the session's real value.
    ///
    /// THE TWO ASSERTIONS HAVE DIFFERENT POWER, AND SAYING SO IS THE POINT. The interval one
    /// catches omission. The duration one CANNOT: measured 2026-08-20, commenting out its `set`
    /// leaves this test green, because VideoToolbox's default for MaxKeyFrameIntervalDuration is
    /// already 0. It is kept because it catches the case that would actually hurt — someone setting
    /// a NON-ZERO duration, which reintroduces a periodic IDR while the frame interval still reads
    /// as infinite — but it is not evidence that the `set` beside it is present, and a reader must
    /// not treat it as such.
    func testVideoToolboxEncoderUsesAnInfiniteGOP() throws {
        for codec in [LLVCore.VideoCodec.h264, .hevc] {
            let encoder = try LLVCore.VideoEncoder(
                codec: codec, width: 640, height: 360, fps: 60, bitrate: 2_000_000,
                temporalCompression: true, outputHandler: { _ in }
            )
            XCTAssertEqual(
                encoder.acceptedSettings.keyframeInterval, Int(Int32.max),
                "\(codec): periodic IDR still configured"
            )
            XCTAssertEqual(
                encoder.acceptedSettings.maxKeyFrameIntervalDuration, 0,
                "\(codec): a duration-based IDR would fire even with an infinite frame interval"
            )
        }
    }

    /// THE TITLEBAR BITRATE CONTROL WAS DEAD ON H.264/H.265. RealtimeVideoEncoder.setBitrate threw
    /// unsupportedCodec on the VideoToolbox backend unconditionally — not a platform limit, since
    /// AverageBitRate is settable on a live session and rdev's own VTEncoder always did it. It was
    /// simply unimplemented, and it is called on every client bitrate change AND every FlexFEC
    /// policy update, which is how the adaptive controller applies its media/FEC split.
    ///
    /// Observed on a real iPad: `asked=9500kbps` against `produced 1536kbps`, because the session
    /// was still at the 1900kbps it was constructed with.
    ///
    /// READ BACK off the live session. `acceptedSettings` is captured at init and structurally
    /// cannot answer whether a LATER retarget took effect, which is the entire question.
    func testVideoToolboxBitrateRetargetReachesTheSession() throws {
        for codec in [LLVCore.VideoCodec.h264, .hevc] {
            let encoder = try LLVCore.VideoEncoder(
                codec: codec, width: 640, height: 360, fps: 60, bitrate: 2_000_000,
                temporalCompression: true, outputHandler: { _ in }
            )
            XCTAssertEqual(encoder.appliedBitrate, 2_000_000, "\(codec): initial")
            try encoder.setBitrate(6_000_000)
            XCTAssertEqual(encoder.appliedBitrate, 6_000_000, "\(codec): after retarget")
        }
    }

    /// The router half, and `currentBitrate` with it. `testRepeatLastFrameIsLibaomOnly` pins that
    /// repeatLastFrame is libaom-only BY DESIGN; this pins that setBitrate is NOT, so the two
    /// asymmetries cannot be mistaken for one rule about the VideoToolbox backend.
    ///
    /// `currentBitrate` is asserted because it had to change WITH the setter: its VideoToolbox arm
    /// returned a fixed startup value, coherent only while the setter refused. Without this, a
    /// working setBitrate would sit beside a currentBitrate reporting the old figure forever.
    func testRealtimeEncoderRetargetsBitrateOnBothBackends() throws {
        for codec in [LLVCore.VideoCodec.h264, .hevc] {
            let encoder = try RealtimeVideoEncoder(
                codec: codec, width: 640, height: 360, fps: 60, bitrate: 2_000_000,
                scalabilityMode: .l1t1,
                av1ObservationHandler: { _ in },
                outputHandler: { _ in }
            )
            XCTAssertEqual(encoder.currentBitrate, 2_000_000, "\(codec): initial")
            XCTAssertNoThrow(try encoder.setBitrate(6_000_000), "\(codec)")
            XCTAssertEqual(encoder.currentBitrate, 6_000_000, "\(codec): currentBitrate must track")
        }
    }

    /// A DROPPED FRAME IS NOT AN ERROR. `noErr` with a nil sample buffer is VideoToolbox's signal
    /// that the low-latency rate controller discarded a frame to hold the bitrate — AGENTS.md
    /// records it doing exactly that (131 of 180 frames at 1652x1080). LLVCore surfaces it as
    /// `missingSampleBuffer`, and logging it per frame produced HUNDREDS of lines in one iPad
    /// session, burying real errors in the one log that knows what is actually being encoded.
    ///
    /// The count is also the instrument for the infinite-GOP change: drops are believed to be a
    /// CONSEQUENCE of keyframes eating the budget, so it should fall. If it does not, they have
    /// another cause and that is worth knowing.
    func testDroppedFramesAreCountedNotReportedAsErrors() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "test")
        XCTAssertEqual(adapter.dropsForTest, 0)

        adapter.deliverForTest(.failure(VideoEncoderError.missingSampleBuffer))
        adapter.deliverForTest(.failure(VideoEncoderError.missingSampleBuffer))
        XCTAssertEqual(adapter.dropsForTest, 2, "a rate-control drop must be counted")

        // A REAL failure must NOT be counted as a drop, or the number stops meaning anything and a
        // genuine encoder fault is silently absorbed into a statistic.
        adapter.deliverForTest(.failure(VideoEncoderError.unsupportedCodec))
        XCTAssertEqual(adapter.dropsForTest, 2, "a genuine failure is not a drop")
    }

    /// THE DISCRIMINATOR FOR "STILL TOO MANY KEYFRAMES ON STILL CONTENT", and it exists because the
    /// infinite-GOP fix worked and was still not enough. That fix removed the ~5 periodic IDRs a
    /// 60-frame interval yields per 5 s window at 60 fps, and a real iPad went 6-15 keyframes per
    /// window to 4-7 — so it did what it claimed AND revealed a second source that was always there.
    ///
    /// Requests and attaches are counted SEPARATELY because they want different fixes: receiver
    /// PLI/FIR means recovery is failing (FlexFEC is disabled on H.265 until the frame-boundary work
    /// lands), while attach churn would mean tracks are being rebound. A single total could not tell
    /// them apart, and guessing between them is what this counter exists to stop.
    func testKeyframeRequestsAndSinkAttachesAreCountedSeparately() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "test")
        XCTAssertEqual(adapter.keyframeRequestsForTest, 0)
        XCTAssertEqual(adapter.sinkAttachesForTest, 0)

        adapter.requestKeyframe()
        adapter.requestKeyframe()
        XCTAssertEqual(adapter.keyframeRequestsForTest, 2, "a keyframe request must be counted")
        XCTAssertEqual(adapter.sinkAttachesForTest, 0, "a request is not an attach")

        adapter.addSink(RecordingTrackSink())
        XCTAssertEqual(adapter.sinkAttachesForTest, 1, "an attach forces a keyframe and is counted")
        XCTAssertEqual(
            adapter.keyframeRequestsForTest, 2,
            "an attach must NOT inflate the request count — telling the two apart is the entire "
                + "purpose of these counters"
        )
    }

    /// An access unit whose frame id was never parked ships with pts 0 rather than being dropped.
    /// A wrong timestamp is something the client's jitter buffer absorbs; no picture is not.
    func testUnknownFrameIDStillDelivers() {
        let sink = RecordingTrackSink()
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "test")
        adapter.addSink(sink)

        adapter.deliverForTest(.success(EncodedAccessUnit(
            frameID: 9_999, inputSequence: 9_999, isKeyframe: false,
            encodeNanoseconds: 0, data: Data([0x01])
        )))

        XCTAssertEqual(sink.writes.count, 1)
        XCTAssertEqual(sink.writes.first?.ptsNs, 0)
    }
}

/// A `VideoTrackSink` that records instead of writing to the wire.
///
/// LOCK-GUARDED DELIBERATELY: the whole point of these tests is that `receive` may run on a thread
/// the adapter does not own, so a test double that assumed single-threaded access would be
/// assuming away the property under test.
final class RecordingTrackSink: VideoTrackSink, @unchecked Sendable {
    struct Write { let bytes: [UInt8]; let ptsNs: Int64; let keyframe: Bool }

    private let lock = NSLock()
    private var storage: [Write] = []
    var writes: [Write] { lock.lock(); defer { lock.unlock() }; return storage }

    var sinkKey: SinkKey { SinkKey(peer: ObjectIdentifier(self), slot: 0) }

    func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool) {
        lock.lock()
        storage.append(Write(bytes: payload, ptsNs: ptsNs, keyframe: keyframe))
        lock.unlock()
    }
}

// ── the viewer's crop ────────────────────────────────────────────────────────────────────────────
extension LLVEncoderAdapterTests {
    /// A solid-white BGRA frame, so masked pixels (dark checkerboard) and kept pixels (bright luma)
    /// are unmistakable in the staging plane.
    private func whiteBGRA(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height { memset(base + row * stride, 0xFF, width * 4) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func isCheckerboard(_ v: Int) -> Bool {
        v == Int(Checkerboard.darkY) || v == Int(Checkerboard.lightY)
    }

    /// THE TEST THE WHOLE FEATURE RESTS ON: after one encoded frame with a crop, the staging plane
    /// carries the source inside the crop and the checkerboard outside it.
    ///
    /// It reads the adapter's OWN staging buffer rather than a decoded frame, which is what makes it
    /// runnable in-process with no network, no decoder and no host. The decoded-pixel version would
    /// need `gate-rdev-viewer.sh` and is separate work.
    func testACropMasksEverythingOutsideItInTheStagingPlane() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "crop-test", codec: .av1)
        adapter.setCrop(CropRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5))   // bottom-right quarter
        adapter.encode(whiteBGRA(width: 640, height: 480), ptsNs: 1)

        guard let s = adapter.stagingLumaForTest() else {
            return XCTFail("no staging plane — the frame never reached the converter")
        }
        XCTAssertEqual(s.width, 640)
        XCTAssertEqual(s.height, 480)
        let at = { (col: Int, row: Int) in Int(s.bytes[row * s.stride + col]) }

        // Inside the crop: white BGRA is high luma. Video range tops out at 235.
        XCTAssertGreaterThan(at(500, 400), 200, "the crop must carry the source, not the mask")
        // Outside it, on all four sides of the kept quarter.
        for (col, row) in [(10, 10), (500, 10), (10, 400), (320, 239)] {
            XCTAssertTrue(isCheckerboard(at(col, row)),
                          "pixel \(col),\(row) reads \(at(col, row)) — outside the crop must be the checkerboard")
        }
    }

    /// A FULL CROP MUST COST NOTHING AND CHANGE NOTHING. This is the default every source runs at,
    /// and it is the non-zero guard for the test above: without it, a converter that simply never
    /// painted would pass that one.
    func testAFullCropLeavesEveryPixelAsTheSource() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "full-test", codec: .av1)
        adapter.setCrop(.full)
        adapter.encode(whiteBGRA(width: 640, height: 480), ptsNs: 1)
        guard let s = adapter.stagingLumaForTest() else { return XCTFail("no staging plane") }
        for (col, row) in [(10, 10), (500, 10), (10, 400), (500, 400), (320, 239)] {
            XCTAssertGreaterThan(Int(s.bytes[row * s.stride + col]), 200,
                                 "pixel \(col),\(row) was masked under a FULL crop")
        }
    }

    /// A RECREATED ENCODER GETS A FRESH STAGING BUFFER, so a mask painted only on crop CHANGES would
    /// vanish the next time Auto moved the scale — which is the moment the user zooms, the moment
    /// this feature exists for. Driving two different frame sizes forces the recreate.
    func testTheMaskSurvivesAResolutionChange() {
        let adapter = LLVEncoderAdapter(fps: 60, bitrateBps: 2_000_000, label: "recreate-test", codec: .av1)
        adapter.setCrop(CropRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5))
        adapter.encode(whiteBGRA(width: 640, height: 480), ptsNs: 1)
        adapter.encode(whiteBGRA(width: 800, height: 600), ptsNs: 2)   // forces recreate()
        guard let s = adapter.stagingLumaForTest() else { return XCTFail("no staging plane") }
        XCTAssertEqual(s.width, 800)
        let v = Int(s.bytes[10 * s.stride + 10])
        XCTAssertTrue(isCheckerboard(v),
                      "after a resolution change the mask read \(v) — the fresh staging was not painted")
    }
}
