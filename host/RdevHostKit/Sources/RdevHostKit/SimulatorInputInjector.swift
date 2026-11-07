import Foundation
import RdevCore

/// Input into a simulator's OWN HID (docs/superpowers/specs/2026-10-13-simulator-sources-design.md) — the Mac's
/// cursor is never touched, no window is raised, and no Accessibility grant is needed.
///
/// - EVERYTHING RUNS IN ORDER ON ONE SERIAL QUEUE, which is also where the connection is made (it BLOCKS for its
///   liveness barrier) and where `devicectl` runs for a paste: a gesture's start, moves and end must reach the guest
///   in the order they happened, and a pasted string must not overtake the keys before it.
/// - TOUCHES ARE TURNED BACK TO THE NATIVE FRAME through the stream's `SimDisplayState`, the rotation the capture
///   turned the picture by.
/// - A DEAD CONNECTION (the device rebooted) is replaced on the next event, at most once per `reconnectBackoffMs`; the
///   gesture, the held keys and the wheel it carried died with it and start afresh.
/// - At most `pendingCap` operations wait; beyond that they are dropped and counted, never queued without bound.
public final class SimulatorInputInjector: InputInjector, @unchecked Sendable {
    public static let reconnectBackoffMs = 2000
    public static let pendingCap = 256
    /// The largest text a paste may hand a simulator's pasteboard (final review I9): a paste may be 1 GiB, and this one
    /// goes through `devicectl`'s stdin.
    public static let pasteCapBytes = 1 << 20
    /// A touch, a wheel or a button older than this when its turn comes is DROPPED (final review I3): taps made while a
    /// slow connect ran — a window reading "Booting…" — all landed at once when it succeeded.
    static let staleMs = 500
    /// Points per wheel LINE: the mock host's figure, and a browser's usual line height.
    public static let linePoints = 16.0
    /// Between the keys of a TYPED string and of a chord. UNMEASURED as a need — the probe typed with 30 ms gaps — and
    /// cheap: the gate's typing arm checks it.
    static let keyGapSeconds = 0.01
    /// TEST-ONLY (scripts/gate-simulator.sh's negative control): touches are NOT turned through the rotation, so the
    /// gate's rotated taps must land wrong and the gate must fail.
    static let ignoresRotationForTests = ProcessInfo.processInfo.environment["RDEV_TEST_SIM_IGNORE_ROTATION"] == "1"

    private let udid: String
    private let connect: () -> SimHIDSink?
    private let connectScroll: () -> SimScrollHIDSink?
    private let display: SimDisplayState
    private let control: SimulatorControl
    private let nativePointW: Int, nativePointH: Int
    private let isInputCurrent: @Sendable () -> Bool
    private let nowMs: @Sendable () -> Int
    private let queue = DispatchQueue(label: "rdev.sim.input", qos: .userInteractive)
    private let inputScope: ScopedInputExecution
    private let pendingLock = NSLock()
    private var pending = 0
    private var dropped = 0
    // `queue`-confined:
    private var sink: SimHIDSink?
    private var lastAttemptMs: Int?
    private var tracker = SimTouchTracker()
    private var wheel: SimWheelDrag?
    private var wheelRotation = SimRotation.rot0
    private var wheelTick: DispatchWorkItem?
    private var held = Set<UInt32>()
    private var scopedTouchPoints: [SimPoint]?
    private var scopedTouchMode = false
    private var scrollSink: SimScrollHIDSink?
    private var scrollAttemptMs: Int?
    private var nativeScroll: SimNativeScrollDrag?
    private var nativeScrollContact = false
    private var nativeScrollRotation = SimRotation.rot0
    /// Actual accepted posts, independent of a model advanced under a subsequently revoked lease.
    private var nativeScrollFinger: SimPoint?

