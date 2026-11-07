import AppKit
import Foundation

/// **THE HOST'S OWN WINDOWS ARE OUT OF THE PICTURE, SO THEY MUST BE OUT OF THE WAY.**
///
/// A display is the one source whose picture and whose screen deliberately DISAGREE: `SelfCapture`
/// cuts every window this process owns out of it (the pairing secret lives in one), so the client
/// sees whatever is BEHIND them. Its input is real clicks at real coordinates, though, and those land
/// on whatever is IN FRONT — so every tap over the host's own window went into a window the client
/// could not see, nothing it could see changed, and the picture read as frozen.
///
/// MEASURED 2026-09-25 on the Mac mini, reported as "the desktop gives the first frame and stalls,
/// unless I open another window first": capture, encode, decode and paint all ran at ~58 fps while
/// the encoder produced ~30 kbps — a screen that genuinely was not changing — because the Xpromptvs
/// window, 1000x800 pt in the middle of a 1920x1080 display, was frontmost and took every tap.
/// Opening a window first "fixed" it only because a window subscribe RAISES that window over it.
///
/// So a display taking input focus HIDES this application: the counterpart, for a display, of
/// raising the subscribed window. Hiding touches nothing on the capture side — the exclusion stays
/// the thing that keeps the secret out of the picture, and must go on being gated as such.
///
/// Nothing un-hides it again automatically. Bringing the app back is the local person's call, like
/// any other hidden app — and when they do mid-session, the next press or scroll from the display
/// client hides it again (`reclearIfUnhidden`), because the invisible-window hazard has come back
/// with it. That press WAITS for the hide (bounded), or it would be posted into the very window it is
/// clearing. `orderFrontRegardless` and `makeKeyAndOrderFront` on a hidden app unhide it implicitly
/// and post `didUnhideNotification` too (measured), so a window the app raises by itself counts.
enum OwnWindows {
    private static let lock = NSLock()
    /// Set by `NSApplication.didUnhideNotification` once a hide has happened; cleared by the next.
    nonisolated(unsafe) private static var unhiddenSinceHide = false
    /// Main-thread only.
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// Hide this host's application so the display a client drives is the display it sees.
    ///
    /// ASYNC TO THE MAIN QUEUE, and never `.sync`: AppKit called from a background thread silently
    /// does nothing here, and the app calls into the host ON the main thread, so a `.sync` from a
    /// path that thread is waiting on would deadlock. Called from `WindowInputInjector.raise()`, which runs
    /// off the main thread at both places input focus moves.
    static func clearForDisplayInput(then done: (@Sendable () -> Void)? = nil) {
        lock.withLock { unhiddenSinceHide = false }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                defer { done?() }
                // A process with no NSApplication (the headless test-pattern harness) has no windows
                // to be in the way of anything.
                guard let app = NSApp else { return }
                watchUnhide()
                guard !app.isHidden else { return }
                app.hide(nil)
                print("[display-input] hid this host's own windows — they are cut out of the picture "
                    + "a display client clicks through, so they must not be under its clicks either")
            }
        }
    }

    /// Before a press or a scroll from a display client: hide again if someone at the Mac brought
    /// the application back, and WAIT for it — the caller posts the event next, and posted first it
    /// lands in the window being cleared. One lock read in the ordinary case.
    ///
    /// BOUNDED, not a `.sync`: the main thread may itself be waiting on the input queue, and a
    /// deadlock there would take every input with it. Past the bound the event is posted anyway —
    /// one misdirected press, the cost of the old behaviour, and never a hang.
    static func reclearIfUnhidden(waitingUpTo bound: DispatchTimeInterval = .milliseconds(250)) {
        guard lock.withLock({ unhiddenSinceHide }) else { return }
        let hidden = DispatchSemaphore(value: 0)
        clearForDisplayInput { hidden.signal() }
        if hidden.wait(timeout: .now() + bound) == .timedOut {
            print("[display-input] the re-hide did not finish within the bound; posting anyway")
        }
    }

    @MainActor private static func watchUnhide() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: nil
        ) { _ in lock.withLock { unhiddenSinceHide = true } }
    }
}
