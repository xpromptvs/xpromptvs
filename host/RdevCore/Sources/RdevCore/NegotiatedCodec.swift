/// The video codec a track's SDP offer/answer settled on.
///
/// This crosses the Go↔Swift ABI as a plain int (`pion_on_codec_resolved`), so the raw values are a
/// CONTRACT with `bridge.go`'s `cb_codec` and `peer.go`'s `codecID` — keep the two in step. It replaces
/// the `Bool hevc` that the resolve path used to carry, which could not express a third codec.
///
/// NOTE this is deliberately NOT `VTEncoder.VideoCodec`. That enum names which codec VideoToolbox drives
/// (H.264 or HEVC); AV1 is not one of those, and merging them would put an unreachable case inside
/// `recreateSession`.
public enum NegotiatedCodec: Int32, Sendable, CaseIterable {
    case h264 = 0
    case h265 = 1
    case av1 = 2

    /// Build from the ABI's int. Returns nil for an unknown value rather than defaulting, so a
    /// bridge/host version skew surfaces at the boundary instead of silently mis-encoding.
    public init?(wireValue: Int32) { self.init(rawValue: wireValue) }

    public var wireValue: Int32 { rawValue }

    /// How this codec is spelled on the WIRE (`view-set`'s `activeCodec`). Lowercase, and identical to
    /// `CodecPref`'s spelling so a client can compare a request against a result with no mapping table.
    public var wireName: String {
        switch self {
        case .h264: return "h264"
        case .h265: return "h265"
        case .av1:  return "av1"
        }
    }

    /// How this codec is spelled in the host's `[encode]` log lines.
    public var logName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265"
        case .av1: return "AV1"
        }
    }
}
