import CoreVideo
import Foundation
import RdevCore

/// REHOMED FROM `VTEncoder.swift`, WHICH IS GONE. Both protocols were declared inside the
/// VideoToolbox encoder's file, so deleting that file would have taken the protocol every capture
/// source and every encoder is written against with it. They live here because they belong to
/// neither implementation: `ScreenCaptureSource`, `TestPatternSource` and `FrameOverlaySink` all
/// speak `VideoFrameSink`, and `SourceStream`, `SimManager` and `ChannelHub` all speak
/// `VideoEncoding`.
///
/// The only conformance left is `LLVEncoderAdapter` (libaom AV1, in LLV's engine). `VTEncoder`
/// (H.264/H.265, VideoToolbox) and `AV1Encoder` (SVT-AV1 through the deleted Go bridge) went with
/// the transport swap: rdev is AV1-only, and the SVT handle ABI they used no longer exists.
public protocol VideoFrameSink: AnyObject {
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64)
}

/// A pluggable video encoder the capture source feeds and clients subscribe to. Delivery is
/// slot-addressed: each encoded access unit fans out to every registered `TrackSink` (one dynamic
/// track on one peer), so N clients watching one window cost ONE encode.
public protocol VideoEncoding: VideoFrameSink, AnyObject {
    /// The codec this encoder actually produces. Compared against the negotiated codec by
    /// `SimManager.ensureEncoder` to decide whether a pooled encoder can be reused or must be
    /// rebuilt. Always `.av1` now that the engine registers AV1 and nothing else — kept as a
    /// property rather than assumed, because it is what makes that reuse check honest.
    var codec: NegotiatedCodec { get }
    func addSink(_ s: any VideoTrackSink)
    func removeSink(_ s: any VideoTrackSink)
    func removeAllSinks()
    func requestKeyframe()
    func requestRecovery(_ intent: RecoveryIntent)
    func setFps(_ v: Int)
    func setBitrate(_ v: Int)
    /// The region the viewer can actually see; everything outside it is filled with a checkerboard so
    /// the bitrate goes where it is being looked at. Live-tunable like fps and bitrate, and for the
    /// same reason it sits beside them: it changes no DIMENSION, so it costs no encoder recreate and
    /// no keyframe. `.full` is the default and means no mask at all.
    func setCrop(_ v: CropRect)
    /// Tear the encoder's underlying resources down deterministically (grace-pool teardown) — ahead
    /// of and idempotent with whatever `deinit` also does when the last reference drops. Callers
    /// MUST NOT call `encode(_:ptsNs:)` afterward (the feeding capture source is expected to
    /// already be stopped).
    func invalidate()
}

public extension VideoEncoding {
    func requestRecovery(_ intent: RecoveryIntent) { requestKeyframe() }
}
