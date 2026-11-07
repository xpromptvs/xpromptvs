import Foundation

/// **The empty stretch of a client window's tab bar, as the page measured it** (`setChromeGap`): between the
/// plus and Search, where a native grip drags the window (docs/desktop-app.md, "Integrated client chrome").
///
/// THE PAGE MEASURES AT ITS OWN WIDTH, AND A GAP IS USED ONLY AT THAT WIDTH. During a lockstep zoom the page
/// lays out AHEAD of the window (`LockstepResize`), so its report for a width arrives before the window gets
/// there; the first version dropped every gap whenever the window's width changed, which threw that report
/// away the moment it became true — and the page never re-sends a value it already sent, so the grip was
/// gone after every expand/restore (and after a load whose report beat the window's first layout).
public struct ChromeGap: Equatable, Sendable {
    public let left: Double
    public let right: Double
    /// The page's width (`innerWidth`) when it measured; 0 is no measurement.
    public let width: Double

    public static let none = ChromeGap(left: 0, right: 0, width: 0)

    public init(left: Double, right: Double, width: Double) {
        self.left = left; self.right = right; self.width = width
    }

    /// The grip's span in a window `width` wide, outside the fixed grips at either end; nil when there is none
    /// — no gap, an empty one, or one measured at another width. The page's width is whole CSS pixels.
    public func grip(windowWidth: Double, leftGrip: Double, rightGrip: Double) -> (start: Double, end: Double)? {
        guard width > 0, abs(windowWidth - width) < 1 else { return nil }
        let start = max(leftGrip, left), end = min(windowWidth - rightGrip, right)
        return end > start ? (start, end) : nil
    }
}
