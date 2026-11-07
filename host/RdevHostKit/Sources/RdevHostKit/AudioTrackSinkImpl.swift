import Foundation

/// A slot-addressed audio delivery target: one audio track on one peer. The audio twin of
/// `TrackSink`.
///
/// IT SHARES `SinkKey` WITH THE VIDEO SINK, and that is deliberate: two sink objects for the same
/// (peer, slot) must collide in an encoder's map so a re-created sink REPLACES its predecessor,
/// and that rule does not change with the media type. The two never share a MAP — a video encoder
/// holds `VideoTrackSink`s and an audio encoder holds `AudioTrackSink`s — so a video slot and an
/// audio slot carrying the same number cannot collide with each other.
public final class AudioSink {
    public let peer: PionPeer
    public let slot: Int32
    public init(peer: PionPeer, slot: Int32) { self.peer = peer; self.slot = slot }
    public func writeAudio(_ payload: [UInt8], ptsNs: Int64) {
        peer.writeTrackAudio(slot: slot, payload, ptsNs: ptsNs)
    }
    var key: SinkKey { SinkKey(peer: ObjectIdentifier(peer), slot: slot) }
}

extension AudioSink: AudioTrackSink {
    public var sinkKey: SinkKey { key }
}
