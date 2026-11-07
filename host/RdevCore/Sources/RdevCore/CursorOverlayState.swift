// host/RdevCore/Sources/RdevCore/CursorOverlayState.swift

import Foundation

/// Where the remote pointer is, and whether it is pressed.
public struct CursorMarkerState: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let pressed: Bool
    public init(x: Double, y: Double, pressed: Bool) {
        self.x = x; self.y = y; self.pressed = pressed
    }
}

/// Debug overlay state (`RDEV_CURSOR_OVERLAY=1`): the host paints a rectangle at the position the
/// CLIENT last sent, onto the video it streams, just before encode.
///
/// Position comes from the client rather than from the host's real cursor deliberately — that makes
/// the rectangle a pure echo of the INPUT path (uplink + encode + transmit + jitter buffer + decode
/// + display). Using the host's actual cursor would fold in injection and WindowServer time.
///
/// Two gaps become visible at once: your real pointer versus the rectangle is the streaming
/// latency, and the rectangle versus the app's own captured reaction to the same click is the
/// capture latency — which nothing else can show.
///
/// In RdevCore, not RdevHostKit, so it can be tested: RdevHostKit has no test target. It reads no
/// environment; `FrameOverlaySink` owns the enablement flags.
public final class CursorOverlayState: @unchecked Sendable {
    public static let shared = CursorOverlayState()

    private let lock = NSLock()
    private var known = false
    private var nx = 0.0
    private var ny = 0.0
    private var pressed = false
    private var focused: String?

    public init() {}

    /// The driver moved the pointer without pressing (the `hover` message).
    public func hover(x: Double, y: Double) {
        lock.lock(); defer { lock.unlock() }
        known = true; nx = x; ny = y; pressed = false
    }

    /// A touch phase. "down"/"move" press at (x, y); "up" releases but KEEPS the position, so the
    /// rectangle stays put in its normal colour instead of vanishing.
    public func touch(phase: String, x: Double, y: Double) {
        lock.lock(); defer { lock.unlock() }
        known = true; nx = x; ny = y; pressed = (phase != "up")
    }

    /// Which source currently receives input; nil clears it.
    public func setFocused(_ sourceID: String?) {
        lock.lock(); defer { lock.unlock() }
        focused = sourceID
    }

    /// The marker for `sourceID`, or nil when nothing is known yet or that source is not focused.
    ///
    /// `sourceID == nil` means a source with NO focus concept — the headless test pattern, which
    /// runs without SimManager and therefore without a `viewSet`. It is always answered.
    public func marker(forSource sourceID: String?) -> CursorMarkerState? {
        lock.lock(); defer { lock.unlock() }
        guard known else { return nil }
        if let sourceID, sourceID != focused { return nil }
        return CursorMarkerState(x: nx, y: ny, pressed: pressed)
    }
}
