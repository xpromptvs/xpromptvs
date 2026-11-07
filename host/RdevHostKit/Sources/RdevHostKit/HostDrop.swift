import AppKit
@preconcurrency import ApplicationServices
import Foundation
import RdevCore

/// A DROP IS CARRYING: from its own posted press until its mouse-up — PROCESS-WIDE, because the window server has
/// one cursor and one left button whichever injector posts. The window injector reads it and posts none of the
/// driver's pointer events meanwhile (`DropCarryGate`): a tap's mouse-up would end the drag at the tap's point.
/// Set on main at the press; cleared by the carry's thread right after its mouse-up, and on main at every other
/// end (no session began, the let-go bound, the session's end). HELD BY ITS DROP: an end clears only the carry its
/// own `begin` started — a session let go at 30 s that AppKit ends later must not clear the next drop's.
final class DropCarry: @unchecked Sendable {
    static let shared = DropCarry()

    private let lock = NSLock()
    private var holder: UInt64?
    private var issued: UInt64 = 0

    var isCarrying: Bool { lock.withLock { holder != nil } }

    func begin() -> UInt64 {
        lock.withLock {
            issued &+= 1
            holder = issued
            return issued
        }
    }

    func end(_ token: UInt64) {
        lock.withLock { if holder == token { holder = nil } }
    }
}

/// A REAL DROP AT A POINT ON THE MAC (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §5; premise
/// P4 measured it: Chromium got the file and the text at exactly the requested point, Finder copied the file
/// into the folder, TextEdit inserted the text, the target app stayed frontmost, every run first try at load
/// 30–120). The items go on a dragging session started from an 8-point, non-activating panel of THIS process
/// beside the point (the host's own windows are never captured — `SelfCapture` — so the picture never shows
/// it); a posted mouse-down on it starts the session, posted drags carry the REAL cursor to the point and a
/// mouse-up there drops on whatever window is under it.
///
/// THE MECHANISM IS P4'S SPIKE, its shape and its timings unchanged — the 0.3 s before the mouse-down, 12 drags
/// 16 ms apart, 150 ms at rest before the mouse-up — posted through the curtain's marked event source, so it
/// works with the curtain up. What the spike lacked is TARGETING, and each guard below answers one of its
/// findings (the first was a drop that went wrong while reporting success):
/// 1. the drop lands ONLY on its target (`landsOnTarget`): the spike's one unguarded drop, made while the person
///    at the Mac switched apps, landed in another application's window (another app's, or this one's own) and
///    reported success. Checked BEFORE THE PRESS (`pressVerdict`), so a point something else already covers
///    posts nothing at all and the delivery pastes — THE ONLY CANCEL THERE IS. Once the drag has begun nothing
///    of this host's can refuse it: AppKit fixes a drag's possible destinations, and where they are, WHEN THE
///    DRAG BEGINS. MEASURED 2026-10-01 (9 drops, against paste-live-check D2's scene — a Picture-in-Picture
///    window over the target — one property changed at a time): a refusing panel of this host's shown under
///    the point mid-drag, or shown before the press elsewhere and MOVED there, translucent or opaque, at level
///    101 or 1000, was never consulted (no `draggingEntered`) and the drop landed in the PiP; a panel above the
///    drag's own window (500) is no destination even when present from the start; and AppKit asks the
///    source's operation mask only before the drag is under way. Just before the mouse-up guard 1 is asked
///    AGAIN, as DETECTION ONLY: a window that came over the point during the ~0.6 s carry is logged loudly,
///    the mouse-up goes as usual, and the answer is the session's own (`answer`). That residual — a floating
///    window APPEARING over the point during the carry — is accepted. Never Escape: this app is not the
///    active one, so a posted Escape goes to the ACTIVE app — leaving its full screen, cancelling an edit, a
///    keystroke into vim — and the drag would still drop;
/// 2. the mouse-down goes only where the panel is ON TOP (`windowUnder` at any layer) — else nothing is posted:
///    a covered panel turns the press into a click on whatever covers it, with the button left held;
/// 3. a HIDDEN host app (`OwnWindows` hides it whenever a display takes input, and nothing unhides it on its
///    own) still shows the panel — `canHide = false` — and guard 2 refuses the press if it is not on top
///    after all;
/// 4. held modifiers cannot change the operation — every posted event says no modifier, and the session
///    ignores them (`ignoreModifierKeys`): the strip's held ⌘ or ⌥ would turn the copy into a move or a link;
/// 5. the driver's own pointer stays out of the carry (`DropCarry`, from the press to the mouse-up): the window
///    injector posts no touch, hover or scroll meanwhile, or a tap's mouse-up would end the drag at the TAP's
///    point — in whatever window is there, which guard 1 never looked at.
/// Every refusal answers `false` and the caller pastes instead (§5's run-time fallback) — but the answer is
/// whether a drop HAPPENED (`answer`): one that landed — on a window that came over the point mid-drag too —
/// answers `true`, because a paste after it would deliver twice.
enum HostDrop {
    /// From the drop point to the panel's centre: far enough that the panel never covers the point.
    static let offset: CGFloat = 24
    static let panelSize: CGFloat = 8
    static let steps = 12
    /// The panel is on screen this long before the mouse-down (measured: 0.3 s, at load 30–120).
    static let lead = 0.3
    /// §5: a session that has not begun within this of the mouse-down is a refusal, and the delivery pastes.
    static let beginBound = 1.0
    /// A session that began and has not ENDED this long after the mouse-down is answered without its end.
    static let endBound = 10.0
    /// ...and this long after, LET GO: later drops may run. AppKit may still call it, so it is kept alive.
    static let letGoBound = 30.0

