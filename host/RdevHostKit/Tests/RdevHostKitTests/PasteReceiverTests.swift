import CoreGraphics
import ImageIO
import XCTest
import RdevCore
@testable import RdevHostKit

/// The driver's pastes and drops, received and delivered (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md
/// §3–§6) — a real `PasteStore` in a temporary folder, fake destinations that record what they were asked and
/// call back at once, so `drain()` reaches the end of every chain.
final class PasteReceiverTests: XCTestCase {
    final class Fake: @unchecked Sendable {
        var typed: [([String], TermTabID)] = []
        var tabAlive = true
        var pasteboard: [PasteboardContent] = []
        var drops: [(PasteboardContent, CGPoint)] = []
        /// The window each drop was told to land on — a `win:` source's number, nil for a `dsp:` one.
        var dropWindows: [CGWindowID?] = []
        /// The probe each drop was given: whether its delivery has been abandoned since.
        var dropProbes: [() -> Bool] = []
        var dropWorks = true
        /// When set, the pasteboard write and the drop HOLD their completion here instead of calling it —
        /// what a real one does while it is on main.
        var holding = false
        var held: [(Bool) -> Void] = []
        var shortcutCount = 0
        var replies: [[String: String]] = []
        /// Whether the window's application is (or comes to be, within its bound) the FRONT one.
        var frontmost = true
        /// Whether it is STILL the front one when the ⌘V is about to be posted — after the clipboard.
        var frontAtPost = true
        /// The window side's acts, in order: `front?`, `clipboard`, `⌘V`.
        var order: [String] = []
        /// What a SIMULATOR pasted through its own pasteboard.
        var simPasted: [String] = []
    }
    /// A simulator's injector, as a paste sees it: its own pasteboard, and no files.
    final class SimFakeInjector: InputInjector {
        let fake: Fake
        init(_ f: Fake) { fake = f }
        func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {}
        func pasteText(_ text: String) -> Bool? { fake.simPasted.append(text); return true }
        var takesFilePastes: Bool { false }
    }
    final class FakeInjector: InputInjector {
        let fake: Fake
        init(_ f: Fake) { fake = f }
        func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {}
        func scroll(normalizedX: Double, normalizedY: Double, deltaX: Double, deltaY: Double, unit: ScrollUnit, mods: InputModifiers) {}
        func scrollFling(normalizedX: Double, normalizedY: Double, velocityX: Double, velocityY: Double, mods: InputModifiers) {}
        func move(normalizedX: Double, normalizedY: Double) {}
        func key(down: Bool, code: String, key: String, repeat: Bool, mods: InputModifiers) {}
        func releaseKeys() {}
        func raise() {}
        func pasteShortcut() -> Bool {
            guard fake.frontAtPost else { fake.order.append("⌘V refused"); return false }
            fake.shortcutCount += 1; fake.order.append("⌘V")
            return true
        }
        func awaitFrontmost() -> Bool { fake.order.append("front?"); return fake.frontmost }
        func screenPoint(normalizedX: Double, normalizedY: Double) -> CGPoint? { CGPoint(x: normalizedX * 1000, y: normalizedY * 500) }
    }

    private var dir: URL!
    private var fake: Fake!
    private var clock = 0.0
    private var rx: PasteReceiver!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rx-\(UUID().uuidString)")
        fake = Fake()
        rx = receiver(PasteStore(directory: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func receiver(_ store: PasteStore) -> PasteReceiver {
        store.prepareAtLaunch()
        let f = fake!
        return PasteReceiver(store: store, destinations: .init(
            typeIntoTerminal: { text, tab in f.typed.append((text, tab)); return f.tabAlive },
            windowTarget: { $0 == "win:1" || $0 == "dsp:2" ? FakeInjector(f) : $0 == "sim:U" ? SimFakeInjector(f) : nil },
            writePasteboard: { c, done in
                f.pasteboard.append(c); f.order.append("clipboard")
                if f.holding { f.held.append(done) } else { done(true) }
            },
            drop: { c, p, window, cancelled, done in
                f.drops.append((c, p)); f.dropWindows.append(window); f.dropProbes.append(cancelled)
                if f.holding { f.held.append(done) } else { done(f.dropWorks) }
            }),
            reply: { data, _ in f.replies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]) },
            now: { [unowned self] in self.clock })
    }

