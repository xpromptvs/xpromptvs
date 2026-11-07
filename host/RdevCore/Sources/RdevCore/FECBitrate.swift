import Foundation

/// The lowest fraction of its request a source may be driven to. A ratio of zero would stop the
/// encoder, and a stopped encoder presents exactly like a dead capture — a frozen last frame with
/// no overlay and nothing in any log saying why.
public let fecMinimumMediaRatio: Double = 0.05

/// The bitrate to hand one source's encoder, given the client's REQUEST and the adaptive FlexFEC
/// controller's media fraction.
///
/// WHY A RATIO AND NOT THE CONTROLLER'S OWN NUMBER. `RecoveryPolicyUpdate` carries an ABSOLUTE
/// `mediaBitrateBitsPerSecond` measured against the session's total RTP budget, and that budget is
/// immutable — it is passed to `ActivateAdaptiveFlexFEC` at construction with no runtime setter,
/// while rdev's clients change bitrate live from the titlebar picker and subscribe sources
/// mid-session. So the budget is set to the bitrate CAP, which no client request can exceed by
/// definition, and the controller's absolute figure — meaningless applied to a 2 Mbit/s stream when
/// the budget is 20 — becomes a fraction that is applied per source. The client still owns the
/// TOTAL wire cost it asked for; the controller owns the SPLIT between media and FEC.
///
/// ALWAYS CALLED WITH THE REQUEST, NEVER WITH THE LAST APPLIED VALUE. Feeding the result back
/// compounds the ratio and ratchets the bitrate down on every policy update, with every individual
/// step looking correct: 2 Mbit/s at a constant 0.85 becomes 1.7, then 1.445, and so on. This is the
/// same shape as the Auto-resolution rule, where `sync()` must not reflect the echoed scale back
/// onto the select. `FECBitrateTests` pins the diverged number so the hazard stays measurable, but
/// the rule itself is a property of the CALL SITE and cannot be enforced from here.
public func fecAppliedBitrate(requested: Int, ratio: Double) -> Int {
    // NaN is not merely improbable: the ratio is a division by a budget, and `min`/`max` propagate
    // NaN rather than clamping it, which would reach the encoder as a garbage bitrate.
    let usable = ratio.isFinite ? ratio : 1.0
    let clamped = min(max(usable, fecMinimumMediaRatio), 1.0)
    return max(1, Int((Double(requested) * clamped).rounded()))
}
