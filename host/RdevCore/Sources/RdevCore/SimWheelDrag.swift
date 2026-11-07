import Foundation

/// A wheel or trackpad over a simulator, as ONE synthesized finger drag.
///
/// AN iOS SIMULATOR HAS NO SCROLL SERVICE: `com.apple.coredevice.feature.remote.hid.scroll` is not vended
/// (SimError 405, docs/superpowers/specs/2026-10-13-simulator-sources-design.md, "Measured"), so the only way to
/// scroll one is to drag it.
///
/// A DRAG THAT MOVES TOO LITTLE IS A TAP, which is the one thing a wheel must never do. So the press waits until the
/// accumulated delta passes `slopPoints`, and then lands at the pointer and moves past the slop in the same breath.
/// The finger moves AGAINST the scroll: a wheel down (dy > 0) moves the content up, which is a finger dragged up.
/// `idleMs` after the last delta the finger lifts where it is. A finger that would leave the screen lifts at the edge,
/// and the next delta presses again at the pointer.
public struct SimWheelDrag: Sendable {
    public static let slopPoints = 8.0
    public static let idleMs = 120
    /// How far inside every edge a press lands (see `wheel`).
    public static let edgeInsetPoints = 30.0
    /// How far below the shown frame's TOP a press lands: past the status bar, which runs to ~62 pt on a Dynamic Island
    /// iPhone. MEASURED (scripts/gate-simulator.sh, G4, iPhone 18 Pro): a press 30 pt down never reached the app.
    public static let topInsetPoints = 70.0

    private let pointW: Double, pointH: Double
    private var anchor = SimPoint(x: 0.5, y: 0.5)
    private var pendingDX = 0.0, pendingDY = 0.0     // points, before the press
    private var finger: SimPoint?                    // nil until pressed
    private var lastMs = 0

    public init(pointW: Double, pointH: Double) {
        self.pointW = max(pointW, 1); self.pointH = max(pointH, 1)
    }

    /// `x`/`y` are the pointer, normalised to the frame the deltas are in; `dxPoints`/`dyPoints` the wheel's delta in
    /// that frame's points, signed as a browser reports it.
    public mutating func wheel(x: Double, y: Double, dxPoints: Double, dyPoints: Double, nowMs: Int) -> [SimTouchEvent] {
        lastMs = nowMs
        guard let at = finger else {
            // THE PRESS LANDS `edgeInsetPoints` INSIDE EVERY EDGE (final review I4): within the slop of one, the press,
            // its move to the clamped edge and the lift came in one breath — a TAP, and at the top the status bar's
            // scroll-to-top — and a touch that STARTS at an edge is a system gesture. Inside the inset the first move
            // always clears the slop. At the TOP the inset clears the status bar, which takes the touch from the app.
            if pendingDX == 0, pendingDY == 0 { anchor = inset(SimPoint(x: x, y: y)) }
            pendingDX += dxPoints; pendingDY += dyPoints
            guard (pendingDX * pendingDX + pendingDY * pendingDY).squareRoot() >= Self.slopPoints else { return [] }
            let to = moved(anchor, dx: pendingDX, dy: pendingDY)
            pendingDX = 0; pendingDY = 0
            finger = to.point
            var out: [SimTouchEvent] = [.start([anchor]), .move([to.point])]
            if to.clamped { out.append(.end([to.point])); finger = nil }
            return out
        }
        let to = moved(at, dx: dxPoints, dy: dyPoints)
        if to.clamped { finger = nil; return [.move([to.point]), .end([to.point])] }
        finger = to.point
        return [.move([to.point])]
    }

    /// Lift the finger once nothing has moved it for `idleMs`; a slop that never pressed is forgotten then too.
    public mutating func tick(nowMs: Int) -> [SimTouchEvent] {
        guard nowMs - lastMs >= Self.idleMs else { return [] }
        pendingDX = 0; pendingDY = 0
        guard let at = finger else { return [] }
        finger = nil
        return [.end([at])]
    }

    private func inset(_ p: SimPoint) -> SimPoint {
        let ix = min(Self.edgeInsetPoints / pointW, 0.5)
        let top = min(Self.topInsetPoints / pointH, 0.5), bottom = min(Self.edgeInsetPoints / pointH, 0.5)
        return SimPoint(x: min(max(p.x, ix), 1 - ix), y: min(max(p.y, top), 1 - bottom))
    }

    private func moved(_ p: SimPoint, dx: Double, dy: Double) -> (point: SimPoint, clamped: Bool) {
        let x = p.x - dx / pointW, y = p.y - dy / pointH
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return (SimPoint(x: cx, y: cy), cx != x || cy != y)
    }
}
