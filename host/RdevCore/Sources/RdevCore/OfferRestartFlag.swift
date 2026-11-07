import Foundation

/// Whether the NEXT offer a peer emits should be tagged `restart: true`.
///
/// WHAT THE TAG MEANS TO THE CLIENT: "keep your peer connection". A client receiving an untagged
/// offer rebuilds its `RTCPeerConnection`; a tagged one keeps it and expects the offer to continue
/// the negotiation it already has.
///
/// SO TAGGING A FRESH PEER'S FIRST OFFER IS A LIE WITH A HARD FAILURE. The client keeps a peer
/// connection whose m-line history belongs to the PREVIOUS host peer, and `setRemoteDescription`
/// refuses the offer outright:
///
///     InvalidAccessError: Failed to set remote offer sdp:
///     The order of m-lines in subsequent offer doesn't match order from previous offer/answer.
///
/// It exists as a type because the flag was a bare `Bool` set unconditionally by `removeVideoTrack`,
/// including for the NO-OP removal `ChannelHub.rebindPeer` issues against a just-built peer — so a
/// rebuild's opening offer went out tagged, and the client was told to keep a connection it had to
/// replace. The Go side was fixed to skip the renegotiation for a no-op removal; the flag was not,
/// and it is sticky, so it survived to the next offer.
///
/// A COUNT, NOT A BOOL (2026-09-29). Each mark is one renegotiation the engine will turn into one
/// offer, and it QUEUES the next until the previous is answered — so two marks can land before the
/// first offer is even emitted. A bool held one of them: a driver's reconcile added two windows'
/// tracks back to back, the first offer took the only tag, the second went out untagged, and the
/// client rebuilt its connection under the host's answer (`e2e/session-state-check.mjs`). Counting
/// high is harmless — every offer after a peer's first IS a renegotiation (a rebuild is a new peer)
/// — which is what a no-op removal the engine skips costs; counting low is the defect.
public struct OfferRestartFlag: Equatable {
    private var pending = 0

    public init() {}

    /// A renegotiation that CONTINUES this peer's existing session: an ICE restart, a track added or
    /// removed. The client must keep its peer connection for these.
    public mutating func markRestart() { pending += 1 }

    /// This peer is about to emit its FIRST offer, which CLEARS any tag set before it.
    ///
    /// Clearing rather than refusing to set: the callers that set it are doing the right thing for a
    /// peer mid-session, and one of them (`rebindPeer`'s no-op removal) legitimately runs against a
    /// peer that has not offered yet. The peer's own lifecycle is what knows the difference, so it is
    /// asserted here rather than asked of every caller.
    public mutating func markFirstOffer() { pending = 0 }

    /// Whether THIS offer is a restart — one pending renegotiation consumed.
    public mutating func consume() -> Bool {
        guard pending > 0 else { return false }
        pending -= 1
        return true
    }
}
