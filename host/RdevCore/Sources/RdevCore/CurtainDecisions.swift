import Foundation

/// What the curtain's event tap does with one event (`curtainTapCallback`, CurtainController.swift).
public enum CurtainTapVerdict: Equatable, Sendable {
    /// rdev's own injected input: through, untouched.
    case pass
    /// The Mac's own keyboard or trackpad while curtained: swallowed.
    case drop
    /// ⌃⌥⌘U on the Mac's OWN keyboard: the panic unlock.
    case lower
}

/// `U` on an ANSI keyboard — the panic unlock's key.
public let curtainPanicKeycode: Int64 = 32

/// The tap's decision (docs/curtain.md). ORDER IS THE RULE: rdev's own input — it carries
/// `curtainInputMarker` — passes BEFORE the panic combo is looked at, so ⌃⌥⌘U unlocks only from the Mac's
/// own keyboard. From the driver (or a modifier stuck on the host plus a `u`) it is a key for the focused
/// app like any other; the driver lowers the curtain with its toggle. Until 2026-09-30 the combo was tested
/// first, and a forwarded ⌃⌥⌘U lifted the curtain.
public func curtainTapVerdict(marked: Bool, keyDown: Bool, keycode: Int64,
                              control: Bool, option: Bool, command: Bool) -> CurtainTapVerdict {
    if marked { return .pass }
    if keyDown && keycode == curtainPanicKeycode && control && option && command { return .lower }
    return .drop
}

/// Which displays the curtain must (re)black on a tick: every ACTIVE display it has not blacked — one
/// that woke or was attached mid-curtain — and every one whose gamma is no longer black: macOS or another
/// app restored its colour (a ColorSync restore, Night Shift, a mode change, a display utility) while the
/// curtain stayed up. Until 2026-09-30 only a change in the SET of active displays was noticed, so such a
/// screen sat lit with the Mac's own input still dead. A display that went away needs nothing: it is
/// blacked when it comes back.
public func curtainDisplaysToBlack(active: Set<UInt32>, blacked: Set<UInt32>,
                                   isBlack: (UInt32) -> Bool) -> Set<UInt32> {
    active.filter { !blacked.contains($0) || !isBlack($0) }
}
