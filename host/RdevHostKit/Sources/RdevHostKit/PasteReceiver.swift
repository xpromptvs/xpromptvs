import CoreGraphics
import Foundation
import RdevCore

/// THE DRIVER'S PASTES AND DROPS, received and delivered (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md
/// §3–§6). One delivery per client at a time — from its `paste-begin` until it is ANSWERED. EVERYTHING RUNS ON
/// ONE SERIAL QUEUE — never the pion thread or the socket queue that handed the message over (raising a window
/// can block on AX for a second, and a HEIC's conversion is real work) and never under a hub lock: `ChannelHub`
/// gates on the driver and calls in after releasing its own, and `reply` takes it again only to find the
/// client, whose `bulk` channel carries the reply.
///
/// What the receiver does NOT decide: who may paste (the hub — the driver only, on its current connection)
/// and when a client stops being able to (`abandon`, from the hub's change of driver, a departure or a
/// rebuilt connection). It keeps the delivery honest to its `paste-begin` (`PasteDeliveryState`) and the
/// folder clean: whatever a delivery that does not finish had saved is deleted with it.
final class PasteReceiver: @unchecked Sendable {
    /// Where a finished delivery goes. Called on the paste queue; a callback may come back on any thread.
    /// NONE MAY WAIT ON MAIN: `abandonAll` is called from main at quit and waits for this queue.
    struct Destinations {
        /// Type the pieces (`PasteTyping.pieces`) into THAT tab, as pastes; false when the tab is gone (or a
        /// tmux tab has no pane yet).
        var typeIntoTerminal: ([String], TermTabID) -> Bool
        /// The window's injector, the window FOCUSED in the session first — nil when it is not open in it.
        var windowTarget: (String) -> InputInjector?
        var writePasteboard: (PasteboardContent, @escaping (Bool) -> Void) -> Void
        /// `CGWindowID?`: the window the drop must land on (nil for a display). A drop that would land
        /// anywhere else is cancelled and answers false, and the caller pastes instead (`HostDrop`).
        /// `() -> Bool`: whether the delivery has been ABANDONED since — asked from main, by a drop that has not
        /// pressed yet, which then posts nothing and answers false.
        var drop: (PasteboardContent, CGPoint, CGWindowID?, @escaping @Sendable () -> Bool, @escaping (Bool) -> Void) -> Void
    }

    private final class Open {
        var state: PasteDeliveryState
        /// Item index → its file, while it is still a PARTIAL. Committed files leave this map one by one, so
        /// what is left in it when a delivery is dropped is exactly what must be discarded.
        var files: [Int: PasteFile] = [:]
        /// The committed files, in ITEM order: every item of a file delivery is a file (sizes are ≥ 1, and
        /// the state machine moves to an item only once the one before it is whole).
        var committed: [URL] = []
        /// A window's text — held in memory, never written to disk (§4.2).
        var text = Data()
        /// Set (on the paste queue) when the delivery is abandoned AFTER its `paste-end`, while it is being
        /// delivered: read at every point the delivery is about to act — before the clipboard or the drop
        /// starts, before ⌘V, and when the drop answers — and from there it does nothing more. Behind a lock,
        /// because the drop reads it too, from main.
        let cancelled = Flag()
        init(_ s: PasteDeliveryState) { state = s }
    }