    public init(udid: String, connect: @escaping () -> SimHIDSink?, connectScroll: @escaping () -> SimScrollHIDSink? = { nil }, display: SimDisplayState, control: SimulatorControl,
                nativePointW: Int, nativePointH: Int,
                isInputCurrent: @escaping @Sendable () -> Bool = { true },
                nowMs: @escaping @Sendable () -> Int = { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }) {
        self.inputScope = ScopedInputExecution(queue: queue)
        self.udid = udid; self.connect = connect; self.display = display; self.control = control
        self.connectScroll = connectScroll
        self.isInputCurrent = isInputCurrent
        self.nativePointW = nativePointW; self.nativePointH = nativePointH; self.nowMs = nowMs
    }

    public func submitScoped(_ event: SourceInputEvent, postFence: @escaping InputPostFence) {
        enqueue { [self] in inputScope.run(fence: postFence) { dispatchScoped(event) } }
    }

    public func releaseAfterOwnershipChange(postFence: @escaping InputPostFence) {
        submitScoped(.winKeysRelease, postFence: postFence)
    }

    public func drainForFocusChange(_ completion: @escaping () -> Void) {
        // Never subject an owed neutral release to the ordinary bounded admission cap.
        queue.async { [self] in inputScope.run(fence: nil) { releaseKeys(); completion() } }
    }

    // MARK: - InputInjector

    /// A WINDOW-style touch reaching a simulator (a client that sent `touch`): one finger.
    public func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {
        let p = phase == "down" || phase == "up" ? phase : "move"
        simTouch(phase: p, points: [SimPoint(x: x, y: y)])
    }

    public func simTouch(phase: String, points: [SimPoint]) {
        let at = nowMs()
        enqueue { [self] in
            guard let s = liveSink(), fresh(at) else { return }
            let r = Self.ignoresRotationForTests ? .rot0 : display.rotation
            let native = points.map { p -> SimPoint in
                let n = r.nativePoint(shownX: p.x, shownY: p.y)
                return SimPoint(x: n.x, y: n.y)
            }
            for e in tracker.apply(phase: phase, points: native) { s.touch(e) }
        }
    }

    public func key(down: Bool, code: String, key: String, repeat isRepeat: Bool, mods: InputModifiers) {
        // iOS REPEATS A HELD KEY ITSELF, as from a real keyboard; forwarding the browser's repeats would double them.
        if isRepeat && down { return }
        enqueue { [self] in
            let fromKey = key.count == 1 ? key.first.flatMap { SimKeyUsage.usage(forCharacter: $0)?.usage } : nil
            guard let usage = SimKeyUsage.usage(forCode: code) ?? fromKey, let s = liveSink() else { return }
            if inputScope.fence == nil { if down { held.insert(usage) } else { held.remove(usage) } }
            // ⌘ SWALLOWS KEYUP (final review I5; `WindowInputInjector`'s rule): a browser never sends the other key's
            // up while ⌘ is held, so ⌘'s up releases every key still held first, or ⌘A leaves the A down.
            if !down, usage == SimKeyUsage.leftCommand || usage == SimKeyUsage.leftCommand + 4 {
                for u in held where u < SimKeyUsage.leftControl { s.key(u, down: false) }
                if inputScope.fence == nil { held = held.filter { $0 >= SimKeyUsage.leftControl } }
            }
            s.key(usage, down: down)
        }
    }

    public func releaseKeys() {
        enqueue { [self] in
            guard inputScope.current else { return }
            cancelNativeScroll()
            guard let raw = sink, !raw.invalidated else { held = []; tracker = SimTouchTracker(); wheel = nil; scopedTouchPoints = nil; scopedTouchMode = false; return }
            let s = scopedSink(raw)
            for u in held { s.key(u, down: false) }
            if inputScope.fence == nil { held = [] }
            let cancellation = tracker.cancel()
            if inputScope.fence == nil && scopedTouchMode {
                // The tracker can contain a rejected start or have forgotten a rejected up. Only
                // successful native posts determine whether a neutral end is actually owed.
                if let points = scopedTouchPoints { raw.touch(.end(points)) }
                scopedTouchPoints = nil; scopedTouchMode = false; wheel = nil
            } else {
                for e in cancellation { s.touch(e) }
                if var w = wheel { for e in w.tick(nowMs: Int.max / 2) { s.touch(rotated(e, display.rotation)) }; wheel = w }
            }
        }
    }

