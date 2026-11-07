import Foundation

/// A client's video-codec PREFERENCE for one source.
///
/// Distinct from `NegotiatedCodec`, which is what the SDP answer actually settled on. A preference can
/// go UNMET — ask for AV1 in a browser that cannot decode it and the answer strips it — and the UI
/// depends on being able to tell those apart, so they are separate types and separate wire fields.
public enum CodecPref: String, Sendable, CaseIterable {
    case auto, av1, h265, h264

    /// Parse the wire form. Returns nil for anything unrecognised, deliberately: `applyVideoPrefs` then
    /// leaves the current value alone rather than silently reinterpreting a typo as `auto`, which would
    /// drop a pin the client had deliberately set.
    public init?(wire: String) { self.init(rawValue: wire) }

    public var wireName: String { rawValue }

    /// The integer `pion_peer_add_video_track` / `pion_peer_set_track_codec` take.
    ///
    /// LOAD-BEARING: this is a CONTRACT with `codecorder.go`'s `codecPref`, and deliberately NOT
    /// `NegotiatedCodec`'s numbering. The two cross the same ABI in opposite directions — a preference
    /// in, a resolved codec out — so sharing a numbering would make 0 mean two different things.
    public var bridgeValue: Int32 {
        switch self {
        case .auto: return 0
        case .av1:  return 1
        case .h265: return 2
        case .h264: return 3
        }
    }
}
