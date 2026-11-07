import Foundation

/// Native trackpad boundaries; direct deltas continue to use the existing scroll message.
public enum ScrollGesturePhase: String, Equatable, Sendable {
    case begin, end, cancel
}

/// The unit the CLIENT's wheel event actually reported, forwarded rather than normalized:
/// `deltaMode === 0` (trackpad, and Chrome's mouse-wheel emulation) is pixels; `deltaMode === 1`
/// (a notched wheel) is lines. Posting a notched wheel as `.line` is MORE faithful than smoothing
/// it, so both host paths are permanent — this is not a compatibility shim to delete later.
///
/// ABSENT MEANS LINE, deliberately. A client that predates the field sends line deltas; reading
/// them as pixels would scroll a fortieth of what was asked for.
public enum ScrollUnit: String, Equatable, Sendable {
    case line
    case pixel

    public init(wire: String?) { self = (wire == "px") ? .pixel : .line }
}

/// Carries the sub-pixel remainder between events.
///
/// `CGEvent(scrollWheelEvent2Source:)` takes `Int32`. The old path rounded each delta on its own,
/// so a slow drag of 0.4 px per event produced zero every time and the window never moved. The
/// remainder here is what makes a slow drag scroll at all.
public struct PixelScrollAccumulator: Equatable, Sendable {
    private var xRemainder: Double = 0
    private var yRemainder: Double = 0

    public init() {}

    /// Adds the deltas and returns the whole-pixel part to post, keeping the fraction for next time.
    /// Truncation is toward zero on BOTH signs — rounding away from zero would flip the remainder's
    /// sign and make a steady drag alternate direction.
    public mutating func take(dx: Double, dy: Double) -> (x: Int32, y: Int32) {
        xRemainder += dx.isFinite ? dx : 0
        yRemainder += dy.isFinite ? dy : 0
        let wx = xRemainder.rounded(.towardZero)
        let wy = yRemainder.rounded(.towardZero)
        xRemainder -= wx
        yRemainder -= wy
        return (Self.clamp(wx), Self.clamp(wy))
    }

    /// A hostile or broken client must not trap the host on an `Int32` conversion.
    private static func clamp(_ v: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), v)))
    }
}

public enum ScrollPhaseAction: Equatable, Sendable {
    case began
    case changed
    case ended
}

/// The synthesized scroll phase. A browser wheel event carries no phase, and AppKit gates
/// rubber-banding and per-pixel tracking on a real `began → changed → ended` sequence, so the host
/// derives one: the first event of a gesture is `began`, later events are `changed`, and a quiet
/// interval with no event closes the gesture with `ended`.
public struct ScrollPhaseMachine: Equatable, Sendable {
    /// How long a gesture may go quiet before it is considered over. A BOUND, not a tuned value.
    public static let quietInterval: Double = 0.08

    private var active = false
    private var lastEventAt: Double = 0

    public init() {}

    public var isActive: Bool { active }

    public mutating func event(now: Double) -> ScrollPhaseAction {
        lastEventAt = now
        if active { return .changed }
        active = true
        return .began
    }

    /// `.ended` exactly once, and only after the quiet interval has actually elapsed; nil otherwise.
    /// A timer that fires early (or twice) must not close a live gesture or end one twice.
    public mutating func expire(now: Double) -> ScrollPhaseAction? {
        guard active, now >= lastEventAt + Self.quietInterval else { return nil }
        active = false
        return .ended
    }

    /// Forget the gesture WITHOUT emitting `ended` — for a focus change or a release-all, where the
    /// target that would receive the `ended` is no longer the target that saw the `began`.
    public mutating func reset() { active = false }
}
