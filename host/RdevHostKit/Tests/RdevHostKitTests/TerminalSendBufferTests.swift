import XCTest
import RdevCore
@testable import RdevHostKit

/// A clock and a scheduler the test drives: nothing fires until `advance`, and it fires on the
/// advancing thread. Counts the timers ever armed and those still outstanding.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: UInt64 = 1_000_000_000_000
    private var timers: [(due: UInt64, seq: Int, work: @Sendable () -> Void)] = []
    private var seq = 0
    private(set) var armed = 0

    var now: UInt64 { lock.lock(); defer { lock.unlock() }; return t }
    var outstanding: Int { lock.lock(); defer { lock.unlock() }; return timers.count }

    func schedule(after: UInt64, _ work: @escaping @Sendable () -> Void) {
        lock.lock(); timers.append((t + after, seq, work)); seq += 1; armed += 1; lock.unlock()
    }

    /// Move time forward, running every timer that falls due (in due order, including any a timer arms).
    func advance(by d: UInt64) {
        lock.lock(); let target = t + d; lock.unlock()
        while true {
            lock.lock()
            guard let i = timers.indices.filter({ timers[$0].due <= target })
                    .min(by: { (timers[$0].due, timers[$0].seq) < (timers[$1].due, timers[$1].seq) }) else {
                t = target; lock.unlock(); return
            }
            let item = timers.remove(at: i)
            t = max(t, item.due)
            lock.unlock()
            item.work()
        }
    }
}

