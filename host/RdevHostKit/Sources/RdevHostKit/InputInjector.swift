import CoreGraphics
import Foundation
import RdevCore

/// AnyObject-constrained: every injector owns per-source mutable state (bounds, modifier flags, the
/// held-key ledger, a scroll phase), so a value type could never satisfy it — and `ChannelHub`
/// needs reference identity to tell a real routing change from re-committing the same injector.
public protocol InputInjector: AnyObject {
    /// Source-bound input is fail-closed unless an injector implements a final native-post fence.
    func submitScoped(_ event: SourceInputEvent, postFence: @escaping InputPostFence)
    /// Drain neutral releases on the input queue before another route can be raised/admitted.
    func drainForFocusChange(_ completion: @escaping () -> Void)
    /// An old ownership effect may arrive late. Real injectors carry this neutral-only fence to post.
    func releaseAfterOwnershipChange(postFence: @escaping InputPostFence)

    /// `button` is which mouse button to drive. Left is the wire default, so a client that predates
    /// the field is unchanged.
    func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton)
    /// Scroll the focused source. Default no-op — only a window injector acts on it (a simulator
    /// has no scroll surface here).
    ///
    /// `unit` is what the CLIENT's wheel event reported, forwarded rather than normalized: a notched
    /// wheel stays `.line` and a trackpad stays `.pixel`. For pixels the deltas are already in HOST
    /// POINTS — the client divides by its draw scale before sending, so a flick moves the content by
    /// what it looks like it moves it by.
    func scroll(normalizedX: Double, normalizedY: Double,
                deltaX: Double, deltaY: Double, unit: ScrollUnit, mods: InputModifiers)
    /// A TOUCH client's flick has ended: run the glide HERE, on the host's own clock. Velocity is in
    /// host points per second in the same sign convention as `scroll`'s deltas; ZERO cancels a glide
    /// in flight. Default no-op — only a window injector generates momentum.
    ///
    /// Never sent by a Mac trackpad client: macOS already synthesizes that momentum into the browser,
    /// where it arrives as ordinary `scroll` deltas, and a second source would double-scroll it.
    func scrollFling(normalizedX: Double, normalizedY: Double,
                     velocityX: Double, velocityY: Double, mods: InputModifiers)
    func scrollGesture(normalizedX: Double, normalizedY: Double, phase: ScrollGesturePhase,
                       velocityX: Double, velocityY: Double, mods: InputModifiers)
    /// Move the pointer over the focused source WITHOUT pressing (hover), so the host app updates the cursor
    /// shape under it. Default no-op — only a window injector acts on it; a simulator has no hover concept
    /// (its input is touch) and no system cursor.
    func move(normalizedX: Double, normalizedY: Double)
    /// One key transition into the focused source. Default no-op — only a window injector acts on it.
    func key(down: Bool, code: String, key: String, repeat: Bool, mods: InputModifiers)
    /// Release every key the injector believes is held and clear its modifier flags. Called on an
    /// explicit client release, on a focus/injector swap, on client leave, and on a hidden tab.
    func releaseKeys()
    /// Bring the source frontmost so global input lands on it. Default no-op — only a window injector
    /// (global CGEvents) needs it; a simulator injects into its own HID, not the shared cursor.
    func raise()
    /// EXACTLY ⌘V into the source — ⌘ down, V down and up, ⌘ up, with the Command flag ALONE — for a paste
    /// (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §4.2). Never the held modifiers: a held
    /// ⇧ would make it ⌘⇧V, "paste and match style". Whether it was POSTED: a window's ⌘V goes only into its
    /// own application, checked again at post time, and posts nothing when another one is in front. BLOCKS the
    /// caller until it is posted. Default false: posts nothing, and says so.
    func pasteShortcut() -> Bool
    /// Whether a KEY posted now reaches the source — its application is the FRONT one, which is where the window
    /// server sends a key, wherever the window is stacked — waiting, bounded, for a `raise()` to take effect.
    /// BLOCKS the caller up to the bound. Default true: a display has no application of its own (a paste there
    /// goes to whatever is in front, §4.2), and a simulator takes keys through its own HID.
    func awaitFrontmost() -> Bool
    /// The GLOBAL point (CG coordinates, top-left origin) of a normalized point on the source, or nil when
    /// unknown — where a drop lands (§5). Default nil.
    func screenPoint(normalizedX: Double, normalizedY: Double) -> CGPoint?
    /// A SIMULATOR's pass-through touch: one or two contacts, 0…1 on the picture AS SHOWN (`sim-touch`). Default
    /// no-op — a window has no fingers.
    func simTouch(phase: String, points: [SimPoint])
    /// What a soft keyboard inserted into a SIMULATOR window (`sim-text`). Default no-op.
    func simText(_ text: String)
    /// A source whose paste does NOT go through the Mac's clipboard — a simulator pastes through its own. nil, the
    /// default, means "write the Mac's clipboard, then `pasteShortcut`". BLOCKS until pasted or failed.
    func pasteText(_ text: String) -> Bool?
    /// Whether a paste or drop of FILES may land here. Default true; a simulator takes none.
    var takesFilePastes: Bool { get }
}

