import CoreGraphics

/// Maps a point normalized (0…1) over the captured **device screen** to device points.
/// In-process capture attaches to the bare iOS framebuffer (no Mac window chrome), so the mapping is direct.
public func deviceTouchPoint(normalizedX: Double, normalizedY: Double, deviceSize: CGSize) -> CGPoint {
    CGPoint(
        x: min(max(normalizedX, 0), 1) * deviceSize.width,
        y: min(max(normalizedY, 0), 1) * deviceSize.height
    )
}

/// Maps a point normalized (0…1) over a captured **window** to a global display point.
/// `bounds` is the window's `kCGWindowBounds` (global, top-left origin, points) — the same
/// coordinate space `CGEvent` mouse locations use — so the mapping is direct (no chrome offset,
/// no flip). x/y are clamped to [0,1] so an out-of-surface pointer lands on the window edge.
public func windowInputPoint(normalizedX nx: Double, normalizedY ny: Double, bounds: CGRect) -> CGPoint {
    let cx = min(max(nx, 0), 1), cy = min(max(ny, 0), 1)
    return CGPoint(x: bounds.origin.x + cx * bounds.width, y: bounds.origin.y + cy * bounds.height)
}

/// Where a window must move to sit fully inside `visible`, or nil if it already does.
///
/// BOTH rects are in the TOP-LEFT-origin space that `kCGWindowBounds` and AX `kAXPosition` use — the caller
/// converts `NSScreen.visibleFrame` (bottom-left, y-up) before calling. `visible` should be the VISIBLE frame
/// (menu bar and Dock excluded) so the whole window stays usable.
///
/// Why this exists: content in a window's off-screen strip is captured and streamed fine, and the cursor can
/// even be posted to those coordinates — but the window server hit-tests clicks against on-screen geometry,
/// so the app never receives them. Nudging the window fully on-screen is what makes the whole surface
/// interactive. A window LARGER than the visible frame can't fit; it pins to the top-left so at least its
/// origin is reachable.
public func onScreenPosition(window: CGRect, visible: CGRect) -> CGPoint? {
    let x = window.width  >= visible.width  ? visible.minX
          : min(max(window.minX, visible.minX), visible.maxX - window.width)
    let y = window.height >= visible.height ? visible.minY
          : min(max(window.minY, visible.minY), visible.maxY - window.height)
    let target = CGPoint(x: x, y: y)
    return (abs(x - window.minX) < 1 && abs(y - window.minY) < 1) ? nil : target
}