    // MARK: pure

    /// A CG (top-left origin) point's square of `size` in Cocoa coordinates (bottom-left, flipped against
    /// the PRIMARY screen's height, whatever display the point is on).
    static func cocoaRect(around p: CGPoint, size: CGFloat, screenHeight: CGFloat) -> NSRect {
        NSRect(x: p.x - size / 2, y: screenHeight - p.y - size / 2, width: size, height: size)
    }

    /// The cursor's path from the panel to the drop point, ending EXACTLY on it.
    static func path(from a: CGPoint, to b: CGPoint, steps: Int) -> [CGPoint] {
        (1...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// Where the panel goes: `offset` below and right of the drop point, flipped to the other side on an axis
    /// where the panel would leave the point's display — a mouse-down posted off a display lands where the
    /// system clamps the cursor, which is not on the panel.
    static func startPoint(for target: CGPoint, on display: CGRect) -> CGPoint {
        let reach = offset + panelSize / 2
        return CGPoint(x: target.x + (target.x + reach > display.maxX ? -offset : offset),
                       y: target.y + (target.y + reach > display.maxY ? -offset : offset))
    }

    /// The window a click at `point` would reach, from a `CGWindowListCopyWindowInfo` list (front to back):
    /// the first that contains it and can take a click — not fully transparent — skipping `excludingPID`'s.
    ///
    /// ONLY THE LAYERS BELOW THE DOCK'S (normal 0 through utility 19) unless `anyLayer`: the Dock's full-screen
    /// layer-20 window is in every list, with the menu bar and the cursor's windows above it, and bounds carry
    /// no shapes — a walk over them finds the Dock everywhere. A floating window over the point takes a drop
    /// like any window, so it counts. `anyLayer` is for the panel itself (the screen saver's level, 1000):
    /// whatever is in front of it at any layer is what a posted mouse-down would click.
    static func windowUnder(_ point: CGPoint, in list: [[String: Any]], excludingPID: pid_t?,
                            anyLayer: Bool = false) -> CGWindowID? {
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        for w in list {
            guard let n = number(w) else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard anyLayer || (0..<dock).contains(layer) else { continue }
            // An unknown alpha counts as opaque: skipping a window that does take the click is the error
            // that matters here.
            guard ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { continue }
            if let excludingPID, owner(w) == excludingPID { continue }
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(point) else { continue }
            return n
        }
        return nil
    }

    /// GUARD 1 — may the mouse-up go? The window in front at the point must BE the target; this host's own
    /// windows are not skipped, because they take a drop like any other (P4's unguarded wrong drop went into
    /// this app's own window or the one beside it). A display (`target == nil`) has no window to name, but
    /// its picture never shows this host's windows (`SelfCapture`), so the drop must not land on one of them;
    /// anything else under the point — the bare desktop included — is what the picture shows there.
    ///
    /// `lookingThrough`: this host's windows that appeared SINCE THE PRESS (`ownWindows` then and now) — what
    /// AppKit opened for the drag itself, which takes nothing. Looked through by number AND owner, so another
    /// app's window can never be mistaken for one. MEASURED (2026-10-01, one drop onto Chromium): AppKit's drag
    /// window is this process's, at the dragging level (500) and the size of the whole screen — the layer
    /// bound already passes it, and looking through keeps that true whatever level a later macOS gives it.
    static func landsOnTarget(_ point: CGPoint, in list: [[String: Any]], target: CGWindowID?, ownPID: pid_t,
                              lookingThrough opened: Set<CGWindowID> = []) -> Bool {
        let seen = opened.isEmpty ? list : list.filter { w in
            !(owner(w) == ownPID && number(w).map(opened.contains) == true)
        }
        let front = windowUnder(point, in: seen, excludingPID: nil)
        if let target { return front == target }
        return front == windowUnder(point, in: seen, excludingPID: ownPID)
    }

    /// What the press may do, from ONE window list read just before anything is posted.
    enum PressVerdict: Equatable {
        case press
        /// Guard 1: something other than the target is already in front at the drop point.
        case notOnTarget
        /// Guard 2: the panel is not what is on top at the start point.
        case panelCovered
    }

    /// Guards 1 and 2 at the press. Guard 1 FIRST: a drop that could only land on the wrong window is refused
    /// whatever the panel's state, and with nothing posted the delivery pastes instead. Nothing is looked through
    /// — nothing of the drag exists yet, and the panel sits at the start point, above the layers guard 1 reads.
    static func pressVerdict(start: CGPoint, panel: CGWindowID, target: CGPoint, targetWindowID: CGWindowID?,
                             ownPID: pid_t, in list: [[String: Any]]) -> PressVerdict {
        guard landsOnTarget(target, in: list, target: targetWindowID, ownPID: ownPID) else { return .notOnTarget }
        guard windowUnder(start, in: list, excludingPID: nil, anyLayer: true) == panel else { return .panelCovered }
        return .press
    }

    /// The numbers of `pid`'s windows in a window list.
    static func ownWindows(in list: [[String: Any]], pid: pid_t) -> Set<CGWindowID> {
        Set(list.compactMap { w in owner(w) == pid ? number(w) : nil })
    }

    private static func number(_ w: [String: Any]) -> CGWindowID? { (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    private static func owner(_ w: [String: Any]) -> pid_t? { (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }

    /// GUARD 4's half on the wire: a mouse event that says NO modifier, whatever the strip holds, and carries
    /// the curtain's marker — the curtain swallows every other event, and a remote driver drops with it up.
    static func mouseEvent(_ type: CGEventType, at p: CGPoint, from previous: CGPoint?) -> CGEvent? {
        WindowInputInjector.makeMouseEvent(source: source, type: type, at: p, from: previous,
                                           button: .left, clickState: 1, flags: [])
    }

    /// The drop's answer: whether a drop HAPPENED — never where it was meant to. An ended session says by its
    /// operation (a drop that landed on a window that came over the point mid-drag landed, and a paste after it
    /// would deliver twice);
    /// one that never ended (`nil`) counts as dropped once its session began and its mouse-up went — the
    /// target holds it, an app may keep a dialog up inside its drop handler — for the same reason.
    static func answer(endedWith operation: NSDragOperation?, sessionBegan: Bool, released: Bool) -> Bool {
        if let operation { return !operation.isEmpty }
        return sessionBegan && released
    }

    /// What is due `elapsed` seconds after the press, for a drop whose session has not ended.
    enum Overdue: Equatable {
        case nothing
        /// The press began no session: release the button it holds, and refuse.
        case noSession
        /// The session began and has not ended: answer without its end (`answer`).
        case answerWithoutEnd
        /// It still has not ended: stop counting it as the drop under way, or every later drop in the process
        /// refuses as "another drop is under way".
        case letGo
    }

    static func overdue(elapsed: Double, began: Bool) -> Overdue {
        guard began else { return elapsed >= beginBound ? .noSession : .nothing }
        if elapsed >= letGoBound { return .letGo }
        return elapsed >= endBound ? .answerWithoutEnd : .nothing
    }

    nonisolated(unsafe) private static let source = WindowInputInjector.makeMarkedSource()

    // MARK: the drop

    /// Perform the drop of `content` at `point` (global CG coordinates) onto `targetWindowID` (nil: a display,
    /// whatever is under the point). AppKit, so it runs on MAIN, reached with `async` — never `.sync`.
    /// `isCancelled`: whether the delivery has been abandoned since — asked before the panel shows and right
    /// before the press (true: nothing is posted, the answer is false); after the press nothing can call the drop
    /// back, and the receiver deals with an abandoned one by its answer. `completion` is called exactly once, on
    /// main: whether a drop happened.
    static func perform(_ content: PasteboardContent, at point: CGPoint, targetWindowID: CGWindowID?,
                        isCancelled: @escaping @Sendable () -> Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Session.start(content, at: point, targetWindowID: targetWindowID, isCancelled: isCancelled,
                              completion: completion)
            }
        }
    }

    private static func onScreenWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// What the thread carrying the drag tells main. Behind a lock: written there, read on main.
    private final class Carried: @unchecked Sendable {
        private let lock = NSLock()
        private var _strayed = false
        private var _released = false
        /// Something other than the target was under the point at the mouse-up: the drop may have landed there.
        var strayed: Bool { lock.withLock { _strayed } }
        /// The mouse-up was posted.
        var released: Bool { lock.withLock { _released } }
        func stray() { lock.withLock { _strayed = true } }
        func release() { lock.withLock { _released = true } }
    }

    /// The drag OFF main: main runs the session, and the posted events must reach it while it does. Touches
    /// no AppKit. `ownAtPress`: this host's windows on screen when the mouse-down went — guard 1 looks through
    /// any newer one (AppKit's own drag window).
    private static func carry(from start: CGPoint, to target: CGPoint, targetWindowID: CGWindowID?,
                              ownAtPress: Set<CGWindowID>, isCancelled: @escaping @Sendable () -> Bool,
                              carry token: UInt64, _ c: Carried) {
        var last = start
        for q in path(from: start, to: target, steps: steps) {
            mouseEvent(.leftMouseDragged, at: q, from: last)?.post(tap: .cghidEventTap)
            last = q
            usleep(16_000)
        }
        usleep(150_000)                          // the target sees draggingUpdated at rest
        let now = onScreenWindows()
        let opened = ownWindows(in: now, pid: getpid()).subtracting(ownAtPress)
        let lands = landsOnTarget(target, in: now, target: targetWindowID, ownPID: getpid(), lookingThrough: opened)
        // DETECTION ONLY — nothing can refuse a drag under way (see guard 1): said loudly, and the answer is the
        // session's own.
        if !lands {
            c.stray()
            print("[drop] SOMETHING OTHER THAN THE TARGET CAME UNDER THE POINT DURING THE DRAG — the drop may land "
                + "on it: a drag under way cannot be refused (AppKit fixes its destinations when it begins); the "
                + "answer is the session's, and a drop that lands is never delivered a second time")
        }
        if isCancelled() {
            print("[drop] its delivery was abandoned during the drag — the drop goes on: it cannot be called back")
        }
        mouseEvent(.leftMouseUp, at: target, from: last)?.post(tap: .cghidEventTap)
        c.release()
        // Only AFTER the mouse-up is posted: the driver's next pointer event posts behind it, never into the drag.
        DropCarry.shared.end(token)
    }

    /// One drop: the panel, the session started from it, and the one answer. Lives until its session ends
    /// (or it never began one) — AppKit may still be calling its source methods until then.
    @MainActor
    private final class Session: NSView, NSDraggingSource {
        /// One drop at a time: a second would post its events into the first one's drag (a change of driver
        /// abandons a delivery, but cannot call back a drop already moving the cursor). Set while a session
        /// is under way, until it ends or is let go.
        private static var current: Session?

        private let content: PasteboardContent
        private let target: CGPoint
        private let targetWindowID: CGWindowID?
        private let start: CGPoint
        private let screenHeight: CGFloat
        private let isCancelled: @Sendable () -> Bool
        private var completion: ((Bool) -> Void)?
        /// Kept until the session ends: it and this view hold each other, which is what keeps a session
        /// AppKit never ended alive after it is let go — AppKit may still call its source.
        private var panel: NSPanel?
        /// The press reached the panel and a session was asked for.
        private var began = false
        /// AppKit says the session has begun (`willBeginAt`) — only then can the mouse-up have dropped anything.
        private var sessionBegan = false
        /// The session ended, or never began and was refused: nothing more is due.
        private var over = false
        private let carried = Carried()
        /// This host's windows on screen at the press — the panel among them.
        private var ownAtPress: Set<CGWindowID> = []
        /// This drop's hold on `DropCarry`, from its press — nil before it.
        private var carryToken: UInt64?

        static func start(_ content: PasteboardContent, at point: CGPoint, targetWindowID: CGWindowID?,
                          isCancelled: @escaping @Sendable () -> Bool, completion: @escaping (Bool) -> Void) {
            func refuse(_ why: String) {
                print("[drop] not dropped — \(why)")
                completion(false)
            }
            guard !isCancelled() else { return refuse("its delivery was abandoned") }
            guard current == nil else { return refuse("another drop is under way; pasting instead") }
            // A process with no NSApplication has no panel to show at all.
            guard NSApp != nil else { return refuse("no application; pasting instead") }
            guard AXIsProcessTrusted() else { return refuse("no Accessibility permission; pasting instead") }
            var display: CGDirectDisplayID = 0
            var count: UInt32 = 0
            guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1,
                  let screenHeight = NSScreen.screens.first?.frame.height else {
                return refuse("the point is on no display; pasting instead")
            }
            let s = Session(content: content, target: point, targetWindowID: targetWindowID,
                            start: startPoint(for: point, on: CGDisplayBounds(display)), screenHeight: screenHeight,
                            isCancelled: isCancelled, completion: completion)
            current = s
            s.show()
        }

        private init(content: PasteboardContent, target: CGPoint, targetWindowID: CGWindowID?, start: CGPoint,
                     screenHeight: CGFloat, isCancelled: @escaping @Sendable () -> Bool,
                     completion: @escaping (Bool) -> Void) {
            self.content = content; self.target = target; self.targetWindowID = targetWindowID
            self.start = start; self.screenHeight = screenHeight
            self.isCancelled = isCancelled; self.completion = completion
            super.init(frame: NSRect(x: 0, y: 0, width: HostDrop.panelSize, height: HostDrop.panelSize))
        }
        required init?(coder: NSCoder) { nil }

        /// An 8-point panel of this process around `point`, in front of every ordinary window, showing `view`.
        private func makePanel(around point: CGPoint, _ view: NSView) -> NSPanel {
            let p = NSPanel(contentRect: HostDrop.cocoaRect(around: point, size: HostDrop.panelSize, screenHeight: screenHeight),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = NSColor(white: 1, alpha: 0.02)   // alpha 0 is click-through
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // A panel hides when its app deactivates by default — and raising the target deactivates this
            // one, possibly during the lead: guard 2 would refuse every such drop.
            p.hidesOnDeactivate = false
            // GUARD 3. A display taking input HIDES this app (`OwnWindows`) and nothing unhides it on its own,
            // so without this every window drop after one display press would become a paste. If showing the
            // panel unhides the app after all (`orderFrontRegardless` does that for an ordinary window), the
            // re-hiding is `OwnWindows`' own: the next press from a display client hides it again and waits.
            p.canHide = false
            p.contentView = view
            p.orderFrontRegardless()
            return p
        }

        private func show() {
            panel = makePanel(around: start, self)
            DispatchQueue.main.asyncAfter(deadline: .now() + HostDrop.lead) { MainActor.assumeIsolated { self.press() } }
        }

        private func press() {
            guard !over, let panel else { return }
            // Abandoned during the lead (a change of driver, a departure, the client's own cancel): nothing posted.
            if isCancelled() {
                print("[drop] not dropped — its delivery was abandoned before the press; nothing posted")
                return end(false)
            }
            // GUARDS 1 AND 2, from one list: the drop point is the target's, and the panel is what is on top at the
            // start point, at ANY layer.
            let list = HostDrop.onScreenWindows()
            switch HostDrop.pressVerdict(start: start, panel: CGWindowID(exactly: panel.windowNumber) ?? 0, target: target,
                                         targetWindowID: targetWindowID, ownPID: getpid(), in: list) {
            case .press:
                break
            case .notOnTarget:
                print("[drop] not dropped — something other than the target is under the point before the press; "
                    + "nothing posted, pasting instead")
                return end(false)
            case .panelCovered:
                print("[drop] not dropped — the source panel is covered at the start point; nothing posted, pasting instead")
                return end(false)
            }
            ownAtPress = HostDrop.ownWindows(in: list, pid: getpid())
            // The carry begins BEFORE the press is posted: from here the driver's own taps, hovers and scrolls are
            // not posted (`DropCarryGate`) until the mouse-up — or until whatever ends this drop instead.
            carryToken = DropCarry.shared.begin()
            HostDrop.mouseEvent(.leftMouseDown, at: start, from: nil)?.post(tap: .cghidEventTap)
            for t in [HostDrop.beginBound, HostDrop.endBound, HostDrop.letGoBound] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { self.due(at: t) } }
            }
        }

        private func due(at elapsed: Double) {
            guard !over else { return }
            switch HostDrop.overdue(elapsed: elapsed, began: began) {
            case .nothing:
                return
            case .noSession:
                // The press reached the panel but began nothing: release the button it holds — over the panel,
                // still there to take it — and refuse.
                HostDrop.mouseEvent(.leftMouseUp, at: start, from: start)?.post(tap: .cghidEventTap)
                print("[drop] not dropped — no dragging session began within \(HostDrop.beginBound) s; pasting instead")
                end(false)
            case .answerWithoutEnd:
                guard completion != nil else { return }
                let landed = HostDrop.answer(endedWith: nil, sessionBegan: sessionBegan, released: carried.released)
                print("[drop] the dragging session has not ended after \(HostDrop.endBound) s — answered "
                    + (landed ? "as dropped (a paste could deliver it twice)" : "not dropped"))
                answer(landed)
            case .letGo:
                print("[drop] the dragging session has not ended after \(HostDrop.letGoBound) s — let go; later drops may run")
                panel?.orderOut(nil)
                releaseCarry()
                if Session.current === self { Session.current = nil }
            }
        }

        private func answer(_ ok: Bool) {
            guard let c = completion else { return }
            completion = nil
            c(ok)
        }

        /// Answer, and let the panel and this session go — only where no session is running or it has ended.
        private func end(_ ok: Bool) {
            over = true
            answer(ok)
            panel?.orderOut(nil)
            panel = nil
            releaseCarry()
            if Session.current === self { Session.current = nil }
        }

        /// This drop's carry is over, whatever ended it: the driver's pointer posts again. The carry's own thread
        /// has normally done it already, right after the mouse-up; a press that began no session (released at the
        /// `noSession` bound) and a session let go never reach that line. Idempotent, and only ever this drop's.
        private func releaseCarry() {
            if let t = carryToken { DropCarry.shared.end(t) }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // A press that arrives after the bound was answered (`noSession` released it) begins nothing.
            guard !over, !began else { return }
            began = true
            let writers: [NSPasteboardWriting]
            switch content {
            case .text(let s): writers = [s as NSString]
            case .files(let urls): writers = urls.map { $0 as NSURL }
            }
            let items = writers.map { w -> NSDraggingItem in
                let i = NSDraggingItem(pasteboardWriter: w)
                i.setDraggingFrame(NSRect(x: 0, y: 0, width: 4, height: 4), contents: nil)
                return i
            }
            beginDraggingSession(with: items, event: event, source: self)
            panel?.orderOut(nil)                       // the drop must land on the TARGET under the point
            let (from, to, window, own, probe, carried) = (start, target, targetWindowID, ownAtPress, isCancelled, carried)
            // Begun at the press, which is what delivered this mouse-down — begun here only if something else did.
            if carryToken == nil { carryToken = DropCarry.shared.begin() }
            let token = carryToken!
            DispatchQueue.global(qos: .userInteractive).async {
                HostDrop.carry(from: from, to: to, targetWindowID: window, ownAtPress: own, isCancelled: probe,
                               carry: token, carried)
            }
        }

        func draggingSession(_ s: NSDraggingSession, willBeginAt p: NSPoint) { sessionBegan = true }
        func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
            let landed = HostDrop.answer(endedWith: operation, sessionBegan: true, released: true)
            switch (landed, carried.strayed) {
            case (true, false): print("[drop] dropped")
            case (true, true):
                print("[drop] DROPPED — POSSIBLY ON THE WINDOW THAT CAME OVER THE POINT, not the target; answered as "
                    + "dropped, so nothing pastes it a second time")
            case (false, _): print("[drop] not dropped — the window under the point refused it; pasting instead")
            }
            end(landed)
        }
    }
}