    private func send(_ id: String, _ to: PasteTarget, _ items: [(PasteItem, Data)], client: String = "c1") {
        rx.begin(PasteBegin(id: id, to: to, items: items.map(\.0)), clientId: client)
        for (i, (_, bytes)) in items.enumerated() {
            var seq = 0
            for off in stride(from: 0, to: bytes.count, by: PasteLimits.chunkBytes) {
                rx.piece(id: id, item: i, seq: seq, bytes: bytes.subdata(in: off..<min(off + PasteLimits.chunkBytes, bytes.count)), clientId: client)
                seq += 1
            }
        }
        rx.end(id: id, clientId: client)
        rx.drain()
    }
    /// `paste-accepted`: the reply to a `paste-begin` that OPENED its delivery — the first word about it.
    private func accepted(_ id: String) -> [String: String] { ["t": "paste-accepted", "id": id] }
    private func savedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }
    private func everything() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    func testFilesForATerminalAreSavedAndTheirPathsTypedIntoThatTab() throws {
        let a = Data(repeating: 1, count: 40_000), b = Data("hi".utf8)
        send("p1", .terminal(.pty(2)), [(.file(name: "a.png", type: "image/png", size: a.count), a),
                                        (.file(name: "b.txt", type: "text/plain", size: b.count), b)])
        XCTAssertEqual(fake.replies.last, ["t": "paste-done", "id": "p1", "how": "paste"])
        XCTAssertEqual(fake.typed.count, 1)
        XCTAssertEqual(fake.typed[0].1, .pty(2))
        let paths = fake.typed[0].0.map { $0.trimmingCharacters(in: .whitespaces) }   // one piece per path
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[0])), a)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[1])), b)
    }

    func testATabGoneByTheEndTypesNothingAndKeepsNothing() {
        fake.tabAlive = false
        send("p1", .terminal(.pty(2)), [(.file(name: "a", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.replies.last, ["t": "paste-error", "id": "p1", "reason": "no-target"])
        XCTAssertEqual(savedFiles(), [])
    }

    /// A SIMULATOR pastes through its OWN pasteboard — never the Mac's clipboard, never a Mac ⌘V
    /// (docs/superpowers/specs/2026-10-13-simulator-sources-design.md).
    func testASimulatorPastesTextThroughItsOwnPasteboard() {
        let text = Data("héllo".utf8)   // 6 bytes: the size a paste declares is BYTES
        send("p9", .window(source: "sim:U", at: nil), [(.text(size: text.count), text)])
        XCTAssertEqual(fake.simPasted, ["héllo"])
        XCTAssertEqual(fake.pasteboard, [], "the Mac's clipboard is untouched")
        XCTAssertEqual(fake.shortcutCount, 0)
        XCTAssertEqual(fake.replies.last?["how"], "paste")
    }

    func testASimulatorTakesNoFiles() {
        send("p10", .window(source: "sim:U", at: nil), [(.file(name: "a.png", type: "image/png", size: 1), Data([1]))])
        XCTAssertEqual(fake.replies.last, ["t": "paste-error", "id": "p10", "reason": "no-target"])
        XCTAssertEqual(fake.simPasted, [])
        XCTAssertEqual(savedFiles(), [])
    }

    func testWindowTextGoesToTheClipboardNeverToDiskThenCommandV() {
        send("p2", .window(source: "win:1", at: nil), [(.text(size: 5), Data("hello".utf8))])
        XCTAssertEqual(fake.pasteboard.first, .text("hello"))
        XCTAssertEqual(fake.pasteboard.count, 1)
        XCTAssertEqual(fake.shortcutCount, 1)
        XCTAssertEqual(savedFiles(), [])
        XCTAssertEqual(fake.replies.last?["how"], "paste")
    }

    /// A KEY GOES TO THE FRONT APPLICATION: ⌘V is posted only once the window's application IS in front — and
    /// the clipboard is not touched before that is known, so a paste that cannot happen changes nothing on the Mac.
    func testTheCommandVWaitsForTheWindowsApplicationToBeInFront() {
        send("p2", .window(source: "win:1", at: nil), [(.text(size: 5), Data("hello".utf8))])
        XCTAssertEqual(fake.order, ["front?", "clipboard", "⌘V"])
        XCTAssertEqual(fake.replies.last?["how"], "paste")
    }

    /// A ⌘V posted while another application is in front pastes into THAT one — what phase 2 of paste-live-check
    /// risked with its token. (Its own failure was the ⌘V's shape — `WindowPasteTests` — the target WAS in front.)
    /// An application that never comes to the front gets NO ⌘V, its clipboard is left alone, the delivery FAILS
    /// and its files go — a drop's fallback included.
    func testAWindowWhoseApplicationNeverComesToTheFrontGetsNoCommandV() {
        fake.frontmost = false
        send("p2", .window(source: "win:1", at: nil), [(.file(name: "a.txt", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.order, ["front?"])
        XCTAssertTrue(fake.pasteboard.isEmpty, "the Mac's clipboard is not touched")
        XCTAssertEqual(fake.shortcutCount, 0)
        XCTAssertEqual(fake.replies.last, ["t": "paste-error", "id": "p2", "reason": "failed"])
        XCTAssertEqual(everything(), [], "its file goes")

        fake.dropWorks = false
        send("p3", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.5)), [(.text(size: 1), Data("x".utf8))])
        XCTAssertEqual(fake.drops.count, 1)
        XCTAssertEqual(fake.shortcutCount, 0, "nor the drop's fallback paste")
        XCTAssertEqual(fake.replies.last, ["t": "paste-error", "id": "p3", "reason": "failed"])
    }

    /// THE FRONT APPLICATION CAN CHANGE DURING THE CLIPBOARD WRITE — an image is decoded to PNG and TIFF and the
    /// write hops to main, hundreds of ms for a large photo — and a ⌘V posted then pastes into whichever app came
    /// to the front. So the ⌘V is checked again AT POST TIME, with no wait: not front any more, NOTHING is
    /// posted, and the delivery FAILS — one reply, its files gone — a drop's fallback included.
    func testAnApplicationThatLeavesTheFrontDuringTheClipboardWriteGetsNoCommandV() {
        fake.frontAtPost = false
        send("p2", .window(source: "win:1", at: nil), [(.file(name: "a.txt", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.order, ["front?", "clipboard", "⌘V refused"])
        XCTAssertEqual(fake.shortcutCount, 0)
        XCTAssertEqual(fake.replies, [accepted("p2"), ["t": "paste-error", "id": "p2", "reason": "failed"]], "exactly one answer")
        XCTAssertEqual(everything(), [], "its file goes")

        fake.dropWorks = false
        send("p3", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.5)), [(.text(size: 1), Data("x".utf8))])
        XCTAssertEqual(fake.shortcutCount, 0, "nor the drop's fallback")
        XCTAssertEqual(fake.replies.last, ["t": "paste-error", "id": "p3", "reason": "failed"])
        XCTAssertEqual(fake.replies.count, 4, "each accepted, then answered once")
    }

    func testADropLandsAtThePointAndFallsBackToAPasteWhenItCannot() {
        send("p3", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.2)), [(.file(name: "a", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.drops.first?.1, CGPoint(x: 500, y: 100))
        XCTAssertEqual(fake.replies.last?["how"], "drop")
        fake.dropWorks = false
        send("p4", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.2)), [(.file(name: "a", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.replies.last?["how"], "paste")
        XCTAssertEqual(fake.shortcutCount, 1)
    }

    /// The drop is told which window it must land on: a `win:` source's number, and NONE for a display —
    /// whatever is under the point there is what its picture shows.
    func testADropIsToldItsTargetWindowAndADisplayHasNone() {
        send("p3", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.2)), [(.text(size: 1), Data("x".utf8))])
        send("p4", .window(source: "dsp:2", at: PastePoint(x: 0.5, y: 0.2)), [(.text(size: 1), Data("x".utf8))])
        XCTAssertEqual(fake.dropWindows, [1, nil])
        XCTAssertEqual(fake.replies, [accepted("p3"), ["t": "paste-done", "id": "p3", "how": "drop"],
                                      accepted("p4"), ["t": "paste-done", "id": "p4", "how": "drop"]])
    }

    // MARK: past `paste-end` — a delivery under way is still the client's, until it is answered

    /// A change of driver (or a departure, or a rebuild) abandons a delivery that is ALREADY being delivered —
    /// here, while its clipboard write is on main: no ⌘V, no `paste-done`, its files deleted, and the client
    /// that lost control is told `not-driver` as for one still arriving.
    func testLosingControlDuringTheClipboardWriteStopsTheCommandV() {
        fake.holding = true
        send("p1", .window(source: "win:1", at: nil), [(.file(name: "a.txt", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.held.count, 1, "the clipboard write is under way")
        XCTAssertEqual(savedFiles().count, 1)
        rx.abandon(clientId: "c1", reply: .notDriver); rx.drain()
        fake.held.removeFirst()(true); rx.drain()
        XCTAssertEqual(fake.shortcutCount, 0, "no ⌘V into the new driver's session")
        XCTAssertEqual(fake.replies, [accepted("p1"), ["t": "paste-error", "id": "p1", "reason": "not-driver"]])
        XCTAssertEqual(everything(), [], "its files go with it")
    }

    /// The same while the DROP is under way, and it fails: its fallback is a paste, which must not happen
    /// either — nothing more is posted, nothing is said (a departure has nobody to tell), the files go.
    func testLeavingDuringAFailedDropStopsItsFallbackPaste() {
        fake.holding = true
        send("p1", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.5)), [(.file(name: "a.txt", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.drops.count, 1)
        rx.abandon(clientId: "c1", reply: nil); rx.drain()
        fake.held.removeFirst()(false); rx.drain()
        XCTAssertTrue(fake.pasteboard.isEmpty, "the fallback never began")
        XCTAssertEqual(fake.shortcutCount, 0)
        XCTAssertEqual(fake.replies, [accepted("p1")], "nothing after its acceptance")
        XCTAssertEqual(everything(), [])
    }

    /// A DROP CANNOT BE CALLED BACK ONCE IT PRESSES — but until then it can: before its mouse-down (on main,
    /// after a lead) it asks the probe it was given, which an abandon or the client's own cancel turns true.
    /// The drop then answers false having posted nothing, and the delivery, cancelled, pastes nothing.
    func testADropAsksWhetherItsDeliveryWasAbandonedBeforeItPresses() {
        fake.holding = true
        send("p1", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.5)), [(.file(name: "a.txt", type: "", size: 1), Data([1]))])
        let probe = fake.dropProbes[0]
        XCTAssertFalse(probe(), "nothing has abandoned it yet")
        rx.abandon(clientId: "c1", reply: .notDriver); rx.drain()
        XCTAssertTrue(probe(), "the drop, on main, sees the abandon")
        fake.held.removeFirst()(false); rx.drain()
        XCTAssertTrue(fake.pasteboard.isEmpty)
        XCTAssertEqual(fake.replies, [accepted("p1"), ["t": "paste-error", "id": "p1", "reason": "not-driver"]])
        XCTAssertEqual(everything(), [])

        send("p2", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.5)), [(.text(size: 1), Data("x".utf8))])
        rx.cancel(id: "p2", clientId: "c1"); rx.drain()
        XCTAssertTrue(fake.dropProbes[1](), "the client's own cancel too")
        fake.held.removeFirst()(false); rx.drain()
        XCTAssertTrue(fake.pasteboard.isEmpty)
        XCTAssertEqual(fake.replies, [accepted("p1"), ["t": "paste-error", "id": "p1", "reason": "not-driver"], accepted("p2")],
                       "a cancelled delivery is not answered")
    }

    /// A drop that LANDED before the abandon reached it has happened: nothing can call it back. It is not
    /// answered (the client was told `not-driver`) — and its files STAY, because the app it landed on may
    /// still be reading them (Finder copies after the drop returns); the sweep takes them later.
    func testADropThatLandedBeforeTheAbandonKeepsItsFilesAndIsNotAnswered() {
        fake.holding = true
        send("p1", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.5)), [(.file(name: "a.txt", type: "", size: 1), Data([1]))])
        rx.abandon(clientId: "c1", reply: .notDriver); rx.drain()
        fake.held.removeFirst()(true); rx.drain()
        XCTAssertEqual(fake.replies, [accepted("p1"), ["t": "paste-error", "id": "p1", "reason": "not-driver"]])
        XCTAssertEqual(savedFiles().count, 1)
    }

    /// AN ABANDON THAT ARRIVES WHILE THE TARGET IS BEING RAISED (AX can take a second) is honoured before the
    /// clipboard or the drop is touched: the raise is the delivery's first act, and the next waits its turn.
    func testAnAbandonQueuedDuringTheRaiseStopsTheDeliveryBeforeItStarts() {
        let f = fake!
        var rxRef: PasteReceiver?
        let store = PasteStore(directory: dir)
        store.prepareAtLaunch()
        final class RaisingInjector: InputInjector {
            let onRaise: () -> Void
            init(_ r: @escaping () -> Void) { onRaise = r }
            func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {}
            func raise() { onRaise() }
            func screenPoint(normalizedX: Double, normalizedY: Double) -> CGPoint? { CGPoint(x: 1, y: 1) }
        }
        rx = PasteReceiver(store: store, destinations: .init(
            typeIntoTerminal: { _, _ in true },
            windowTarget: { _ in RaisingInjector { rxRef?.abandon(clientId: "c1", reply: .notDriver) } },
            writePasteboard: { c, done in f.pasteboard.append(c); done(true) },
            drop: { c, p, w, _, done in f.drops.append((c, p)); f.dropWindows.append(w); done(true) }),
            reply: { data, _ in f.replies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]) })
        rxRef = rx
        send("p1", .window(source: "win:1", at: PastePoint(x: 0.5, y: 0.5)), [(.file(name: "a.txt", type: "", size: 1), Data([1]))])
        send("p2", .window(source: "win:1", at: nil), [(.text(size: 1), Data("x".utf8))])
        XCTAssertTrue(f.drops.isEmpty, "the drop never started")
        XCTAssertTrue(f.pasteboard.isEmpty, "nor the clipboard")
        XCTAssertEqual(f.replies, [accepted("p1"), ["t": "paste-error", "id": "p1", "reason": "not-driver"],
                                   accepted("p2"), ["t": "paste-error", "id": "p2", "reason": "not-driver"]])
        XCTAssertEqual(everything(), [])
    }

    /// The session's end reaches a delivery under way as well: quitting posts no ⌘V after it.
    func testTheSessionsEndStopsADeliveryUnderWay() {
        fake.holding = true
        send("p1", .window(source: "win:1", at: nil), [(.text(size: 1), Data("x".utf8))])
        rx.abandonAll()
        fake.held.removeFirst()(true); rx.drain()
        XCTAssertEqual(fake.shortcutCount, 0)
        XCTAssertEqual(fake.replies, [accepted("p1")], "nothing after its acceptance")
    }

    /// THE MAC ACKNOWLEDGES A DELIVERY'S START (2026-10-02): a `paste-begin` that OPENS a delivery is answered
    /// `paste-accepted` at once, before any piece arrives — the client sends none until it has it, so a Mac that
    /// never answers (an older Xpromptvs ignored `paste-*`) costs no upload. Exactly once, and FIRST: the
    /// delivery's own answer comes after it.
    func testAnOpenedDeliveryIsAcceptedFirstAndOnce() {
        rx.begin(PasteBegin(id: "p1", to: .terminal(.pty(1)), items: [.file(name: "a", type: "", size: 3)]), clientId: "c1")
        rx.drain()
        XCTAssertEqual(fake.replies, [accepted("p1")], "answered before any piece")
        rx.piece(id: "p1", item: 0, seq: 0, bytes: Data([1, 2, 3]), clientId: "c1")
        rx.end(id: "p1", clientId: "c1"); rx.drain()
        XCTAssertEqual(fake.replies, [accepted("p1"), ["t": "paste-done", "id": "p1", "how": "paste"]])
    }

    /// A REFUSED begin opens nothing and is not accepted: `busy` and `too-large` get their error ALONE — the client
    /// takes the error as the answer it was waiting for and sends no piece.
    func testARefusedBeginGetsItsErrorAndNoAcceptance() {
        rx.begin(PasteBegin(id: "a", to: .terminal(.pty(1)), items: [.file(name: "a", type: "", size: 10)]), clientId: "c1")
        rx.begin(PasteBegin(id: "b", to: .terminal(.pty(1)), items: [.file(name: "b", type: "", size: 10)]), clientId: "c1")
        rx.begin(PasteBegin(id: "c", to: .terminal(.pty(1)), items: [.file(name: "c", type: "", size: PasteLimits.fileMaxBytes + 1)]), clientId: "c2")
        rx.drain()
        XCTAssertEqual(fake.replies, [accepted("a"), ["t": "paste-error", "id": "b", "reason": "busy"],
                                      ["t": "paste-error", "id": "c", "reason": "too-large"]])
    }

    /// ONE DELIVERY AT A TIME, until it is ANSWERED: a `paste-begin` while one is still being delivered is
    /// `busy`. A `paste-cancel` reaches it too — the client's uploader cancels a delivery it has ended and
    /// moves on to its next, which must not find itself `busy` behind it.
    func testADeliveryUnderWayIsBusyUntilAnsweredAndACancelReachesIt() {
        fake.holding = true
        send("p1", .window(source: "win:1", at: nil), [(.text(size: 1), Data("x".utf8))])
        rx.begin(PasteBegin(id: "p2", to: .terminal(.pty(1)), items: [.file(name: "b", type: "", size: 1)]), clientId: "c1")
        rx.drain()
        XCTAssertEqual(fake.replies, [accepted("p1"), ["t": "paste-error", "id": "p2", "reason": "busy"]], "a busy begin is not accepted")
        rx.cancel(id: "p1", clientId: "c1")
        fake.holding = false
        send("p3", .terminal(.pty(1)), [(.file(name: "c", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.replies.last, ["t": "paste-done", "id": "p3", "how": "paste"])
        fake.held.removeFirst()(true); rx.drain()
        XCTAssertEqual(fake.shortcutCount, 0, "the cancelled one never pastes")
        XCTAssertEqual(fake.replies, [accepted("p1"), ["t": "paste-error", "id": "p2", "reason": "busy"],
                                      accepted("p3"), ["t": "paste-done", "id": "p3", "how": "paste"]], "and is never answered")
    }

    func testAWindowNotInTheSessionIsNoTarget() {
        send("p5", .window(source: "win:9", at: nil), [(.file(name: "a", type: "", size: 1), Data([1]))])
        XCTAssertEqual(fake.replies.last?["reason"], "no-target")
        XCTAssertEqual(savedFiles(), [])
    }

    func testOneDeliveryAtATimeTooLargeAndMalformed() {
        rx.begin(PasteBegin(id: "a", to: .terminal(.pty(1)), items: [.file(name: "a", type: "", size: 10)]), clientId: "c1")
        rx.begin(PasteBegin(id: "b", to: .terminal(.pty(1)), items: [.file(name: "b", type: "", size: 10)]), clientId: "c1")
        rx.begin(PasteBegin(id: "c", to: .terminal(.pty(1)), items: [.file(name: "c", type: "", size: PasteLimits.fileMaxBytes + 1)]), clientId: "c2")
        rx.piece(id: "a", item: 0, seq: 1, bytes: Data([1]), clientId: "c1")          // a gap
        rx.drain()
        XCTAssertEqual(fake.replies.map { $0["id"]! + ":" + ($0["reason"] ?? $0["t"]!) },
                       ["a:paste-accepted", "b:busy", "c:too-large", "a:malformed"])
        XCTAssertEqual(everything(), [], "the partial is gone too")
    }

    func testLosingControlAbandonsAndDeletesAndAnEndForAnUnknownIdIsFailed() {
        rx.begin(PasteBegin(id: "a", to: .terminal(.pty(1)), items: [.file(name: "a", type: "", size: 10)]), clientId: "c1")
        rx.piece(id: "a", item: 0, seq: 0, bytes: Data([1, 2]), clientId: "c1")
        rx.abandon(clientId: "c1", reply: .notDriver)
        rx.end(id: "a", clientId: "c1")
        rx.drain()
        XCTAssertEqual(fake.replies, [accepted("a"), ["t": "paste-error", "id": "a", "reason": "not-driver"],
                                      ["t": "paste-error", "id": "a", "reason": "failed"]])
        XCTAssertTrue(fake.typed.isEmpty)
        XCTAssertEqual(everything(), [])
    }

    func testThirtySecondsOfSilenceIsAbandoned() {
        rx.begin(PasteBegin(id: "a", to: .terminal(.pty(1)), items: [.file(name: "a", type: "", size: 10)]), clientId: "c1")
        rx.drain()
        clock = 29
        rx.piece(id: "a", item: 0, seq: 0, bytes: Data([1]), clientId: "c1")
        rx.drain()                       // the clock is read when the piece RUNS on the paste queue
        clock = 58
        rx.checkStalls(); rx.drain()
        XCTAssertEqual(fake.replies, [accepted("a")], "29 s since the last piece is not a stall")
        clock = 60
        rx.checkStalls(); rx.drain()
        XCTAssertEqual(fake.replies.last, ["t": "paste-error", "id": "a", "reason": "failed"])
        XCTAssertEqual(everything(), [], "its partial goes with it")
    }

    func testCancelReplyless() {
        rx.begin(PasteBegin(id: "a", to: .terminal(.pty(1)), items: [.file(name: "a", type: "", size: 10)]), clientId: "c1")
        rx.cancel(id: "a", clientId: "c1"); rx.drain()
        XCTAssertEqual(fake.replies, [accepted("a")], "the cancel itself is not answered")
        rx.begin(PasteBegin(id: "b", to: .terminal(.pty(1)), items: [.file(name: "b", type: "", size: 1)]), clientId: "c1")
        rx.piece(id: "b", item: 0, seq: 0, bytes: Data([1]), clientId: "c1"); rx.end(id: "b", clientId: "c1"); rx.drain()
        XCTAssertEqual(fake.replies.last?["t"], "paste-done", "a cancel frees the client for its next delivery")
    }

    /// A LEAVING client is told nothing (`reply: nil`), and the session's end abandons every client's delivery
    /// at once, waiting for it, so the folder can be emptied behind it.
    func testLeavingAndTheSessionsEndAbandonInSilence() {
        rx.begin(PasteBegin(id: "a", to: .terminal(.pty(1)), items: [.file(name: "a", type: "", size: 10)]), clientId: "c1")
        rx.piece(id: "a", item: 0, seq: 0, bytes: Data([1]), clientId: "c1")
        rx.abandon(clientId: "c1", reply: nil)
        rx.drain()
        XCTAssertEqual(fake.replies, [accepted("a")], "nothing after its acceptance")
        XCTAssertEqual(everything(), [])
        for c in ["c1", "c2"] {
            rx.begin(PasteBegin(id: "b", to: .terminal(.pty(1)), items: [.file(name: "b", type: "", size: 10)]), clientId: c)
            rx.piece(id: "b", item: 0, seq: 0, bytes: Data([1]), clientId: c)
        }
        rx.abandonAll()
        XCTAssertEqual(everything(), [], "abandonAll waits: nothing is left for the folder's emptying to race")
        XCTAssertEqual(fake.replies, [accepted("a"), accepted("b"), accepted("b")], "nothing after the acceptances")
    }

    /// A commit that fails leaves its `.partial` — the abandon must discard EVERY file still open, the one that
    /// failed included. The final name is made unusable after the partial was opened.
    func testAFailedCommitIsADiskErrorAndLeavesNoPartial() throws {
        rx.begin(PasteBegin(id: "a", to: .terminal(.pty(1)), items: [.file(name: "a.txt", type: "", size: 2)]), clientId: "c1")
        rx.piece(id: "a", item: 0, seq: 0, bytes: Data([1, 2]), clientId: "c1")
        rx.drain()
        let partial = try XCTUnwrap(everything().first { $0.hasSuffix(".partial") })
        let finalName = String(partial.dropFirst().dropLast(".partial".count))
        let blocker = dir.appendingPathComponent(finalName)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        try Data([9]).write(to: blocker.appendingPathComponent("x"))
        rx.end(id: "a", clientId: "c1"); rx.drain()
        XCTAssertEqual(fake.replies.last, ["t": "paste-error", "id": "a", "reason": "disk"])
        XCTAssertEqual(everything(), [finalName], "the partial is gone; only the blocker is left")
        XCTAssertTrue(fake.typed.isEmpty)
    }

    /// §4.1: a HEIC for a TERMINAL is typed as a JPEG beside it (Claude cannot read HEIC), the HEIC removed;
    /// a WINDOW gets the original (macOS apps read it).
    func testAHEICForATerminalIsTypedAsAJPEGAndAWindowGetsTheOriginal() throws {
        let heic = try heicBytes()
        send("h1", .terminal(.pty(1)), [(.file(name: "IMG_1.heic", type: "image/heic", size: heic.count), heic)])
        XCTAssertEqual(fake.replies.last?["t"], "paste-done")
        let typed = try XCTUnwrap(fake.typed.last?.0.first).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(typed.hasSuffix(".jpg"), typed)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: typed) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, "public.jpeg")
        // §6: EVERY file in the folder is 0600 — this one too, though ImageIO made it (with the umask's 0644).
        let mode = try FileManager.default.attributesOfItem(atPath: typed)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(savedFiles(), [URL(fileURLWithPath: typed).lastPathComponent], "the HEIC is gone")

        send("h2", .window(source: "win:1", at: nil), [(.file(name: "IMG_1.heic", type: "image/heic", size: heic.count), heic)])
        guard case .files(let urls) = try XCTUnwrap(fake.pasteboard.last) else { return XCTFail("not files") }
        XCTAssertEqual(urls.map(\.pathExtension), ["heic"])
        XCTAssertEqual(try Data(contentsOf: urls[0]), heic)
    }

    /// The JPEG never takes a name already in use: with `<stem>.jpg` taken, the HEIC's JPEG is `<stem>-2.jpg`
    /// and the file already there is untouched (`PasteStore.sibling`).
    func testAHEICsJPEGNeverOverwritesAFileOfThatName() throws {
        let heic = try heicBytes()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        rx = receiver(PasteStore(directory: dir, now: { at }))
        let taken = PasteNames.savedName(original: "IMG_1.jpg", type: "", at: at) { _ in false }
        try Data("mine".utf8).write(to: dir.appendingPathComponent(taken))
        send("h1", .terminal(.pty(1)), [(.file(name: "IMG_1.heic", type: "image/heic", size: heic.count), heic)])
        let typed = try XCTUnwrap(fake.typed.last?.0.first).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(URL(fileURLWithPath: typed).lastPathComponent,
                       String(taken.dropLast(".jpg".count)) + "-2.jpg")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(taken)), Data("mine".utf8))
    }

    /// A 2×2 HEIC made with ImageIO, so the test needs no fixture file.
    private func heicBytes() throws -> Data {
        let out = NSMutableData()
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("this Mac cannot encode HEIC") }
        return out as Data
    }
}
