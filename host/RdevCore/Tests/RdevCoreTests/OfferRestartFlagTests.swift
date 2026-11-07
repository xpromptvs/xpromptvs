import Testing
@testable import RdevCore

/// The tag means "keep your peer connection". A FRESH peer's first offer can never mean that: there
/// is no negotiation to continue, and a client that keeps its old connection then rejects the offer
/// with `The order of m-lines in subsequent offer doesn't match order from previous offer/answer`.
@Suite struct OfferRestartFlagTests {
    @Test("a renegotiation is tagged, and the tag is consumed once")
    func tagsRenegotiations() {
        var flag = OfferRestartFlag()
        #expect(flag.consume() == false)          // nothing asked for one
        flag.markRestart()
        #expect(flag.consume() == true)
        #expect(flag.consume() == false)          // consumed, not sticky
    }

    @Test("a fresh peer's FIRST offer is never a restart, whatever was set before it")
    func firstOfferIsNeverARestart() {
        var flag = OfferRestartFlag()
        // THE REPORTED PATH: PeerHub.rebuildPeer builds a fresh peer, ChannelHub.rebindPeer issues a
        // no-op removeVideo against it — which sets this unconditionally — and then startOffer emits
        // the peer's opening offer. Tagged, the client keeps a connection whose m-line history
        // belongs to the peer that was just closed.
        flag.markRestart()
        flag.markFirstOffer()
        #expect(flag.consume() == false)
    }

    @Test("two renegotiations asked for before either offer is emitted tag BOTH offers")
    func queuedRenegotiationsAreEachTagged() {
        var flag = OfferRestartFlag()
        flag.markFirstOffer()
        #expect(flag.consume() == false)          // the opening offer
        // THE MEASURED PATH (e2e/session-state-check.mjs, 2026-09-29): a driver's reconcile adds TWO
        // windows' tracks back to back. Each `addSourceTracks` marks a restart, the engine queues the
        // second renegotiation until the first answer, and the first offer consumed the only mark —
        // so the second offer went out UNTAGGED, the client read it as the host having rebuilt,
        // rebuilt its own connection, and the host's answer landed on a closed one. Every reconnect
        // with two windows open looped on it.
        flag.markRestart()
        flag.markRestart()
        #expect(flag.consume() == true)
        #expect(flag.consume() == true)
        #expect(flag.consume() == false)          // and no more than were asked for
    }

    @Test("a restart AFTER the first offer is still tagged")
    func laterRestartsStillTagged() {
        var flag = OfferRestartFlag()
        flag.markFirstOffer()
        // PAIRED WITH THE ABOVE: clearing on the first offer must not disarm the flag permanently, or
        // every later ICE restart and track change would tell the client to REBUILD — throwing away a
        // healthy connection on every subscribe.
        flag.markRestart()
        #expect(flag.consume() == true)
    }
}
