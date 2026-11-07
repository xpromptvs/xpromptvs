import AppKit
import ApplicationServices
import RdevCore
import CoreGraphics
import Foundation

/// Public-AX helpers for window discoverability + activation (window-liveness spec 2). Resolve a CGWindowID
/// to its app's AX window element (via `WindowSPI.getWindowID` == `_AXUIElementGetWindow`, matched against the
/// app's window list) and read `kAXMinimized`. A 1s AX messaging timeout is set BEFORE any read so a hung app
/// can't stall the host at the default 6s (same guard as `WindowInputInjector.matchedWindowElement`). Fail-closed:
/// any AX failure / missing Accessibility permission yields the conservative result (isMinimized → false), so a
/// window we cannot classify is never surfaced. `unminimize` is added in the activation task.
enum WindowAX {
    /// Owning pid of a window id. Uses `.optionAll` (NOT `.optionIncludingWindow`, which is on-screen-only and
    /// so returns nil for a MINIMIZED window — the whole case we need here) and matches by window number. nil
    /// if the window is gone.
    static func ownerPID(_ windowID: CGWindowID) -> pid_t? {
        guard let arr = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return arr.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
            .flatMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
    }

    /// The owning pid of each of `windowIDs` that the window server still has, from ONE `.optionAll` copy —
    /// `ownerPID` copies the whole list per call (review F5: the bell watch asked once per window).
    static func ownerPIDs(_ windowIDs: Set<CGWindowID>) -> [CGWindowID: pid_t] {
        guard !windowIDs.isEmpty,
              let arr = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [CGWindowID: pid_t] = [:]
        for d in arr {
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value, windowIDs.contains(id),
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            out[id] = pid
        }
        return out
    }

