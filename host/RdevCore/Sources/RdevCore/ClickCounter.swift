import Foundation

/// The click count a posted mouse event must carry (`kCGMouseEventClickState`, AppKit's `clickCount`).
///
/// WINDOWSERVER DOES NOT COUNT CLICKS FOR POSTED EVENTS. Measured 2026-09-25 against an AppKit view
/// with events posted exactly as `WindowInputInjector` posts them (`.hidSystemState` source,
/// `.cghidEventTap`): `CGEvent(mouseEventSource:…)` stamps EVERY down `1` and every up `0`, and
/// nothing downstream recounts them — two clicks 100 ms apart arrived as `clickCount` 1, 0, 1, 0.
/// So a double-click, a word selection by double-click and a triple-click line selection were all
/// IMPOSSIBLE from any client, and an up read as `0` besides. Setting the field explicitly is
/// what AppKit then reports, verbatim.
///
/// The rule is macOS's own: a press continues the run when it is the SAME button, within the
/// double-click interval of the previous press, and near it. The run's count is carried by that
/// press's drags and its release, exactly as a real mouse's are.
///
/// PURE and platform-free so it is testable without CoreGraphics; the caller supplies the clock,
/// the interval (`NSEvent.doubleClickInterval`, a user setting) and points in global POINTS.
public struct ClickCounter: Sendable {
    /// How far, in points, a press may land from the previous one and still continue the run.
    /// UNTUNED. It absorbs a mouse's jitter and the rounding of a normalized coordinate; a finger's
    /// jitter is far larger once the picture is scaled, and the touch client removes it before the
    /// wire by snapping a second tap onto the first (`direct-touch.ts`) rather than widening this.
    public static let slopPoints: Double = 6

    private var last: (button: MouseButton, x: Double, y: Double, t: TimeInterval)?
    /// The count the current run has reached — what a drag or a release reports.
    public private(set) var count: Int = 1

    public init() {}

    /// A press. Returns the count it carries, 1 for a press that starts a new run.
    public mutating func down(button: MouseButton, x: Double, y: Double,
                              now: TimeInterval, interval: TimeInterval) -> Int {
        if let last, last.button == button, now - last.t <= interval,
           hypot(x - last.x, y - last.y) <= Self.slopPoints {
            count += 1
        } else {
            count = 1
        }
        last = (button, x, y, now)
        return count
    }

    /// Forget the run — the target that saw it is no longer the target.
    public mutating func reset() {
        last = nil
        count = 1
    }
}