    public func simText(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue { [self] in
            guard let sink = liveSink() else { return }
            // Text commits/paste are independent of physical chords. Restore keys only while the
            // same owner still holds them; a handoff's release must never be undone.
            let physical = held.sorted()
            for usage in physical { sink.key(usage, down: false) }
            defer { if isInputCurrent() && inputScope.current { for usage in physical { sink.key(usage, down: true) } } }
            guard SimKeyUsage.typeable(text) else {
                if text.utf8.count <= Self.pasteCapBytes { _ = pasteOnQueue(text) }
                return
            }
            guard let s = liveSink() else { return }
            for ch in text {
                guard isInputCurrent(), inputScope.current else { break }
                guard let (usage, shift) = SimKeyUsage.usage(forCharacter: ch) else { continue }
                if shift { s.key(SimKeyUsage.leftShift, down: true) }
                s.key(usage, down: true)
                s.key(usage, down: false)
                if shift { s.key(SimKeyUsage.leftShift, down: false) }
                Thread.sleep(forTimeInterval: Self.keyGapSeconds)
            }
        }
    }

    public func pasteText(_ text: String) -> Bool? {
        guard text.utf8.count <= Self.pasteCapBytes else { return false }
        return queue.sync { pasteOnQueue(text) }
    }
    public var takesFilePastes: Bool { false }

    public func pasteShortcut() -> Bool {
        queue.sync {
            guard let s = liveSink() else { return false }
            commandV(s)
            return true
        }
    }

    public func scroll(normalizedX x: Double, normalizedY y: Double, deltaX dx: Double, deltaY dy: Double,
                       unit: ScrollUnit, mods: InputModifiers) {
        let k = unit == .line ? Self.linePoints : 1
        let at = nowMs()
        enqueue { [self] in
            guard fresh(at) else { return }
            if nativeScrollContact {
                guard inputScope.current, let raw = scrollSink, !raw.invalidated, nativeScroll != nil else { return }
                let events = nativeScroll!.move(dx: dx * k, dy: dy * k)
                for event in events { postNativeScroll(event, to: raw) }
                return
            }
            let r = display.rotation
            if wheel == nil || r != wheelRotation {
                // THE DRAG RUNS IN THE SHOWN FRAME (the wheel's deltas are the picture's), and each point it makes is
                // turned to the native frame as it is sent.
                let shown = r.shownSize(nativeW: nativePointW, nativeH: nativePointH)
                wheel = SimWheelDrag(pointW: Double(shown.w), pointH: Double(shown.h))
                wheelRotation = r
            }
            let events = wheel!.wheel(x: x, y: y, dxPoints: dx * k, dyPoints: dy * k, nowMs: nowMs())
            guard !events.isEmpty, let s = liveSink() else { return }
            for e in events { s.touch(rotated(e, r)) }
            scheduleWheelTick()
        }
    }

    /// Native source focus prepares the bounded HID connection before acknowledging the input lease.
    public func awaitFrontmost() -> Bool {
        queue.sync { _ = liveScrollSink(); return true }
    }
    public func prepareNativeScroll(_ completion: @escaping (Bool) -> Void) {
        enqueue { [self] in completion(liveScrollSink() != nil) }
    }
    var nativeScrollGestureSupported: Bool { queue.sync { scrollSink?.invalidated == false } }

