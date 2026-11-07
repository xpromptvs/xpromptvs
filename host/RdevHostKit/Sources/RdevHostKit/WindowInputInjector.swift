import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ApplicationServices
import RdevCore
import RdevWorkspaceKit

/// Global-CGEvent input injection into a captured macOS window (dedicated-host / cross-device model).
/// Conforms to `InputInjector`: touch down/move/up map to left-button mouseDown/mouseDragged/mouseUp;
/// `scroll` maps to a scrollWheel event. Every event is posted to the global HID stream
/// (`CGEvent.post(tap: .cghidEventTap)`) at the window's mapped global point — so `raise()` MUST have
/// made the window frontmost first (global events go to the front window under the point). This moves
/// the host's system cursor; that's fine when driving from another device. (The Task-1 gate disproved
/// the cursorless `postToPid` alternative for background apps.) Injection no-ops (one-time log) when the
/// Accessibility permission is absent. A private serial queue preserves down→move→up (and scroll)
/// ordering — the same guarantee `SimHIDInjector`'s single-consumer stream provides.
/// @unchecked Sendable: ALL mutable state (`bounds`, `warned`, `currentFlags`, the scroll
/// accumulator/phase/generation, the momentum glide and its generation, `heldKeys`, the click run,
/// the last mouse point and the drop-carry gate) is confined to `queue`. `raise()` and `awaitFrontmost()` are the exceptions and
/// touch only immutable state.
public final class WindowInputInjector: InputInjector, @unchecked Sendable {
    private let target: SourceTarget
    private let workspaceAdmission: (@Sendable (Double, Double) -> Bool)?
    private let workspaceReady: (@Sendable () -> Bool)?
    private let workspacePost: (@Sendable (CGEvent) -> Bool)?
    private var workspaceGesture = WorkspaceInputGesture()
    private let workspaceLease = WorkspaceInputLease()
    private var workspaceLastSafe: (point: CGPoint, owner: WorkspaceOwner)?
    private var workspaceScrollPoint: CGPoint?
    private var workspaceModifiers: Set<UInt16> = []
    // Bounded automation diagnostics; no titles or executable paths are logged.
    private let workspaceDiagnosticsEnabled = ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1"
    private var workspaceDiagnosticEvents = 0
    private var workspaceDiagnosticLines = 0
    private var workspaceDiagnosticEventActive = false
    private func workspaceDiagnostic(_ message: @autoclosure () -> String) {
        guard isWorkspace, workspaceDiagnosticsEnabled, workspaceDiagnosticEventActive,
              workspaceDiagnosticLines < 1080 else { return }
        workspaceDiagnosticLines += 1
        FileHandle.standardError.write(Data(("[workspace-input] event=\(workspaceDiagnosticEvents) \(message())\n").utf8))
    }
    private struct WorkspaceOwner: Equatable {
        let pid: pid_t
        let generation: String
        let executable: URL
    }
    private var isWorkspace: Bool { if case .workspace = target { return true }; return false }
    /// The owning process, for `raise()` ONLY. nil for a display — and nothing else needs it, because
    /// every event already posts globally to `.cghidEventTap`. The pid never fed anything but the raise.
    private let pid: pid_t?
    private let source = WindowInputInjector.makeMarkedSource()
    // Retired workspace releases finish before a successor's input on this one session workspace.
    private static let workspaceInputQueue = DispatchQueue(label: "rdev.workspace.input")
    private let queue: DispatchQueue
    private let inputScope: ScopedInputExecution
    private var postForTests: ((CGEvent) -> Void)?
    private var scopedModifiers = Set<UInt16>()
    private var scopedButtons: [(MouseButton, CGPoint)] = []

    /// A HID event source stamped with `curtainInputMarker`. Every CGEvent built from it carries the
    /// marker in `.eventSourceUserData`, so the curtain's event tap lets rdev's injected input through
    /// while swallowing local keyboard/trackpad. Setting it on the SOURCE covers all post sites
    /// (down/move/up, hover, scroll) uniformly — no per-event stamping to forget. `HostDrop` posts through
    /// one too: its drag must reach the Mac with the curtain up.
    static func makeMarkedSource() -> CGEventSource? {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.userData = curtainInputMarker
        return src
    }
    private var bounds: CGRect      // window's global frame; confined to `queue`
    private var warned = false      // one-time "no permission" log; confined to `queue`

    /// The modifier flags the client last reported, stamped on EVERY event this injector posts —
    /// mouse included, which is what makes ⇧-click, ⌘-click and ⌥-drag work with no protocol change.
    /// Confined to `queue`. Written ONLY by messages that carry their own `mods` snapshot (`scroll`,
    /// `win-key`), so there is exactly one writer and it cannot drift from the client's own state.
    private var currentFlags: CGEventFlags = []
    private var scrollAccumulator = PixelScrollAccumulator()   // confined to `queue`
    private var scrollPhase = ScrollPhaseMachine()             // confined to `queue`
    private var scrollGeneration = 0                           // confined to `queue`; stale-timer guard
    private var nativeScrollContact = false                    // explicit AppKit contact, not a quiet-time guess
    private var momentum = ScrollMomentum()                    // confined to `queue`
    private var momentumGeneration = 0                         // confined to `queue`; stale-tick guard
    private var heldKeys = HeldKeys()                          // confined to `queue`
    private var clicks = ClickCounter()                        // confined to `queue`
    /// Where the last mouse event this injector posted put the pointer, for the drag/move deltas.
    /// nil until the first one: a delta measured from somewhere this injector never put the pointer
    /// would be a jump nobody made. Confined to `queue`.
    private var lastMousePoint: CGPoint?
    /// A drop's carry (`DropCarry`) and the press it swallowed, if one began during it. Confined to `queue`.
    private var carryGate = DropCarryGate()

    /// Arrival-cadence instrument (`RDEV_SCROLL_PROBE=1`). **nil unless the variable is set**, so an
    /// ordinary host allocates nothing, arms no timer and takes one nil check per scroll — the same
    /// rule the frame instruments follow (`gate-latency-overlay.sh` asserts their absence).
    ///
    /// MEASURED AT THE POST SITE, not at message arrival, and that is the point: what an app judders
    /// on is the cadence of the CGEvents it actually receives, which includes this queue's own hop.
    /// A probe reading the channel instead would measure something no app can see. Confined to
    /// `queue`, reported from `queue`.
    private var scrollCadence: ScrollCadence? =
        ProcessInfo.processInfo.environment["RDEV_SCROLL_PROBE"] == "1" ? ScrollCadence() : nil
    private var scrollProbeTimer: DispatchSourceTimer?         // confined to `queue`

