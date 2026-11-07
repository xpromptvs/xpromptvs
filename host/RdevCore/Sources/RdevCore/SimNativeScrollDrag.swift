import Foundation

/// Cancellable universal-HID contact used only by phase-aware native trackpad scrolling.
public enum SimScrollTouchEvent: Equatable, Sendable {
    case contact(SimPoint), end(SimPoint), cancel(SimPoint)
}

public struct SimNativeScrollDrag: Sendable {
    private let width: Double, height: Double
    private var anchor: SimPoint?
    private var finger: SimPoint?
    private var movedPastSlop = false
    public init(pointW: Double, pointH: Double) { width = max(pointW, 1); height = max(pointH, 1) }
    public mutating func begin(x: Double, y: Double) -> [SimScrollTouchEvent] {
        var output = end(moving: false)
        let ix = min(SimWheelDrag.edgeInsetPoints / width, 0.5)
        let top = min(SimWheelDrag.topInsetPoints / height, 0.5), bottom = min(SimWheelDrag.edgeInsetPoints / height, 0.5)
        let p = SimPoint(x: min(max(x, ix), 1 - ix), y: min(max(y, top), 1 - bottom))
        anchor = p; finger = p; movedPastSlop = false
        output.append(.contact(p)); return output
    }
    public mutating func move(dx: Double, dy: Double) -> [SimScrollTouchEvent] {
        guard let old = finger, let anchor else { return [] }
        let x = old.x - dx / width, y = old.y - dy / height
        let p = SimPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        finger = p
        if x != p.x || y != p.y { return end(moving: false) }
        let tx = (p.x - anchor.x) * width, ty = (p.y - anchor.y) * height
        movedPastSlop = movedPastSlop || hypot(tx, ty) >= SimWheelDrag.slopPoints
        return [.contact(p)]
    }
    public mutating func end(moving: Bool) -> [SimScrollTouchEvent] {
        guard let p = finger else { return [] }
        finger = nil; anchor = nil
        return moving && movedPastSlop ? [.end(p)] : [.cancel(p)]
    }
}
