import Foundation

/// pion's `PeerConnectionState` numbering, as carried across the `pion_on_connection_state` ABI.
///
/// These are not rdev's numbers to choose: `rdevPeerStateWire` (PionBridge/rdev_abi.go) is built
/// FROM pion's own enum rather than written as literals, precisely so it cannot drift.
public enum PeerConnectionState {
    public static let connected: Int32 = 3
    public static let disconnected: Int32 = 4
    public static let failed: Int32 = 5
    public static let closed: Int32 = 6
}

/// Pure decision: should this peer-connection state release the client's media (drop its delivery
/// sinks and retire capture/encode)?
///
/// TERMINAL STATES ONLY. `disconnected` is recoverable — ICE may return — and releasing there would
/// tear down a stream that was about to heal itself.
///
/// `hasVideoSlots` carries two things at once, and both are load-bearing. It is GUARD 1: a passive
/// client never holds tracks, and `SimManager`'s grace timer is global rather than per client, so
/// releasing on a passive peer's failure would retire the ACTIVE client's sources. And it is the
/// idempotency guard: a real close fires `failed` then `closed`, and the first release clears
/// `videoSlots`, so the second observation carries `false` and cannot re-arm the 10s pool timer —
/// which `onClientGone` would otherwise cancel and re-arm, extending the very window it starts.
public func shouldReleaseMedia(state: Int32, hasVideoSlots: Bool) -> Bool {
    guard state == PeerConnectionState.failed || state == PeerConnectionState.closed else {
        return false
    }
    return hasVideoSlots
}

/// Pure decision: a resume that would REUSE the retained peer is unsafe once that peer's media has
/// been released, so it is downgraded to a rebuild.
///
/// The client chooses `.ice` vs `.rebuild` from ITS OWN view of its peer connection, which can
/// disagree with the host's. An ICE restart keeps the retained peer and re-establishes nothing:
/// `establishVideoIfActive` runs on state 3, and `ChannelHub.pionPeer(_:stateDidChange:)` warns it
/// may not re-fire when the PC never left `Connected`. So a `.restartICE` onto a released peer
/// resumes to a permanently black window. A rebuild goes through the path that already works.
///
/// Every other action is returned unchanged: this narrows one case and must not become a general
/// rewrite of the grace state machine, which `graceDecide` owns.
public func resumeActionAfterMediaRelease(_ action: GraceAction, mediaReleased: Bool) -> GraceAction {
    (action == .restartICE && mediaReleased) ? .rebuild : action
}

/// Pure decision: an ICE restart onto a retained peer whose last OFFER was never answered is
/// impossible, so it is downgraded to a rebuild.
///
/// The offer went into a signalling session that died — sealed into a socket that read open, or
/// withheld because the session was already gone — so the peer sits in `have-local-offer`, and
/// pion refuses the restart's own offer there ("invalid proposed signaling state transition").
/// MEASURED: every `.ice` resume after a lost answer failed that way, and the client recovered only
/// when its own retry forced a rebuild, a reconnect or two later. Same narrowing rule as above:
/// only `.restartICE` changes.
public func resumeActionAfterUnansweredOffer(_ action: GraceAction, awaitingAnswer: Bool) -> GraceAction {
    (action == .restartICE && awaitingAnswer) ? .rebuild : action
}