    /// Resolve the target's initial global bounds (and, for a window, its owning pid). Returns nil when
    /// the subject cannot be resolved — the caller then falls back to a video-only, nil injector. NEVER
    /// construct with a zero frame, which would silently misdirect every click.
    ///
    /// A DISPLAY'S BOUNDS COME FROM `CGDisplayBounds`, which is ALREADY the global top-left-origin space
    /// that `kCGWindowBounds` and `windowInputPoint` use — so the mapping is unchanged and there is no
    /// conversion to get wrong. Note a second display legitimately has a non-zero or NEGATIVE origin,
    /// which a single-display machine can never exercise; `TouchMappingTests` is the guard.
    public init?(target: SourceTarget, workspaceAdmission: (@Sendable (Double, Double) -> Bool)? = nil,
                 workspaceReady: (@Sendable () -> Bool)? = nil,
                 workspacePost: (@Sendable (CGEvent) -> Bool)? = nil) {
        self.target = target
        if case .workspace = target { self.queue = Self.workspaceInputQueue }
        else { self.queue = DispatchQueue(label: "rdev.window.input") }
        self.inputScope = ScopedInputExecution(queue: queue)
        self.workspaceAdmission = workspaceAdmission
        self.workspaceReady = workspaceReady
        self.workspacePost = workspacePost
        switch target {
        case .simulator:
            // A simulator is driven through its OWN HID (SimulatorInputInjector), never by global CGEvents.
            return nil
        case .window(let w):
            guard let info = WindowInputInjector.lookup(CGWindowID(w)),
                  let pid = info.pid, let bounds = info.bounds else { return nil }
            self.pid = pid
            self.bounds = bounds
        case .workspace(let d):
            guard workspaceAdmission != nil, workspaceReady != nil, workspacePost != nil else { return nil }
            let b = CGDisplayBounds(CGDirectDisplayID(d))
            guard CGDisplayIsOnline(CGDirectDisplayID(d)) != 0, b.width > 0, b.height > 0 else { return nil }
            self.pid = nil; self.bounds = b
        case .display(let d):
            let b = CGDisplayBounds(CGDirectDisplayID(d))
            guard b.width > 0, b.height > 0 else { return nil }
            self.pid = nil
            self.bounds = b
        }
    }

    /// No native lookup, permission or system post: tests exercise the real event/queue machinery.
    init(testBounds: CGRect, post: @escaping (CGEvent) -> Void) {
        target = .window(0); pid = nil; bounds = testBounds
        workspaceAdmission = nil; workspaceReady = nil; workspacePost = nil
        queue = DispatchQueue(label: "rdev.window.input.test")
        inputScope = ScopedInputExecution(queue: queue)
        postForTests = post
    }
    func enqueueForTests(_ work: @escaping () -> Void) { queue.async(execute: work) }

    public func submitScoped(_ event: SourceInputEvent, postFence: @escaping InputPostFence) {
        guard !isWorkspace else { return } // Parked application workspaces have a separate post boundary.
        queue.async { [self] in inputScope.run(fence: postFence) { dispatchScoped(event) } }
    }
    public func releaseAfterOwnershipChange(postFence: @escaping InputPostFence) {
        if isWorkspace { releaseKeys(); return } // Its legacy workspace boundary must not nest hub fences.
        submitScoped(.winKeysRelease, postFence: postFence)
    }

    public func drainForFocusChange(_ completion: @escaping () -> Void) {
        queue.async { [self] in inputScope.run(fence: nil) { releaseKeys(); completion() } }
    }

    /// Bring the *subscribed* window frontmost so global CGEvents land on it. Load-bearing (SimManager calls
    /// this on attach). Skipped by `RDEV_WINDOW_NO_RAISE=1` (debugging).
    ///
    /// Fronts the owning process with `SetFrontProcessWithOptions` (NSRunningApplication.activate is
    /// advisory-only since macOS 14), then raises the AX element whose `_AXUIElementGetWindow` matches THIS
    /// window id. This replaces the previous AX `wins.first` approach, which raised the app's FIRST window
    /// rather than the subscribed one — wrong for any multi-window app, and unsound since the cap became
    /// unbounded.
    ///
    /// NO FALLBACK by design: if the SPI is unavailable we log once and no-op. Falling back to the old path
    /// would silently re-introduce the wrong-window bug and be indistinguishable from it.
    public func raise() {
        guard ProcessInfo.processInfo.environment["RDEV_WINDOW_NO_RAISE"] != "1" else { return }
        // A DISPLAY HAS NOTHING TO RAISE — BUT IT HAS SOMETHING TO CLEAR: this host's own windows,
        // which are cut out of the display's picture and would otherwise take every click over them.
        // See `OwnWindows`; this was a no-op until 2026-09-25, and the Mac mini's desktop "froze".
        if isWorkspace { OwnWindows.clearForDisplayInput(); return }
        if case .display = target {
            OwnWindows.clearForDisplayInput()
            return
        }
        guard case .window(let w) = target, let pid else { return }
        let windowID = CGWindowID(w)
        guard let getPSN = WindowSPI.getProcessForPID,
              let setFront = WindowSPI.setFrontProcessWithOptions,
              let getWin = WindowSPI.getWindowID else {
            Self.warnSPIOnce()
            return
        }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else {
            print("[window-input] raise: GetProcessForPID failed for pid \(pid) — clicks may land on the wrong window")
            return
        }
        _ = setFront(&psn, WindowSPI.kSetFrontProcessFrontWindowOnly | WindowSPI.kSetFrontProcessCausedByUser)

        guard let match = matchedWindowElement(getWin, pid: pid, windowID: windowID) else {
            print("[window-input] raise: no AX element matched wid \(windowID) — clicks may land on the wrong window")
            return
        }
        // A stale element (the app silently rebuilt the window's a11y node) makes AXRaise no-op SILENTLY.
        // Re-resolve by wid once and retry rather than swallow it.
        if AXUIElementPerformAction(match, kAXRaiseAction as CFString) == .invalidUIElement,
           let fresh = matchedWindowElement(getWin, pid: pid, windowID: windowID) {
            let err = AXUIElementPerformAction(fresh, kAXRaiseAction as CFString)
            if err != .success {
                print("[window-input] raise: AXRaise retry failed for wid \(windowID) (err \(err.rawValue)) — clicks may land on the wrong window")
            }
        }
    }

