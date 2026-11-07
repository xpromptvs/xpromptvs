import Foundation

/// WHAT AN ENCODER NEEDS FROM A DELIVERY TARGET: an identity to key it by, and somewhere to put
/// bytes. `TrackSink` is the production conformance and holds a live `PionPeer`.
///
/// IT EXISTS SO THE DELIVERY PATH CAN BE TESTED. `LLVEncoderAdapter`'s handoff is about to stop
/// assuming the encoder calls back inline — libaom does, VideoToolbox does not — and that change is
/// invisible to `bazelisk build` and unreachable from the GUI smokes, which cannot construct a
/// non-AV1 encoder. A test needs a sink, and a `TrackSink` needs a live peer connection. The
/// encoder depends on the ABILITY TO RECEIVE BYTES, not on a peer, so this is the dependency the
/// adapter always had, written down.
///
/// `sinkKey` rather than `key`: `TrackSink.key` is already internal, and a protocol requirement of
/// the same name would silently widen it to the protocol's access level.
/// PUBLIC because `VideoEncoding` is public and names it in `addSink`/`removeSink`. `SinkKey` comes
/// with it for the same reason — it is a requirement of this protocol.
public protocol VideoTrackSink: AnyObject {
    var sinkKey: SinkKey { get }
    func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool)
    func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool, reference: AV1ReferenceFrameMetadata)
}

public extension VideoTrackSink {
    func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool, reference: AV1ReferenceFrameMetadata) {
        writeVideo(payload, ptsNs: ptsNs, keyframe: keyframe)
    }
}

/// A slot-addressed video delivery target: one dynamic track on one peer. Replaces "the peer is a
/// consumer" — an encoder fans encoded access units out to its sinks, each writing to its track slot.
public final class TrackSink {
    public let peer: PionPeer
    public let slot: Int32
    public init(peer: PionPeer, slot: Int32) { self.peer = peer; self.slot = slot }
    public func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool) {
        peer.writeTrackVideo(slot: slot, payload, ptsNs: ptsNs, keyframe: keyframe)
    }
    public func writeVideo(_ payload: [UInt8], ptsNs: Int64, keyframe: Bool, reference: AV1ReferenceFrameMetadata) {
        peer.writeTrackVideo(slot: slot, payload, ptsNs: ptsNs, keyframe: keyframe, reference: reference)
    }
    var key: SinkKey { SinkKey(peer: ObjectIdentifier(peer), slot: slot) }
}

extension TrackSink: VideoTrackSink {
    public var sinkKey: SinkKey { key }
}

/// TWO DIFFERENT `TrackSink` OBJECTS FOR THE SAME (peer, slot) MUST COLLIDE. That is why the key is
/// the peer's identity plus the slot rather than the sink's own identity: a re-created sink has to
/// REPLACE its predecessor in the encoder's map, and `ChannelHub` drops a stale sink by the OLD
/// peer's identity when it rebuilds one.
public struct SinkKey: Hashable {
    let peer: ObjectIdentifier
    let slot: Int32
    public init(peer: ObjectIdentifier, slot: Int32) { self.peer = peer; self.slot = slot }
}
