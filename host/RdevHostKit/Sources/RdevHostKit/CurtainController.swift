import AppKit
import CoreGraphics
import Darwin
import RdevCore

/// Local "curtain": blacks out every physical display, hides the system cursor, and suppresses local
/// keyboard/trackpad — while rdev keeps streaming and driving the host normally. It does NOT lock the
/// session and does NOT switch console (the ARD LockScreen path does both and ends in a password prompt);
/// this is an in-place shield, so `console=true locked=false` throughout.
///
/// Input gating rides `curtainInputMarker`: a `.cghidEventTap` swallows every event EXCEPT those whose
/// `.eventSourceUserData` matches the marker `WindowInputInjector` stamps on its `CGEventSource`. So the
/// remote driver's clicks/moves/scrolls pass through untouched while the person at the machine is locked out.
///
/// Blackout is DISPLAY GAMMA, not a covering window (see `blackDisplays`): a full-screen opaque window
/// occludes the captured window, and macOS suspends rendering of a fully-occluded window, which stops SCK
/// frames. Gamma darkens the scanout without occluding anything, so capture keeps flowing.
///
/// Security honesty: this is a userspace deterrent, not a secure lock. It dies with the process (which is
/// also its deadman — a crash restores gamma + drops input suppression), and keyboard events bypass event
/// taps during secure event input (any password field). For a real lock use the OS lock; this is for
/// unattended remote use.
///
/// All state is confined to the main thread (the tap's run-loop source lives there); `raise()` and
/// `lower()` are safe to call from any thread and hop to main.
public final class CurtainController: @unchecked Sendable {
    public static let shared = CurtainController()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var reassertTimer: DispatchSourceTimer?
    private var up = false
    /// How many *unbalanced* CGDisplayHideCursor calls we've issued. CGDisplayHideCursor is CUMULATIVE —
    /// N hides need N shows — so this MUST be drained to 0 on lower, or the cursor stays hidden until the
    /// process exits. All access is main-thread (raise/lower/timer + the tap callback on the main runloop).
    private var cursorHideDepth = 0
    private var loggedAsleep = false   // diagnostic: last-logged main-display sleep state while curtained
    /// The displays we have actually blacked, so the reassert timer can notice one waking or being
    /// attached mid-curtain and black that one too.
    private var blackedIDs: Set<CGDirectDisplayID> = []
    /// Displays found with their gamma RESET on the last tick — logged once per reset, not per tick (a
    /// display whose gamma cannot be set at all would otherwise log four times a second).
    private var lastReset: Set<CGDirectDisplayID> = []

    private init() {}

    public var isUp: Bool { up }

    // MARK: control (thread-safe)

    public func raise() { onMain { self._raise() } }
    public func lower() { onMain { self._lower() } }
    public func toggle() { onMain { self.up ? self._lower() : self._raise() } }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: raise / lower (main thread only)