public extension InputInjector {
    func submitScoped(_ event: SourceInputEvent, postFence: @escaping InputPostFence) {}
    func releaseAfterOwnershipChange(postFence: @escaping InputPostFence) {
        if postFence({}) { releaseKeys() } // Non-native stand-ins; real posting injectors override.
    }
    func drainForFocusChange(_ completion: @escaping () -> Void) { releaseKeys(); completion() }

    func scroll(normalizedX: Double, normalizedY: Double,
                deltaX: Double, deltaY: Double, unit: ScrollUnit, mods: InputModifiers) {}
    func scrollFling(normalizedX: Double, normalizedY: Double,
                     velocityX: Double, velocityY: Double, mods: InputModifiers) {}
    func scrollGesture(normalizedX: Double, normalizedY: Double, phase: ScrollGesturePhase,
                       velocityX: Double, velocityY: Double, mods: InputModifiers) {}
    func move(normalizedX: Double, normalizedY: Double) {}
    func key(down: Bool, code: String, key: String, repeat: Bool, mods: InputModifiers) {}
    func releaseKeys() {}
    func raise() {}
    func pasteShortcut() -> Bool { false }
    func awaitFrontmost() -> Bool { true }
    func screenPoint(normalizedX: Double, normalizedY: Double) -> CGPoint? { nil }
    func simTouch(phase: String, points: [SimPoint]) {}
    func simText(_ text: String) {}
    func pasteText(_ text: String) -> Bool? { nil }
    var takesFilePastes: Bool { true }
}

/// Real stand-in: logs the normalized + mapped coordinates (proves the input pipeline round-trips).
public final class LoggingInjector: InputInjector {
    private let simWidth: Double
    private let simHeight: Double
    public init(simWidth: Double = 390, simHeight: Double = 844) { self.simWidth = simWidth; self.simHeight = simHeight }
    public func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {
        print("[input] \(phase) \(button.rawValue) normalized=(\(x), \(y)) sim=(\(x * simWidth), \(y * simHeight))")
    }
    /// Logged so the headless `RDEV_TEST_PATTERN=1` path can assert the WIRE end to end — two green
    /// unit suites either side of a seam say nothing about the seam.
    public func scroll(normalizedX x: Double, normalizedY y: Double,
                       deltaX dx: Double, deltaY dy: Double, unit: ScrollUnit, mods: InputModifiers) {
        print("[input] scroll normalized=(\(x), \(y)) d=(\(dx), \(dy)) unit=\(unit.rawValue) mods=\(mods.raw)")
    }
    public func scrollFling(normalizedX x: Double, normalizedY y: Double,
                            velocityX vx: Double, velocityY vy: Double, mods: InputModifiers) {
        print("[input] fling normalized=(\(x), \(y)) v=(\(vx), \(vy)) mods=\(mods.raw)")
    }
    public func key(down: Bool, code: String, key: String, repeat isRepeat: Bool, mods: InputModifiers) {
        print("[input] key \(down ? "down" : "up") code=\(code) key=\(key) repeat=\(isRepeat) mods=\(mods.raw)")
    }
    public func releaseKeys() { print("[input] keys released") }
}
