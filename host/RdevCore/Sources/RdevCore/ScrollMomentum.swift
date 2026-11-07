import Foundation

/// The phase a scroll event carries AFTER the fingers have left the glass.
///
/// IT IS A DIFFERENT FIELD FROM THE GESTURE PHASE, and the distinction is the whole point: real
/// macOS momentum events carry `scrollPhase = 0` and step `momentumPhase` begin → continue → end,
/// which is how AppKit tells "the finger is still moving" from "the finger is gone and this is
/// inertia". Sending inertia as more `scrollPhase = changed` events instead — which is what a
/// forwarded Mac trackpad's momentum looks like today — leaves an app unable to release a
/// rubber-band or to defer work until the gesture is really over.
public enum MomentumPhase: Equatable, Sendable {
    case begin
    case continuing
    case end

    /// `kCGMomentumScrollPhaseBegin` / `Continue` / `End`. Not exposed as Swift constants.
    public var cgValue: Int64 {
        switch self {
        case .begin: return 1
        case .continuing: return 2
        case .end: return 3
        }
    }
}

/// Host-generated scroll inertia for a TOUCH client — the glide that follows a two-finger flick.
///
/// WHY THE HOST OWNS THIS. A Mac trackpad client needs nothing here: macOS synthesizes momentum into
/// the browser itself, so it reaches the host as ordinary wheel deltas and a second source would
/// double-scroll it. A touchscreen has no such source at all, and the obvious client-side answer —
/// decay the velocity in a rAF loop and send the deltas — puts every frame of the animation on the
/// wire, where it inherits exactly the delivery jitter that makes a glide judder. Generated here, the
/// curve runs on the host's own clock and the network is not in the loop.
///
/// **THE DECAY IS EXPONENTIAL IN TIME AND THE DISPLACEMENT IS ITS INTEGRAL, never `v * dt`.** A
/// per-tick decay factor makes the whole curve a function of how punctually the timer fires, so a
/// stalled queue would travel a different distance than a healthy one for the same flick — the same
/// class of error as summing rounded deltas into an RTP clock. Integrating means a late tick costs
/// smoothness and never distance, and it is also what bounds a pathological one: the integral over
/// all remaining time converges to `speed * timeConstant`, so even a tick that arrives ten seconds
/// late delivers the rest of the glide exactly once and ends.
public struct ScrollMomentum: Equatable, Sendable {
    /// Time constant of the decay. UNTUNED — chosen to sit near the feel of macOS and iOS momentum
    /// (both decay to about a twentieth of launch speed within a second); a glide's total length is
    /// `speed * timeConstant`, so this and nothing else sets how far a flick throws.
    public static let timeConstant: Double = 0.325
    /// Below this speed, in points per second, the glide is over. A BOUND, not a tuned value: it is
    /// roughly a fifth of a point per frame at 120Hz, i.e. already invisible.
    public static let stopSpeed: Double = 24
    /// A lift slower than this is not a flick and starts nothing. The CLIENT gates on its own floor
    /// too; this one exists because the host must not take a number on trust from the wire.
    public static let minimumLaunchSpeed: Double = 120
    /// Fastest flick honoured, direction preserved. A touchscreen cannot produce this; a broken or
    /// hostile client can.
    public static let maximumLaunchSpeed: Double = 8000

    /// Points per second, in the CG sign convention (already negated by the caller, exactly as the
    /// live scroll path negates its deltas).
    private var vx: Double = 0
    private var vy: Double = 0
    private var lastTick: Double = 0
    /// The phase the NEXT step will carry; nil means no glide is running.
    private var pending: MomentumPhase?

    public init() {}

    public var isRunning: Bool { pending != nil }

    /// Start a glide, replacing any glide already running. Returns false — and starts nothing — when
    /// the flick is too slow to be one, so a caller can tell "no momentum" from "a momentum of zero
    /// length" and post accordingly.
    public mutating func launch(velocityX: Double, velocityY: Double, now: Double) -> Bool {
        guard velocityX.isFinite, velocityY.isFinite else { return false }
        let speed = (velocityX * velocityX + velocityY * velocityY).squareRoot()
        guard speed >= Self.minimumLaunchSpeed else { return false }
        let scale = speed > Self.maximumLaunchSpeed ? Self.maximumLaunchSpeed / speed : 1
        vx = velocityX * scale
        vy = velocityY * scale
        lastTick = now
        pending = .begin
        return true
    }

    public struct Step: Equatable, Sendable {
        /// Points travelled since the previous step, already in the CG sign convention.
        public let dx: Double
        public let dy: Double
        public let phase: MomentumPhase
    }

    /// Advance the glide to `now`, or nil when none is running.
    ///
    /// A GLIDE ALWAYS EMITS AT LEAST A `begin` AND AN `end`, and the `end` exactly once. That is why
    /// the stop test skips the first step: a tick that arrives very late could otherwise decay the
    /// whole glide before anything was posted, leaving an app an `end` for a momentum it never saw
    /// begin.
    public mutating func tick(now: Double) -> Step? {
        guard let phase = pending else { return nil }
        let dt = max(0, now - lastTick)
        lastTick = now

        let decay = exp(-dt / Self.timeConstant)
        // ∫ v·e^(−t/τ) dt over [0, dt] — the exact distance for this interval, whenever it arrived.
        let travel = Self.timeConstant * (1 - decay)
        let dx = vx * travel
        let dy = vy * travel
        vx *= decay
        vy *= decay

        let speed = (vx * vx + vy * vy).squareRoot()
        if phase != .begin && speed < Self.stopSpeed {
            pending = nil
            return Step(dx: dx, dy: dy, phase: .end)
        }
        pending = .continuing
        return Step(dx: dx, dy: dy, phase: phase)
    }

    /// Stop because something superseded the glide — a finger back on the glass, a fresh flick, a
    /// touch. Returns whether an `end` is still OWED to the app: a glide that has not yet emitted its
    /// `begin` owes nothing, and a spurious second `end` is not harmless (an app that rubber-bands
    /// reads it as a second release).
    public mutating func cancel() -> Bool {
        guard let phase = pending else { return false }
        pending = nil
        vx = 0
        vy = 0
        return phase != .begin
    }

    /// Forget the glide WITHOUT owing an `end` — for a focus change, an injector swap or a client
    /// leaving, where the target that would receive it is no longer the target that saw the flick.
    /// The same distinction `ScrollPhaseMachine.reset` draws, for the same reason.
    public mutating func reset() {
        pending = nil
        vx = 0
        vy = 0
    }
}