    /// The app's AX window element whose CGWindowID == our subscribed windowID. Creates a FRESH app element
    /// each call — so a re-resolve after a stale element reads a live tree — and applies the 1s AX messaging
    /// timeout (F8) BEFORE any AX read, so neither the initial lookup NOR the retry can stall the host at the
    /// default 6s.
    private func matchedWindowElement(
        _ getWin: @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError,
        pid: pid_t, windowID: CGWindowID
    ) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
              let wins = winRef as? [AXUIElement] else { return nil }
        return wins.first { el in
            var id: CGWindowID = 0
            return getWin(el, &id) == .success && id == windowID
        }
    }

    private static let spiWarnLock = NSLock()
    private nonisolated(unsafe) static var spiWarned = false
    /// One-time log — mirrors the Accessibility no-op precedent in this file.
    private static func warnSPIOnce() {
        spiWarnLock.lock(); defer { spiWarnLock.unlock() }
        guard !spiWarned else { return }
        spiWarned = true
        print("[window-input] raise: window-raise SPI unavailable on this macOS — window input will target the wrong window; video is unaffected")
    }

    /// Ask macOS for Accessibility, showing its prompt. Returns the trust state AFTER asking.
    ///
    /// UNCONDITIONAL, unlike `ensureAccessibilityPrompt` below: this is the explicit-consent path
    /// behind the app's Grant button, and a click that silently did nothing would be worse than a
    /// dialog macOS declines to show. Suppression is macOS's job — once the app has a TCC record
    /// the prompt simply does not appear, which is exactly why the caller must fall back to
    /// System Settings rather than assume a dialog is on screen.
    ///
    /// It never grants inline: the dialog's button opens Settings, and trust arrives later through
    /// the caller's poll. So `false` here means "not yet", never "refused".
    public static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        return AXIsProcessTrusted()
    }

    /// One-shot Accessibility permission nudge. If untrusted, triggers the system prompt and hands a
    /// human-readable note to `status` (broadcast by the caller via the existing sim-status channel).
    /// Idempotent across the process: only the first untrusted call prompts. Returns true if a note was
    /// emitted (untrusted) so the caller can order its broadcast last.
    private nonisolated(unsafe) static var prompted = false
    @discardableResult
    static func ensureAccessibilityPrompt(status: (String) -> Void) -> Bool {
        if AXIsProcessTrusted() { return false }
        if !prompted {
            prompted = true
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        // NAMES THE APP, NOT A TERMINAL. This text predates the Electron app and told the user to
        // grant the permission to "the terminal running `swift run`" — true of the harness, and
        // simply wrong in Xpromptvs.app, where the grant is keyed to the app's own signature.
        status("Accessibility permission needed to control windows — grant it to this app in "
             + "System Settings › Privacy & Security › Accessibility.")
        return true
    }

    // MARK: InputInjector

    public func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {
        inputScope.enqueue { [self] in
            if isWorkspace, workspaceDiagnosticsEnabled {
                workspaceDiagnosticEvents += 1
                workspaceDiagnosticEventActive = workspaceDiagnosticEvents <= 180
            }
            defer { workspaceDiagnosticEventActive = false }
            workspaceDiagnostic("touch phase=\(phase) normalized=\(x),\(y) ready=\(workspaceCanPost())")
            guard permitted() else { workspaceDiagnostic("denied accessibility"); return }
            guard workspaceCanPost() else { workspaceDiagnostic("denied capture-not-ready"); cancelWorkspaceInput(); return }
            // The phase→event mapping lives in RdevCore so its six cases are testable without
            // CoreGraphics; this switch does nothing but name the CGEventType for each.
            let plan = touchEventPlan(phase: phase, button: button)
            // NOTHING INTO A DROP'S CARRY: while a drop holds the button and carries the cursor, a tap's mouse-up
            // would end the drag at the tap's point. Dropped outright — no glide stopped, no click counted — and a
            // press that began during the carry is dropped whole, its up included (`DropCarryGate`).
            guard carryGate.admits(plan.kind, carrying: DropCarry.shared.isCarrying) else { return }
            // A press lands ON the coasting view: stop the glide, the way putting a finger down on a
            // trackpad does. The touch client also sends an explicit zero fling for the case where a
            // finger arrives and produces no touch at all (in trackpad mode a press is silent until
            // it becomes a tap or a move) — this covers the direct-pointer path, which is not silent.
            if phase != "up" { stopMomentum() }
            if phase != "up" { refreshBounds() }   // re-read the frame on press/drag (window may have moved)
            if phase == "down" { clearOwnWindowsIfDisplay() }
            let p = globalPoint(normalizedX: x, normalizedY: y)
            let type: CGEventType
            switch (plan.kind, plan.button) {
            case (.down, .left):     type = .leftMouseDown
            case (.dragged, .left):  type = .leftMouseDragged
            case (.up, .left):       type = .leftMouseUp
            case (.down, .right):    type = .rightMouseDown
            case (.dragged, .right): type = .rightMouseDragged
            case (.up, .right):      type = .rightMouseUp
            }
            var admittedOwner: WorkspaceOwner?
            if isWorkspace {
                let owner = workspaceOwner(at: p)
                let wasHeld = workspaceGesture.button
                let mask = workspaceMask(at: p)
                workspaceDiagnostic("admission global=\(p) mask=\(mask) native=\(owner != nil) held=\(String(describing: wasHeld))")
                guard workspaceGesture.admit(phase: phase, button: button,
                        mask: mask, native: owner != nil) else {
                    workspaceDiagnostic("denied gesture-admission")
                    if wasHeld != nil { cancelWorkspacePointer() }
                    return
                }
                // The snapshot immediately before this event, not a cached capture owner.
                guard let owner else { return }
                admittedOwner = owner
            }
            if plan.kind == .down {
                _ = clicks.down(button: plan.button, x: p.x, y: p.y,
                                now: Date().timeIntervalSince1970, interval: NSEvent.doubleClickInterval)
            }
            // ⇧-click / ⌘-click, from the keyboard path's holder.
            guard postPointer(Self.makeMouseEvent(source: source, type: type, at: p, from: lastMousePoint,
                                button: plan.button, clickState: clicks.count,
                                flags: currentFlags), at: p) else {
                if isWorkspace { cancelWorkspacePointer() }; return
            }
            if inputScope.fence != nil {
                let hadPress = scopedButtons.contains { $0.0 == button }
                scopedButtons.removeAll { $0.0 == button }
                if phase == "down" || (phase == "move" && hadPress) { scopedButtons.append((button, p)) }
            }
            if isWorkspace {
                workspaceGesture.didPost(phase: phase, button: button)
                if phase == "up" { workspaceLastSafe = nil }
                else if let admittedOwner { workspaceLastSafe = (p, admittedOwner) }
            }
            lastMousePoint = p
        }
    }

    /// ONE mapping from a normalized point on the source to a global one, for a touch and for `screenPoint`.
    /// Call on `queue`.
    private func globalPoint(normalizedX x: Double, normalizedY y: Double) -> CGPoint {
        windowInputPoint(normalizedX: x, normalizedY: y, bounds: bounds)
    }

    /// ⌘V AS A KEYBOARD TYPES IT: ⌘ goes down (`flagsChanged`), V down and up with ⌘ held, ⌘ up — never a bare V
    /// that merely carries the Command flag. MEASURED 2026-10-01 against a Chromium page (paste-live-check W, the
    /// harness's own diagnostics): with Chromium the FRONT application and the page's window its focused one, the
    /// flagged V alone reached NOTHING — no keydown, no paste event, not even a plain `v` — and the same moment
    /// with the ⌘ around it gave keydown `Meta`, keydown `v` (meta), the paste event and the text. (The forwarded
    /// ⌘V from a client keyboard always worked because `win-key` sends the ⌘ as its own `flagsChanged` first.)
    ///
    /// The ⌘ alone on every event that holds it — a held ⇧ would make it ⌘⇧V, "paste and match style" — and the
    /// last event puts back what the strip HOLDS (`restoring`), as §4.2 asks: that `flagsChanged` is what tells
    /// the app which modifiers are down once the ⌘ is up. Built side-effect-free so the fields are assertable
    /// without a TCC grant.
    static func pasteShortcutEvents(source: CGEventSource?, restoring held: CGEventFlags = []) -> [CGEvent] {
        [makeKeyEvent(action: .flagsChanged(keyCode: 55, flags: .maskCommand), down: true, source: source),
         makeKeyEvent(action: .key(keyCode: 9, flags: .maskCommand, unicode: nil, autorepeat: false), down: true, source: source),
         makeKeyEvent(action: .key(keyCode: 9, flags: .maskCommand, unicode: nil, autorepeat: false), down: false, source: source),
         makeKeyEvent(action: .flagsChanged(keyCode: 55, flags: held), down: false, source: source)].compactMap { $0 }
    }

    /// SYNC on the injector's queue — like `screenPoint`, which the paste queue already calls the same way: that
    /// queue never waits on the paste queue, so this cannot deadlock, and the answer is what was POSTED.
    ///
    /// THE FRONT APPLICATION IS CHECKED AGAIN HERE, with no wait. `awaitFrontmost` ran BEFORE the clipboard so a
    /// refusal leaves the clipboard alone — but writing it can take hundreds of ms for a large photo (decoded
    /// to PNG and TIFF, then a hop to main), and an application that comes to the front meanwhile (the driver
    /// tapping another window, the person at the Mac, an app activating itself) would get the ⌘V. Read here,
    /// the check and the post are microseconds apart.
    ///
    /// A DISPLAY is checked too (`FrontmostWait.accepts`): never into this host while it is still the front one.
    public func pasteShortcut() -> Bool {
        queue.sync { [self] in
            guard permitted(), workspaceKeyboardAllowed() else { return false }
            let front = Self.frontPID()
            guard FrontmostWait.accepts(front: front, windowOwner: pid, ownPID: getpid()) else {
                let why = pid.map { "the window's application (pid \($0)) left the front before the ⌘V" }
                    ?? "this host is the front application (a display's paste)"
                print("[window-input] not pasted — \(why); pid \(front.map(String.init) ?? "unknown") is front now, "
                    + "and nothing was posted")
                return false
            }
            // `currentFlags` is NOT changed: the strip's held modifiers stay what they were, and the last event
            // says so to the app.
            for e in Self.pasteShortcutEvents(source: source, restoring: currentFlags) {
                guard postKeyboard(e) else { return false }
            }
            return true
        }
    }

    /// How long a paste's ⌘V waits, after `raise()`, for the window's application to be the front one.
    static let frontmostBound = 1.0

    /// A paste's ⌘V is a KEY, and a key goes to the FRONT application — not to the window `raise()` stacked on
    /// top. So the ⌘V waits for the window's application to be the front one (`FrontmostWait`), and is not
    /// posted at all if it never is: posted anyway it would paste into whatever the person left in front.
    /// MEASURED 2026-10-01 (paste-live-check, the harness's diagnostics): `raise()` had made the target front by
    /// the time it returned — the front process read 26027 before `SetFrontProcessWithOptions` + AXRaise and the
    /// target's 25985 right after — so the wait normally costs nothing; it is the guard for a raise that does
    /// not take effect. Touches only immutable state, like `raise()`.
    ///
    /// A DISPLAY pastes into whatever is in front on it (§4.2) — but waits, the same bound, for THIS HOST to stop
    /// being the front application: its raise hides the host app asynchronously (`OwnWindows`), and a ⌘V before
    /// that took effect would paste into the host itself (`FrontmostWait.accepts`).
    public func awaitFrontmost() -> Bool {
        if isWorkspace { return queue.sync { workspaceKeyboardAllowed() } }
        let own = getpid()
        let took = FrontmostWait.wait(bound: Self.frontmostBound, every: 0.01,
                                      now: { ProcessInfo.processInfo.systemUptime },
                                      sleep: { usleep(useconds_t($0 * 1_000_000)) }) {
            FrontmostWait.accepts(front: Self.frontPID(), windowOwner: pid, ownPID: own)
        }
        if let took {
            if took >= 0.01 { print("[window-input] \(frontNeed) after the raise took \(Int(took * 1000)) ms") }
            return true
        }
        let front = Self.frontPID()
        print("[window-input] not pasted — \(frontNeed) did not happen within "
            + "\(Self.frontmostBound) s of the raise; a ⌘V would go to pid \(front.map(String.init) ?? "unknown")")
        return false
    }

    /// What a paste's ⌘V waits for, in a log line.
    private var frontNeed: String {
        pid.map { "the window's application (pid \($0)) coming to the front" } ?? "this host leaving the front (a display's paste)"
    }

    /// The front application's pid, where a posted key goes: the window server's own answer through Carbon's
    /// `GetFrontProcess` (deprecated public API, reached like `SetFrontProcessWithOptions`). NSWorkspace's when
    /// that is gone — the same answer, but delivered to this process through its main run loop, so it can lag.
    static func frontPID() -> pid_t? {
        if let getFront = WindowSPI.getFrontProcess, let getPID = WindowSPI.getProcessPID {
            var psn = ProcessSerialNumber()
            var pid: pid_t = 0
            if getFront(&psn) == noErr, getPID(&psn, &pid) == noErr { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func screenPoint(normalizedX: Double, normalizedY: Double) -> CGPoint? {
        queue.sync { [self] in
            // HostDrop posts its own global events outside this gate. Workspace drops remain refused
            // until that path carries the same per-event native ownership check.
            guard !isWorkspace else { return nil }
            refreshBounds()   // the window may have moved since the last event
            return globalPoint(normalizedX: normalizedX, normalizedY: normalizedY)
        }
    }

    public func move(normalizedX x: Double, normalizedY y: Double) {
        inputScope.enqueue { [self] in
            guard workspaceCanPost() else { cancelWorkspaceInput(); return }
            // Not into a drop's carry: a hover moves the cursor the drop is carrying (`DropCarryGate`).
            guard permitted(), DropCarryGate.admitsMotion(carrying: DropCarry.shared.isCarrying) else { return }
            refreshBounds()   // the window may have moved since the last hover
            let p = windowInputPoint(normalizedX: x, normalizedY: y, bounds: bounds)
            guard !isWorkspace || workspaceMask(at: p) else { return }
            // POST a real mouseMoved — do NOT use CGWarpMouseCursorPosition. Apps update their cursor in
            // response to EVENTS; a silent warp moves the pointer but commonly leaves the shape stale,
            // which would defeat the whole point of cursor passthrough.
            // ⌥-drag and friends see the modifiers the client holds. A hover is not part of any
            // click run, so it carries a click state of 0.
            guard postPointer(Self.makeMouseEvent(source: source, type: .mouseMoved, at: p, from: lastMousePoint,
                                button: .left, clickState: 0,
                                flags: currentFlags), at: p) else { return }
            lastMousePoint = p
        }
    }

    /// Build a mouse event with the two things `CGEvent(mouseEventSource:…)` gets wrong for a posted
    /// event, both MEASURED 2026-09-25 against an AppKit view, and neither filled in downstream:
    ///
    /// - THE CLICK STATE. The initializer stamps every down 1 and every up 0, so no app could ever
    ///   see a double-click. See `ClickCounter`.
    /// - THE DELTAS. Every posted drag read `deltaX == deltaY == 0`, so an app that tracks a drag
    ///   by its deltas rather than its location — sliders, canvases, games, custom drag thresholds —
    ///   saw a press that never moved.
    ///
    /// `static` and side-effect-free so the exact fields are assertable without a window or a TCC
    /// grant, like `makeScrollEvent`.
    static func makeMouseEvent(source: CGEventSource?, type: CGEventType, at p: CGPoint,
                               from previous: CGPoint?, button: MouseButton, clickState: Int,
                               flags: CGEventFlags) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: button == .right ? .right : .left) else { return nil }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if let previous, type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
            e.setDoubleValueField(.mouseEventDeltaX, value: p.x - previous.x)
            e.setDoubleValueField(.mouseEventDeltaY, value: p.y - previous.y)
        }
        e.flags = flags
        return e
    }

    /// A LINE scroll (a notched wheel) posts discrete `.line` events, unchanged from the original
    /// behaviour. A PIXEL scroll (a trackpad, and Chrome's mouse-wheel emulation) posts continuous
    /// `.pixel` events carrying a synthesized `began → changed → ended` phase, which is what AppKit
    /// gates rubber-banding and per-pixel tracking on.
    ///
    /// Momentum is NOT synthesized: macOS already delivers trackpad momentum to the browser as
    /// ordinary wheel events, so it arrives here as more `changed` deltas. Synthesizing a second
    /// source of momentum would double-scroll a Mac client.
    public func scroll(normalizedX x: Double, normalizedY y: Double,
                       deltaX dx: Double, deltaY dy: Double, unit: ScrollUnit, mods: InputModifiers) {
        inputScope.enqueue { [self] in
            guard workspaceCanPost() else { cancelWorkspaceInput(); return }
            guard permitted() else { return }
            currentFlags = mods.cgFlags   // authoritative: this message carries its own snapshot
            // Not into a drop's carry (`DropCarryGate`): dropped, flags aside — a wheel scrolls whatever the carried
            // cursor is over.
            guard DropCarryGate.admitsMotion(carrying: DropCarry.shared.isCarrying) else { return }
            stopMomentum()   // a finger back on the glass, or any wheel, beats a glide in flight
            clearOwnWindowsIfDisplay()
            if isWorkspace {
                refreshBounds()
                let p = globalPoint(normalizedX: x, normalizedY: y)
                guard workspaceMask(at: p), workspaceOwner(at: p) != nil else { return }
                workspaceScrollPoint = p
            }
            // wheel1 = vertical, wheel2 = horizontal. Browser deltaY>0 means "content moves up /
            // scroll down"; negate so the target scrolls the same way the user flicked.
            guard unit == .pixel else {
                let v = Int32((-dy).rounded()), h = Int32((-dx).rounded())
                postScroll(Self.makeScrollEvent(source: source, unit: .line, dx: h, dy: v,
                                     phase: nil, flags: currentFlags))
                return
            }
            // Fractions are CARRIED, never rounded away: at 0.4px per event, rounding each one on
            // its own discards the whole gesture.
            let (h, v) = scrollAccumulator.take(dx: -dx, dy: -dy)
            let phase = scrollPhase.event(now: Date().timeIntervalSince1970)
            if h != 0 || v != 0 {
                postScroll(Self.makeScrollEvent(source: source, unit: .pixel, dx: h, dy: v,
                                     phase: phase, flags: currentFlags))
            } else if phase == .began {
                // The gesture has opened but has not moved a whole pixel yet. Post the `began` with a
                // zero delta rather than swallowing it, or the app's first real delta arrives as a
                // `changed` for a gesture it never saw begin.
                postScroll(Self.makeScrollEvent(source: source, unit: .pixel, dx: 0, dy: 0,
                                     phase: .began, flags: currentFlags))
            }
            if !nativeScrollContact { armScrollEnd() }
            recordScrollCadence()
        }
    }

    /// A display's press or scroll goes to whatever is IN FRONT, and this host's own windows are cut out
    /// of what the client sees — so if someone at the Mac brought them back, they go again first.
    private func clearOwnWindowsIfDisplay() {
        if isWorkspace { OwnWindows.reclearIfUnhidden(); return }
        if case .display = target { OwnWindows.reclearIfUnhidden() }
    }

    /// One sample per posted scroll, plus a lazily-armed 5 s reporter — lazy so a host that never
    /// scrolls never arms a timer, matching `LatencyStages`. Both run on `queue`, which is what keeps
    /// `scrollCadence` confined to it without a lock.
    /// The target's wire id, built by RdevCore's own formatters rather than restated here — the
    /// prefix is what separates a CGWindowID from a CGDirectDisplayID, and two spellings of it
    /// would be one more place for them to drift.
    private var probeLabel: String {
        switch target {
        case .window(let id): return sourceID(windowID: id)
        case .display(let id): return sourceID(displayID: id)
        case .workspace(let id): return "workspace-display:\(id)"
        case .simulator(let u): return sourceID(simUDID: u)
        }
    }

    private func recordScrollCadence() {
        guard scrollCadence != nil else { return }
        scrollCadence?.record(at: Date().timeIntervalSince1970)
        guard scrollProbeTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // `report` RETURNS its line rather than printing, so stdout can never block `queue` —
            // the queue that also orders every injected event. A stalled write here would stall input.
            if let line = self.scrollCadence?.report(source: self.probeLabel) { print(line) }
        }
        scrollProbeTimer = t
        t.resume()
    }

    /// Close the gesture after `quietInterval` of silence. The generation counter is what makes a
    /// superseded timer harmless: every new event bumps it, so only the LAST armed timer can fire an
    /// `ended` — without it a burst of events queues a burst of `ended`s.
    private func armScrollEnd() {
        scrollGeneration &+= 1
        let generation = scrollGeneration
        queue.asyncAfter(deadline: .now() + ScrollPhaseMachine.quietInterval, execute: inputScope.capture { [self] in
            guard generation == scrollGeneration, !nativeScrollContact else { return }
            // The gesture's `ended` is OWED, so a drop's carry DEFERS it rather than drop it: asked again a quiet
            // interval later, until the carry is over (`DropCarryGate`).
            guard DropCarryGate.admitsMotion(carrying: DropCarry.shared.isCarrying) else { return armScrollEnd() }
            guard scrollPhase.expire(now: Date().timeIntervalSince1970) != nil else { return }
            guard permitted() else { return }
            postScroll(Self.makeScrollEvent(source: source, unit: .pixel, dx: 0, dy: 0,
                                 phase: .ended, flags: currentFlags))
        })
    }

    /// Interval between momentum steps. The glide is GENERATED here rather than received, so this is
    /// the only thing deciding how smooth it looks — a real trackpad reports at about this rate. The
    /// curve integrates over the elapsed time, so a late tick costs smoothness and never distance.
    private static let momentumTickInterval: Double = 1.0 / 120

    public func scrollGesture(normalizedX x: Double, normalizedY y: Double, phase: ScrollGesturePhase,
                              velocityX vx: Double, velocityY vy: Double, mods: InputModifiers) {
        // The existing fling boundary closes direct contact and cancels any previous glide on the
        // injector queue. Only a real release may launch; begin/cancel use its zero-velocity STOP.
        inputScope.enqueue { [self] in
            guard workspaceCanPost(), permitted() else { return }
            nativeScrollContact = false
            guard DropCarryGate.admitsMotion(carrying: DropCarry.shared.isCarrying) else {
                // An end owed to a direct gesture waits out the carry, just like the legacy timer.
                if phase != .begin { armScrollEnd() }
                return
            }
            scrollFling(normalizedX: x, normalizedY: y, velocityX: phase == .end ? vx : 0,
                        velocityY: phase == .end ? vy : 0, mods: mods)
            nativeScrollContact = phase == .begin
        }
    }

    /// A TOUCH client's flick: run the glide on the host. See `ScrollMomentum` for why the curve
    /// belongs here rather than on the wire, and `Inbound.scrollFling` for why no Mac client sends it.
    ///
    /// A ZERO velocity is the STOP — a finger landing on a gliding view — and it takes the same path,
    /// because `launch` refuses it and everything before that has already cancelled what was running.
    public func scrollFling(normalizedX x: Double, normalizedY y: Double,
                            velocityX vx: Double, velocityY vy: Double, mods: InputModifiers) {
        inputScope.enqueue { [self] in
            guard workspaceCanPost() else { cancelWorkspaceInput(); return }
            guard permitted() else { return }
            currentFlags = mods.cgFlags   // authoritative: this message carries its own snapshot
            // Not into a drop's carry (`DropCarryGate`): the flick is dropped. An open gesture's `ended` still
            // comes, from its quiet timer, once the carry is over.
            guard DropCarryGate.admitsMotion(carrying: DropCarry.shared.isCarrying) else { return }
            stopMomentum()
            if isWorkspace {
                refreshBounds()
                let p = globalPoint(normalizedX: x, normalizedY: y)
                guard workspaceMask(at: p), workspaceOwner(at: p) != nil else { return }
                workspaceScrollPoint = p
            }
            // The fingers are ALREADY off the glass, so the gesture ends NOW rather than 80ms from
            // now: momentum must not begin while the app still believes a gesture is in progress.
            closeScrollGesture()
            // Same negation as the live path — the client's sign convention is the browser's.
            guard momentum.launch(velocityX: -vx, velocityY: -vy, now: Date().timeIntervalSince1970)
            else { return }
            scheduleMomentumTick()
        }
    }

    /// Post the gesture's `ended` immediately instead of waiting out `quietInterval`, and disarm the
    /// quiet timer so it cannot fire a second one.
    private func closeScrollGesture() {
        nativeScrollContact = false
        scrollGeneration &+= 1
        guard scrollPhase.isActive else { return }
        scrollPhase.reset()
        postScroll(Self.makeScrollEvent(source: source, unit: .pixel, dx: 0, dy: 0,
                             phase: .ended, flags: currentFlags))
    }

    /// Stop a glide and pay what it owes. `cancel()` is what knows whether an `end` is still due — a
    /// glide that never posted its `begin` owes nothing, and an unmatched `end` reads to an app that
    /// rubber-bands as a second release.
    private func stopMomentum() {
        momentumGeneration &+= 1
        guard momentum.cancel(), permitted() else { return }
        postMomentum(dx: 0, dy: 0, phase: .end)
    }

    /// Forget a glide WITHOUT paying it — the target that would receive the `end` is no longer the
    /// target that saw the flick. The same distinction `scrollPhase.reset()` draws beside it.
    private func forgetMomentum() {
        momentumGeneration &+= 1
        momentum.reset()
    }

    /// One step per tick, re-armed from inside itself so the interval is measured from when the last
    /// step actually ran. The generation counter is what makes a superseded tick harmless, exactly as
    /// it does for the quiet timer above.
    private func scheduleMomentumTick() {
        momentumGeneration &+= 1
        let generation = momentumGeneration
        queue.asyncAfter(deadline: .now() + Self.momentumTickInterval, execute: inputScope.capture { [self] in
            guard generation == momentumGeneration else { return }
            // A glide in flight when a drop presses PAUSES through its carry (`DropCarryGate`) — no step taken, so
            // its `begin` and `end` are still owed, and the curve integrates over the elapsed time, so the steps it
            // missed cost smoothness and never distance.
            guard DropCarryGate.admitsMotion(carrying: DropCarry.shared.isCarrying) else { return scheduleMomentumTick() }
            guard let step = momentum.tick(now: Date().timeIntervalSince1970) else { return }
            // A grant lost mid-glide: drop it silently rather than posting into a tap that will
            // refuse every event anyway.
            guard permitted() else { return forgetMomentum() }
            postMomentum(dx: step.dx, dy: step.dy, phase: step.phase)
            if step.phase != .end { scheduleMomentumTick() }
        })
    }

    /// Post one momentum step. Called on `queue` only.
    ///
    /// THE FRACTIONS GO THROUGH THE SAME ACCUMULATOR AS THE LIVE PATH, deliberately: the glide takes
    /// over from the finger mid-gesture, and a second accumulator would drop the remainder standing
    /// at the handoff. A `continue` that rounds to nothing is skipped and its distance carried; a
    /// `begin` or an `end` is posted whatever the delta, because those two events are the message.
    private func postMomentum(dx: Double, dy: Double, phase: MomentumPhase) {
        let (h, v) = scrollAccumulator.take(dx: dx, dy: dy)
        guard h != 0 || v != 0 || phase != .continuing else { return }
        postScroll(Self.makeScrollEvent(source: source, unit: .pixel, dx: h, dy: v,
                             phase: nil, momentum: phase, flags: currentFlags))
    }

    /// Build the event rdev puts on the wire. `static` and side-effect-free so the exact fields can
    /// be asserted without a window, a permission or a GUI session (creating a CGEvent is ungated;
    /// only posting one is not).
    /// `phase` and `momentum` are the GESTURE and the INERTIA, and exactly one of them is set on any
    /// real event: while a finger is on the glass macOS sends `scrollPhase` with no momentum phase,
    /// and once it lifts it sends `momentumPhase` with no scroll phase. An app reads the pair to tell
    /// "still being dragged" from "coasting", which is what decides whether a rubber-band may release.
    static func makeScrollEvent(source: CGEventSource?, unit: ScrollUnit,
                                dx: Int32, dy: Int32,
                                phase: ScrollPhaseAction?, momentum: MomentumPhase? = nil,
                                flags: CGEventFlags) -> CGEvent? {
        guard let e = CGEvent(scrollWheelEvent2Source: source,
                              units: unit == .pixel ? .pixel : .line,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return nil }
        if unit == .pixel {
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let phase {
                // kCGScrollPhaseBegan = 1, Changed = 2, Ended = 4. Not exposed as Swift constants.
                e.setIntegerValueField(.scrollWheelEventScrollPhase,
                                       value: phase == .began ? 1 : phase == .changed ? 2 : 4)
            }
            // kCGScrollWheelEventMomentumPhase = 123, likewise unexposed. Written ONLY when there is
            // a momentum phase: a zero here is `kCGMomentumScrollPhaseNone`, which is what a
            // finger-driven event must carry, and setting it is how that stays true by construction.
            if let momentum {
                e.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum.cgValue)
            }
        }
        e.flags = flags
        return e
    }

    /// Post one key transition. The DECISION is `planKeyInjection`'s (pure, in RdevCore); this only
    /// posts what it returns and keeps the ledger.
    public func key(down: Bool, code: String, key keyChar: String, repeat isRepeat: Bool, mods: InputModifiers) {
        inputScope.enqueue { [self] in
            guard workspaceCanPost() else { cancelWorkspaceInput(); return }
            guard permitted() else { return }
            guard workspaceKeyboardAllowed() else {
                cancelWorkspaceInput(); return
            }
            let wasCommand = currentFlags.contains(.maskCommand)
            currentFlags = mods.cgFlags   // authoritative: the message carries its own snapshot

            let action = planKeyInjection(down: down, code: code, key: keyChar, repeat: isRepeat, mods: mods)
            // A `.drop` still honours the flag update above — a dropped key can have changed modifiers.
            if let event = Self.makeKeyEvent(action: action, down: down, source: source) {
                guard postKeyboard(event) else { cancelWorkspaceInput(); return }
                if case .key(let kc, _, _, _) = action {
                    if down { heldKeys.down(kc) } else { heldKeys.up(kc) }
                }
                if inputScope.fence != nil, case .flagsChanged(let kc, _) = action {
                    if down { scopedModifiers.insert(kc) } else { scopedModifiers.remove(kc) }
                }
                if isWorkspace, case .flagsChanged(let kc, _) = action {
                    if down { workspaceModifiers.insert(kc) } else { workspaceModifiers.remove(kc) }
                }
            }

            // THE ⌘-SWALLOWS-KEYUP RULE. macOS delivers no keyup for other keys while Command is
            // held, so the browser never sends one: after a single ⌘C the host would hold `c`
            // forever and every later keystroke would arrive as a chord. Command going up is the
            // one moment we know those keyups are never coming.
            if wasCommand && !mods.command { releaseHeldKeys() }
        }
    }

    /// Stop ordinary posts NOW, even when the serial input queue already contains old drags.
    /// Matching neutral releases still undergo native target checks and may drain asynchronously.
    func invalidateWorkspace() {
        guard isWorkspace else { return }
        workspaceLease.invalidate()
        releaseKeys()
    }

    /// Release everything held and clear the flags. Idempotent: a second call posts nothing.
    public func releaseKeys() {
        inputScope.enqueue { [self] in
            guard inputScope.current else { return }
            releaseHeldKeys()
            for code in scopedModifiers {
                if postKeyboard(Self.makeKeyEvent(action: .flagsChanged(keyCode: code, flags: []), down: false, source: source)) {
                    scopedModifiers.remove(code)
                }
            }
            if !DropCarry.shared.isCarrying {
                for (button, point) in scopedButtons {
                    let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
                    if postPointer(Self.makeMouseEvent(source: source, type: type, at: point, from: lastMousePoint,
                        button: button, clickState: clicks.count, flags: []), at: point) {
                        scopedButtons.removeAll { $0.0 == button }
                    }
                }
            } else { scopedButtons.removeAll() }
            if isWorkspace {
                cancelWorkspacePointer()
                let modifiers = workspaceModifiers
                workspaceModifiers.removeAll()
                for code in modifiers {
                    _ = postKeyboard(Self.makeKeyEvent(action: .flagsChanged(keyCode: code, flags: []), down: false, source: source), releasingWorkspace: true)
                }
                workspaceScrollPoint = nil
            }
            currentFlags = []
            nativeScrollContact = false
            scrollPhase.reset()   // the target that would receive `ended` is no longer the target
            clicks.reset()        // ...nor the one a next press would double-click
            forgetMomentum()      // ...and neither is the one that would receive the momentum `end`
        }
    }

    /// Called on `queue` only. Drains the ledger even when injection is not permitted, so a later
    /// grant does not begin by replaying keyUps for keys nothing ever pressed.
    private func releaseHeldKeys() {
        let orphaned = heldKeys.releaseAll()
        guard permitted() else { return }
        for kc in orphaned {
            let posted = postKeyboard(Self.makeKeyEvent(action: .key(keyCode: kc, flags: currentFlags, unicode: nil, autorepeat: false),
                              down: false, source: source), releasingWorkspace: isWorkspace)
            if !posted && inputScope.fence != nil { heldKeys.down(kc) }
        }
    }

    /// Build the event for a planned action, or nil for `.drop`. `static` and side-effect-free so its
    /// fields are assertable without a window or a TCC grant.
    static func makeKeyEvent(action: KeyAction, down: Bool, source: CGEventSource?) -> CGEvent? {
        switch action {
        case .drop:
            return nil
        case .flagsChanged(let keyCode, let flags):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
            e.type = .flagsChanged
            e.flags = flags
            return e
        case .key(let keyCode, let flags, let unicode, let autorepeat):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
            e.flags = flags
            if autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            if let unicode {
                let utf16 = Array(unicode.utf16)
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            return e
        }
    }

    // MARK: Workspace post-time boundary (queue confined)

    private func workspaceCanPost() -> Bool { !isWorkspace || workspaceReady?() == true }

    // Capture loss ends the gesture, but the native window may still hold its down.
    // Only ledger-backed releases bypass readiness; native ownership checks still apply.
    private func cancelWorkspaceInput() {
        guard isWorkspace else { return }
        cancelWorkspacePointer()
        releaseHeldKeys()
        let modifiers = workspaceModifiers
        workspaceModifiers.removeAll()
        for code in modifiers {
            _ = postKeyboard(Self.makeKeyEvent(action: .flagsChanged(keyCode: code, flags: []), down: false, source: source), releasingWorkspace: true)
        }
        currentFlags = []
        workspaceScrollPoint = nil
        nativeScrollContact = false
        scrollPhase.reset()
        forgetMomentum()
    }

    private func workspaceMask(at point: CGPoint) -> Bool {
        guard bounds.width > 0, bounds.height > 0, !bounds.isNull, bounds.contains(point) else { return false }
        return workspaceAdmission?((point.x - bounds.minX) / bounds.width,
                                   (point.y - bounds.minY) / bounds.height) ?? false
    }

    private static func workspaceIdentity(_ pid: pid_t) -> WorkspaceOwner? {
        guard pid > 0, pid != getpid(), let generation = RWKProcessGeneration(pid),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let executable = app.executableURL, RWKProcessGeneration(pid) == generation else { return nil }
        return WorkspaceOwner(pid: pid, generation: generation, executable: executable)
    }

    /// CG rectangles include noninteractive full-display overlays (notably Dock). Ask the
    /// system AX hit test which element receives this point, then validate its window and live
    /// owner against CG. Never guess a lower window when AX attribution is unavailable.
    private func workspaceOwner(at point: CGPoint) -> WorkspaceOwner? {
        refreshBounds()
        guard point.x.isFinite, point.y.isFinite, !bounds.isNull, bounds.contains(point),
              let getWindow = WindowSPI.getWindowID else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard result == .success, let hit else {
            workspaceDiagnostic("native AX hit denied result=\(result.rawValue) point=\(point)"); return nil
        }
        AXUIElementSetMessagingTimeout(hit, 0.05)
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success,
              let owner = Self.workspaceIdentity(hitPID) else {
            workspaceDiagnostic("native AX identity denied pid=\(hitPID)"); return nil
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
        if let menuRole = role as? String, ["AXMenuBarItem", "AXMenuItem"].contains(menuRole) {
            return workspaceMenuOwner(hit: hit, role: menuRole, owner: owner, point: point)
        }
        var windowValue: CFTypeRef?
        AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &windowValue)
        let window: AXUIElement
        if let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            window = unsafeBitCast(windowValue, to: AXUIElement.self)
        } else if (role as? String) == (kAXWindowRole as String) {
            window = hit
        } else {
            workspaceDiagnostic("native AX window unavailable pid=\(hitPID) role=\(String(describing: role))"); return nil
        }
        AXUIElementSetMessagingTimeout(window, 0.05)
        var windowPID: pid_t = 0
        var id: CGWindowID = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == hitPID,
              getWindow(window, &id) == .success, id != 0,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let row = rows.first,
              let frameData = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: frameData as CFDictionary) else {
            workspaceDiagnostic("native AX/CG window unresolved pid=\(hitPID) id=\(id)"); return nil
        }
        let candidate = WorkspaceInputWindow(id: (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
            ownerPID: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            identityKnown: Self.workspaceIdentity(hitPID) == owner,
            bundleID: NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier,
            layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue, frame: frame)
        let allowed = WorkspaceInputPolicy.allowsAXHit(point: point, bounds: bounds, hitPID: hitPID,
            windowID: id, windows: [candidate], ownPID: getpid())
        workspaceDiagnostic("native AX pid=\(hitPID) role=\(String(describing: role)) id=\(id) bundle=\(candidate.bundleID ?? "nil") layer=\(String(describing: candidate.layer)) frame=\(frame) allowed=\(allowed)")
        return allowed ? owner : nil
    }

    /// Menus can have no CG-backed AXWindow. Admit only a native menu descendant of this
    /// live front application's own menu bar, with its focused ordinary window in our display.
    /// This deliberately does not infer context-menu ownership from a rectangle or app name.
    private func workspaceMenuOwner(hit: AXUIElement, role: String, owner: WorkspaceOwner,
                                    point: CGPoint) -> WorkspaceOwner? {
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        guard Self.frontPID() == owner.pid,
              workspaceKeyboardAllowed(requireMask: false),
              let position = value(hit, kAXPositionAttribute) , CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(hit, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {
            workspaceDiagnostic("native menu denied focus-or-geometry pid=\(owner.pid) role=\(role)"); return nil
        }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let frame = CGRect(origin: origin, size: dimensions)
        let app = AXUIElementCreateApplication(owner.pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let menuBar = element(value(app, kAXMenuBarAttribute)) else { return nil }
        var ancestor = hit
        var verified = false
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        for _ in 0..<10 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            AXUIElementSetMessagingTimeout(ancestor, 0.05)
            var pid: pid_t = 0
            guard AXUIElementGetPid(ancestor, &pid) == .success, pid == owner.pid,
                  let ancestorRole = value(ancestor, kAXRoleAttribute) as? String,
                  ["AXMenuBarItem", "AXMenuItem", "AXMenu", "AXMenuBar"].contains(ancestorRole) else { break }
            if CFEqual(ancestor, menuBar), ancestorRole == "AXMenuBar" { verified = true; break }
            guard let parent = element(value(ancestor, kAXParentAttribute)) else { break }
            ancestor = parent
        }
        let candidate = WorkspaceInputWindow(id: 0, ownerPID: owner.pid,
            identityKnown: Self.workspaceIdentity(owner.pid) == owner,
            bundleID: NSRunningApplication(processIdentifier: owner.pid)?.bundleIdentifier, layer: 0, frame: frame)
        let allowed = WorkspaceInputPolicy.allowsMenuHit(point: point, bounds: bounds, role: role,
            frame: frame, owner: candidate, ownPID: getpid(), verifiedMenuAncestry: verified,
            focusedWorkspace: Self.frontPID() == owner.pid)
        workspaceDiagnostic("native menu pid=\(owner.pid) role=\(role) frame=\(frame) ancestry=\(verified) allowed=\(allowed)")
        return allowed ? owner : nil
    }

    /// A key goes to the front application's focused AX window, not necessarily the top visible
    /// window. Both its live process and its complete global frame must still belong here.
    private func workspaceKeyboardAllowed(requireMask: Bool = true) -> Bool {
        guard isWorkspace else { return true }
        refreshBounds()
        guard let front = Self.frontPID(), let before = Self.workspaceIdentity(front),
              let getWindow = WindowSPI.getWindowID else { return false }
        let app = AXUIElementCreateApplication(front)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.05)
        var id: CGWindowID = 0
        guard getWindow(window, &id) == .success,
              let info = Self.lookup(id), info.pid == front, let frame = info.bounds,
              WorkspaceInputPolicy.keyboardFrame(frame, in: bounds),
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let row = rows.first else { return false }
        let candidate = WorkspaceInputWindow(id: id, ownerPID: front, identityKnown: true,
            bundleID: NSRunningApplication(processIdentifier: front)?.bundleIdentifier,
            layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue, frame: frame)
        return WorkspaceInputPolicy.ownerAllowed(candidate, ownPID: getpid()) &&
            (!requireMask || workspaceMask(at: CGPoint(x: frame.midX, y: frame.midY))) &&
            Self.frontPID() == front && Self.workspaceIdentity(front) == before
    }

    @discardableResult private func postPointer(_ event: CGEvent?, at point: CGPoint, releasingWorkspace: Bool = false) -> Bool {
        guard let event else { return false }
        if isWorkspace {
            guard releasingWorkspace || workspaceCanPost() else { workspaceDiagnostic("denied post capture-not-ready"); cancelWorkspaceInput(); return false }
            guard workspaceOwner(at: point) != nil else { workspaceDiagnostic("denied post native-owner"); return false }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .mouseMoved {
                guard workspaceMask(at: point) else { workspaceDiagnostic("denied post mask"); return false }
            }
        }
        if isWorkspace && !releasingWorkspace {
            var readyAtPost = true
            var owned = false
            let admitted = workspaceLease.perform(whileReady: { readyAtPost = workspaceCanPost(); return readyAtPost }) {
                owned = workspacePost?(event) ?? false
            }
            let posted = admitted && owned
            workspaceDiagnostic("post type=\(event.type.rawValue) point=\(point) posted=\(posted) readyAtPost=\(readyAtPost)")
            if !readyAtPost { cancelWorkspaceInput() }
            return posted
        }
        guard postNative(event) else { return false }
        workspaceDiagnostic("post type=\(event.type.rawValue) point=\(point) posted=true release=\(releasingWorkspace)")
        return true
    }

    private func postScroll(_ event: CGEvent?) {
        guard let event else { return }
        if isWorkspace {
            guard let point = workspaceScrollPoint, workspaceMask(at: point),
                  let owner = workspaceOwner(at: point),
                  let cursor = CGEvent(source: nil)?.location,
                  workspaceOwner(at: cursor) == owner else { return }
            event.location = point
        }
        if isWorkspace { workspaceLease.perform(whileReady: { workspaceCanPost() }) { _ = workspacePost?(event) } }
        else { _ = postNative(event) }
    }

    @discardableResult private func postKeyboard(_ event: CGEvent?, releasingWorkspace: Bool = false) -> Bool {
        guard let event, permitted(), workspaceKeyboardAllowed(requireMask: !releasingWorkspace) else { return false }
        if isWorkspace && !releasingWorkspace {
            var owned = false
            let admitted = workspaceLease.perform(whileReady: { workspaceCanPost() }) { owned = workspacePost?(event) ?? false }
            return admitted && owned
        }
        return postNative(event)
    }

    private func postNative(_ event: CGEvent) -> Bool {
        inputScope.post {
            if let postForTests { postForTests(event) } else { event.post(tap: .cghidEventTap) }
        }
    }

    private func cancelWorkspacePointer() {
        guard isWorkspace else { return }
        let button = workspaceGesture.takeCancellationButton()
        defer { workspaceLastSafe = nil }
        guard let button, let safe = workspaceLastSafe,
              workspaceOwner(at: safe.point) == safe.owner else { return }
        _ = postPointer(Self.makeMouseEvent(source: source,
            type: button == .left ? .leftMouseUp : .rightMouseUp,
            at: safe.point, from: lastMousePoint, button: button, clickState: clicks.count, flags: []), at: safe.point, releasingWorkspace: true)
    }

    // MARK: - internals (all called on `queue`)

    private func permitted() -> Bool {
        if postForTests != nil || AXIsProcessTrusted() { return true }
        if !warned { warned = true; print("[window-input] Accessibility permission absent — window input disabled") }
        return false
    }

    private func refreshBounds() {
        switch target {
        case .window(let w):
            if let info = WindowInputInjector.lookup(CGWindowID(w)), let b = info.bounds { bounds = b }   // keep last-good on failure
        case .display(let d):
            // Same keep-last-good rule: CGDisplayBounds reports .zero for a detached id, and adopting
            // that would send every subsequent click to (0,0).
            let b = CGDisplayBounds(CGDirectDisplayID(d))
            if b.width > 0, b.height > 0 { bounds = b }
        case .workspace(let d):
            // A detached workspace is invalid, never a last-good coordinate mapping.
            let b = CGDisplayBounds(CGDirectDisplayID(d))
            bounds = CGDisplayIsOnline(CGDirectDisplayID(d)) != 0 && b.width > 0 && b.height > 0 ? b : .null
        case .simulator:
            break   // unreachable: `init?` refuses a simulator
        }
    }

    /// One synchronous CGWindowList lookup for a single window id → (owner pid, global bounds). `bounds`
    /// is nil when `kCGWindowBounds` is missing/unparseable (so callers never fall back to a zero frame).
    static func lookup(_ windowID: CGWindowID) -> (pid: pid_t?, bounds: CGRect?)? {
        guard let arr = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let d = arr.first else { return nil }
        let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        var bounds = CGRect.zero
        let parsed = (d[kCGWindowBounds as String] as? [String: Any])
            .map { CGRectMakeWithDictionaryRepresentation($0 as CFDictionary, &bounds) } ?? false
        return (pid, parsed ? bounds : nil)
    }
}
