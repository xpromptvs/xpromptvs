import Foundation

/// A minimum interval between forced IDRs, per source.
///
/// IT EXISTS BECAUSE rdev ANSWERED EVERY PLI WITH A FULL IDR, and a request storm therefore became a
/// bitrate storm. Measured on a real iPad at 2368x1538: 60 requests in fifteen seconds became 60
/// keyframes, **99% of the bitrate**, and the stream collapsed to 9.2 fps — at which point there was
/// no capacity left for the video the keyframes were meant to restore. A later session showed 127
/// keyframes among 979 received frames, one frame in eight.
///
/// THE LOOP IS SELF-SUSTAINING, WHICH IS WHY A CAP IS WORTH HAVING WHATEVER THE ROOT CAUSE IS. An IDR
/// is the largest frame in the stream; enough of them starve the encoder, which drops frames, which
/// gives the receiver more reason to ask. Every production sender bounds this; rdev did not.
///
/// A SUPPRESSED REQUEST MUST BE DEFERRED, NEVER DROPPED, and this cost a shipped regression.
///
/// The first version dropped it, reasoning that receivers repeat PLIs — which they do. What they
/// cannot do is get past the ENGINE's own gate: the NACK responder marks a keyframe response
/// outstanding when it forwards a request and reopens only when `markKeyframeSent` fires. Drop the
/// request and no keyframe is ever produced, so that gate never reopens and the engine stops
/// forwarding the retries. It is a DEADLOCK, not a rate limit.
///
/// MEASURED under 1% packet loss with the drop version: 204 client PLIs became ONE keyframe and the
/// stream died after one second and never recovered, against a steady 60 fps for twenty seconds with
/// the debounce disabled. `allow` therefore reports HOW LONG to wait rather than yes-or-no, and the
/// caller owes every suppressed request an IDR at the end of that wait.
public struct KeyframeDebounce: Sendable {
    /// Long enough to break the storm, short enough that a genuine reference loss recovers promptly.
    /// The worst observed storm was 5 requests per second; this caps it at 2. NOT a tuned value —
    /// the deeper question is why a receiver asks at all, and this only bounds the damage.
    public static let defaultMinimumInterval: TimeInterval = 0.5

    public let minimumInterval: TimeInterval
    private var lastEmitted: [String: TimeInterval] = [:]

    public init(minimumInterval: TimeInterval = KeyframeDebounce.defaultMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    /// How long this source must wait before its next IDR: zero when it may emit now (recording the
    /// emission), otherwise the remaining time the caller must defer by.
    ///
    /// THE FIRST REQUEST FOR A SOURCE IS ALWAYS SERVED. A fresh subscribe pushes a keyframe so the
    /// client has something to decode, and delaying that would trade a storm for a black window.
    public mutating func waitBeforeKeyframe(source: String, now: TimeInterval) -> TimeInterval {
        if let last = lastEmitted[source] {
            let waited = now - last
            if waited < minimumInterval { return minimumInterval - waited }
        }
        lastEmitted[source] = now
        return 0
    }

    /// Forget a source, so a re-subscribe is served immediately rather than inheriting a stale clock.
    public mutating func forget(source: String) {
        lastEmitted.removeValue(forKey: source)
    }
}

/// What to do with a keyframe request the debounce has deferred.
public enum DeferredKeyframeAction: Equatable, Sendable {
    /// Nothing is pending: schedule the IDR for `wait` from now.
    case arm(wait: TimeInterval)
    /// A pending IDR is still due and will satisfy this request.
    case alreadyArmed
    /// The pending IDR missed its deadline and is presumed lost — replace it.
    case rearmStale(wait: TimeInterval)
}

/// How long past its deadline a pending IDR may be before it is presumed lost.
///
/// A work item runs a little late under load all the time, and re-arming on ordinary lateness would
/// turn one keyframe into a storm. Two seconds is far outside scheduling jitter and far inside the
/// time a user would sit looking at a dead stream.
public let deferredKeyframeGrace: TimeInterval = 2

/// Decide what a deferred keyframe request should do, given whether one is already pending.
///
/// LOAD-BEARING — A DEFERRED REQUEST MUST NEVER BE ABLE TO VANISH. The engine's age-aware responder
/// marks a keyframe response outstanding when it forwards a request and reopens only when one is
/// actually SENT. So a deferred IDR that never reaches the encoder stops the engine forwarding the
/// receiver's retries, and the stream cannot recover: measured as `0 requested` at the host for 40+
/// seconds while the receiver reported `pli=21-29` every window.
///
/// The previous rule was "if something is pending, drop this request" — silently, with no counter and
/// no log. That is correct only if the pending work ALWAYS runs, and nothing guaranteed it: the work
/// is dispatched onto a serial queue and calls into the encoder, which can be mid-rebuild (a scale or
/// codec change recreates it) or saturated. `rearmStale` is what closes that hole.
public func deferredKeyframeAction(
    wait: TimeInterval,
    pendingDeadline: TimeInterval?,
    now: TimeInterval,
    grace: TimeInterval = deferredKeyframeGrace,
) -> DeferredKeyframeAction {
    guard let pendingDeadline else { return .arm(wait: wait) }
    return now > pendingDeadline + grace ? .rearmStale(wait: wait) : .alreadyArmed
}