    /// A flag set on one thread and read on another.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isSet: Bool { lock.withLock { on } }
        func set() { lock.withLock { on = true } }
    }

    private let queue = DispatchQueue(label: "dev.rdev.paste")
    /// clientId → its delivery still ARRIVING (between `paste-begin` and `paste-end`). Touched only on `queue`.
    private var open: [String: Open] = [:]
    /// clientId → its delivery being DELIVERED (from `paste-end` until it is answered). A window's delivery is
    /// spread over a raise, a hop to main for the clipboard and up to a second of a real drop, and a change of
    /// driver in that time must still stop it (§7): `abandon` finds it here. Touched only on `queue`.
    private var delivering: [String: Open] = [:]
    private let store: PasteStore
    private let d: Destinations
    private let reply: (Data, String) -> Void
    private let now: () -> Double

    /// `now`: seconds on a monotonic clock, for the stall rule (`PasteLimits.stallSeconds`).
    init(store: PasteStore, destinations: Destinations, reply: @escaping (Data, String) -> Void,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.d = destinations; self.reply = reply; self.now = now
    }

    func begin(_ b: PasteBegin, clientId: String) {
        queue.async { [self] in
            // A delivery still being delivered counts: the client sends its next only once this one is
            // answered, and two at once would race each other's ⌘V.
            if open[clientId] != nil || delivering[clientId] != nil {
                return reply(pasteErrorJSON(id: b.id, reason: .busy), clientId)
            }
            if let e = PasteLimits.check(b.items) { return reply(pasteErrorJSON(id: b.id, reason: e), clientId) }
            open[clientId] = Open(PasteDeliveryState(begin: b, now: now()))
            // OPEN, and said so before any piece can arrive: the client sends none until it has this (5 s, then it
            // gives up — `PasteUploader`). A Mac that ignored `paste-*` once took a whole upload and left the
            // client's note at 94% for the 60 s reply timeout. Sent from here, on this queue, so it reaches the
            // client ahead of anything else this delivery answers.
            reply(pasteAcceptedJSON(id: b.id), clientId)
        }
    }

    func piece(id: String, item: Int, seq: Int, bytes: Data, clientId: String) {
        queue.async { [self] in
            guard let o = open[clientId], o.state.begin.id == id else { return }   // unknown id: dropped
            switch o.state.piece(item: item, seq: seq, count: bytes.count, now: now()) {
            case .fail(let e):
                drop(clientId, reply: e)
            case .write(let i):
                switch o.state.begin.items[i] {
                case .text:
                    o.text.append(bytes)
                case .file(let name, let type, _):
                    do {
                        let f = try o.files[i] ?? store.open(name: name, type: type)
                        o.files[i] = f
                        try f.append(bytes)
                    } catch {
                        drop(clientId, reply: .disk)
                    }
                }
            }
        }
    }

    func end(id: String, clientId: String) {
        queue.async { [self] in
            guard let o = open[clientId], o.state.begin.id == id else {
                // Abandoned meanwhile (a stall, a malformed piece) or never begun: the client is waiting
                // for an answer and gets one.
                return reply(pasteErrorJSON(id: id, reason: .failed), clientId)
            }
            guard o.state.complete() else { return drop(clientId, reply: .malformed) }
            do {
                for i in o.files.keys.sorted() {
                    o.committed.append(try store.commit(o.files[i]!))
                    o.files[i] = nil   // only now: a commit that throws leaves its partial for `drop` to discard
                }
            } catch {
                return drop(clientId, reply: .disk)
            }
            open[clientId] = nil
            delivering[clientId] = o
            deliver(o, clientId: clientId)
        }
    }

    /// The client's own cancel — of a delivery still arriving, or of one it has ended and is waiting on (its
    /// uploader then moves on to the next, which must not find itself `busy`). No reply: the client already
    /// counts it cancelled.
    func cancel(id: String, clientId: String) {
        queue.async { [self] in
            if let o = open[clientId], o.state.begin.id == id { return drop(clientId, reply: nil) }
            if let o = delivering[clientId], o.state.begin.id == id { stopDelivering(clientId, reply: nil) }
        }
    }

    /// The client lost control (`reply: .notDriver`), left, or had its connection rebuilt (`nil` — nobody is
    /// there to tell): its delivery goes, files and all — one still arriving, and one being delivered too.
    func abandon(clientId: String, reply r: PasteError?) {
        queue.async { [self] in
            if open[clientId] != nil { drop(clientId, reply: r) } else { stopDelivering(clientId, reply: r) }
        }
    }

    /// The session's end: every delivery goes, and this WAITS for it — the folder is emptied right after, and
    /// a partial still being written behind the emptying would outlive the quit.
    func abandonAll() {
        queue.sync {
            for c in Array(open.keys) { drop(c, reply: nil) }
            for c in Array(delivering.keys) { stopDelivering(c, reply: nil) }
        }
    }

    /// §3: a delivery with no piece for `PasteLimits.stallSeconds` is abandoned (a suspended page, a dead link).
    func checkStalls() {
        queue.async { [self] in
            for (c, o) in open where o.state.stalled(now: now()) { drop(c, reply: .failed) }
        }
    }

    /// §6's hourly sweep — on the paste queue, so it never runs beside a delivery's own.
    func sweepFolder() { queue.async { [self] in store.sweep(keep: nil) } }

    /// Tests: wait for everything queued so far AND what it queued in turn — the longest chain is five hops
    /// (`end` → the turn after the raise → the drop's callback → the turn after the wait for the front → the
    /// fallback paste's clipboard callback), and the test fakes call back synchronously, so six passes always
    /// reach the end.
    func drain() { for _ in 0..<6 { queue.sync {} } }

    // MARK: on `queue`

    private func drop(_ clientId: String, reply r: PasteError?) {
        guard let o = open.removeValue(forKey: clientId) else { return }
        for f in o.files.values { store.discard(f) }
        store.delete(o.committed)
        print("[paste] \(clientId) \(o.state.begin.id) abandoned (\(r?.rawValue ?? "no reply"))")
        if let r { reply(pasteErrorJSON(id: o.state.begin.id, reason: r), clientId) }
    }

    /// A delivery being delivered is stopped where it stands: the flag is read at its next step, which also
    /// deletes its files — not here, because a drop may be carrying them to the target at this moment.
    private func stopDelivering(_ clientId: String, reply r: PasteError?) {
        guard let o = delivering.removeValue(forKey: clientId) else { return }
        o.cancelled.set()
        print("[paste] \(clientId) \(o.state.begin.id) abandoned while being delivered (\(r?.rawValue ?? "no reply"))")
        if let r { reply(pasteErrorJSON(id: o.state.begin.id, reason: r), clientId) }
    }

    /// Whether a delivery may take its next step. A cancelled one deletes its files and does nothing more —
    /// `landed`: unless it has already been handed to the app it was dropped on, which may still be reading
    /// them (Finder copies after the drop has returned); those the sweep takes.
    private func goesOn(_ o: Open, landed: Bool = false) -> Bool {
        guard o.cancelled.isSet else { return true }
        if !landed { store.delete(o.committed) }
        return false
    }

    /// A `win:` source's window number — what a drop must land on. nil for a display (and for a number no
    /// window can have).
    static func windowID(_ source: String) -> CGWindowID? {
        if case .window(let n) = parseSourceID(source) { return CGWindowID(exactly: n) }
        return nil
    }

    private func finish(_ o: Open, _ clientId: String, _ how: PasteHow, keep: URL?) {
        if delivering[clientId] === o { delivering[clientId] = nil }
        print("[paste] \(clientId) \(o.state.begin.id) delivered (\(how.rawValue), \(o.state.begin.items.count) item(s))")
        reply(pasteDoneJSON(id: o.state.begin.id, how: how), clientId)
        store.sweep(keep: keep)   // §6: after every save, never the file just saved
    }

    private func fail(_ o: Open, _ clientId: String, _ e: PasteError) {
        if delivering[clientId] === o { delivering[clientId] = nil }
        store.delete(o.committed)
        print("[paste] \(clientId) \(o.state.begin.id) failed (\(e.rawValue))")
        reply(pasteErrorJSON(id: o.state.begin.id, reason: e), clientId)
    }

    private func deliver(_ o: Open, clientId: String) {
        let b = o.state.begin
        switch b.to {
        case .terminal(let tab):
            for (i, url) in o.committed.enumerated() {
                guard case .file(let name, let type, _) = b.items[i], PasteImages.isHEIC(type: type, name: name) else { continue }
                // §4.1: Claude cannot read HEIC — a terminal gets a JPEG beside it, the HEIC removed. A name
                // the folder already uses is never overwritten (`sibling`), and the JPEG is 0600 like every
                // file here (§6) though ImageIO made it.
                let jpg = store.sibling(of: url, ext: "jpg")
                if PasteImages.jpeg(fromHEIC: url, to: jpg), store.makePrivate(jpg) {
                    store.delete([url])
                    o.committed[i] = jpg
                } else {
                    store.delete([jpg])   // a failed Finalize can leave a half-written file; the HEIC is typed
                }
            }
            guard d.typeIntoTerminal(PasteTyping.pieces(paths: o.committed.map(\.path)), tab) else {
                return fail(o, clientId, .noTarget)
            }
            finish(o, clientId, .paste, keep: o.committed.last)
        case .window(let source, let at):
            guard let inj = d.windowTarget(source) else { return fail(o, clientId, .noTarget) }
            // A SIMULATOR PASTES THROUGH ITS OWN PASTEBOARD, never the Mac's, and takes no files
            // (docs/superpowers/specs/2026-10-13-simulator-sources-design.md, "The wire").
            if !inj.takesFilePastes, !o.committed.isEmpty { return fail(o, clientId, .noTarget) }
            if o.committed.isEmpty, let pasted = inj.pasteText(String(decoding: o.text, as: UTF8.self)) {
                return pasted ? finish(o, clientId, .paste, keep: nil) : fail(o, clientId, .failed)
            }
            let content: PasteboardContent = o.committed.isEmpty
                ? .text(String(decoding: o.text, as: UTF8.self)) : .files(o.committed)
            inj.raise()
            // The raise can hold this queue for a second (AX): an abandon that arrived meanwhile is queued
            // behind it, so the next step takes ITS turn after that one and finds the flag.
            queue.async { [self] in
                guard goesOn(o) else { return }
                guard let at, let point = inj.screenPoint(normalizedX: at.x, normalizedY: at.y) else {
                    return paste(o, content, inj, clientId)
                }
                let cancelled = o.cancelled
                d.drop(content, point, Self.windowID(source), { cancelled.isSet }) { ok in
                    self.queue.async {
                        guard self.goesOn(o, landed: ok) else { return }
                        guard ok else { return self.paste(o, content, inj, clientId) }   // §5: the run-time fallback
                        self.finish(o, clientId, .drop, keep: o.committed.last)
                    }
                }
            }
        }
    }

    /// §4.2: the clipboard, then exactly ⌘V — once the window's application is the FRONT one, where a key goes
    /// (`awaitFrontmost`), and unless the delivery was abandoned meanwhile. Asked BEFORE the clipboard is
    /// touched, so a paste that cannot reach its window changes nothing on the Mac: it fails, files and all —
    /// and asked again, with no wait, as the ⌘V posts (`pasteShortcut`): not front any more, nothing is posted
    /// and it fails the same way, though the clipboard has been written by then.
    private func paste(_ o: Open, _ content: PasteboardContent, _ inj: InputInjector, _ clientId: String) {
        guard inj.awaitFrontmost() else { return fail(o, clientId, .failed) }
        // The wait held this queue up to its bound: an abandon that arrived meanwhile is queued behind it, so the
        // clipboard waits its turn after that one and finds the flag — as after the raise.
        queue.async { [self] in
            guard goesOn(o) else { return }
            d.writePasteboard(content) { ok in
                self.queue.async {
                    guard self.goesOn(o) else { return }
                    guard ok else { return self.fail(o, clientId, .failed) }
                    // Checked AGAIN as it posts (`pasteShortcut`): the clipboard write took time, and a ⌘V into an
                    // application that came to the front meanwhile is the one thing this must never do.
                    guard inj.pasteShortcut() else { return self.fail(o, clientId, .failed) }
                    self.finish(o, clientId, .paste, keep: o.committed.last)
                }
            }
        }
    }
}
