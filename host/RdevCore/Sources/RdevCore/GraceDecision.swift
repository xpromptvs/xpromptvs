import Foundation

/// Pure decision for the host's per-peer grace state machine. `held` = the peer is currently suspended
/// (inside its grace window). See connection-resilience spec §"Host-side state retention".
public enum GraceEvent { case suspend, resume(ResumeMode), graceExpired }

public enum GraceAction: Equatable {
    case hold        // enter grace: keep the peer, start the grace timer
    case restartICE  // resume on the retained peer via ICE restart
    case rebuild     // resume by dropping the stale peer and building a fresh one for the same id
    case teardown    // grace expired: run the real client-left teardown
    case freshJoin   // resume arrived but nothing was held (grace already gave up) → treat as new peer
    case ignore      // no-op (double suspend, or a stale expiry timer)
}

public func graceDecide(held: Bool, _ ev: GraceEvent) -> GraceAction {
    switch (held, ev) {
    case (false, .suspend): return .hold
    case (true, .suspend): return .ignore
    case (true, .resume(.ice)): return .restartICE
    case (true, .resume(.rebuild)): return .rebuild
    case (false, .resume): return .freshJoin
    case (true, .graceExpired): return .teardown
    case (false, .graceExpired): return .ignore
    }
}
