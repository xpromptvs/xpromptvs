import Foundation

/// A KEY GOES TO THE FRONT APPLICATION — wherever the target window is stacked. A click lands on the window
/// under the point and activates its app on the way in, but a posted key event has no point: the window
/// server hands it to whichever application is frontmost at that moment. So a paste's ⌘V
/// (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §4.2), posted right after `raise()` asked for
/// the window's application to come to the front, reaches the target only once that has TAKEN EFFECT —
/// before it, the ⌘V pastes into whatever the person left in front.
///
/// So the paste WAITS for it, bounded: the seconds it took, or nil, and a nil posts nothing. PURE — the clock,
/// the sleep and the question are the caller's — so the rule is testable without a window server.
public enum FrontmostWait {
    /// Whether a paste's ⌘V may go to `front`, the front application's pid (nil: unknown). A WINDOW's paste goes
    /// only into the window's own application (`windowOwner`). A DISPLAY's (`windowOwner` nil) goes to whatever is
    /// in front on it — EXCEPT this host itself (`ownPID`): a display's raise hides the host app, but the hide
    /// takes effect ASYNCHRONOUSLY (`OwnWindows`), and a ⌘V posted while the host is still the front application
    /// pastes into it — the This Mac terminal, the dashboard — a window the display's picture never shows.
    public static func accepts(front: Int32?, windowOwner: Int32?, ownPID: Int32) -> Bool {
        guard let windowOwner else { return front != ownPID }
        return front == windowOwner
    }

    /// Ask `isFront` every `interval` seconds until it answers true or `bound` seconds have passed. The last
    /// ask is AT the deadline (the last sleep is cut to end there), so an activation landing exactly then counts.
    /// Returns the seconds it took — 0 when it already was — or nil when it never was.
    public static func wait(bound: Double, every interval: Double, now: () -> Double, sleep: (Double) -> Void,
                            until isFront: () -> Bool) -> Double? {
        let start = now()
        while true {
            if isFront() { return now() - start }
            let elapsed = now() - start
            if elapsed >= bound { return nil }
            sleep(min(interval, bound - elapsed))
        }
    }
}
