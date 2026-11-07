import Foundation

/// The largest forced FEC overhead the client may request, in basis points of media (50%).
///
/// Above this the repair stream rivals the media stream and the session's egress budget starts
/// suppressing it, so the number requested stops being the number delivered — a knob whose reading
/// silently stops meaning anything is worse than one that refuses.
public let maximumRecoveryOverrideBp = 5000

/// Clamp a requested FEC overhead into range. `nil` is Auto and passes through unchanged.
///
/// It CLAMPS rather than refusing, because refusal here would have to be reported somewhere and
/// there is no channel for it — the only caller is a select whose options are all in range, so an
/// out-of-range value means a hand-written message or a version skew, and the nearest legal setting
/// is a better answer than silently ignoring it.
public func clampRecoveryOverrideBp(_ raw: Int?) -> Int? {
    guard let raw else { return nil }
    return min(max(raw, 0), maximumRecoveryOverrideBp)
}