/// The host-side terminal SEND BUFFER through the REAL `TerminalManager` (docs/terminal.md, "The send
/// buffer"): a `pty:` tab with no shell behind it (`openDetachedForTests`), fed bytes on its serial
/// path exactly as the pty's reader would (`feedForTests`), against a clock the test drives.
final class TerminalSendBufferTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private var clock = ManualClock()
    private var rec = EmissionRecorder()
    private var answers: [[UInt8]] = []
    private let answersLock = NSLock()

    private func manager(emit: ((TermEmission) -> Bool)? = nil) -> TerminalManager {
        clock = ManualClock()
        rec = EmissionRecorder()
        answersLock.lock(); answers = []; answersLock.unlock()
        let c = clock
        let tm = TerminalManager(cols: 80, rows: 24, clock: { c.now }, schedule: { c.schedule(after: $0, $1) })
        tm.onEmit = emit ?? rec.record
        tm.hostAnswerForTests = { [weak self] _, b in
            guard let self else { return }
            self.answersLock.lock(); self.answers.append(b); self.answersLock.unlock()
        }
        return tm
    }
    private var hostAnswers: [[UInt8]] { answersLock.lock(); defer { answersLock.unlock() }; return answers }

    private func outputs(_ id: TermTabID, since: Int = 0) -> [[UInt8]] {
        rec.all.dropFirst(since).compactMap { if case .output(id, let b) = $0 { return b }; return nil }
    }
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func kinds(since: Int) -> [String] {
        rec.all.dropFirst(since).map {
            switch $0 {
            case .output(_, let b): return "output:\(String(decoding: b, as: UTF8.self))"
            case .snapshot: return "snapshot"
            case .screen: return "screen"
            case .history: return "history"
            case .closed: return "closed"
            }
        }
    }

    /// A live tab with its snapshot emitted: what the driver's wire already holds.
    private func liveTab(_ tm: TerminalManager) throws -> TermTabID {
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        XCTAssertEqual(rec.snapshots(of: id).count, 1, "opening emits the snapshot")
        return id
    }

    func testSmallWritesInsideTheHoldBecomeOneMessage() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        for i in 0..<20 { tm.feedForTests(id, b("line \(i)\r\n")) }
        XCTAssertEqual(outputs(id, since: mark), [], "held")
        XCTAssertEqual(clock.outstanding, 1, "one timer for the tab, not one per write")
        clock.advance(by: TermSendBuffer.hold - 1)
        XCTAssertEqual(outputs(id, since: mark), [], "still held just before the hold is up")
        clock.advance(by: 1)
        XCTAssertEqual(outputs(id, since: mark), [b((0..<20).map { "line \($0)\r\n" }.joined())], "ONE message, in order")
        XCTAssertEqual(clock.outstanding, 0)
    }

    func testTheCapSendsAtOnce() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        let chunk = [UInt8](repeating: 0x41, count: 1024)
        let n = TermSendBuffer.cap / 1024
        for _ in 0..<(n - 1) { tm.feedForTests(id, chunk) }
        XCTAssertEqual(outputs(id, since: mark).count, 0)
        tm.feedForTests(id, chunk)
        XCTAssertEqual(outputs(id, since: mark).map(\.count), [n * 1024], "the cap sends without waiting for the timer")
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(outputs(id, since: mark).count, 1, "the spent timer sends nothing")
    }

    func testInputToTheTabSendsItsOutputAtOnceUntilTheWindowPasses() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        tm.write(Data("x".utf8), toTerminal: id)                              // a keystroke (mouse/wheel ride the same message)
        tm.feedForTests(id, b("x"))
        XCTAssertEqual(outputs(id, since: mark), [b("x")], "the echo pays nothing")
        clock.advance(by: TermSendBuffer.inputWindow - 1)
        tm.feedForTests(id, b("y"))
        XCTAssertEqual(outputs(id, since: mark), [b("x"), b("y")], "still inside the window")
        clock.advance(by: 1)
        tm.feedForTests(id, b("z"))
        XCTAssertEqual(outputs(id, since: mark), [b("x"), b("y")], "the window has passed: held")
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(outputs(id, since: mark), [b("x"), b("y"), b("z")])
    }

    /// Input is PER TAB: a keystroke to one tab does not unhold another's output.
    func testInputToAnotherTabDoesNotUnholdThisOne() throws {
        let tm = manager()
        let one = try liveTab(tm)
        let two = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))   // active
        let mark = rec.count
        tm.write(Data("k".utf8), toTerminal: two)
        tm.feedForTests(one, b("background"))
        XCTAssertEqual(outputs(one, since: mark), [], "held")
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(outputs(one, since: mark), [b("background")])
    }

    /// A snapshot is a BOUNDARY: the held bytes go out first, so the stream between two snapshots is
    /// exactly what was fed between them — and nothing of it follows the snapshot.
    func testASnapshotFlushesTheHeldBytesAheadOfIt() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        tm.feedForTests(id, b("held"))
        tm.snapshot(id)
        XCTAssertEqual(kinds(since: mark), ["output:held", "snapshot"])
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(kinds(since: mark), ["output:held", "snapshot"], "the timer finds nothing")
    }

    func testClosingFlushesTheHeldBytesAndTheTimerSendsNothingAfterIt() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        tm.feedForTests(id, b("last words"))
        XCTAssertTrue(tm.close(id))
        XCTAssertEqual(kinds(since: mark), ["output:last words", "closed"])
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(kinds(since: mark), ["output:last words", "closed"], "nothing after closed")
    }

    /// A pause DROPS the held bytes: the resume re-serializes the tab, and that snapshot has them.
    func testAPauseDropsTheHeldBytesAndTheResumeSnapshotCarriesThem() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        tm.feedForTests(id, b("HIDDENMARK"))
        tm.pauseForwarding()
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(kinds(since: mark), [], "nothing is sent once the pause applies")
        tm.resumeForwarding()
        XCTAssertEqual(kinds(since: mark), ["snapshot"])
        XCTAssertTrue(String(decoding: rec.snapshots(of: id, since: mark)[0].bytes, as: UTF8.self).contains("HIDDENMARK"))
    }

    /// A NEW WIRE drops the held bytes: they were meant for the old wire's context, and the new wire's
    /// snapshot has them. Nothing of them may follow the new wire's snapshot.
    func testANewWireDropsTheHeldBytesAndNothingOfThemFollowsItsSnapshot() throws {
        let tm = manager(); let id = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
        let mark = rec.count
        tm.feedForTests(id, b("OLDWIRE"))
        tm.setDriverDecodesWire(true, generation: 2)                           // the rebind
        clock.advance(by: TermSendBuffer.hold / 2)
        tm.snapshot(id)                                                        // the binder's snapshotAll
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(kinds(since: mark), ["snapshot"], "the old wire's bytes are neither sent nor duplicated")
        XCTAssertTrue(String(decoding: rec.snapshots(of: id, since: mark)[0].bytes, as: UTF8.self).contains("OLDWIRE"))
        tm.feedForTests(id, b("new"))
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(kinds(since: mark), ["snapshot", "output:new"], "and the tab streams on the new wire")
    }

    /// A resize FLUSHES: the bytes were written at the old size and must precede the redraw's. Then it
    /// RE-SENDS the tab at the new size (docs/terminal.md, "A RESIZE RE-SENDS EVERY TAB"), and the tab
    /// streams on from there.
    func testAResizeFlushesTheHeldBytes() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        tm.feedForTests(id, b("before resize"))
        tm.resizeAll(cols: 100, rows: 30)
        XCTAssertEqual(kinds(since: mark), ["output:before resize", "snapshot"])
        XCTAssertEqual(rec.snapshots(of: id, since: mark).first?.size, TermGridSize(cols: 100, rows: 30),
                       "the snapshot is the tab at its NEW size")
        tm.feedForTests(id, b("after"))
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(kinds(since: mark), ["output:before resize", "snapshot", "output:after"])
    }

    /// Only a CHANGE re-sends: the driver reports its grid on every fit, and the same grid again must
    /// cost nothing.
    func testAnUnchangedResizeSendsNothing() throws {
        let tm = manager(); _ = try liveTab(tm)
        let mark = rec.count
        tm.resizeAll(cols: 80, rows: 24)
        XCTAssertEqual(kinds(since: mark), [])
    }

    /// Every timer flush is made ON the tab's serial path — the probe from
    /// `testSnapshotAndLiveOutputComposeToTheHostScreen`, on the one path that test barely reaches
    /// (its output mostly falls inside the input window).
    func testATimerFlushIsMadeOnTheSerialPath() throws {
        var tmRef: TerminalManager?
        let probe = NSLock(); var on = 0, off = 0
        let r = EmissionRecorder()
        let tm = manager(emit: { e in
            if case .output(let id, _) = e, let tm = tmRef {
                let held = tm.serialIsHeld(id)
                probe.lock(); if held { on += 1 } else { off += 1 }; probe.unlock()
            }
            return r.record(e)
        })
        tmRef = tm
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        for i in 0..<5 {
            tm.feedForTests(id, b("burst \(i)"))
            clock.advance(by: TermSendBuffer.hold)
        }
        probe.lock(); defer { probe.unlock() }
        XCTAssertEqual(on, 5, "every burst flushed by its timer")
        XCTAssertEqual(off, 0, "a timer flush emitted OFF the tab's serial path")
    }

    // MARK: device queries — exactly one answer with held bytes

    /// The active tab's query whose bytes the driver's xterm.js is to answer is NEVER held: the held
    /// bytes and the query go out at once, and the host decides from that emission's real result.
    func testAQueryTheDriverAnswersIsSentAtOnceAndTheHostStaysSilent() throws {
        let tm = manager(); let id = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
        let mark = rec.count
        tm.feedForTests(id, b("held "))
        tm.feedForTests(id, b("\u{1b}[5n"))                                    // DSR 5n
        XCTAssertEqual(outputs(id, since: mark), [b("held \u{1b}[5n")], "sent at once, the held bytes ahead of it")
        XCTAssertEqual(hostAnswers, [], "the driver's xterm.js answers it")
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(outputs(id, since: mark).count, 1)
    }

    /// A query SPLIT across reads: its first half is held; the read that completes it sends both.
    func testASplitQueryIsSentWholeAtOnce() throws {
        let tm = manager(); let id = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
        let mark = rec.count
        tm.feedForTests(id, b("\u{1b}["))
        XCTAssertEqual(outputs(id, since: mark), [])
        tm.feedForTests(id, b("5n"))
        XCTAssertEqual(outputs(id, since: mark), [b("\u{1b}[5n")])
        XCTAssertEqual(hostAnswers, [])
    }

    /// The same query, but the emission reaches no context (the wire has no snapshot of the tab): the
    /// host answers — once — because it asked the wire, not because it assumed.
    func testAQueryWhoseEmissionDidNotReachTheDriverIsAnsweredByTheHost() throws {
        var reach = true
        let tm = manager(emit: { [unowned self] e in _ = self.rec.record(e); return reach })
        let id = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
        reach = false
        tm.feedForTests(id, b("\u{1b}[5n"))
        XCTAssertEqual(hostAnswers, [b("\u{1b}[0n")])
    }

    /// A BACKGROUND tab's query that reached the driver is the CLIENT's to answer too — its instance is
    /// live, and the host cannot know whether the client is showing it (a switch in flight). The host
    /// stays silent, and the bytes are still NOT held: a query leaves exactly when it did before the
    /// send buffer.
    func testABackgroundTabsQueryThatReachedTheDriverIsTheClientsAndItsBytesAreNotHeld() throws {
        let tm = manager()
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))        // active
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        let mark = rec.count
        tm.feedForTests(one, b("held "))
        tm.feedForTests(one, b("\u{1b}[5n"))
        XCTAssertEqual(hostAnswers, [], "the client's instance of the tab answers it")
        XCTAssertEqual(outputs(one, since: mark), [b("held \u{1b}[5n")], "sent at once, the held bytes ahead of it")
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(outputs(one, since: mark).count, 1)
        XCTAssertEqual(hostAnswers, [])
    }

    // MARK: exactly one answer while the client's visible tab and the host's active tab differ

    private var delivered: [(TermTabID, [UInt8])] = []
    private func deliveries(_ tm: TerminalManager) {
        delivered = []
        tm.ptyInputForTests = { [weak self] id, b in
            guard let self else { return }
            self.answersLock.lock(); self.delivered.append((id, b)); self.answersLock.unlock()
        }
    }
    private func deliveredTo(_ id: TermTabID) -> [[UInt8]] {
        answersLock.lock(); defer { answersLock.unlock() }
        return delivered.filter { $0.0 == id }.map(\.1)
    }

    /// Window (a): the user switched the client to `one` and the host has not processed
    /// `switch-terminal` yet — `two` is still its active tab. A query in `one`'s bytes (the tab on the
    /// user's screen) was answered by the host AND by the client's instance once the switch landed
    /// ahead of the reply; a query in `two`'s bytes (hidden on the client) by neither. Now the host
    /// answers neither and the client's instance of each tab answers its own, as a `term-reply` naming
    /// it, which reaches that tab whichever way the switch lands — once.
    func testAUserSwitchTheHostHasNotAppliedGetsExactlyOneAnswerPerQuery() throws {
        for switchLandsFirst in [false, true] {
            let tm = manager(); deliveries(tm)
            let one = try liveTab(tm)
            let two = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))   // host: active
            tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
            tm.feedForTests(one, b("\u{1b}[5n"))                              // on the user's screen
            tm.feedForTests(two, b("\u{1b}[6n"))                              // hidden on the client
            XCTAssertEqual(hostAnswers, [], "both reached the client: the host answers neither")
            if switchLandsFirst { XCTAssertTrue(tm.switchTo(one)) }
            tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
            tm.writeReply(Data("\u{1b}[1;1R".utf8), toTerminal: two)
            if !switchLandsFirst { XCTAssertTrue(tm.switchTo(one)) }
            XCTAssertEqual(deliveredTo(one), [b("\u{1b}[0n")], "switch first: \(switchLandsFirst)")
            XCTAssertEqual(deliveredTo(two), [b("\u{1b}[1;1R")], "switch first: \(switchLandsFirst)")
            // A second reply was never owed: the tab that is not active refuses it, as a keystroke.
            tm.writeReply(Data("\u{1b}[1;1R".utf8), toTerminal: two)
            XCTAssertEqual(deliveredTo(two).count, 1, "never two answers")
        }
    }

    /// Window (b): the HOST opened a tab (it is active there at once) and the client still shows the
    /// old one until the `term-list` arrives. The new tab's query is answered by its (hidden) client
    /// instance, the old tab's by the one the user sees — once each; the host answers neither.
    func testAHostOpenedTabBeforeItsTermListGetsExactlyOneAnswerPerQuery() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(one)
        let two = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))   // the host opened it: active
        tm.feedForTests(two, b("\u{1b}[c"))
        tm.feedForTests(one, b("\u{1b}[5n"))
        XCTAssertEqual(hostAnswers, [])
        tm.writeReply(Data("\u{1b}[?1;2c".utf8), toTerminal: two)
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(two), [b("\u{1b}[?1;2c")])
        XCTAssertEqual(deliveredTo(one), [b("\u{1b}[0n")])
    }

    /// The keystroke rule is untouched: a KEY naming a tab the host is not on is dropped, even while that
    /// tab is owed a reply. Only a `term-reply` spends what is owed.
    func testTypingIntoATabThatIsNotActiveIsDroppedEvenWhileItIsOwedAReply() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        let two = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}[5n"))
        tm.write(Data("secret\r".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [], "typing aimed at a tab the host is not on is refused")
        tm.write(Data("ls\r".utf8), toTerminal: two)
        XCTAssertEqual(deliveredTo(two), [b("ls\r")])
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [b("\u{1b}[0n")], "the owed reply still arrives")
    }

    // MARK: queries the client's xterm.js does NOT answer are the host's, for every tab (fix round I1)

    /// CSI 18 t (report the grid): this product's xterm.js answers no window op (no `windowOptions`), so
    /// the HOST answers it — for a background tab whose bytes reached the client, where the host used to
    /// leave it to a client that never answers, and for the active tab too — exactly once, owing nothing.
    func testAWindowOpIsAnsweredByTheHostExactlyOnceOnEveryTab() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        let two = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))   // active
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}[18t"))
        XCTAssertEqual(hostAnswers, [b("\u{1b}[8;24;80t")], "a background tab: the host, once")
        tm.feedForTests(two, b("\u{1b}[18t"))
        XCTAssertEqual(hostAnswers.count, 2, "the active tab: the host too")
        tm.writeReply(Data("\u{1b}[8;24;80t".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [], "and it owes the client nothing")
    }

    /// In one read, a query the client answers and one it does not: the host answers ONLY the second,
    /// and owes the client one reply.
    func testOneReadWithBothKindsSplitsTheAnswers() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("x\u{1b}[5ny\u{1b}[18tz"))
        XCTAssertEqual(hostAnswers, [b("\u{1b}[8;24;80t")], "not the DSR's `ESC[0n` — the client answers that")
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [b("\u{1b}[0n")], "one credit, one reply")
    }

    /// When the host answers BOTH kinds (the bytes reached nobody), its answers go to the pty in the order
    /// the queries came — the capability-probe pattern: a probe (`CSI ? u`), then DA1 as the sentinel. An
    /// answer to the probe arriving AFTER the sentinel's is read as "unsupported", then typed as keys.
    func testTheHostsAnswersKeepTheQueriesOrder() throws {
        let tm = manager(emit: { [unowned self] e in _ = self.rec.record(e); return false })
        let one = try liveTab(tm)
        tm.feedForTests(one, b("\u{1b}[?u\u{1b}[c"))
        let all = hostAnswers.flatMap { $0 }
        let probe = try XCTUnwrap(all.firstRange(of: b("\u{1b}[?")).map(\.lowerBound))
        let flags = try XCTUnwrap(all.firstRange(of: b("u")).map(\.lowerBound))
        let da = try XCTUnwrap(all.lastIndex(of: UInt8(ascii: "c")))
        XCTAssertTrue(probe < flags && flags < da, "the `?u` answer precedes DA1's: \(String(decoding: all, as: UTF8.self).debugDescription)")
    }

    /// A string ended by the NEXT sequence's ESC (as both parsers end it) does not hide the query after
    /// it, nor is its own query missed: reached, the client answers both, and the host neither — before,
    /// the scanner saw no query here and the host answered beside xterm.js.
    func testQueriesAroundAStringEndedByAnESCAreTheClientsOnce() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}]0;t\u{1b}[6n"))
        tm.feedForTests(one, b("\u{1b}]11;?\u{1b}[m"))
        XCTAssertEqual(hostAnswers, [])
        for r in ["\u{1b}[1;1R", "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\"] { tm.writeReply(Data(r.utf8), toTerminal: one) }
        XCTAssertEqual(deliveredTo(one).count, 2, "one credit each")
    }

    /// Credits are per expected ANSWER: OSC 4 asking two colours owes two replies.
    func testAColourQueryForTwoColoursOwesTwoReplies() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}]4;1;?;2;?\u{07}"))
        XCTAssertEqual(hostAnswers, [])
        for c in ["1", "2", "3"] { tm.writeReply(Data("\u{1b}]4;\(c);rgb:cccc/0000/0000\u{1b}\\".utf8), toTerminal: one) }
        XCTAssertEqual(deliveredTo(one).count, 2)
    }

    /// A new wire (generation) voids every credit: its instances were rebuilt from snapshots, so no reply
    /// to a query of the old wire can still be owed.
    func testANewWireVoidsEveryCredit() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}[5n"))
        tm.setDriverDecodesWire(true, generation: 2); tm.snapshotAll()
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [])
    }

    /// A credit admits only something SHAPED like a reply (ESC first, no control byte but ESC/BEL, at most
    /// 256 bytes); anything else — a command line — falls back to the keystroke rule and, for a tab that
    /// is not active, is dropped. The credit is not spent on it.
    func testACreditAdmitsOnlyAReplyShapedMessage() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}[5n"))
        tm.writeReply(Data("\r rm -rf ~\r".utf8), toTerminal: one)
        tm.writeReply(Data("\u{1b}[0n\r".utf8), toTerminal: one)
        tm.writeReply(Data(("\u{1b}[" + String(repeating: "1", count: 300) + "R").utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [])
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [b("\u{1b}[0n")], "the credit was still there")
    }

    /// A query the client never saw (its emission reached no context) is the host's — and owes the
    /// client nothing, so a reply for that tab, not active, is refused: never two answers.
    func testAQueryThatDidNotReachTheClientOwesItNothing() throws {
        var reach = true
        let tm = manager(emit: { [unowned self] e in _ = self.rec.record(e); return reach }); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        reach = false
        tm.feedForTests(one, b("\u{1b}[5n"))
        XCTAssertEqual(hostAnswers, [b("\u{1b}[0n")], "nobody else saw it")
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [])
    }

    // MARK: a query torn by a snapshot

    /// A query whose bytes STRADDLE a snapshot — its head reached the OLD context (here, flushed to the
    /// old wire), its tail arrives after the NEW wire's snapshot — was counted as reached, so the host
    /// stayed silent, while the client's new instance (built from the snapshot) saw only `5n` and
    /// answered nothing: nobody answered. It is the host's now — SwiftTerm has parsed the whole
    /// sequence — and owes the client nothing.
    func testAQueryTornByANewWiresSnapshotIsAnsweredByTheHostOnce() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))        // active: `one` is background
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        let head = rec.count
        tm.feedForTests(one, b("\u{1b}["))
        clock.advance(by: TermSendBuffer.hold)                                   // the head reaches the old wire
        XCTAssertEqual(outputs(one, since: head), [b("\u{1b}[")])
        tm.setDriverDecodesWire(true, generation: 2); tm.snapshotAll()
        let tail = rec.count
        tm.feedForTests(one, b("5n"))
        XCTAssertEqual(outputs(one, since: tail), [b("5n")], "the new instance sees only the tail")
        XCTAssertEqual(hostAnswers, [b("\u{1b}[0n")], "the host answers it, once")
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [], "and owes the client no reply")
    }

    /// The same across a pause and its resume: the resume's snapshot starts a new instance too.
    func testAQueryTornByAResumeSnapshotIsAnsweredByTheHostOnce() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}]11;"))
        tm.pauseForwarding()
        tm.feedForTests(one, b("?"))
        tm.resumeForwarding()
        tm.feedForTests(one, b("\u{07}"))
        XCTAssertEqual(hostAnswers.count, 1, "the host answers it, once")
        XCTAssertEqual(hostAnswers.first.map { String(decoding: $0, as: UTF8.self).hasPrefix("\u{1b}]11;rgb:") }, true)
        tm.writeReply(Data("\u{1b}]11;rgb:0000/0000/0000\u{1b}\\".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [], "and owes the client no reply")
    }

    // MARK: the host's colour answers are the driver's xterm.js's

    /// A distinctive palette, as a driver's `term-palette` would state it.
    private var driverPalette: TermPalette {
        var p = TermPalette.xtermDefault
        p.foreground = .init(r: 0xec, g: 0xec, b: 0xe0)
        p.background = .init(r: 0x1e, g: 0x1e, b: 0x2e)
        p.cursor = .init(r: 0xab, g: 0xcd, b: 0xef)
        p.ansi[1] = .init(r: 0xc8, g: 0x1e, b: 0x10)
        return p
    }

    /// When the HOST answers a `pty:` tab's colour query (paused: the bytes reach nobody), the answer is
    /// what the DRIVER's xterm.js would have sent — its theme's colour, in xterm.js's format — never
    /// SwiftTerm's own palette (`reportColor`) or its format.
    func testAPausedPtyTabsColourQueryIsAnsweredFromTheDriversPalette() throws {
        let tm = manager(); deliveries(tm)
        let id = try liveTab(tm)
        tm.setTermPalette(driverPalette, seq: 1)
        tm.pauseForwarding()
        tm.feedForTests(id, b("\u{1b}]11;?\u{07}"))
        tm.feedForTests(id, b("\u{1b}]4;1;?\u{1b}\\"))
        tm.feedForTests(id, b("\u{1b}]10;?;?\u{07}"))
        tm.feedForTests(id, b("\u{1b}]12;?\u{07}"))
        let E = "\u{1b}"
        XCTAssertEqual(hostAnswers.map { String(decoding: $0, as: UTF8.self) }, [
            "\(E)]11;rgb:1e1e/1e1e/2e2e\(E)\\",
            "\(E)]4;1;rgb:c8c8/1e1e/1010\(E)\\",
            "\(E)]10;rgb:ecec/ecec/e0e0\(E)\\\(E)]11;rgb:1e1e/1e1e/2e2e\(E)\\",
            "\(E)]12;rgb:abab/cdcd/efef\(E)\\",
        ])
    }

    /// The same for a colour query TORN by a resume's snapshot (split across reads): the host answers
    /// the whole query from the driver's palette, and a cursor report stays the emulator's.
    func testATornColourQueryIsAnsweredFromTheDriversPalette() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setTermPalette(driverPalette, seq: 1)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("ab\u{1b}]11;"))
        tm.pauseForwarding()
        tm.feedForTests(one, b("?"))
        tm.resumeForwarding()
        tm.feedForTests(one, b("\u{07}"))
        tm.pauseForwarding()
        tm.feedForTests(one, b("\u{1b}[6n"))
        XCTAssertEqual(hostAnswers.map { String(decoding: $0, as: UTF8.self) },
                       ["\u{1b}]11;rgb:1e1e/1e1e/2e2e\u{1b}\\", "\u{1b}[1;3R"])
    }

    // The client-query fixture: every candidate the real xterm.js was fed, and what it answered.
    private struct QueryCase: Decodable { let q: String; let replies: Int; let answers: String }
    private struct QueryPalette: Decodable {
        let fg: String, bg: String, cursor: String, ansi: [String]
        /// The 16-255 slots the theme replaces — what the client sends as `term-palette.ext`.
        let ext: [String: String]
        var wire: [String: Any] { ["fg": fg, "bg": bg, "cursor": cursor, "ansi": ansi, "ext": ext] }
    }
    private struct QueryPalettes: Decodable { let dark: QueryPalette }
    private struct QueryFixture: Decodable { let cases: [QueryCase]; let palettes: QueryPalettes }
    private static let queryFixture: QueryFixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/term-client-queries.json")
        return try! JSONDecoder().decode(QueryFixture.self, from: Data(contentsOf: url))
    }()
    /// Whether the sequence `walk` found at `start` is an OSC (7-bit, C0 executed after the ESC, or C1).
    private static func isOSC(_ b: [UInt8], at start: Int) -> Bool {
        if b[start] == 0xC2 { return b[start + 1] == 0x9d }
        var j = start + 1
        while j < b.count, b[j] < 0x20 || b[j] == 0x7f { j += 1 }
        return j < b.count && b[j] == 0x5d
    }

    /// EXACTLY what the driver's xterm.js gives, for every COLOUR query the fixture measured: paused (the
    /// bytes reach nobody), the host's answer is the fixture's recorded answer — and where xterm.js gave
    /// NOTHING (aborted by CAN/SUB or a C1, `OSC 4;256;?`, a malformed identifier) the host types nothing,
    /// never SwiftTerm's own answer in SwiftTerm's own palette.
    func testEveryColourQueryGetsExactlyXtermJsAnswerFromTheHost() throws {
        let dark = try XCTUnwrap(TermPalette(wire: Self.queryFixture.palettes.dark.wire))
        var checked = 0, silent = 0
        for c in Self.queryFixture.cases {
            let bytes = Array("a\(c.q)b\u{1b}[m".utf8)
            var scanner = StreamingQueryStripper()
            let asked = scanner.scan(bytes).filter(\.queryLike)
            guard !asked.isEmpty, asked.allSatisfy({ Self.isOSC(bytes, at: $0.start) }) else { continue }
            let tm = manager(); deliveries(tm)
            let id = try liveTab(tm)
            tm.setTermPalette(dark, seq: 1)
            tm.pauseForwarding()
            tm.feedForTests(id, bytes)
            XCTAssertEqual(String(decoding: hostAnswers.joined(), as: UTF8.self), c.answers, c.q.debugDescription)
            checked += 1
            if c.replies == 0 { silent += 1 }
        }
        XCTAssertGreaterThan(checked, 20)
        XCTAssertGreaterThanOrEqual(silent, 5, "the cases xterm.js answers with nothing")
    }

    /// And a colour query whose payload is past xterm.js's limit (10 MB): xterm.js answers nothing, so the
    /// host types nothing.
    func testAColourQueryPastThePayloadLimitGetsNoHostAnswer() throws {
        let tm = manager(); deliveries(tm)
        let id = try liveTab(tm)
        tm.setTermPalette(driverPalette, seq: 1)
        tm.pauseForwarding()
        var q = b("\u{1b}]4;1;?;")
        q += [UInt8](repeating: 0x78, count: 10_000_001)
        q += b("\u{07}")
        var at = 0
        while at < q.count { tm.feedForTests(id, Array(q[at..<min(at + 65536, q.count)])); at += 65536 }
        XCTAssertEqual(hostAnswers, [])
        tm.feedForTests(id, b("\u{1b}]4;1;?\u{07}"))
        XCTAssertEqual(hostAnswers.map { String(decoding: $0, as: UTF8.self) }, ["\u{1b}]4;1;rgb:c8c8/1e1e/1010\u{1b}\\"],
                       "the positive control: the same query under the limit")
    }

    /// A colour query LONGER than the 4 KB hold, paused (its bytes reach nobody): its bytes are gone by
    /// the read that ends it, but not what it ASKS — the host answers from the driver's palette exactly
    /// what xterm.js answers the whole query (`TermHostReplies` on its bytes), whole or split around the
    /// hold. Until 2026-09-27 it kept SwiftTerm's answer, from SwiftTerm's own palette.
    func testALongColourQueryIsAnsweredFromTheDriversPalette() throws {
        let junk = String(repeating: "x;", count: 3000)
        for q in ["\u{1b}]4;\(junk)1;?;2;?\u{07}", "\u{1b}]11;\(String(repeating: "z", count: 5000));?\u{1b}\\",
                  "\u{1b}]12;?;\(String(repeating: "y", count: 5000))\u{07}"] {
            let bytes = b(q)
            // The whole query as the parsers end it (at the ESC of an ST: its `\` is not part of it).
            let expected = try XCTUnwrap(TermHostReplies.colourAnswer(bytes.last == 0x5c ? Array(bytes.dropLast()) : bytes, palette: driverPalette))
            XCTAssertFalse(expected.isEmpty)
            // Whole in one read it is not long at all; 4097 and 1000 leave it open past the hold.
            for chunk in [bytes.count, 4097, 1000] {
                let tm = manager(); deliveries(tm)
                let id = try liveTab(tm)
                tm.setTermPalette(driverPalette, seq: 1)
                tm.pauseForwarding()
                var at = 0
                while at < bytes.count { tm.feedForTests(id, Array(bytes[at..<min(at + chunk, bytes.count)])); at += chunk }
                XCTAssertEqual(hostAnswers.map { String(decoding: $0, as: UTF8.self) }, [String(decoding: expected, as: UTF8.self)],
                               "\(q.prefix(8).debugDescription) chunk \(chunk)")
            }
        }
    }

    /// Colour queries and DA/DSR queries in ONE read: the host's answers leave in QUERY order, one write —
    /// the colour ones from the driver's palette, the others the emulator's — never grouped by kind.
    func testColourAndDeviceQueriesInOneReadAreAnsweredInQueryOrder() throws {
        let tm = manager(); deliveries(tm)
        let id = try liveTab(tm)
        tm.setTermPalette(driverPalette, seq: 1)
        tm.pauseForwarding()
        tm.feedForTests(id, b("\u{1b}[c"))                      // the emulator's own DA1, alone
        let da = String(decoding: try XCTUnwrap(hostAnswers.first), as: UTF8.self)
        XCTAssertTrue(da.hasPrefix("\u{1b}[?") && da.hasSuffix("c"), da.debugDescription)
        let before = hostAnswers.count
        tm.feedForTests(id, b("\u{1b}]11;?\u{07}\u{1b}[c\u{1b}]4;1;?\u{1b}\\\u{1b}[6n\u{1b}]12;?\u{07}"))
        let E = "\u{1b}"
        XCTAssertEqual(hostAnswers.dropFirst(before).map { String(decoding: $0, as: UTF8.self) }, [
            "\(E)]11;rgb:1e1e/1e1e/2e2e\(E)\\" + da + "\(E)]4;1;rgb:c8c8/1e1e/1010\(E)\\" + "\(E)[1;1R"
                + "\(E)]12;rgb:abab/cdcd/efef\(E)\\",
        ])
    }

    /// Not torn: a query begun AFTER the snapshot, even one split across reads, is still the client's.
    func testAQuerySplitAfterTheSnapshotIsStillTheClients() throws {
        let tm = manager(); deliveries(tm)
        let one = try liveTab(tm)
        _ = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshotAll()
        tm.feedForTests(one, b("\u{1b}["))
        tm.setDriverDecodesWire(true, generation: 2); tm.snapshotAll()
        tm.feedForTests(one, b("m\u{1b}["))
        tm.feedForTests(one, b("5n"))
        XCTAssertEqual(hostAnswers, [], "the client's instance saw it whole")
        tm.writeReply(Data("\u{1b}[0n".utf8), toTerminal: one)
        XCTAssertEqual(deliveredTo(one), [b("\u{1b}[0n")])
    }

    // MARK: every query the client answers — never held either

    /// A query only the CLIENT's xterm.js counts as its own (OSC 4 colour query) goes out at once, the
    /// held bytes ahead of it: held, a pause or a new wire could drop it (snapshots carry no queries)
    /// and nobody would answer.
    func testAQueryTheClientAnswersIsSentAtOnce() throws {
        let tm = manager(); let id = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
        let mark = rec.count
        tm.feedForTests(id, b("held "))
        tm.feedForTests(id, b("\u{1b}]4;1;?\u{07}"))
        XCTAssertEqual(outputs(id, since: mark), [b("held \u{1b}]4;1;?\u{07}")])
        XCTAssertEqual(hostAnswers, [], "it reached the client, which answers it")
    }

    /// The same query split across reads: its first half is held, the read that completes it sends both.
    func testAClientQuerySplitAcrossReadsIsSentWhole() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        tm.feedForTests(id, b("\u{1b}]4;1"))
        XCTAssertEqual(outputs(id, since: mark), [], "not yet a query: held")
        tm.feedForTests(id, b(";?\u{07}"))
        XCTAssertEqual(outputs(id, since: mark), [b("\u{1b}]4;1;?\u{07}")])
        XCTAssertEqual(hostAnswers, [])
    }

    /// A sequence that COULD be a query is never held, whether or not either measured set recognises it
    /// (docs/terminal.md, "The send buffer"; the rule is walked against xterm.js's registered handlers,
    /// `TermReplyHandlersFixtureTests`): an OSC asking with `?` (xterm's clipboard read), any DCS, any
    /// window op. Held, a pause or a new wire could drop it, and an answer with it.
    func testASequenceThatCouldBeAQueryIsNeverHeld() throws {
        for q in ["\u{1b}]52;c;?\u{07}", "\u{1b}P1x#0;2;0;0;0\u{1b}\\", "\u{1b}[5t", "\u{1b}[?1$p"] {
            let tm = manager(); let id = try liveTab(tm)
            let mark = rec.count
            tm.feedForTests(id, b("held "))
            tm.feedForTests(id, b(q))
            XCTAssertEqual(outputs(id, since: mark), [b("held \(q)")], q.debugDescription)
        }
    }

    /// The host types an answer only for a QUERY in the measured sets. SwiftTerm answers a plain
    /// `CSI Ps y` (no `*`) with a DECRQCRA checksum report that neither xterm.js nor a real VT sends for
    /// it; alone in a read, that report landed in a host segment and was typed into the program as
    /// input. Anything SwiftTerm sends outside a query's own segment is dropped.
    func testTheHostTypesNoAnswerForASequenceThatIsNotAQuery() throws {
        for reached in [true, false] {
            let tm = manager(emit: { [unowned self] e in _ = self.rec.record(e); return reached })
            let id = try liveTab(tm)
            tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
            tm.feedForTests(id, b("x\u{1b}[1yz"))
            XCTAssertEqual(hostAnswers, [], "reached: \(reached)")
            tm.feedForTests(id, b("\u{1b}[18t"))                             // a window op: still the host's
            XCTAssertEqual(hostAnswers.count, 1, "reached: \(reached)")
        }
    }

    // MARK: 8-bit C1 — read as the client's xterm.js reads it

    /// A DSR introduced by U+009B: xterm.js answers it (measured). Reached, the client does and the
    /// bytes are not held; not reached, the HOST does — SwiftTerm is handed the 7-bit form.
    func testAC1QueryIsAnsweredExactlyOnce() throws {
        var reach = true
        let tm = manager(emit: { [unowned self] e in _ = self.rec.record(e); return reach })
        let id = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
        let mark = rec.count
        tm.feedForTests(id, b("held "))
        tm.feedForTests(id, b("\u{9b}5n"))
        XCTAssertEqual(outputs(id, since: mark), [b("held \u{9b}5n")], "sent at once")
        XCTAssertEqual(hostAnswers, [], "the client's xterm.js answers it")
        reach = false
        tm.feedForTests(id, b("\u{9b}5n"))
        XCTAssertEqual(hostAnswers, [b("\u{1b}[0n")], "nobody saw it: the host, once")
    }

    /// A colour query ended by U+009C, more output after it in the same read: xterm.js answers it at the
    /// ST. SwiftTerm, reading bytes, took the C2 as data and answered at the NEXT ESC — in the part of
    /// the read after the query, which is the host's — so the app got two answers.
    func testAColourQueryEndedByTheC1STIsAnsweredOnce() throws {
        let tm = manager(); let id = try liveTab(tm)
        tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
        tm.feedForTests(id, b("\u{1b}]11;?\u{9c}more\u{1b}[m"))
        XCTAssertEqual(hostAnswers, [], "the client answers it; the host does not answer it again")
    }

    // MARK: a string longer than the scanner's 4 KB hold

    /// A DECRQSS longer than 4 KB split across reads is still recognised — on the read that ends it —
    /// and answered once: reached by the client, not reached by the host. Before, its bytes were
    /// released unclassified, so SwiftTerm's answer counted as the host's while xterm.js answered too.
    func testALongDECRQSSSplitAcrossReadsIsAnsweredOnce() throws {
        for reached in [true, false] {
            let tm = manager(emit: { [unowned self] e in _ = self.rec.record(e); return reached })
            let id = try liveTab(tm)
            tm.setDriverDecodesWire(true, generation: 1); tm.snapshot(id)
            let data = String(repeating: "x", count: 6000)
            let q = b("\u{1b}P$q\(data)\u{1b}\\")
            for i in stride(from: 0, to: q.count, by: 1024) { tm.feedForTests(id, Array(q[i..<min(i + 1024, q.count)])) }
            XCTAssertEqual(hostAnswers, reached ? [] : [b("\u{1b}P0$r\u{1b}\\")], "reached: \(reached)")
        }
    }

    /// An escape sequence that asks nothing (a colour, a title) is held like any output.
    func testASequenceThatAsksNothingIsHeld() throws {
        let tm = manager(); let id = try liveTab(tm)
        let mark = rec.count
        tm.feedForTests(id, b("\u{1b}[31mred\u{1b}]0;title\u{07}"))
        XCTAssertEqual(outputs(id, since: mark), [])
        clock.advance(by: TermSendBuffer.hold)
        XCTAssertEqual(outputs(id, since: mark).count, 1)
    }

    // MARK: the PRODUCT's timers (real time, the default scheduler)

    /// Tab A's flush is stuck holding A's `serial` (its emission blocks at a barrier — as a big snapshot
    /// or a host answer written into a pty nobody reads would hold it); tab B's held output must still
    /// flush on time. The product's timers share ONE strict timer queue, so a flush that took the tab's
    /// `serial` ON that queue stalled every other tab's.
    func testOneTabsStalledFlushDoesNotStallAnothers() throws {
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let r = EmissionRecorder()
        var aId: TermTabID?
        let tm = TerminalManager(cols: 80, rows: 24)                           // the PRODUCT scheduler
        tm.onEmit = { e in
            if case .output(let id, _) = e, id == aId { entered.signal(); gate.wait() }
            return r.record(e)
        }
        defer { gate.signal() }
        let a = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24)); aId = a
        let bTab = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(a, b("A held"))
        tm.feedForTests(bTab, b("B held"))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "A's flush is running, and stuck")
        let deadline = Date().addingTimeInterval(1)
        while r.output(of: bTab).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertEqual(r.output(of: bTab), b("B held"), "B flushed while A's serial path is stuck")
        gate.signal()
    }

    /// The PRODUCT wires the STRICT, zero-leeway timer source — the App Nap fix (`asyncAfter` slipped
    /// the 8 ms hold to 25-43 ms, measured) is guarded by a test, not only by that measurement: a
    /// default manager's flush must be made by a timer `strictTimerSourcesForTests` saw built.
    func testTheProductSchedulesFlushesOnAStrictZeroLeewayTimer() throws {
        let r = EmissionRecorder()
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.onEmit = r.record
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        let before = TerminalManager.strictTimerSourcesForTests
        tm.feedForTests(id, b("held"))
        r.wait("the timer flushed it", timeout: 2) { r.output(of: id) == self.b("held") }
        let after = TerminalManager.strictTimerSourcesForTests
        XCTAssertEqual(after.made - before.made, 1, "one strict timer source for the one held batch")
        XCTAssertTrue(after.strict)
        XCTAssertEqual(after.leewayNanos, 0)
    }
}