    public func scrollGesture(normalizedX x: Double, normalizedY y: Double, phase: ScrollGesturePhase,
                              velocityX vx: Double, velocityY vy: Double, mods: InputModifiers) {
        let at = nowMs()
        enqueue { [self] in
            guard inputScope.current else { return }
            if phase == .begin {
                nativeScrollContact = true
                guard let raw = liveScrollSink(), fresh(at), inputScope.current else { return }
                cancelNativeScroll()
                nativeScrollContact = true
                wheelTick?.cancel(); wheelTick = nil
                if var old = wheel, let s = sink, !s.invalidated {
                    for event in old.tick(nowMs: Int.max / 2) { scopedSink(s).touch(rotated(event, wheelRotation)) }
                }
                wheel = nil
                nativeScrollRotation = display.rotation
                let size = nativeScrollRotation.shownSize(nativeW: nativePointW, nativeH: nativePointH)
                nativeScroll = SimNativeScrollDrag(pointW: Double(size.w), pointH: Double(size.h))
                for event in nativeScroll!.begin(x: x, y: y) { postNativeScroll(event, to: raw) }
            } else {
                nativeScrollContact = false
                guard let raw = scrollSink, !raw.invalidated else { nativeScroll = nil; nativeScrollFinger = nil; return }
                let events = nativeScroll?.end(moving: phase == .end && hypot(vx, vy) > 0) ?? []
                for event in events { postNativeScroll(event, to: raw) }
                nativeScroll = nil
            }
        }
    }

    private func liveScrollSink() -> SimScrollHIDSink? {
        guard isInputCurrent() else { return nil }
        if let raw = scrollSink, !raw.invalidated { return raw }
        nativeScroll = nil; nativeScrollFinger = nil; scrollSink = nil
        if let at = scrollAttemptMs, nowMs() - at < Self.reconnectBackoffMs { return nil }
        scrollSink = connectScroll(); scrollAttemptMs = nowMs()
        return isInputCurrent() ? scrollSink : nil
    }
    private func postNativeScroll(_ event: SimScrollTouchEvent, to raw: SimScrollHIDSink) {
        let p: SimPoint
        switch event { case .contact(let at), .end(let at), .cancel(let at): p = at }
        let n = nativeScrollRotation.nativePoint(shownX: p.x, shownY: p.y), point = SimPoint(x: n.x, y: n.y)
        let native: SimScrollTouchEvent
        switch event { case .contact: native = .contact(point); case .end: native = .end(point); case .cancel: native = .cancel(point) }
        if inputScope.post({ raw.touch(native) }) {
            switch native { case .contact(let at): nativeScrollFinger = at; case .end, .cancel: nativeScrollFinger = nil }
        }
    }
    private func cancelNativeScroll() {
        nativeScroll = nil; nativeScrollContact = false
        guard let raw = scrollSink, !raw.invalidated, let p = nativeScrollFinger else { nativeScrollFinger = nil; return }
        if inputScope.post({ raw.touch(.cancel(p)) }) { nativeScrollFinger = nil }
    }

    // MARK: - buttons

    public func press(_ button: SimButton) {
        let at = nowMs()
        enqueue { [self] in
            guard let s = liveSink(), fresh(at) else { return }
            s.button(button, down: true)
            Thread.sleep(forTimeInterval: 0.1)
            s.button(button, down: false)
        }
    }

    /// Two home presses 150 ms apart — the app switcher.
    public func appSwitcher() {
        press(.home)
        enqueue { Thread.sleep(forTimeInterval: 0.15) }
        press(.home)
    }

    func drainForTests() { queue.sync {} }

    // MARK: - on `queue`

    private func enqueue(_ work: @escaping () -> Void) {
        if inputScope.executing { work(); return }
        let admitted = pendingLock.withLock { () -> Bool in
            guard pending < Self.pendingCap else { dropped += 1; return false }
            pending += 1
            return true
        }
        guard admitted else {
            let n = pendingLock.withLock { dropped }
            if n == 1 || n % 100 == 0 { print("[sim] input for \(udid) is backed up — \(n) dropped") }
            return
        }
        queue.async { [self] in
            work()
            pendingLock.withLock { pending -= 1 }
        }
    }