    /// Every window id the window server has, on-screen or not — a HIDDEN app's, another Space's, a
    /// minimized one — so a window absent from it has really gone (its app quit or it was closed).
    /// `.optionAll`, as `ownerPID`. Window NUMBERS need no Screen Recording, unlike titles.
    static func allWindowIDs() -> Set<CGWindowID> {
        guard let arr = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(arr.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// The app's AX window element whose `_AXUIElementGetWindow` == windowID, or nil.
    static func windowElement(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        guard let getWin = WindowSPI.getWindowID else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return nil }
        return wins.first { el in
            var id: CGWindowID = 0
            return getWin(el, &id) == .success && id == windowID
        }
    }

    /// AX messaging timeout for the DISCOVERY sweep, deliberately shorter than the 1s the per-window
    /// ACTIONS below use. Those run once, against a window the user just picked, where waiting is right.
    /// Discovery runs against every app on the machine, including hung ones, where waiting is the bug.
    /// Measured 2026-07-31: healthy apps answer `kAXWindows` in ≤0.013s, so this is >10× the observed
    /// worst case — while an unresponsive app costs 0.15s instead of 1s.
    private static let discoveryTimeout: Float = 0.15

    /// Every window of `pid` that AX reports minimized, in ONE round trip.
    ///
    /// LOAD-BEARING — this is per-PID, not per-window, and that is the whole point. It replaces an
    /// `isMinimized(pid:windowID:)` that the caller invoked once per candidate window, where EACH call
    /// re-fetched the app's entire `kAXWindows` list: an app with N off-screen windows cost N round
    /// trips, and a hung one cost N × the timeout.
    ///
    /// Measured on a machine where Simulator had ~90 phantom `CGWindowList` entries and an
    /// unresponsive AX interface (it reported ZERO AX windows while still taking the full timeout):
    /// **105 probes, 91.36s total.** `listSources` awaits this, so the palette stayed empty, no
    /// `source-list` was ever sent, and `smoke-multisource` timed out at 30s — presenting as "the host
    /// lists no windows" rather than as anything slow. Per-pid makes that one round trip per app;
    /// worst case is now (unresponsive apps) × 0.15s.
    ///
    /// Fail-closed, unchanged: any AX failure yields an EMPTY set, so a window that cannot be
    /// classified is simply never surfaced as minimized.
    static func minimizedWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        guard AXIsProcessTrusted(), let getWin = WindowSPI.getWindowID else { return [] }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, discoveryTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return [] }
        var minimized: Set<CGWindowID> = []
        for el in wins {
            var id: CGWindowID = 0
            guard getWin(el, &id) == .success else { continue }
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &v) == .success,
                  (v as? Bool) == true else { continue }
            minimized.insert(id)
        }
        return minimized
    }

    /// Un-minimize the window (set `kAXMinimized = false`) so ScreenCaptureKit can capture it. Best-effort:
    /// returns false (caller logs) on missing Accessibility permission / AX failure — a no-op if already
    /// non-minimized. Mutates the host's real desktop, which is fine under the dedicated-host window-control
    /// model. Touches only the window id + a fresh AX tree, so it is safe to call off any queue.
    @discardableResult
    /// Move the window so it sits fully on screen, if it doesn't already. Best-effort and ADVISORY (same
    /// caveats as `setSize`); returns true when a move was attempted.
    ///
    /// Why: a window's off-screen strip captures and streams fine, and the cursor can even be posted to
    /// those coordinates — but the window server hit-tests clicks against ON-SCREEN geometry, so the app
    /// never receives them and that part of the window is dead to input. Pulling the window back on screen
    /// is what makes its whole surface interactive.
    ///
    /// MAIN-THREAD: reads `NSScreen` (AppKit) to find the target display's VISIBLE frame (menu bar + Dock
    /// excluded), converting it from AppKit's bottom-left origin into the top-left space AX/CGWindow use.
    @MainActor
    static func nudgeOnScreen(windowID: CGWindowID) -> Bool {
        guard let bounds = WindowLivenessMonitor.onScreenBounds(windowID) else { return false }
        // Match by the window's centre, like ScreenCaptureSource does; fall back to the main screen.
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let screen = NSScreen.screens.first { s in
            let topLeft = CGRect(x: s.frame.minX, y: primaryH - s.frame.maxY,
                                 width: s.frame.width, height: s.frame.height)
            return topLeft.contains(centre)
        } ?? NSScreen.main
        guard let screen else { return false }
        let vf = screen.visibleFrame
        let visible = CGRect(x: vf.minX, y: primaryH - vf.maxY, width: vf.width, height: vf.height)
        guard let target = onScreenPosition(window: bounds, visible: visible) else { return false }
        guard let pid = ownerPID(windowID), let el = windowElement(pid: pid, windowID: windowID) else { return false }
        var p = target
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        let ok = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, value) == .success
        print("[window] nudged wid \(windowID) on-screen: \(Int(bounds.minX)),\(Int(bounds.minY)) -> "
            + "\(Int(target.x)),\(Int(target.y)) \(ok ? "ok" : "FAILED")")
        return ok
    }

    /// Resize the window to `w`x`h` POINTS via the public AX size attribute, then read back what the window
    /// ACTUALLY became and return that. Best-effort and ADVISORY: apps clamp to their own min/max, fixed-size
    /// dialogs refuse, and full-screen windows ignore it — so the requested size and the returned size often
    /// differ, and the RETURNED one is the truth. The caller replies with it unconditionally, which is what
    /// lets the client settle on reality instead of the size the user dragged to. nil only when the window
    /// can't be resolved at all. Requires the same Accessibility permission window input already needs.
    static func setSize(windowID: CGWindowID, w: Int, h: Int) -> CGSize? {
        guard let pid = ownerPID(windowID), let el = windowElement(pid: pid, windowID: windowID) else { return nil }
        var want = CGSize(width: CGFloat(w), height: CGFloat(h))
        if let value = AXValueCreate(.cgSize, &want) {
            _ = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, value)
        }
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var got = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &got) else { return nil }
        return got
    }

    static func unminimize(windowID: CGWindowID) -> Bool {
        guard AXIsProcessTrusted(), let pid = ownerPID(windowID),
              let el = windowElement(pid: pid, windowID: windowID) else { return false }
        return AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }
}
