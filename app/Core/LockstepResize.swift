import CoreGraphics
import Foundation

/// **A client window's expand/restore, in LOCKSTEP with its page** (docs/desktop-app.md, "Expand and
/// restore"). WebKit lays the page out in another process and nothing on the app's side waits for it —
/// `layoutSubtreeIfNeeded` included: WKWebView has no `-layout` of its own and sends its size from
/// `setFrameSize:` as one asynchronous message (measured 2026-10-02: 0 of 24 window steps showed the page
/// at the window's size, with or without it; the 240 ms `animator()` zoom, 0 of 27, up to 94 pt apart).
///
/// So each step sizes the WEB VIEW first and moves the WINDOW only inside WebKit's presentation callback,
/// which runs in the main-thread turn that applied the page's commit, before Core Animation flushes it
/// (24 of 24 measured): the window's frame and the page laid out for it reach the screen together.
///
/// Pure: `LockstepZoom` feeds it the clock and does what it returns. Progress is TIME, never a count of
/// steps — a page slower than the display gets fewer steps, not a longer animation.
public struct LockstepResize: Equatable, Sendable {
    public let from: CGRect
    public let to: CGRect
    public let start: Double
    public let duration: Double

    public init(from: CGRect, to: CGRect, start: Double, duration: Double) {
        self.from = from; self.to = to; self.start = start; self.duration = duration
    }

    /// The window frame for `now` and whether it is the destination. Each EDGE is eased and rounded to a
    /// whole point, so an edge moving one way never steps back (rounding origin and size apart can).
    public func frame(at now: Double) -> (frame: CGRect, last: Bool) {
        let t = duration > 0 ? min(1, max(0, (now - start) / duration)) : 1
        if t >= 1 { return (to, true) }
        let e = CGFloat(Self.ease(t))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * e).rounded() }
        let minX = mix(from.minX, to.minX), maxX = mix(from.maxX, to.maxX)
        let minY = mix(from.minY, to.minY), maxY = mix(from.maxY, to.maxY)
        return (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), false)
    }

    /// What the web view is sized to BEFORE the window moves. With `overflows` — the page's stale content
    /// can spill past a shrunken web view, its layer-hosting view's clip released — the page may lay out
    /// at the target at once, growing or shrinking. Without it, never smaller than what the window shows
    /// now: a shrinking dimension then follows the window, its stale content clipped for one step.
    public static func webSize(showing current: CGSize, target: CGSize, overflows: Bool) -> CGSize {
        overflows ? target : CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
    }

    /// Core Animation's ease-in-ease-out, the cubic Bézier (0.42, 0, 0.58, 1).
    public static func ease(_ t: Double) -> Double {
        let (x1, y1, x2, y2) = (0.42, 0.0, 0.58, 1.0)
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
        }
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        // x(s) is monotonic on [0, 1]: bisection converges without the curve's derivative.
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<40 {
            s = (lo + hi) / 2
            if bezier(s, x1, x2) < t { lo = s } else { hi = s }
        }
        return bezier(s, y1, y2)
    }
}