    private func liveSink() -> SimHIDSink? {
        guard isInputCurrent() else { return nil }
        if let s = sink, !s.invalidated { return scopedSink(s) }
        if sink != nil {
            // The old connection's gesture, keys and wheel died with it.
            sink = nil; tracker = SimTouchTracker(); held = []; wheel = nil; scopedTouchPoints = nil; scopedTouchMode = false
        }
        if let at = lastAttemptMs, nowMs() - at < Self.reconnectBackoffMs { return nil }
        let began = nowMs()
        sink = connect()
        let elapsed = nowMs() - began
        if elapsed > Self.staleMs { print("[sim] HID connect for \(udid) took \(elapsed) ms") }
        // FROM THE ATTEMPT'S END (final review I3): a connect can take seconds, and counted from its start the next
        // queued event reconnected at once.
        lastAttemptMs = nowMs()
        return isInputCurrent() ? sink.map { scopedSink($0) } : nil
    }

    private func scopedSink(_ raw: SimHIDSink) -> SimHIDSink {
        guard let fence = inputScope.fence else { return raw }
        return ScopedSimHIDSink(raw: raw, fence: fence, didAttemptTouch: { [self] in scopedTouchMode = true }, didTouch: { [self] event in
            switch event {
            case .start(let points), .move(let points): scopedTouchPoints = points
            case .end: scopedTouchPoints = nil
            }
        }) { [self] usage, down in
            // Include successful text/chord posts too, so revocation between down/up can be drained.
            if down { held.insert(usage) } else { held.remove(usage) }
        }
    }

    /// Whether input queued at `at` is still worth delivering (`staleMs`).
    private func fresh(_ at: Int) -> Bool {
        let age = nowMs() - at
        if age > Self.staleMs { print("[sim] dropped stale input for \(udid), age=\(age) ms") }
        return age <= Self.staleMs
    }

    private func pasteOnQueue(_ text: String) -> Bool {
        guard isInputCurrent(), control.copyToPasteboard(udid: udid, text: text), let s = liveSink() else { return false }
        commandV(s)
        return true
    }

    /// ⌘V as usages — 0xE3 down, 0x19 down and up, 0xE3 up — MEASURED to paste the simulator's pasteboard.
    private func commandV(_ s: SimHIDSink) {
        s.key(SimKeyUsage.leftCommand, down: true); Thread.sleep(forTimeInterval: Self.keyGapSeconds)
        s.key(SimKeyUsage.v, down: true); s.key(SimKeyUsage.v, down: false)
        Thread.sleep(forTimeInterval: Self.keyGapSeconds)
        s.key(SimKeyUsage.leftCommand, down: false)
    }

    private func scheduleWheelTick() {
        wheelTick?.cancel()
        let item = DispatchWorkItem(block: inputScope.capture { [weak self] in
            guard let self, self.isInputCurrent(), var w = self.wheel, let raw = self.sink, !raw.invalidated else { return }
            let s = self.scopedSink(raw)
            let r = self.wheelRotation
            for e in w.tick(nowMs: self.nowMs()) { s.touch(self.rotated(e, r)) }
            self.wheel = w
        })
        wheelTick = item
        queue.asyncAfter(deadline: .now() + .milliseconds(SimWheelDrag.idleMs + 5), execute: item)
    }

    private func rotated(_ e: SimTouchEvent, _ r: SimRotation) -> SimTouchEvent {
        func turn(_ ps: [SimPoint]) -> [SimPoint] {
            ps.map { p in let n = r.nativePoint(shownX: p.x, shownY: p.y); return SimPoint(x: n.x, y: n.y) }
        }
        switch e {
        case .start(let p): return .start(turn(p))
        case .move(let p): return .move(turn(p))
        case .end(let p): return .end(turn(p))
        }
    }
}
