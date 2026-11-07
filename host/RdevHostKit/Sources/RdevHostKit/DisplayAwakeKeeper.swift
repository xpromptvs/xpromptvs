import Foundation
import IOKit.pwr_mgt
import RdevCore

/// Keeps the host's display awake, and WAKES it when it is already asleep.
///
/// WHY THIS EXISTS: a sleeping display is online but NOT active, which empties both
/// `CGGetActiveDisplayList` and `SCShareableContent.displays` — so there is no `dsp:` source, no
/// thumbnail and no frame on any source, while windows keep enumerating and the palette merely looks
/// incomplete. Measured on a deployed host: twelve hours in that state with every counter healthy.
///
/// TWO MECHANISMS, DELIBERATELY:
///
/// - `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` on a 30 s tick. THIS IS THE ONE THAT
///   MATTERS. `PreventUserIdleDisplaySleep` alone does NOT stop the screensaver: loginwindow's idle
///   check reads HID idle time (measured on the mini: `actualUserIdle = 269.8, targetUserIdle =
///   1200.0`), which a display-sleep assertion does not touch. The screensaver fires, the lock
///   follows 300 s later, and a locked Mac cannot be recovered remotely AT ALL — `loginwindow`
///   discards synthetic events from an Aqua-session app. Declaring user activity resets that timer
///   AND wakes an already-sleeping display, so this recovers as well as prevents. 30 s because the
///   shortest screensaver idle macOS offers is 60 s.
/// - A continuous `PreventUserIdleDisplaySleep` assertion. Belt and braces, and it is what makes
///   `pmset -g` print "display sleep prevented by Rdev" — which is how this gets diagnosed from
///   outside a packaged app, whose stdout goes to /dev/null.
///
/// All state is confined to `lock`; `hold`/`release`/`wakeNow` are safe from any thread.
public final class DisplayAwakeKeeper: @unchecked Sendable {
    public static let shared = DisplayAwakeKeeper()

    private let lock = NSLock()
    private var reasons = DisplayAwakeReasons()
    private var preventSleep: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var userActivity: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var timer: DispatchSourceTimer?

    private init() {}

    public var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return reasons.isHeld }

    public func hold(_ reason: DisplayAwakeReasons.Reason) {
        lock.lock()
        let wasHeld = reasons.isHeld
        reasons.add(reason)
        let names = reasons.reasons
        lock.unlock()
        if !wasHeld { startHolding() }
        print("[awake] holding for \(names.joined(separator: "+"))")
        // UNCONDITIONAL, even when a hold was already live: a NEW reason arriving over an
        // already-sleeping display must still wake it. This is the whole recovery path.
        wakeNow()
    }

    public func release(_ reason: DisplayAwakeReasons.Reason) {
        lock.lock()
        reasons.remove(reason)
        let stillHeld = reasons.isHeld
        let names = reasons.reasons
        lock.unlock()
        if !stillHeld { stopHolding() }
        print("[awake] released \(reason.rawValue); now \(names.isEmpty ? "nothing" : names.joined(separator: "+"))")
    }

    /// Declare local user activity: resets the idle timer and WAKES a sleeping display. Safe to call
    /// repeatedly — the same assertion id is re-armed rather than a new one created.
    public func wakeNow() {
        lock.lock(); defer { lock.unlock() }
        let rc = IOPMAssertionDeclareUserActivity(
            "rdev — remote session active" as CFString, kIOPMUserActiveLocal, &userActivity)
        if rc != kIOReturnSuccess {
            print("[awake] WARN: IOPMAssertionDeclareUserActivity failed rc=\(rc) — the display may sleep and kill capture")
        }
    }

    private func startHolding() {
        lock.lock()
        if preventSleep == IOPMAssertionID(kIOPMNullAssertionID) {
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "rdev — keep display awake" as CFString, &preventSleep)
            if rc != kIOReturnSuccess {
                print("[awake] WARN: display-sleep assertion failed rc=\(rc)")
                preventSleep = IOPMAssertionID(kIOPMNullAssertionID)
            }
        }
        // Utility queue, not main: this must keep ticking while the main thread is busy, and it
        // touches nothing main-affine.
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.wakeNow() }
        t.resume()
        timer = t
        lock.unlock()
    }

    private func stopHolding() {
        lock.lock()
        timer?.cancel(); timer = nil
        if preventSleep != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(preventSleep)
            preventSleep = IOPMAssertionID(kIOPMNullAssertionID)
        }
        if userActivity != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(userActivity)
            userActivity = IOPMAssertionID(kIOPMNullAssertionID)
        }
        lock.unlock()
    }
}