    private func _raise() {
        guard !up else { return }
        guard installTap() else {
            print("[curtain] NOT raised — CGEvent.tapCreate failed (needs Accessibility/Input Monitoring)")
            return
        }
        // WAKE BEFORE BLACKING. Measured 2026-08-31 on a deployed host: raised over a SLEEPING display,
        // `setGammaBlack` iterated an empty `CGGetActiveDisplayList` and blacked NOTHING (rMax read
        // 1.000 from another process) while the tap still suppressed local input — a Mac fully visible
        // with its keyboard and trackpad dead, the exact inverse of what the curtain promises. The hold
        // is taken regardless of `RDEV_KEEP_AWAKE`: a curtain over a dark display is the defect this
        // removes, not a preference.
        DisplayAwakeKeeper.shared.hold(.curtain)
        // Black out via DISPLAY GAMMA, NOT a covering window. LOAD-BEARING: a full-screen opaque window
        // (at ANY level) fully OCCLUDES the captured window, and macOS suspends rendering of a fully
        // occluded window → it stops producing damage → SCK stops delivering frames (measured: capture
        // drops to 0 within ~2s under a cover at every level, shielding or not). Gamma-to-black occludes
        // nothing: compositing continues, windows keep rendering, and SCK captures PRE-gamma (real)
        // content while the physical scanout is black. Verified: 10fps of real frames throughout.
        guard blackDisplays() > 0 else {
            DisplayAwakeKeeper.shared.release(.curtain)
            removeTap()   // installTap() already ran; leaving it armed would suppress input for nothing
            print("[curtain] NOT raised — no ACTIVE display to black (asleep or none attached). "
                  + "A curtain that suppresses input without darkening anything is worse than none.")
            return
        }
        enableBackgroundCursorControl()
        hideCursor()
        // Re-assert the cursor hide on a slow tick (a backstop; the fast path is per-event in the tap), and
        // watchdog the display: if it ever reads asleep while curtained, the sleep assertion failed to hold
        // and SCK capture is about to die (the "video stops at ~2 min" bug). Log it loudly rather than let
        // it fail silently — same discipline as the frame-arrival watchdog gap.
        //
        // FOUR TIMES A SECOND, because the tick is also what re-blacks a display whose gamma was RESET
        // (below): the interval is how long the Mac's screen can show before it goes dark again.
        loggedAsleep = false
        lastReset = []
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.reassertCursorHidden()
            // A display that WAKES or is ATTACHED mid-curtain arrives UNBLACKED — and so does one whose
            // gamma macOS or another app RESETS while the curtain stays up (a ColorSync restore, Night
            // Shift, a mode change, a display utility). Until 2026-09-30 only a change in the SET of
            // active displays was noticed, so a reset screen sat lit with the Mac's own input still dead.
            // Each blacked display's table is read back from WindowServer (`gammaIsBlack`).
            let active = Self.activeDisplaySet()
            let need = curtainDisplaysToBlack(active: active, blacked: self.blackedIDs, isBlack: Self.gammaIsBlack)
            let reset = need.intersection(self.blackedIDs)
            if !reset.subtracting(self.lastReset).isEmpty {
                print("[curtain] display(s) \(reset.sorted()) had their gamma RESET while curtained — blacking again")
            }
            self.lastReset = reset
            if need.isEmpty { self.blackedIDs.formIntersection(active) } else { _ = self.blackDisplays() }
            let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            if asleep && !self.loggedAsleep {
                print("[curtain] WARN: main display went ASLEEP while curtained — SCK capture will die; DisplayAwakeKeeper's hold did not take")
            }
            self.loggedAsleep = asleep
        }
        t.resume()
        reassertTimer = t
        up = true
        print("[curtain] UP — gamma blacked, cursor hidden, input suppressed, display kept awake")
    }

    private func _lower() {
        guard up else { return }
        reassertTimer?.cancel(); reassertTimer = nil
        DisplayAwakeKeeper.shared.release(.curtain)
        restoreGamma()
        showCursor()
        removeTap()
        up = false
        print("[curtain] DOWN — display restored, cursor shown, local input live")
    }

    /// Every ACTIVE display id. A sleeping display is ONLINE but not ACTIVE, and only an active one
    /// can be blacked — which is exactly why raising over a sleeping display used to black nothing.
    private static func activeDisplaySet() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return Set(ids.prefix(Int(n)))
    }

    /// Force every ACTIVE display's scanout to black via its gamma transfer function (output = 0 for all
    /// inputs) and return HOW MANY were blacked. Gamma is applied at scanout AFTER window compositing and
    /// AFTER SCK's capture, so this darkens the physical screen without touching what SCK sees. macOS
    /// restores a process's gamma automatically when it exits, so a host crash self-heals the blackout.
    ///
    /// RETURNING THE COUNT IS LOAD-BEARING: the caller refuses to raise on zero. A silent partial
    /// success here is the whole defect — a curtain that reports itself UP while darkening nothing.
    @discardableResult private func blackDisplays() -> Int {
        let active = Self.activeDisplaySet()
        // ONLY WHAT macOS ACCEPTED counts: a display whose gamma cannot be set is not dark, and counting it
        // would be the same silent partial success as blacking an empty list.
        let blacked = active.filter { CGSetDisplayTransferByFormula($0, 0, 0, 1, 0, 0, 1, 0, 0, 1) == .success }
        blackedIDs = blacked
        return blacked.count
    }

    /// Whether `id`'s gamma still maps every input to black, read back from WindowServer, so a restore by
    /// macOS or another process shows. A read that fails counts as NOT black: blacking again is harmless.
    private static func gammaIsBlack(_ id: CGDirectDisplayID) -> Bool {
        let capacity: UInt32 = 256
        var r = [CGGammaValue](repeating: 1, count: Int(capacity)), g = r, b = r
        var n: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &n) == .success, n > 0 else { return false }
        let k = Int(n)
        return r.prefix(k).allSatisfy { $0 < 0.01 } && g.prefix(k).allSatisfy { $0 < 0.01 } && b.prefix(k).allSatisfy { $0 < 0.01 }
    }

    private func restoreGamma() {
        CGDisplayRestoreColorSyncSettings()
        blackedIDs = []
    }

    // MARK: event tap

    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) | (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: curtainTapCallback, userInfo: selfPtr) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = src
        return true
    }

    private func removeTap() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        runLoopSource = nil; tap = nil
    }

    fileprivate func reEnableTap() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    // MARK: cursor — CGDisplayHideCursor is a CUMULATIVE (balanced) API; every hide is counted so lower
    // can drain exactly as many shows. Hide/show on the main display only (the visibility counter is
    // system-global, so one display is enough and keeps the count unambiguous).

    /// Initial hide when the curtain raises: exactly one unbalanced hide.
    private func hideCursor() {
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHideDepth += 1
    }

    /// Re-assert the hide (an injected mouse move can re-show the sprite). CGCursorIsVisible is unavailable
    /// on this SDK, so we can't guard on real visibility — instead CAP the unbalanced depth. Extra hides
    /// beyond the cap are pointless (already hidden) and only lengthen the drain; the cap keeps `lower`
    /// instant no matter how long the curtain was up or how many moves it saw.
    private static let maxHideDepth = 16
    fileprivate func reassertCursorHidden() {
        guard up, cursorHideDepth < Self.maxHideDepth else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHideDepth += 1
    }

    /// Balance EXACTLY the hides we issued. This is the fix for "cursor stays hidden until the host is
    /// killed": a single show could never balance the initial + timer + per-event hides, so the cumulative
    /// hide level stayed negative and only the process exit (which releases all its hides) restored it.
    private func showCursor() {
        while cursorHideDepth > 0 { CGDisplayShowCursor(CGMainDisplayID()); cursorHideDepth -= 1 }
    }

    /// Lift the "cursor is only hideable by the frontmost app" restriction so `CGDisplayHideCursor` sticks
    /// from this background process. Private SkyLight; resolved by dlsym so a missing symbol degrades to a
    /// visible cursor rather than a crash.
    private func enableBackgroundCursorControl() {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func sym(_ s: String) -> UnsafeMutableRawPointer? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), s) ?? sky.flatMap { dlsym($0, s) }
        }
        guard let mc = sym("CGSMainConnectionID"), let sp = sym("CGSSetConnectionProperty") else {
            print("[curtain] SetsCursorInBackground unavailable — cursor may reappear on move"); return
        }
        let conn = unsafeBitCast(mc, to: (@convention(c) () -> Int32).self)()
        let set = unsafeBitCast(sp, to: (@convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32).self)
        _ = set(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

/// C tap callback: pass events carrying the curtain marker, swallow everything else. On a mouse event
/// that passes, re-hide the cursor immediately (closes the reappear gap the slow re-assert timer left).
private func curtainTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let ctrl = Unmanaged<CurtainController>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        ctrl.reEnableTap()
        return nil
    }
    // `curtainTapVerdict` (RdevCore) decides, and its ORDER is the rule: rdev's own input — it carries the
    // marker — passes BEFORE the panic combo is looked at, so ⌃⌥⌘U unlocks only from the Mac's OWN
    // keyboard (the shield covers the menu bar, so without it a locally locked host with no remote client
    // could only be freed by SSH/kill). Forwarded, it is a key for the focused app; the driver has its toggle.
    let flags = event.flags
    switch curtainTapVerdict(marked: event.getIntegerValueField(.eventSourceUserData) == curtainInputMarker,
                             keyDown: type == .keyDown,
                             keycode: event.getIntegerValueField(.keyboardEventKeycode),
                             control: flags.contains(.maskControl), option: flags.contains(.maskAlternate),
                             command: flags.contains(.maskCommand)) {
    case .pass:
        ctrl.reassertCursorHidden()              // our injected move may have re-shown it — re-hide (counted)
        return Unmanaged.passUnretained(event)   // rdev's own input — let it through
    case .lower:
        print("[curtain] lowering — ⌃⌥⌘U on the Mac's own keyboard")
        ctrl.lower()
        return nil                               // consumed
    case .drop:
        return nil                               // local keyboard/trackpad — drop
    }
}
