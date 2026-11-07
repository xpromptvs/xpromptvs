import Foundation
import RdevCore

/// WHAT AN AUDIO ENCODER NEEDS FROM A DELIVERY TARGET — the `VideoTrackSink` contract, for audio.
///
/// `SinkKey` is REUSED from TrackSink.swift rather than redefined: two different sink objects for
/// the same (peer, slot) must collide in the encoder's map so a re-created sink REPLACES its
/// predecessor, and that rule does not change with the media type.
public protocol AudioTrackSink: AnyObject {
    var sinkKey: SinkKey { get }
    func writeAudio(_ payload: [UInt8], ptsNs: Int64)
}

/// A pluggable audio encoder the capture source feeds and clients subscribe to, mirroring
/// `VideoEncoding`. One encode fans out to every registered sink, so N clients watching one window
/// cost ONE encode.
///
/// IT NEEDS NO CODEC NEGOTIATION, which is the one place it diverges from `VideoEncoding`: Opus is
/// the only audio codec rdev registers, so there is no `codec-resolved` round trip and this encoder
/// is built at SUBSCRIBE time rather than lazily.
public protocol AudioEncoding: AnyObject {
    func encode(_ frame: AudioFraming.Frame)
    func addSink(_ s: any AudioTrackSink)
    func removeSink(_ s: any AudioTrackSink)
    func removeAllSinks()
    func setBitrate(_ v: Int)
    /// Tear the encoder's underlying resources down deterministically, ahead of and idempotent with
    /// whatever `deinit` also does. `encode` is a no-op afterwards rather than a trap.
    func invalidate()
}
