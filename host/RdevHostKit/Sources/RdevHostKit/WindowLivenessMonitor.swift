import Foundation
import CoreGraphics
import RdevCore

/// Polls the runtime liveness of the subscribed sources (~1 Hz, only while >=1 is watched) and reports a
/// change via `onChange`. For a WINDOW, "live" = the id is currently on an active Space's screen (a
/// `.optionOnScreenOnly` CGWindowList query); minimized, on-another-Space, and closed all read `live:false`.
/// For a DISPLAY, "live" = still attached. Public CGWindowList/CoreGraphics only — no AX, no SkyLight.
/// All mutable state is confined to `queue`.
/// @unchecked Sendable: `timer`/`watched*`/`last` are only ever touched on `queue`.
final class WindowLivenessMonitor: @unchecked Sendable {
    private static let intervalMs = 1000

    private let queue = DispatchQueue(label: "rdev.window.liveness")
    private var timer: DispatchSourceTimer?
    private var watchedWindows: [CGWindowID] = []       // subscribed window ids to poll; confined to `queue`
    private var watchedDisplays: [CGDirectDisplayID] = []  // subscribed display ids to poll; confined to `queue`
    private var last = LivenessSnapshot()                  // last-broadcast liveness; confined to `queue`

    /// Invoked ON `queue` with the full watched liveness snapshot whenever it changes. Set by the owner
    /// (SimManager) after construction. The handler must not block (it fans out a control broadcast).
    var onChange: ((LivenessSnapshot) -> Void)?

    /// Replace the watched set (called by SimManager after any change to the subscribed set). Starts the timer
    /// when anything is watched, cancels it when nothing is (no idle polling). Polls once immediately so a
    /// subscribe to an already-hidden window reflects without waiting a full interval.
    func setTargets(windows: [CGWindowID], displays: [CGDirectDisplayID]) {
        queue.async { [self] in
            watchedWindows = windows
            watchedDisplays = displays
            // Forget ids no longer watched. SEPARATELY, per kind — the two id spaces overlap numerically.
            last.windows = last.windows.filter { windows.contains($0.key) }
            last.displays = last.displays.filter { displays.contains($0.key) }
            if windows.isEmpty && displays.isEmpty { timer?.cancel(); timer = nil; return }
            if timer == nil { startTimer() }
            poll()
        }
    }

    /// The current known liveness snapshot (for the baseline push on control-open / claim). Safe from any thread
    /// other than `queue` itself.
    func snapshot() -> LivenessSnapshot { queue.sync { last } }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(Self.intervalMs), repeating: .milliseconds(Self.intervalMs))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    /// One poll tick (on `queue`): read the on-screen window ids once, map each watched id to its liveness, and
    /// invoke `onChange` with the full map iff anything changed.
    private func poll() {
        let current = buildLivenessSnapshot(
            watchedWindows: watchedWindows,
            onScreenWindows: watchedWindows.isEmpty ? [] : Self.onScreenWindowIDs(),
            watchedDisplays: watchedDisplays,
            // Only ask CoreGraphics when something needs the answer. The common case is windows only,
            // and this runs at 1 Hz for the life of every session.
            activeDisplays: watchedDisplays.isEmpty ? [] : ScreenCaptureSource.activeDisplayIDs())
        guard current != last else { return }
        last = current
        onChange?(current)
    }

    /// The window's current on-screen size in POINTS, or nil if it isn't on an active Space's screen. Used as
    /// the fallback truth when replying to a resize request whose AX element couldn't be resolved, so the
    /// client is never left waiting on a confirmation that can't come.
    static func onScreenSize(_ id: CGWindowID) -> CGSize? { onScreenBounds(id)?.size }

    /// The window's current bounds in the TOP-LEFT-origin space `kCGWindowBounds` uses, or nil if it can't
    /// be read. Shared by the resize reply and the on-screen nudge.
    static func onScreenBounds(_ id: CGWindowID) -> CGRect? {
        guard let arr = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = arr.first, let b = d[kCGWindowBounds as String] as? [String: Any] else { return nil }
        var r = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(b as CFDictionary, &r) else { return nil }
        return r
    }

    /// The ids of every window currently on an active Space's screen (one CGWindowList syscall). A watched window
    /// absent from this set is minimized, on another Space, or closed — all "not live" for our purposes.
    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(arr.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }
}
