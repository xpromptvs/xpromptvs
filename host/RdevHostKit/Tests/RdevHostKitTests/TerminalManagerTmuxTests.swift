import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

private final class TmuxNullVideo: VideoEncoding, @unchecked Sendable {
    var codec: NegotiatedCodec { .av1 }
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {}
    func addSink(_ s: any VideoTrackSink) {}
    func removeSink(_ s: any VideoTrackSink) {}
    func removeAllSinks() {}
    func requestKeyframe() {}
    func setFps(_ v: Int) {}
    func setBitrate(_ v: Int) {}
    func setCrop(_ v: CropRect) {}
    func invalidate() {}
}

/// tmux tabs through the REAL `TerminalManager` against REAL tmux on a PRIVATE socket. Skips LOUDLY
/// without tmux.
final class TerminalManagerTmuxTests: XCTestCase {
    /// Every snapshot starts with the emitter's soft reset.
    static let fullAttach = "\u{1b}[!p\u{1b}[?7h"
    private var rec = EmissionRecorder()
    private var runner: TmuxRunner!

    private struct PrivateServerDidNotStart: Error { let status: Int32 }
    private static let socketName = "rdev-tm-\(getpid())"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment.merging(["RDEV_TMUX_SOCKET": Self.socketName]) { $1 }
        guard let r = TmuxRunner.locate(environment: env) else {
            throw XCTSkip("tmux is not installed — TerminalManagerTmuxTests did NOT run")
        }
        // EVERY command — the manager's and its control clients' included — carries `-f /dev/null`, so
        // whichever one starts the PRIVATE server, the user's ~/.tmux.conf never shapes what is measured.
        runner = r.withConfigFile("/dev/null")
        // Started HERE, kept up by a KEEPER session that ends on its own — so a run that crashes before
        // tearDown leaves no server behind for long. A server that will not start is a failure, not a
        // silent fallback to whatever the first `newSession` does.
        let started = runner.run(["new-session", "-d", "-s", "keeper", "sleep", "600"])
        guard started.status == 0 else { throw PrivateServerDidNotStart(status: started.status) }
    }

    /// Kill the private server, then remove its socket FILE (tmux leaves it behind on `kill-server`).
    override func tearDown() {
        guard let runner else { return }
        _ = runner.run(["kill-server"])
        TmuxTestSocket.remove(Self.socketName)
    }

    private func manager() -> TerminalManager {
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.tmux = runner
        rec = EmissionRecorder()
        tm.onEmit = rec.record
        return tm
    }

    /// A fresh snapshot of the ACTIVE tab, as text (what an attach used to return).
    private func payload(_ tm: TerminalManager) -> String {
        guard let id = tm.descriptors().activeId else { return "" }
        let mark = rec.count
        tm.snapshot(id)
        rec.wait("a snapshot of \(id.wire)") { !rec.snapshots(of: id, since: mark).isEmpty }
        return String(decoding: rec.snapshots(of: id, since: mark).first?.bytes ?? [], as: UTF8.self)
    }

    private func pane(_ sid: String) -> String { runner.run(["capture-pane", "-p", "-t", sid]).stdout }

    func testOpenTypeAttachDetach() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        XCTAssertNoThrow(try tm.openTmux(sid).get())
        XCTAssertEqual(tm.descriptors().activeId, .tmux(sid))
        XCTAssertTrue(payload(tm).hasPrefix(Self.fullAttach))                       // attach first: it learns the pane
        tm.write(Data("echo tmux''mark\r".utf8), toTerminal: .tmux(sid))
        // POLLED, not slept: a real login shell under a loaded machine can take seconds to answer, and a
        // fixed one-second sleep failed at load ~25 while passing at ~9 (with or without this branch).
        let deadline = Date().addingTimeInterval(15)
        while !pane(sid).contains("tmuxmark") && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(pane(sid).contains("tmuxmark"), "the keystrokes reached the pane")
        let p = payload(tm)
        XCTAssertTrue(p.hasPrefix(Self.fullAttach))
        XCTAssertTrue(p.contains("tmuxmark"), "the snapshot carries what the pane shows")
        XCTAssertTrue(tm.close(.tmux(sid)))                                    // detach
        XCTAssertTrue(tm.isEmpty)
        XCTAssertTrue(runner.listSessions().contains { $0.id == sid }, "closing the tab does not end the session")
    }

    /// Opening an already-open session selects it instead of adding a second tab.
    func testOpeningAnOpenSessionSelectsIt() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = tm.openTmux(b)
        _ = tm.openTmux(a)
        XCTAssertEqual(tm.descriptors().tabs.map(\.id), [.tmux(a), .tmux(b)])
        XCTAssertEqual(tm.descriptors().activeId, .tmux(a))
    }

    /// Keystrokes naming a tmux tab that is not active are refused, like any tab's.
    func testKeyToAnInactiveTmuxTabIsDropped() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)
        tm.write(Data("echo leak''ed\r".utf8), toTerminal: .tmux(a))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(pane(a).contains("leaked"))
        XCTAssertFalse(pane(b).contains("leaked"))
    }

    /// A session ending closes ITS tab, and only its client exits: the surviving tab kept its own client
    /// the whole time (one client per tab), so it is repainted at once and never re-attached. (With one
    /// shared client, tmux's detach-on-destroy took the client with the dead session and a replacement
    /// had to attach first.)
    func testASessionEndingClosesOnlyItsTab() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        let closed = expectation(description: "tmux-closed for b")
        tm.onTmuxClosed = { s, _ in if s == b { closed.fulfill() } }
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)
        XCTAssertTrue(runner.killSession(b))
        wait(for: [closed], timeout: 10)
        XCTAssertEqual(tm.descriptors().tabs.map(\.id), [.tmux(a)])
        XCTAssertEqual(tm.descriptors().activeId, .tmux(a))
        XCTAssertEqual(controlClients(a), 1, "A's own client was never replaced")
        rec.wait("the driver is told b is gone") { rec.closed().contains(.tmux(b)) }
        XCTAssertTrue(payload(tm).hasPrefix(Self.fullAttach))
    }

    func testKillEndsTheSessionAndClosesTheTab() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        let closed = expectation(description: "tmux-closed")
        tm.onTmuxClosed = { s, _ in if s == a { closed.fulfill() } }
        _ = tm.openTmux(a)
        XCTAssertTrue(tm.killTmux(a))
        wait(for: [closed], timeout: 10)
        XCTAssertTrue(tm.isEmpty)
        XCTAssertFalse(runner.listSessions().contains { $0.id == a })
    }

    func testNewTmuxCreatesAndOpens() throws {
        let tm = manager()
        let sid = try tm.newTmux().get()
        XCTAssertEqual(tm.descriptors().activeId, .tmux(sid))
        XCTAssertTrue(runner.listSessions().contains { $0.id == sid })
    }

    func testUnavailable() {
        let tm = TerminalManager(cols: 80, rows: 24)             // tmux nil
        XCTAssertFalse(tm.listTmux().available)
        if case .failure(.unavailable) = tm.newTmux() {} else { XCTFail("expected .unavailable") }
        if case .failure(.unavailable) = tm.openTmux("$1") {} else { XCTFail("expected .unavailable") }
    }

    func testOpeningAGoneSessionFails() {
        let tm = manager()
        if case .failure(.gone) = tm.openTmux("$999") {} else { XCTFail("expected .gone") }
        XCTAssertTrue(tm.isEmpty)
    }

    // MARK: review fixes

    /// Output emitted for `id` (default: whichever tab is active when read) from now on.
    private func collectOutput(_ tm: TerminalManager, _ id: TermTabID? = nil) -> () -> String {
        let mark = rec.count
        let r = rec
        return { (id ?? tm.descriptors().activeId).map { r.text(of: $0, since: mark) } ?? "" }
    }

    /// A tmux tab streams whether or not it is active — with a PLAIN tab on screen too.
    func testATmuxTabStreamsWhileAPlainTabIsActive() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a)
        rec.wait("a's first snapshot") { !rec.snapshots(of: .tmux(a)).isEmpty }
        XCTAssertTrue(tm.open(cols: 80, rows: 24))                      // a plain tab becomes active
        defer { tm.close(.pty(1)) }
        let out = collectOutput(tm, .tmux(a))
        _ = runner.run(["send-keys", "-t", a, "echo seen''here", "Enter"])
        rec.wait("a's output reaches the driver while pty:1 is active") { out().contains("seenhere") }
    }

    /// A query tmux does NOT answer (OSC 4, measured) is left in the stream for xterm.js — and its reply
    /// reaches the pane that asked even when that tab is in the BACKGROUND: the tmux tab earns a
    /// `term-reply` credit per answer xterm.js gives, as a `pty:` tab does. Before, the reply took the
    /// keystroke path and was dropped unless the tab was the host's active one (final review M1). A
    /// query tmux DOES answer (DSR) is stripped and earns nothing: a reply for it is still refused.
    func testABackgroundTmuxTabsLeftInQueryEarnsItsReply() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)                                // b is active; a in the background
        let out = collectOutput(tm, .tmux(a))
        _ = runner.run(["send-keys", "-t", a, "clear; printf '\\033]4;1;?\\007\\033[6n'; cat -v", "Enter"])
        rec.wait("a's OSC 4 query reaches the driver") { out().contains("\u{1b}]4;1;?\u{07}") }
        XCTAssertFalse(out().contains("\u{1b}[6n"), "DSR is tmux's to answer: stripped")
        Thread.sleep(forTimeInterval: 0.5)
        tm.writeReply(Data("\u{1b}]4;1;rgb:cdcd/0000/0000\u{1b}\\".utf8), toTerminal: .tmux(a))
        waitFor("the reply reached a's program") { self.pane(a).contains("]4;1;rgb:cdcd/0000/0000") }
        XCTAssertFalse(pane(b).contains("rgb:cdcd"))
        // ONE credit (the OSC 4; the DSR tmux answered itself earned none): a second reply is refused.
        tm.writeReply(Data("\u{1b}[9;9R".utf8), toTerminal: .tmux(a))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(pane(a).contains("[9;9R"), "one credit, one reply")
    }

    /// A credit belongs to the PANE that asked: after the tab moves to another pane, a late reply is
    /// refused rather than typed into a program that never queried.
    func testAReplyCreditDoesNotSurviveAPaneChange() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)                                // b is active; a in the background
        let out = collectOutput(tm, .tmux(a))
        _ = runner.run(["send-keys", "-t", a, "clear; printf '\\033]4;1;?\\007'", "Enter"])
        rec.wait("a's OSC 4 query reaches the driver") { out().contains("\u{1b}]4;1;?\u{07}") }
        let mark = rec.count
        _ = runner.run(["split-window", "-t", a, "cat -v"])                // a's active pane changes
        rec.wait("a re-snapshots on the new pane") { !self.rec.snapshots(of: .tmux(a), since: mark).isEmpty }
        tm.writeReply(Data("\u{1b}]4;1;rgb:cdcd/0000/0000\u{1b}\\".utf8), toTerminal: .tmux(a))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(pane(a).contains("rgb:cdcd"), "the new pane never asked")
    }

    /// The same query is never HELD on the tmux send path: held, a pause or a new wire could drop it.
    func testALeftInQueryIsNeverHeldOnTheTmuxPath() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let (tm, clock, _) = heldManager()
        _ = tm.openTmux(sid); _ = payload(tm)
        settle(tm, sid, clock)
        let mark = rec.count
        _ = runner.run(["send-keys", "-t", sid, "printf 'q\\033]4;1;?\\007'", "Enter"])
        waitFor("the pane printed it") { self.pane(sid).contains("q") && self.pane(sid).split(separator: "\n").count > 1 }
        Thread.sleep(forTimeInterval: 0.3)
        tm.syncTmuxQueueForTests(sid)
        XCTAssertTrue(rec.text(of: .tmux(sid), since: mark).contains("\u{1b}]4;1;?\u{07}"), "sent with the clock standing still")
    }

    // MARK: the queries tmux leaves for the client, when their bytes reach NO client

    /// OSC 4, OSC 12, a multi-colour OSC 10, DECDSR and a C1 DA1: tmux answers none of them, so they are
    /// left for the client's xterm.js. Their answers, echoed by the pane's tty, are counted there. The C1
    /// DA1 goes first and a CR after it: tmux prints its `c` (it reads bytes), xterm.js does not, and the
    /// CR puts both at column 0 before the DECDSR.
    private static let leftInQueries = "printf '\\302\\233c\\r\\033]4;1;?\\007\\033]12;?\\007\\033]10;?;?\\007\\033[?6n'; cat -v"
    /// Counted in the pane's JOINED lines (`-J`): the echo wraps at the pane's width.
    private func occurrences(_ needle: String, in sid: String) -> Int {
        runner.run(["capture-pane", "-p", "-J", "-t", sid]).stdout.components(separatedBy: needle).count - 1
    }
    private func assertAnsweredOnce(_ sid: String, fg: String = "ffff/ffff/ffff", ansi1: String = "cccc/0000/0000",
                                    file: StaticString = #filePath, line: UInt = #line) {
        waitFor("the host's answers reached the pane") { self.pane(sid).contains("[?1;2c") }
        Thread.sleep(forTimeInterval: 0.5)                                    // a second answer would land by now
        XCTAssertEqual(occurrences("]4;1;rgb:\(ansi1)", in: sid), 1, "OSC 4", file: file, line: line)
        XCTAssertEqual(occurrences("]12;rgb:", in: sid), 1, "OSC 12", file: file, line: line)
        XCTAssertEqual(occurrences("]10;rgb:\(fg)", in: sid), 1, "OSC 10;?;? — the foreground", file: file, line: line)
        XCTAssertEqual(occurrences("]11;rgb:0000/0000/0000", in: sid), 1, "OSC 10;?;? — the background", file: file, line: line)
        XCTAssertEqual(occurrences("[?1;1R", in: sid), 1, "DECDSR, from tmux's cursor (the screen was just cleared)", file: file, line: line)
        XCTAssertEqual(occurrences("[?1;2c", in: sid), 1, "C1 DA1", file: file, line: line)
    }

    /// PAUSED (a hidden driver): the bytes are withheld, nothing reaches any client — the host answers,
    /// once, in xterm.js's format, from xterm.js's default palette (no client has sent one).
    func testALeftInQueryWithheldByAPauseIsAnsweredByTheHostOnce() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        tm.pauseForwarding()
        _ = runner.run(["send-keys", "-t", sid, "clear; \(Self.leftInQueries)", "Enter"])
        assertAnsweredOnce(sid)
    }

    /// Forwarded, but the emission reached NO context (no wire): the host answers, once — from the
    /// DRIVER's palette once it has sent one (`term-palette`).
    func testALeftInQueryThatReachedNoClientIsAnsweredByTheHostFromThePalette() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        tm.onEmit = { [rec] e in _ = rec.record(e); return false }
        var p = TermPalette.xtermDefault
        p.foreground = .init(r: 0xec, g: 0xec, b: 0xec)
        p.ansi[1] = .init(r: 0xc8, g: 0x1e, b: 0x10)
        tm.setTermPalette(p, seq: 1)
        _ = tm.openTmux(sid); _ = payload(tm)
        _ = runner.run(["send-keys", "-t", sid, "clear; \(Self.leftInQueries)", "Enter"])
        assertAnsweredOnce(sid, fg: "ecec/ecec/ecec", ansi1: "c8c8/1e1e/1010")
    }

    // MARK: the panes' default colours (`TmuxColourReport`)

    /// tmux answers a pane's single OSC 10/11 ITSELF, from what its client reported — and a control client
    /// reported nothing, so it answered black for both (measured, tmux 3.7c; Codex's "Working" shimmer went
    /// black). A program in the tab now reads the DRIVER's foreground and background.
    private static let colourQueries = "printf '\\033]10;?\\033\\\\\\033]11;?\\033\\\\'; cat -v"
    private func assertColours(_ sid: String, fg: String, bg: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor("tmux's answers reached the pane") { self.pane(sid).contains("]11;rgb:") }
        XCTAssertEqual(occurrences("]10;rgb:\(fg)", in: sid), 1, "OSC 10 — the foreground", file: file, line: line)
        XCTAssertEqual(occurrences("]11;rgb:\(bg)", in: sid), 1, "OSC 11 — the background", file: file, line: line)
        XCTAssertEqual(occurrences("rgb:0000/0000/0000", in: sid), 0, "not tmux's black", file: file, line: line)
    }

    func testAProgramInATmuxTabReadsTheDriversDefaultColours() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        var p = TermPalette.xtermDefault
        p.foreground = .init(r: 0xd4, g: 0xd4, b: 0xd4)
        p.background = .init(r: 0x1e, g: 0x1e, b: 0x1e)
        tm.setTermPalette(p, seq: 1)
        _ = tm.openTmux(sid); _ = payload(tm)
        Thread.sleep(forTimeInterval: 0.5)                                     // the reports follow the snapshot
        _ = runner.run(["send-keys", "-t", sid, "clear; \(Self.colourQueries)", "Enter"])
        assertColours(sid, fg: "d4d4/d4d4/d4d4", bg: "1e1e/1e1e/1e1e")
    }

    /// A theme change (a new `term-palette`) is reported to a tab already attached.
    func testAPaletteChangeReachesAnAttachedTab() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        var light = TermPalette.xtermDefault
        light.foreground = .init(r: 0x22, g: 0x22, b: 0x22)
        light.background = .init(r: 0xfa, g: 0xfa, b: 0xfa)
        tm.setTermPalette(light, seq: 1)
        Thread.sleep(forTimeInterval: 0.5)
        _ = runner.run(["send-keys", "-t", sid, "clear; \(Self.colourQueries)", "Enter"])
        assertColours(sid, fg: "2222/2222/2222", bg: "fafa/fafa/fafa")
    }

    /// REACHED a client: its xterm.js answers (here, nobody does — the recorder is no xterm.js), and the
    /// host must NOT: never two.
    func testALeftInQueryThatReachedTheClientIsNotAnsweredByTheHost() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        let out = collectOutput(tm, .tmux(sid))
        _ = runner.run(["send-keys", "-t", sid, "clear; \(Self.leftInQueries)", "Enter"])
        rec.wait("the queries reach the driver") { out().contains("\u{1b}[?6n") }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(pane(sid).contains("rgb:"), "the client answers these")
        XCTAssertFalse(pane(sid).contains("[?1;2c"))
    }

    // MARK: the host's left-in answers — order, a discarded stretch, the other withheld paths

    /// A manager whose host answers to a tmux tab's left-in queries are RECORDED (in the order they would
    /// be typed), and an open, snapshotted tab on an idle pane. Events are injected on the tab's own
    /// control-client queue, exactly where tmux's would run, so nothing can interleave inside a block.
    private func answeringTab() throws -> (tm: TerminalManager, sid: String, pane: String, answers: () -> [String]) {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        let lock = NSLock(); var got: [String] = []
        tm.tmuxHostAnswerForTests = { _, b in lock.lock(); got.append(String(decoding: b, as: UTF8.self)); lock.unlock() }
        _ = tm.openTmux(sid); _ = payload(tm)
        Thread.sleep(forTimeInterval: 0.5)                                 // the shell's first prompt, then idle
        _ = payload(tm)
        let pane = try XCTUnwrap(tm.tmuxPaneForTests(sid))
        return (tm, sid, pane, { lock.lock(); defer { lock.unlock() }; return got })
    }
    private func settled(_ tm: TerminalManager, _ sid: String) {
        Thread.sleep(forTimeInterval: 0.5)
        tm.syncTmuxQueueForTests(sid)
    }
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: an agent's activity (docs/terminal.md, "An agent's activity")

    /// A tmux tab's agent: its pane's FOREGROUND (the kernel's table, by `#{pane_tty}`) holds one, and its pane's screen
    /// (`capture-pane`, on the tab's own control client) says what it does — whatever reaches the client. The "agent" is
    /// `sleep` run as `codex` (its first argument, through a symlink — what `AgentProcess` reads of the real one).
    func testATmuxTabsAgentIsReadOffItsPaneOnlyWhileOneRuns() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        let agent = { tm.descriptors().tabs.first { $0.id == .tmux(sid) }?.agent }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let codex = dir.appendingPathComponent("codex").path
        try FileManager.default.createSymbolicLink(atPath: codex, withDestinationPath: "/bin/sleep")
        XCTAssertNil(agent())
        _ = runner.run(["send-keys", "-t", sid, "clear; printf 'Thinking (esc to interrupt)\\n'", "Enter"])
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertNil(agent(), "THE FALSE POSITIVE RULED OUT: the words on screen, a shell in the foreground")
        // Codex's own status line (`•` is U+2022: `\\342\\200\\242`).
        _ = runner.run(["send-keys", "-t", sid, "clear; printf '\\342\\200\\242 Working (3s \\342\\200\\242 esc to interrupt)\\n'; \(codex) 30", "Enter"])
        waitFor("working: an agent in the foreground, the hint on its screen") { agent() == .working }
        tm.pauseForwarding()
        _ = runner.run(["send-keys", "-t", sid, "C-c", ""])
        _ = runner.run(["send-keys", "-t", sid, "clear; printf 'Worked for 3s\\n'; \(codex) 30", "Enter"])
        waitFor("idle: the agent at its prompt — the driver's output withheld") { agent() == .idle }
        _ = runner.run(["send-keys", "-t", sid, "C-c", ""])
        waitFor("none: the agent exited") { agent() == nil }
        // Its TITLE spinning (the PANE's title, `#{pane_title}` — OSC 2; a braille frame, `\\342\\240\\213` is ⠋),
        // its status line a description too long to show its hint: working.
        _ = runner.run(["send-keys", "-t", sid,
                        "clear; printf '\\033]2;\\342\\240\\213 Exploring | repo\\033\\\\'; printf 'Investigating the planner\\n'; \(codex) 30", "Enter"])
        waitFor("working: the pane's title spins") { agent() == .working }
        _ = runner.run(["send-keys", "-t", sid, "C-c", ""])
        waitFor("none again") { agent() == nil }
    }

    /// THE SCREEN AN OFFER CARRIES, of a tmux tab (docs/sources-and-focus.md, "The offer carries the tab bar"): tmux's
    /// own capture of the screen — the batch the wire's snapshot runs, its history shrunk to a line and given to nobody
    /// — at the grid the driver's join resize gave it, and nothing scrolled off it.
    func testATmuxTabsOfferScreenIsItsScreenAloneAtTheJoinGrid() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        _ = runner.run(["send-keys", "-t", sid, "clear; for i in $(seq -w 0 99); do echo T$i; done", "Enter"])
        waitFor("the loop ran") { runner.run(["capture-pane", "-p", "-t", sid]).stdout.contains("T99") }
        tm.resizeAll(cols: 90, rows: 20)
        let got = expectation(description: "the screen")
        let box = NSMutableArray()
        tm.screenPreview(.tmux(sid), within: 3_000_000_000) { screen in
            if let screen { box.add(screen.size.cols); box.add(screen.size.rows); box.add(String(decoding: screen.bytes, as: UTF8.self)) }
            got.fulfill()
        }
        wait(for: [got], timeout: 5)
        XCTAssertEqual(box.count, 3, "a screen")
        guard box.count == 3, let text = box[2] as? String else { return }
        XCTAssertEqual([box[0] as? Int, box[1] as? Int], [90, 20])
        XCTAssertTrue(text.contains("T99"), "the screen's last line")
        XCTAssertFalse(text.contains("T50") || text.contains("T00"), "and nothing scrolled off it")
    }

    // MARK: the host's bell (docs/terminal.md, "The bell")

    /// A tmux tab's BELs as xterm.js rings them (`TermBellWatch`), followed while its bytes are WITHHELD: a
    /// bell in them reached no client — the host's, once per stretch; an OSC's terminating BEL is none.
    private func bellTab() throws -> (tm: TerminalManager, sid: String, pane: String, bells: () -> [TermTabID]) {
        let (tm, sid, pane, _) = try answeringTab()
        let lock = NSLock(); var got: [TermTabID] = []
        tm.onBell = { id in lock.lock(); got.append(id); lock.unlock() }
        return (tm, sid, pane, { lock.lock(); defer { lock.unlock() }; return got })
    }

    func testABellInWithheldTmuxOutputIsTheHostsOncePerStretch() throws {
        let (tm, sid, pane, bells) = try bellTab()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("live\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(bells(), [], "forwarded and reached: the client's xterm.js rang it")
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]0;title\u{07}")),
                                          .output(pane: pane, bytes: b("\u{1b}]2;split")),
                                          .output(pane: pane, bytes: b(" title\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(bells(), [], "a title's terminating BEL, whole or split across reads, is no bell")
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("done\u{07}")), .output(pane: pane, bytes: b("\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(bells(), [.tmux(sid)], "one term-bell for the withheld stretch")
        tm.resumeForwarding()
        _ = payload(tm)                                                         // the resume's snapshot
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(bells(), [.tmux(sid), .tmux(sid)], "the snapshot ended the stretch")
    }

    /// Forwarded, but the emission reached no context: the host's, by the emission's own result.
    func testABellInForwardedTmuxOutputThatReachedNoContextIsTheHosts() throws {
        let (tm, sid, pane, bells) = try bellTab()
        tm.onEmit = { [rec] e in _ = rec.record(e); return false }
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("x\u{07}")), .output(pane: pane, bytes: b("y\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(bells(), [.tmux(sid)])
    }

    /// `%pause`: tmux DISCARDED the pane's output, so an OSC open before it cannot swallow a BEL after it.
    func testAnOSCOpenAcrossAPauseDoesNotSwallowTheNextBell() throws {
        let (tm, sid, pane, bells) = try bellTab()
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]0;cut")), .pause(pane: pane),
                                          .output(pane: pane, bytes: b("\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(bells(), [.tmux(sid)])
    }

    /// A pane the tab does not follow rings nothing — its bytes are not the tab's.
    func testABellInAnotherPaneIsNotTheTabs() throws {
        let (tm, sid, _, bells) = try bellTab()
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: "%999", bytes: b("\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(bells(), [])
    }

    /// M1: host answers leave in QUERY ORDER across reads. A read holding a cursor report waits on
    /// `display`; a LATER read without one used to type its answer at once — ahead of the earlier.
    func testHostAnswersKeepTheQueriesOrderAcrossReads() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}[?6n")),
                                          .output(pane: pane, bytes: b("\u{1b}]4;1;?\u{07}"))])
        waitFor("both answered") { answers().joined().contains("rgb:") }
        settled(tm, sid)
        // Coalesced into one round trip since the flood bound, so compare the bytes typed, in order.
        let typed = answers().joined()
        XCTAssertTrue(typed.hasPrefix("\u{1b}[?1;"), typed.debugDescription)
        XCTAssertTrue(typed.hasSuffix("\u{1b}]4;1;rgb:cccc/0000/0000\u{1b}\\"), typed.debugDescription)
        XCTAssertEqual(typed.components(separatedBy: "\u{1b}").count - 1, 3, "each once: CPR, OSC 4 and its ST")
    }

    /// Colour queries and a DECDSR in ONE withheld read: the host's answers leave in QUERY order — each
    /// once, never grouped by kind (the cursor report waits on `display`, and so do the colours after it).
    func testHostAnswersKeepTheQueriesOrderWithinOneRead() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]4;1;?\u{07}\u{1b}[?6n\u{1b}]12;?\u{07}\u{1b}]4;2;?\u{1b}\\"))])
        waitFor("all answered") { answers().joined().components(separatedBy: "rgb:").count - 1 == 3 }
        settled(tm, sid)
        let typed = answers().joined()
        let E = "\u{1b}"
        let head = "\(E)]4;1;rgb:cccc/0000/0000\(E)\\\(E)[?"
        let tail = "\(E)]12;rgb:ffff/ffff/ffff\(E)\\\(E)]4;2;rgb:4e4e/9a9a/0606\(E)\\"
        XCTAssertTrue(typed.hasPrefix(head), typed.debugDescription)
        XCTAssertTrue(typed.hasSuffix(tail), typed.debugDescription)
        let cpr = typed.dropFirst(head.count).dropLast(tail.count)
        XCTAssertNotNil(cpr.wholeMatch(of: /\d+;\d+(;\d+)?R/), "the DECDSR's answer sits between them: \(typed.debugDescription)")
    }

    /// M2: `%pause` means tmux DISCARDED the pane's output, so a query head held from before it cannot
    /// join what follows `%continue`: `ESC [ ? 6` then an unrelated `n` is no DECDSR, and nothing is typed.
    func testAHeadHeldAcrossAPauseDoesNotJoinWhatFollows() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}[?6")), .pause(pane: pane),
                                          .output(pane: pane, bytes: b("n"))])
        settled(tm, sid)
        XCTAssertEqual(answers(), [], "a query nobody asked")
    }

    /// L3: orphan continuation bytes right after a snapshot are skipped (and a fresh snapshot taken); a
    /// left-in query they complete reached no client — the host answers it, once.
    func testALeftInQueryInOrphanBytesIsAnsweredByTheHostOnce() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: [0x80] + b("\u{1b}]4;1;?\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(answers(), ["\u{1b}]4;1;rgb:cccc/0000/0000\u{1b}\\"])
    }

    /// L3: after the tab's window or pane changed, its pane's bytes are withheld until the new snapshot —
    /// a left-in query in them is the host's, once; one in a pane the tab does not follow is nobody's.
    func testALeftInQueryWithheldByAPaneChangeIsAnsweredByTheHostOnce() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        tm.injectTmuxEventsForTests(sid, [.windowPaneChanged(window: "@0", pane: pane),
                                          .output(pane: pane, bytes: b("\u{1b}]12;?\u{07}")),
                                          .output(pane: "%99999", bytes: b("\u{1b}]4;1;?\u{07}"))])
        settled(tm, sid)
        XCTAssertEqual(answers(), ["\u{1b}]12;rgb:ffff/ffff/ffff\u{1b}\\"])
    }

    // MARK: L1 — a left-in query is reached only when its TERMINATOR is sent

    /// `answeringTab`, on a pane that prints NOTHING of its own (a raw `cat`): a shell's late prompt
    /// would be the bytes after the injected ones, and decide what the test means to decide.
    private func quietTab() throws -> (tm: TerminalManager, sid: String, pane: String, answers: () -> [String]) {
        let r = runner.run(["new-session", "-d", "-P", "-F", "#{session_id}", "stty raw -echo; exec cat >/dev/null"])
        XCTAssertEqual(r.status, 0)
        let sid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let tm = manager()
        let lock = NSLock(); var got: [String] = []
        tm.tmuxHostAnswerForTests = { _, b in lock.lock(); got.append(String(decoding: b, as: UTF8.self)); lock.unlock() }
        _ = tm.openTmux(sid); _ = payload(tm)
        let pane = try XCTUnwrap(tm.tmuxPaneForTests(sid))
        return (tm, sid, pane, { lock.lock(); defer { lock.unlock() }; return got })
    }

    /// A left-in OSC ended by an ESC that is the LAST byte of a forwarded read: the stripper holds that
    /// ESC (it begins the next sequence), so the client's xterm.js has the query's body and not its end.
    /// When what follows is WITHHELD (a pause here), the client never gets the ESC: the host answers,
    /// once. Until 2026-09-27 the query counted as reached at once, and nobody answered it.
    func testALeftInQueryWhoseTerminatorIsWithheldIsAnsweredByTheHostOnce() throws {
        let (tm, sid, pane, answers) = try quietTab()
        let out = collectOutput(tm, .tmux(sid))
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]4;1;?\u{1b}"))])
        settled(tm, sid)
        XCTAssertTrue(out().hasSuffix("\u{1b}]4;1;?"), out().debugDescription)
        XCTAssertEqual(answers(), [], "not decided yet: its terminator is held")
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("[m"))])
        settled(tm, sid)
        XCTAssertEqual(answers(), ["\u{1b}]4;1;rgb:cccc/0000/0000\u{1b}\\"])
    }

    /// The same when the stripper is DISCARDED with the ESC still in it — a `%pause` (tmux dropped what
    /// followed) and a snapshot after a pane change (the new instance gets the ESC, not the query): the
    /// host answers, once, into the pane that asked.
    func testALeftInQueryWhoseTerminatorIsHeldAcrossAPauseOrASnapshotIsAnsweredByTheHostOnce() throws {
        for event in ["pause", "pane"] {
            let (tm, sid, pane, answers) = try quietTab()
            let mark = rec.count
            tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]12;?;?\u{1b}"))])
            settled(tm, sid)
            XCTAssertEqual(answers(), [], event)
            tm.injectTmuxEventsForTests(sid, [event == "pause" ? .pause(pane: pane) : .windowPaneChanged(window: "@0", pane: pane)])
            rec.wait("a fresh snapshot (\(event))") { !self.rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
            settled(tm, sid)
            XCTAssertEqual(answers(), ["\u{1b}]12;rgb:ffff/ffff/ffff\u{1b}\\"], event)
        }
    }

    /// And when the ESC goes out after all, the client answers — the host does not: never two.
    func testALeftInQueryWhoseTerminatorFollowsInTheNextReadIsTheClients() throws {
        let (tm, sid, pane, answers) = try quietTab()
        let out = collectOutput(tm, .tmux(sid))
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]4;1;?\u{1b}")), .output(pane: pane, bytes: b("[mZ"))])
        settled(tm, sid)
        XCTAssertTrue(out().hasSuffix("\u{1b}]4;1;?\u{1b}[mZ"), out().debugDescription)
        XCTAssertEqual(answers(), [])
    }

    /// A query tmux answers (stripped) whose ESC ENDS a left-in query keeps that ESC (`ESC \`): without
    /// it the client's xterm.js ran the colour query on into what followed and answered nothing.
    func testAStrippedQueryKeepsTheTerminatorOfALeftInQuery() throws {
        let (tm, sid, pane, answers) = try quietTab()
        let out = collectOutput(tm, .tmux(sid))
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]4;1;?\u{1b}[cZ"))])
        settled(tm, sid)
        XCTAssertTrue(out().hasSuffix("\u{1b}]4;1;?\u{1b}\\Z"), out().debugDescription)
        XCTAssertEqual(answers(), [])
    }

    /// A left-in colour query LONGER than the 4 KB hold, withheld: answered by the host from the shape
    /// the stripper kept (until 2026-09-27: counted, never answered — its bytes were gone).
    func testALongLeftInQueryWithheldIsAnsweredByTheHostOnce() throws {
        let (tm, sid, pane, answers) = try quietTab()
        tm.pauseForwarding()
        let q = b("\u{1b}]4;" + String(repeating: "x;", count: 2100) + "1;?;2;?\u{07}")
        tm.injectTmuxEventsForTests(sid, stride(from: 0, to: q.count, by: 1000).map { .output(pane: pane, bytes: Array(q[$0..<min($0 + 1000, q.count)])) })
        settled(tm, sid)
        XCTAssertEqual(answers(), ["\u{1b}]4;1;rgb:cccc/0000/0000\u{1b}\\\u{1b}]4;2;rgb:4e4e/9a9a/0606\u{1b}\\"])
    }

    // MARK: L2 — a host answer is atomic with respect to keystrokes

    /// A host answer longer than one `send-keys` chunk (2048 bytes): a keystroke typed while it is being
    /// sent must not land INSIDE it. The keystroke here is typed from the hook that runs after each write
    /// of keys to the control client — between two chunks, when each chunk was its own write. The pane
    /// records exactly what it was typed.
    func testAKeystrokeCannotLandInsideAHostAnswer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-l2-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        let r = runner.run(["new-session", "-d", "-P", "-F", "#{session_id}", "stty raw -echo; exec cat > '\(file)'"])
        let sid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(r.status, 0)
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        let pane = try XCTUnwrap(tm.tmuxPaneForTests(sid))
        let lock = NSLock(); var typedOnce = false
        TerminalManager.sendKeysWrittenForTests = { [weak tm] _, n in
            lock.lock(); let first = !typedOnce && n > 1; if first { typedOnce = true }; lock.unlock()
            if first { tm?.write(Data("Z".utf8), toTerminal: .tmux(sid)) }
        }
        defer { TerminalManager.sendKeysWrittenForTests = nil }
        tm.pauseForwarding()
        let asks = (0..<100).map { "\($0);?" }.joined(separator: ";")
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]4;\(asks)\u{07}"))])
        let expected = String(decoding: TermHostReplies.answer(b("\u{1b}]4;\(asks)\u{07}"), palette: .xtermDefault, cursor: nil)!, as: UTF8.self)
        XCTAssertGreaterThan(expected.utf8.count, TerminalManager.sendKeysChunk)
        let got = { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
        waitFor("the answer and the keystroke reached the pane") { got().utf8.count == expected.utf8.count + 1 }
        XCTAssertEqual(got(), expected + "Z", "the keystroke after the whole answer, never inside it")
    }

    // MARK: C1 DECRQM and DECRQSS, answered as xterm.js answers them

    /// Every C1 DECRQM/DECRQSS the fixture measured against a real xterm.js, printed by a REAL pane on a
    /// private tmux, the tab paused (nothing reaches a client): tmux answers none of them (it reads
    /// bytes), so the host does — byte for byte xterm.js's answer, from tmux's region and `?2026` and the
    /// tab's stream tracker. DECSCA's `" q` is the one setting nothing the host keeps can say: answered as
    /// xterm.js answers a request it does not support. Each candidate after a RIS and xterm.js's options
    /// restated (`?12h`, `CSI 20 l`): the fixture measured each in a FRESH instance.
    func testC1ModeAndSettingQueriesAreAnsweredAsXtermJsAnswersThem() throws {
        struct Case: Decodable { let q: String; let answers: String; let hex: String? }
        struct Fixture: Decodable { let cases: [Case] }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/term-client-queries.json")
        let cases = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
            .filter { $0.hex == nil && ($0.q.contains("\u{9b}") && $0.q.contains("$p") || $0.q.contains("\u{90}$q")) }
        XCTAssertGreaterThanOrEqual(cases.count, 60)
        let r = runner.run(["new-session", "-d", "-P", "-F", "#{session_id}",
                            "stty -echo; while IFS= read -r h; do printf '%s' \"$h\" | xxd -r -p; done"])
        let sid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(r.status, 0)
        let tm = manager()
        let lock = NSLock(); var got: [String] = []
        tm.tmuxHostAnswerForTests = { _, b in lock.lock(); got.append(String(decoding: b, as: UTF8.self)); lock.unlock() }
        let answers = { lock.lock(); defer { lock.unlock() }; return got }
        _ = tm.openTmux(sid); _ = payload(tm)
        tm.pauseForwarding()
        for c in cases {
            let before = answers().count
            let bytes = b("\u{1b}c\u{1b}[?12h\u{1b}[20la\(c.q)b\u{1b}[m")
            _ = runner.run(["send-keys", "-t", sid, "-l", bytes.map { String(format: "%02x", $0) }.joined()])
            _ = runner.run(["send-keys", "-t", sid, "Enter"])
            let want = c.q.contains("$q\"q") ? "\u{1b}P0$r\u{1b}\\" : c.answers
            waitFor("the host answered \(c.q.debugDescription)") { answers().dropFirst(before).joined().utf8.count >= want.utf8.count }
            guard answers().count > before else { return }                  // one silence says it all
            let a = answers().dropFirst(before).joined()
            if c.q.contains("$q\"q") {
                XCTAssertEqual(a, "\u{1b}P0$r\u{1b}\\", "DECSCA: not kept")
            } else {
                XCTAssertEqual(a, c.answers, c.q.debugDescription)
            }
        }
    }

    // MARK: the tracker behind the host's C1 DECRQM answers

    /// A snapshot SEEDS the tracker with what it states — the keypad, IRM, ?7 and ?6 from tmux's formats
    /// — so a C1 DECRQM after it reports what the client's fresh instance was built with. The modes are
    /// set BEFORE the tab opens: only the snapshot can know them.
    func testTheSnapshotSeedsTheModesTheHostAnswersFrom() throws {
        let r = runner.run(["new-session", "-d", "-P", "-F", "#{session_id}",
                            "printf '\\033=\\033[4h\\033[?7l\\033[?6h'; stty raw -echo; exec cat >/dev/null"])
        XCTAssertEqual(r.status, 0)
        let sid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        waitFor("the pane set its modes") { self.runner.run(["display", "-p", "-t", sid, "#{keypad_flag}#{insert_flag}"]).stdout.hasPrefix("11") }
        let tm = manager()
        let lock = NSLock(); var got: [String] = []
        tm.tmuxHostAnswerForTests = { _, b in lock.lock(); got.append(String(decoding: b, as: UTF8.self)); lock.unlock() }
        _ = tm.openTmux(sid); _ = payload(tm)
        let pane = try XCTUnwrap(tm.tmuxPaneForTests(sid))
        tm.pauseForwarding()
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{9b}?66$p\u{9b}4$p\u{9b}?7$p\u{9b}?6$p"))])
        let want = "\u{1b}[?66;1$y\u{1b}[4;1$y\u{1b}[?7;2$y\u{1b}[?6;1$y"
        waitFor("answered") { lock.lock(); defer { lock.unlock() }; return got.joined().utf8.count >= want.utf8.count }
        lock.lock(); XCTAssertEqual(got.joined(), want); lock.unlock()
    }

    /// A C1 DECRQM followed IN THE SAME READ by a change to the mode it asks: xterm.js answers the mode
    /// where it parsed the query (measured, `term-client-queries.json`), and so does the host — withheld
    /// by a pause, and forwarded into no client.
    func testAC1ModeQueryIsAnsweredFromTheModesWhereItWasAsked() throws {
        for path in ["paused", "reached nobody"] {
            let (tm, sid, pane, answers) = try quietTab()
            if path == "paused" { tm.pauseForwarding() } else { tm.onEmit = { [rec] e in _ = rec.record(e); return false } }
            tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{9b}?1$p\u{1b}[?1h\u{1b}[4h\u{9b}4$p\u{1b}[4l"))])
            let want = "\u{1b}[?1;2$y\u{1b}[4;1$y"
            waitFor("answered (\(path))") { answers().joined().utf8.count >= want.utf8.count }
            XCTAssertEqual(answers().joined(), want, path)
        }
    }

    // MARK: a flood of left-in queries is bounded

    /// A flood of withheld reads, each completing a left-in query, SHARES round trips: one `display` in
    /// flight per tab, the reads arriving meanwhile answered together when it lands — in query order,
    /// each once. One round trip per read (the design until 2026-09-27) put a `display` per read in
    /// tmux's queue and, measured, a 5 MB flood waited 5.39 s for one: past the 5 s timeout that kills
    /// the tab's control client.
    func testAFloodOfWithheldReadsSharesRoundTrips() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        tm.pauseForwarding()
        let n = 500
        tm.injectTmuxEventsForTests(sid, (0..<n).map { .output(pane: pane, bytes: b("\u{1b}]4;\($0 % 256);?\u{07}")) })
        waitFor("every query answered") { answers().joined().components(separatedBy: "rgb:").count - 1 == n }
        settled(tm, sid)
        let p = TermPalette.xtermDefault
        let expected = (0..<n).map { String(decoding: TermHostReplies.answer(b("\u{1b}]4;\($0 % 256);?\u{07}"), palette: p, cursor: nil)!, as: UTF8.self) }
        XCTAssertEqual(answers().joined(), expected.joined(), "in query order, each once")
        XCTAssertLessThanOrEqual(answers().count, 3, "round trips shared, not one per read (\(answers().count))")
    }

    /// And what the host has typed but tmux has not yet acknowledged is CAPPED
    /// (`TerminalManager.maxHostAnswerBytes`): answers past it are DROPPED — the flood's tail goes
    /// unanswered, never answered twice, never out of order — and the budget comes back once tmux has
    /// caught up, so the next query is answered.
    func testAFloodPastTheAnswerCapIsDroppedNotQueued() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        tm.pauseForwarding()
        let q = b("\u{1b}]4;1;?\u{07}")
        let one = "\u{1b}]4;1;rgb:cccc/0000/0000\u{1b}\\"
        let n = 2 * TerminalManager.maxHostAnswerBytes / one.utf8.count
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: Array((0..<n).map { _ in q }.joined()))])
        settled(tm, sid)
        let got = answers().joined()
        XCTAssertGreaterThan(got.utf8.count, 0)
        XCTAssertLessThanOrEqual(got.utf8.count, TerminalManager.maxHostAnswerBytes)
        XCTAssertEqual(got, String(repeating: one, count: got.utf8.count / one.utf8.count), "whole answers, a prefix")
        let before = answers().count
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]12;?\u{07}"))])
        waitFor("the budget came back") { answers().count > before }
        XCTAssertEqual(answers().last, "\u{1b}]12;rgb:ffff/ffff/ffff\u{1b}\\")
    }

    /// The budget comes back through the REAL acknowledgement: answers typed with `send-keys` (no test
    /// hook standing in for tmux) are counted against the cap until tmux has answered each command, and
    /// only then returned — so a flood past the cap is followed, once tmux has caught up, by an answered
    /// query. Removing the acknowledgement leaves the budget spent for good (a permanent silence).
    func testTheRealSendKeysAcknowledgementReturnsTheBudget() throws {
        // A pane that reads and discards what is typed into it: the answers land nowhere that echoes.
        let r = runner.run(["new-session", "-d", "-P", "-F", "#{session_id}", "stty raw -echo; exec cat >/dev/null"])
        let sid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(r.status, 0)
        let tm = manager()
        let lock = NSLock(); var typed: [String] = []
        tm.tmuxHostAnswerTypedForTests = { _, b in lock.lock(); typed.append(String(decoding: b, as: UTF8.self)); lock.unlock() }
        let got = { lock.lock(); defer { lock.unlock() }; return typed }
        _ = tm.openTmux(sid); _ = payload(tm)
        let pane = try XCTUnwrap(tm.tmuxPaneForTests(sid))
        tm.pauseForwarding()
        let q = b("\u{1b}]4;1;?\u{07}")
        let one = "\u{1b}]4;1;rgb:cccc/0000/0000\u{1b}\\"
        let n = 2 * TerminalManager.maxHostAnswerBytes / one.utf8.count
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: Array((0..<n).map { _ in q }.joined()))])
        waitFor("the flood's prefix typed") { !got().isEmpty }
        XCTAssertLessThanOrEqual(got().joined().utf8.count, TerminalManager.maxHostAnswerBytes)
        waitFor("tmux acknowledged every send-keys") { tm.tmuxAnswersUnackedForTests(sid) == 0 }
        let before = got().count
        tm.injectTmuxEventsForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]12;?\u{07}"))])
        waitFor("the next query is answered") { got().count > before }
        XCTAssertEqual(got().last, "\u{1b}]12;rgb:ffff/ffff/ffff\u{1b}\\")
    }

    /// Queries left for the host while the tab has NO control client (between its client's exit and the
    /// replacement) are dropped — and COUNTED and logged, as the cap's drops are, never silently.
    func testQueriesDroppedForAMissingClientAreCounted() throws {
        let (tm, sid, pane, answers) = try answeringTab()
        let lock = NSLock(); var dropped: [Int] = []
        tm.onTmuxAnswersDroppedForTests = { _, n in lock.lock(); dropped.append(n); lock.unlock() }
        tm.pauseForwarding()
        tm.injectTmuxEventsWithoutClientForTests(sid, [.output(pane: pane, bytes: b("\u{1b}]4;1;?\u{07}\u{1b}]12;?\u{07}")),
                                                       .output(pane: pane, bytes: b("\u{1b}]4;2;?\u{07}"))])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(answers(), [], "no client: nothing can be typed")
        lock.lock(); let total = dropped.reduce(0, +); lock.unlock()
        XCTAssertEqual(total, 3, "every query counted as dropped")
    }

    /// A listing that cannot be TAKEN is not "no sessions": an open must fail as a failure, not as "gone".
    func testUnreachableTmuxForgetsNothing() {
        let broken = TmuxRunner.locate(environment: ["PATH": "/nonexistent"], fileExists: { $0 == "/nonexistent/tmux" })!
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.tmux = broken
        if case .failure(.failed) = tm.openTmux("$1") {} else { XCTFail("expected .failed") }
        XCTAssertTrue(tm.isEmpty)
    }

    // MARK: one control client per open tab

    /// A change of driver KEEPS the tmux tabs: they are the SESSION's, not the outgoing driver's
    /// (docs/superpowers/specs/2026-09-29-host-session-state-design.md) — the incoming driver finds
    /// them open with their control clients still attached. Until 2026-09-29 `apply` dropped them
    /// (`dropTmuxTabs`) and each client restored its own from page memory, which a reload or a new
    /// device did not have.
    func testAChangeOfDriverKeepsTmuxTabsAttached() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        let hub = ChannelHub(terminals: tm, injector: nil, encoder: TmuxNullVideo(),
                             terminalPauseHold: .milliseconds(50))
        let x = PionPeer(clientId: "x", turn: nil), y = PionPeer(clientId: "y", turn: nil)
        defer { x.close(); y.close() }
        hub.register(clientId: "x", peer: x)                     // the driver
        hub.register(clientId: "y", peer: y)                     // passive
        if case .failure(let e) = tm.openTmux(a) { XCTFail("open \(a): \(e)") }
        waitFor("a's control client attached") { self.controlClients(a) == 1 }
        hub.pionPeer(y, didReceive: wrapMessage(Data(#"{"t":"claim-control"}"#.utf8)), on: .control)
        XCTAssertEqual(tm.descriptors().tabs.map(\.id), [.tmux(a)], "the tab survives the change of driver")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(controlClients(a), 1, "and its control client stays attached")
    }

    private func windowSize(_ sid: String) -> String { runner.run(["display", "-p", "-t", sid, "#{window_width}x#{window_height}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func controlClients(_ sid: String) -> Int {
        runner.run(["list-clients", "-t", sid, "-F", "#{client_control_mode}"]).stdout.split(whereSeparator: \.isNewline).filter { $0 == "1" }.count
    }
    private func waitFor(_ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(cond(), what)
    }
    /// Someone else's client on `sid` at 206x58 — the user's own terminal, as far as tmux can tell.
    private func otherClient(_ sid: String) throws -> TmuxControlClient {
        let c = try XCTUnwrap(TmuxControlClient(runner: runner, session: sid, onEvent: { _ in }, onExit: {}))
        c.command("refresh-client -C 206x58") { _ in }
        return c
    }

    /// Every open tmux tab keeps its OWN control client attached, so moving between open tabs attaches
    /// and detaches nothing. With one client switched between sessions, a session shared with another
    /// client was resized on EVERY switch, and its app redrew — the flicker on switching to codex.
    func testEveryOpenTabStaysAttached() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)
        XCTAssertEqual(controlClients(a), 1, "A keeps its client while B is on screen")
        XCTAssertEqual(controlClients(b), 1)
        XCTAssertTrue(tm.close(.tmux(a)))
        waitFor("closing A's tab detaches only A's client") { self.controlClients(a) == 0 }
        XCTAssertEqual(controlClients(b), 1)
    }

    /// The case that flickered: a session also open elsewhere at another size. While rdev is the latest
    /// client its window keeps rdev's size — switching away and back resizes NOTHING.
    func testSwitchingBetweenOpenTabsDoesNotResizeASharedSession() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let other = try otherClient(a)
        waitFor("the other client sizes A") { self.windowSize(a) == "206x58" }
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        waitFor("opening A makes rdev the latest client") { self.windowSize(a) == "80x24" }
        _ = tm.openTmux(b); _ = payload(tm)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(windowSize(a), "80x24", "switching AWAY must not hand A back to the other client")
        XCTAssertTrue(tm.switchTo(.tmux(a))); _ = payload(tm)
        XCTAssertEqual(windowSize(a), "80x24")
        other.stop()
    }

    /// When the other client took the size meanwhile (the user typed at the Mac), switching to the tab
    /// CLAIMS it back — or rdev would render 206-column output in its 80-column terminal.
    func testSwitchingToATabClaimsItsSizeBack() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)
        let other = try otherClient(a)
        other.command("switch-client -t \(a)") { _ in }                 // the other client is latest now
        waitFor("the other client took A") { self.windowSize(a) == "206x58" }
        XCTAssertTrue(tm.switchTo(.tmux(a))); _ = payload(tm)
        waitFor("switching to A claims it") { self.windowSize(a) == "80x24" }
        other.stop()
    }

    /// Typing through rdev does NOT make its client tmux's latest (`send-keys` is not a key from the
    /// client — measured). So after someone else took the size, the next keystroke claims it first.
    func testTypingClaimsTheSizeBackAfterSomeoneElseTookIt() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        let other = try otherClient(a)
        other.command("switch-client -t \(a)") { _ in }
        waitFor("the other client took A") { self.windowSize(a) == "206x58" }
        Thread.sleep(forTimeInterval: 0.3)                                // rdev hears the %layout-change
        tm.write(Data("echo claim\r".utf8), toTerminal: .tmux(a))
        waitFor("a keystroke claims A back") { self.windowSize(a) == "80x24" }
        other.stop()
    }

    /// A tmux tab opens at the grid the driver REPORTED, even with no tab open yet. The hub used to pass
    /// its active tab's grid `?? (80, 24)` — nil with an empty pool — so the first tab attached at 80x24 and was
    /// resized again when the client's real size arrived: two resizes, two redraws of the app.
    func testOpeningUsesTheReportedGridWithNoTabOpen() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        tm.resizeAll(cols: 117, rows: 33)                              // the driver's fit, no tab yet
        _ = tm.openTmux(a); _ = payload(tm)
        waitFor("A opens at the reported grid") { self.windowSize(a) == "117x33" }
    }

    /// A RESIZE RE-SENDS THE TAB, FROM TMUX, AT THE NEW SIZE (docs/terminal.md). The client reflows its
    /// own copy the moment it fits and tmux reflows its own, and output the pane wrote for the old size
    /// reaches the client after it resized: the two drift (a phone's keyboard, 2026-09-29: lines drawn
    /// twice until a reload), and a new driver's wire snapshot taken at the OLD driver's width was
    /// stretched by xterm.js to the new one. Queued behind the tab's `refresh-client -C`, on its own
    /// client, so it is taken once tmux has the new size.
    func testAResizeResendsTheTabAtTheNewSize() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        waitFor("the tab opens at 80x24") { self.windowSize(sid) == "80x24" }
        let mark = rec.count
        tm.resizeAll(cols: 101, rows: 31)
        rec.wait("a snapshot follows the resize") { !rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
        XCTAssertEqual(rec.snapshots(of: .tmux(sid), since: mark).first?.size, TermGridSize(cols: 101, rows: 31),
                       "taken once tmux has the new size")
    }

    /// The same grid again re-sends nothing: the driver reports it on every fit.
    func testAnUnchangedResizeResendsNothing() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        let mark = rec.count
        tm.resizeAll(cols: 80, rows: 24)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(rec.snapshots(of: .tmux(sid), since: mark).isEmpty)
    }

    // MARK: a character half-read by tmux at the boundary of a withheld stretch

    /// A program that prints `X` and the LEAD bytes of `─` (E2 94), then — once `release()` is called —
    /// the last byte (80) and `Y`. tmux reads the two writes separately, so it holds E2 94 in its parser
    /// meanwhile: its grid shows `X`, the cursor is after it, and `─` exists nowhere yet.
    private func splitWriter(in sid: String) throws -> (release: () -> Void, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let go = dir.appendingPathComponent("go").path
        let script = dir.appendingPathComponent("w.py")
        try """
        import os, time, tty
        tty.setraw(0)
        os.write(1, b'\\x1b[2J\\x1b[HX\\xe2\\x94')
        while not os.path.exists('\(go)'): time.sleep(0.02)
        os.write(1, b'\\x80Y\\r\\n')
        time.sleep(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        _ = runner.run(["send-keys", "-t", sid, "python3 \(script.path)", "Enter"])
        waitFor("the pane shows X, and not the half-read character") {
            self.pane(sid).split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) == "X" } ?? false
        }
        return ({ FileManager.default.createFile(atPath: go, contents: Data()) },
                { try? FileManager.default.removeItem(at: dir) })
    }

    /// While the driver is hidden tmux reads the lead bytes and rdev carries them; the resume's
    /// snapshot has the cursor after `X`. The first live bytes (80 Y) must arrive WITH the lead bytes.
    func testACharacterSplitAcrossAPauseArrivesWhole() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid)
        _ = payload(tm)
        tm.pauseForwarding()
        let w = try splitWriter(in: sid)
        defer { w.cleanup() }
        let mark = rec.count
        tm.resumeForwarding()
        rec.wait("the resume's snapshot") { !rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
        let p = String(decoding: rec.snapshots(of: .tmux(sid), since: mark)[0].bytes, as: UTF8.self)
        XCTAssertTrue(p.contains("X") && !p.contains("X\u{2500}"), "the snapshot excludes the half-read character")
        let out = collectOutput(tm, .tmux(sid))
        w.release()
        waitFor("the rest of the character is forwarded") { out().contains("Y") }
        XCTAssertFalse(out().contains("\u{FFFD}"), "no U+FFFD: \(out().debugDescription)")
        XCTAssertTrue(out().contains("\u{2500}Y"), "the whole character arrives before Y: \(out().debugDescription)")
    }

    /// A pane's stream carry lives only as long as the pane: the next attach lists the session's
    /// panes and forgets the carries of the ones that are gone (they were never pruned before).
    func testCarriesOfClosedPanesAreDropped() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid)
        _ = payload(tm)
        let extra = runner.run(["split-window", "-d", "-t", sid, "-P", "-F", "#{pane_id}",
                                "printf 'from the other pane'; sleep 30"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(extra.hasPrefix("%"), "split-window printed \(extra)")
        waitFor("the other pane's output reached its carry") { tm.carriedPanes(sid).contains(extra) }
        _ = runner.run(["kill-pane", "-t", extra])
        _ = payload(tm)
        let active = runner.run(["display", "-p", "-t", sid, "#{pane_id}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(tm.carriedPanes(sid), [active], "only live panes keep a carry")
    }

    // MARK: live tabs

    /// A background tmux tab's lead bytes reach rdev now (its client's output is never off), so a
    /// character split across two reads arrives whole with no fresh snapshot — the orphan case of the
    /// old design cannot happen.
    func testASplitCharacterInABackgroundTabArrivesWhole() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)                                // A is in the background
        let out = collectOutput(tm, .tmux(a))
        let snapsBefore = rec.snapshots(of: .tmux(a)).count
        let w = try splitWriter(in: a)
        defer { w.cleanup() }
        w.release()
        waitFor("A's pane has the whole character") { self.pane(a).contains("X\u{2500}Y") }
        waitFor("and so does its stream") { out().contains("\u{2500}Y") }
        XCTAssertFalse(out().contains("\u{FFFD}"))
        XCTAssertEqual(rec.snapshots(of: .tmux(a)).count, snapsBefore, "no fresh snapshot was needed")
    }

    /// REVIEW FOCUS 1, tmux: snapshot + the `%output` after it == tmux's own screen AND history, while
    /// printing. The WHOLE history, not only the screen: a row lost or doubled at the snapshot's
    /// boundary has scrolled off long before the loop ends, so a screen comparison cannot see it. The
    /// loop stays under tmux's default `history-limit` (2000) so tmux still holds every row, and pauses
    /// every 100 rows so it is still printing when the snapshot lands.
    func testSnapshotAndLiveOutputComposeToTmuxsScreen() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        let out = collectOutput(tm, .tmux(sid))
        _ = runner.run(["send-keys", "-t", sid, "for i in $(seq 1 1500); do echo \"line $i $i\"; [ $((i % 100)) = 0 ] && sleep 0.05; done; echo DO''NE", "Enter"])
        waitFor("printing started") { out().contains("line 40 ") }
        let mark = rec.count
        tm.snapshot(.tmux(sid))
        waitFor("the loop finished") { self.pane(sid).contains("DONE") }
        let snapIndex = try XCTUnwrap(rec.all.indices.dropFirst(mark).first { if case .snapshot(.tmux(sid), _, _) = rec.all[$0] { return true }; return false })
        guard case .snapshot(_, let size, let bytes) = rec.all[snapIndex] else { return XCTFail() }
        let snapText = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(snapText.contains("line 1500 "), "the snapshot landed mid-stream (else this proves nothing)")
        func trimmed(_ rows: [String]) -> [String] {
            var r = rows.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            while r.last == "" { r.removeLast() }
            return r
        }
        func mine() -> [String] {
            let replica = Terminal(cols: size.cols, rows: size.rows)
            _ = replica.feed(bytes)
            _ = replica.feed(rec.output(of: .tmux(sid), since: snapIndex + 1))
            return trimmed(replica.snapshot().normal.lines.map { $0.cells.map { $0.text.isEmpty ? " " : $0.text }.joined() })
        }
        func truth() -> [String] {
            trimmed(runner.run(["capture-pane", "-p", "-S", "-", "-t", sid]).stdout
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        // A CONDITION, not a settle: the `%output` after DONE (the prompt) may still be on its way.
        // Bounded (waitFor's 10 s), and the assertion below still states what must hold.
        waitFor("the stream caught up with tmux's screen") { let t = truth(); return Array(mine().suffix(t.count)) == t }
        let t = truth()
        XCTAssertGreaterThan(t.count, 1500, "tmux kept every row")
        XCTAssertEqual(Array(mine().suffix(t.count)), t, "nothing lost or doubled between the snapshot and the live bytes after it")
    }

    /// A snapshot that keeps timing out (a starved host) must not restart its control client at the
    /// same short interval for good: each consecutive timeout doubles the next batch's, and a snapshot
    /// that succeeds starts again from the base. Stalled here by a `run-shell 'sleep 1'` ahead of the
    /// batch, which holds tmux's command queue: 0.3 s and 0.6 s time out (each kills the client, whose
    /// restart snapshots again), 1.2 s outlasts the stall and succeeds. A FIXED 0.3 s times out on all
    /// three stalled batches and needs a fourth.
    func testASnapshotThatKeepsTimingOutBacksOffAndASuccessResetsIt() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        tm.tmuxSnapshotTimeoutBase = 0.3
        tm.stallTmuxSnapshotsForTests(3, seconds: 1)
        _ = tm.openTmux(sid)
        rec.wait("the tab's first snapshot") { !rec.snapshots(of: .tmux(sid)).isEmpty }
        XCTAssertEqual(tm.tmuxSnapshotTimeoutsForTests(), [0.3, 0.6, 1.2], "each timeout doubled the next; the third outlasted the stall")
        _ = payload(tm)
        XCTAssertEqual(tm.tmuxSnapshotTimeoutsForTests().last, 0.3, "a success resets it")
    }

    /// A failed snapshot is retried 250 ms later — unless the tab was snapshotted AGAIN meanwhile (a
    /// resume, a claim, a new wire): that newer snapshot is the retry, and a second one would only be
    /// another full repaint of the tab on the client.
    func testAFailedSnapshotsRetryIsSkippedWhenANewerSnapshotWasIssued() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        tm.failTmuxSnapshotsForTests(1)
        _ = tm.openTmux(sid)                                              // batch 1: fails (%error)
        tm.snapshot(.tmux(sid))                                           // batch 2: issued before the retry
        rec.wait("the newer snapshot lands") { !rec.snapshots(of: .tmux(sid)).isEmpty }
        Thread.sleep(forTimeInterval: 0.6)                                // past the 250 ms retry
        tm.syncTmuxQueueForTests(sid)
        XCTAssertEqual(tm.tmuxSnapshotTimeoutsForTests().count, 2, "no third batch: the stale retry was skipped")
        XCTAssertEqual(rec.snapshots(of: .tmux(sid)).count, 1)
        XCTAssertTrue(tm.descriptors().tabs.contains { $0.id == .tmux(sid) }, "the tab is still open")
    }

    /// `?1004` has no tmux format: the tracker learns it from the stream, and a re-snapshot keeps it.
    func testFocusReportingSurvivesAResnapshot() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        let out = collectOutput(tm, .tmux(sid))
        _ = runner.run(["send-keys", "-t", sid, "printf '\\033[?1004hfo''cus'", "Enter"])
        waitFor("the app turned focus reporting on") { out().contains("focus") }
        XCTAssertTrue(payload(tm).contains("\u{1b}[?1004h"))
    }

    /// ...and one the app sets while the driver is PAUSED: nothing is forwarded, but the tracker is still
    /// fed from the pane's stream (tracking is independent of forwarding), so the resume's snapshot
    /// carries it. tmux has no ?1004 format: a tracker that skipped these bytes states it OFF.
    func testFocusReportingSetWhilePausedSurvivesTheResume() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        tm.pauseForwarding()
        _ = runner.run(["send-keys", "-t", sid, "printf '\\033[?1004hfo''cus'", "Enter"])
        waitFor("tmux printed it") { self.pane(sid).contains("focus") }
        Thread.sleep(forTimeInterval: 0.5)                                 // the %output reached the manager
        let mark = rec.count
        tm.resumeForwarding()
        rec.wait("the resume snapshots the tab") { !rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
        let snap = String(decoding: rec.snapshots(of: .tmux(sid), since: mark)[0].bytes, as: UTF8.self)
        XCTAssertTrue(snap.contains("\u{1b}[?1004h"), "the resume's snapshot states ?1004 on")
        XCTAssertFalse(snap.contains("\u{1b}[?1004l"))
    }

    func testPauseStopsTmuxOutputAndResumeSnapshots() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let (tm, b) = blockingManager()
        _ = tm.openTmux(sid); _ = payload(tm)
        tm.pauseForwarding()
        let mark = rec.count
        _ = runner.run(["send-keys", "-t", sid, "echo while''hidden", "Enter"])
        waitFor("tmux printed it") { self.pane(sid).contains("whilehidden") }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(rec.output(of: .tmux(sid), since: mark), [], "nothing forwarded while paused")
        tm.resumeForwarding()
        rec.wait("the resume snapshots the tab") { !rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
        XCTAssertTrue(String(decoding: rec.snapshots(of: .tmux(sid), since: mark)[0].bytes, as: UTF8.self).contains("whilehidden"))

        // Deterministically, no byte may be forwarded between the pause LIFTING and the resume's
        // snapshot (it would paint onto the view from before the pause): hold the tab's queue on a live
        // chunk while it keeps printing, pause and resume behind it, then let everything through.
        _ = runner.run(["send-keys", "-t", sid, "for i in $(seq 1 400); do echo tick $i; sleep 0.005; done", "Enter"])
        b.arm(sid)
        XCTAssertEqual(b.entered.wait(timeout: .now() + 10), .success, "the queue is held on a live chunk")
        tm.pauseForwarding()
        Thread.sleep(forTimeInterval: 0.3)                                 // ticks queue up behind it
        let resumed = rec.count
        tm.resumeForwarding()                                              // its snapshot is queued last
        Thread.sleep(forTimeInterval: 0.2)
        b.gate.signal()
        // Past the HELD chunk (index `resumed`, itself ticks): waiting from `resumed` let that chunk alone answer, and
        // the check below ran before the snapshot's tmux round trip — measured 2 in 10 on this machine, 2026-10-11.
        waitFor("output flows after the resume's snapshot") { rec.text(of: .tmux(sid), since: resumed + 1).contains("tick") }
        // A snapshot, or a long history's SCREEN (docs/terminal.md, "Scrollback comes after the screen").
        let first = rec.all.dropFirst(resumed + 1).first {
            switch $0 { case .snapshot(.tmux(sid), _, _), .screen(.tmux(sid), _, _), .output(.tmux(sid), _): return true; default: return false }
        }
        switch first { case .snapshot?, .screen?: break; default: XCTFail("the first emission after the resume is its snapshot, not \(String(describing: first))") }
    }

    func testClosingATmuxTabEmitsClosed() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        XCTAssertTrue(tm.close(.tmux(sid)))
        XCTAssertEqual(rec.closed(), [.tmux(sid)])
    }

    /// Every emission for a tmux tab — its snapshots, its output and its `closed`, on every path that
    /// closes one (the driver's `×`, a change of driver, the session ending) — is made ON its control
    /// client's callback queue: the queue that delivers the pane's `%output` and the snapshot batch's
    /// replies in tmux's own order. Emitted from anywhere else (a snapshot handed to another queue, a
    /// `closed` sent from the closing thread), it can overtake output it precedes in the stream or
    /// follow output it ends. The probe sees that on EVERY emission, without having to win the race.
    func testEveryTmuxEmissionIsMadeOnItsControlClientsQueue() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let c = try XCTUnwrap(runner.newSession())
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.tmux = runner
        let r = EmissionRecorder()
        rec = r
        let probe = NSLock(); var on: [String] = [], off: [String] = []
        // Which session each control client INSTANCE belongs to — only its own client's queue counts.
        let expected = ClientMap()
        tm.onEmit = { e in
            var session: String?
            switch e {
            case .snapshot(.tmux(let s), _, _), .screen(.tmux(let s), _, _), .history(.tmux(let s), _, _): session = s
            case .output(.tmux(let s), _): session = s
            case .closed(.tmux(let s)): session = s
            default: session = nil
            }
            if let session {
                let mine = expected.instance(for: session) { tm.tmuxClientInstanceForTests(session) }
                let queued = mine != nil && TmuxControlClient.currentCallbackQueueInstance == mine
                let kind: String
                switch e {
                case .snapshot: kind = "snapshot"; case .screen: kind = "screen"; case .history: kind = "history"
                case .output: kind = "output"; case .closed: kind = "closed"
                }
                probe.lock(); if queued { on.append(kind) } else { off.append("\(kind) \(session)") }; probe.unlock()
            }
            return r.record(e)
        }
        _ = tm.openTmux(a); _ = payload(tm)
        let out = collectOutput(tm, .tmux(a))
        _ = runner.run(["send-keys", "-t", a, "echo on''queue", "Enter"])
        waitFor("a's output") { out().contains("onqueue") }
        _ = tm.openTmux(b); _ = payload(tm)
        XCTAssertTrue(tm.close(.tmux(b)))                                  // the driver's ×
        XCTAssertEqual(r.closed(), [.tmux(b)], "closed before close() returns: nothing can reopen ahead of it")
        XCTAssertTrue(tm.killTmux(a))                                      // the session ends
        r.wait("a's closed") { r.closed().contains(.tmux(a)) }
        _ = tm.openTmux(c); _ = payload(tm)
        tm.closeAll()                                                      // Stop Sharing
        XCTAssertEqual(r.closed().last, .tmux(c), "closed before closeAll returns")
        probe.lock(); let (onQ, offQ) = (on, off); probe.unlock()
        XCTAssertEqual(offQ, [], "emitted OFF the control client's queue")
        for kind in ["snapshot", "output", "closed"] { XCTAssertTrue(onQ.contains(kind), "the probe saw a \(kind)") }
        XCTAssertEqual(r.closed().filter { $0 == .tmux(a) }.count, 1, "one closed per tab")
    }

    /// A recorder that, once armed, HOLDS the first tmux emission of `session` inside the hook — and so
    /// holds that tab's control-client callback queue — until released.
    private final class QueueBlocker: @unchecked Sendable {
        private let lock = NSLock()
        private var armed: String?
        let entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        func arm(_ session: String) { lock.lock(); armed = session; lock.unlock() }
        func hook(_ e: TermEmission) {
            let s: String?
            switch e { case .snapshot(.tmux(let x), _, _), .output(.tmux(let x), _): s = x; default: s = nil }
            lock.lock(); let hit = s != nil && s == armed; if hit { armed = nil }; lock.unlock()
            if hit { entered.signal(); gate.wait() }
        }
    }

    private func blockingManager() -> (TerminalManager, QueueBlocker) {
        let tm = manager(), b = QueueBlocker(), r = rec
        tm.onEmit = { e in b.hook(e); return r.record(e) }
        return (tm, b)
    }

    /// The driver's `×` and Stop Sharing's `closeAll` return only once the tab's `closed` is emitted — and it
    /// is emitted BEHIND whatever the tab's queue is already delivering. With its queue held, neither
    /// returns; released, `closed` is there when they do. (A `closed` handed off without waiting could
    /// follow the snapshot of the same session reopened at once.)
    func testClosingATmuxTabWaitsForItsQueue() throws {
        for viaCloseAll in [false, true] {
            let a = try XCTUnwrap(runner.newSession())
            let (tm, b) = blockingManager()
            _ = tm.openTmux(a); _ = payload(tm)
            b.arm(a)
            tm.snapshot(.tmux(a))
            XCTAssertEqual(b.entered.wait(timeout: .now() + 10), .success, "the queue is held")
            let done = DispatchSemaphore(value: 0)
            let closedAtReturn = NSLock(); var atReturn: [TermTabID] = []
            DispatchQueue.global().async {
                if viaCloseAll { tm.closeAll() } else { _ = tm.close(.tmux(a)) }
                let c = self.rec.closed()
                closedAtReturn.lock(); atReturn = c; closedAtReturn.unlock()
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 0.5), .timedOut, "\(viaCloseAll ? "closeAll" : "close") returned while the queue was held")
            XCTAssertEqual(rec.closed(), [], "closed overtook what the queue was delivering")
            b.gate.signal()
            XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
            closedAtReturn.lock(); let c = atReturn; closedAtReturn.unlock()
            XCTAssertEqual(c, [.tmux(a)], "closed is emitted before \(viaCloseAll ? "closeAll" : "close") returns")
        }
    }

    /// A session ENDING (here `kill`) closes its tab from whichever thread noticed — the caller, or
    /// ANOTHER tab's queue on `%sessions-changed` — and `closed` still goes onto the tab's own queue,
    /// behind what it is delivering; nothing waits for it there (two queues could wait on each other).
    func testASessionEndingEmitsClosedBehindItsQueue() throws {
        let a = try XCTUnwrap(runner.newSession())
        let (tm, b) = blockingManager()
        _ = tm.openTmux(a); _ = payload(tm)
        b.arm(a)
        tm.snapshot(.tmux(a))
        XCTAssertEqual(b.entered.wait(timeout: .now() + 10), .success, "the queue is held")
        XCTAssertTrue(tm.killTmux(a))                                       // does not wait
        XCTAssertTrue(tm.isEmpty)
        XCTAssertEqual(rec.closed(), [], "closed overtook what the queue was delivering")
        b.gate.signal()
        rec.wait("closed follows") { rec.closed() == [.tmux(a)] }
        let last = rec.all.lastIndex { if case .snapshot(.tmux(a), _, _) = $0 { return true }; return false }
        let closedAt = rec.all.lastIndex { if case .closed(.tmux(a)) = $0 { return true }; return false }
        XCTAssertLessThan(try XCTUnwrap(last), try XCTUnwrap(closedAt), "the held snapshot, then closed")
    }

    // MARK: fix round 1

    /// Each session's control-client INSTANCE, learnt the first time the session emits (while its tab
    /// is open) and remembered after the tab closes. Only that client's queue counts.
    private final class ClientMap: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: UUID] = [:]
        func instance(for session: String, _ ask: () -> UUID?) -> UUID? {
            lock.lock(); defer { lock.unlock() }
            if let id = known[session] { return id }
            let id = ask()
            known[session] = id
            return id
        }
    }

    /// M1: a snapshot batch that fails (a real `%error`) is retried once — and the retry's snapshot is
    /// what the tab shows. Nothing is closed and nothing is reported.
    func testAFailedSnapshotIsRetriedOnce() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        let errors = NSLock(); var reported: [String] = []
        tm.onTmuxError = { s, r in errors.lock(); reported.append("\(s) \(r)"); errors.unlock() }
        tm.failTmuxSnapshotsForTests(1)
        _ = tm.openTmux(a)                                               // its first snapshot fails
        rec.wait("the retry's snapshot") { !rec.snapshots(of: .tmux(a)).isEmpty }
        XCTAssertTrue(String(decoding: rec.snapshots(of: .tmux(a)).first?.bytes ?? [], as: UTF8.self).hasPrefix(Self.fullAttach))
        XCTAssertEqual(tm.descriptors().tabs.map(\.id), [.tmux(a)])
        XCTAssertEqual(rec.closed(), [])
        errors.lock(); XCTAssertEqual(reported, []); errors.unlock()
        let out = collectOutput(tm, .tmux(a))
        _ = runner.run(["send-keys", "-t", a, "echo re''tried", "Enter"])
        rec.wait("and the tab streams") { out().contains("retried") }
    }

    /// M1: when the retry fails too, the tab is CLOSED with a reason the client shows (`tmux-error`,
    /// and the wire's `closed`) — never left blank, or frozen while keystrokes still reach the pane.
    /// The session itself is untouched.
    func testASnapshotThatFailsTwiceClosesTheTabWithAReason() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        let errors = NSLock(); var reported: [String] = []
        tm.onTmuxError = { s, r in errors.lock(); reported.append("\(s) \(r)"); errors.unlock() }
        _ = tm.openTmux(a); _ = payload(tm)                              // live
        let mark = rec.count
        tm.failTmuxSnapshotsForTests(2)
        tm.snapshot(.tmux(a))                                            // the re-snapshot and its retry fail
        rec.wait("the tab is closed on the wire") { rec.closed(since: mark) == [.tmux(a)] }
        XCTAssertTrue(tm.isEmpty)
        XCTAssertEqual(rec.snapshots(of: .tmux(a), since: mark).count, 0)
        waitFor("the driver is told why") { errors.lock(); defer { errors.unlock() }; return reported == ["\(a) snapshot-failed"] }
        XCTAssertTrue(runner.listSessions().contains { $0.id == a }, "the session lives on")
        waitFor("its control client detached") { self.controlClients(a) == 0 }
    }

    /// M2: claiming a window's size BACK re-snapshots the tab after the claim, at rdev's size — the
    /// output it streamed meanwhile was written for another client's size, and only a full-screen app
    /// would redraw it away.
    func testSwitchingBackToATakenWindowResnapshotsItAtRdevsSize() throws {
        let a = try XCTUnwrap(runner.newSession()), b = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        _ = tm.openTmux(b); _ = payload(tm)
        let other = try otherClient(a)
        defer { other.stop() }
        other.command("switch-client -t \(a)") { _ in }
        waitFor("the other client took A") { self.windowSize(a) == "206x58" }
        Thread.sleep(forTimeInterval: 0.3)                                // rdev hears the %layout-change
        let mark = rec.count
        XCTAssertTrue(tm.switchTo(.tmux(a)))
        rec.wait("A is re-snapshotted after the claim") { !rec.snapshots(of: .tmux(a), since: mark).isEmpty }
        XCTAssertEqual(rec.snapshots(of: .tmux(a), since: mark).first?.size.cols, 80, "at rdev's size")
    }

    /// M2, the keystroke's claim: the same re-snapshot, after the claim and before the keys land.
    func testATypingClaimResnapshotsAtRdevsSize() throws {
        let a = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(a); _ = payload(tm)
        let other = try otherClient(a)
        defer { other.stop() }
        other.command("switch-client -t \(a)") { _ in }
        waitFor("the other client took A") { self.windowSize(a) == "206x58" }
        Thread.sleep(forTimeInterval: 0.3)
        let mark = rec.count
        tm.write(Data("echo claim\r".utf8), toTerminal: .tmux(a))
        rec.wait("A is re-snapshotted after the claim") { !rec.snapshots(of: .tmux(a), since: mark).isEmpty }
        XCTAssertEqual(rec.snapshots(of: .tmux(a), since: mark).first?.size.cols, 80, "at rdev's size")
    }

    // MARK: the send buffer (docs/terminal.md, "The send buffer")

    /// A manager on a clock the test drives, whose every output emission records whether it was made on
    /// the tab's own control-client queue.
    private func heldManager() -> (TerminalManager, ManualClock, () -> [Bool]) {
        let clock = ManualClock()
        let tm = TerminalManager(cols: 80, rows: 24, clock: { clock.now }, schedule: { clock.schedule(after: $0, $1) })
        tm.tmux = runner
        let r = EmissionRecorder()
        rec = r
        let probe = NSLock(); var queued: [Bool] = []
        tm.onEmit = { [unowned tm] e in
            if case .output(.tmux(let s), _) = e {
                let mine = tm.tmuxClientInstanceForTests(s)
                let on = mine != nil && TmuxControlClient.currentCallbackQueueInstance == mine
                probe.lock(); queued.append(on); probe.unlock()
            }
            return r.record(e)
        }
        return (tm, clock, { probe.lock(); defer { probe.unlock() }; return queued })
    }

    /// Let a fresh session's shell finish drawing, and send whatever it held.
    private func settle(_ tm: TerminalManager, _ sid: String, _ clock: ManualClock) {
        Thread.sleep(forTimeInterval: 1)
        tm.syncTmuxQueueForTests(sid)
        clock.advance(by: TermSendBuffer.hold)
        tm.syncTmuxQueueForTests(sid)
    }

    private func outputs(_ id: TermTabID, since: Int) -> [[UInt8]] {
        rec.all.dropFirst(since).compactMap { if case .output(id, let b) = $0 { return b }; return nil }
    }

    /// Several `%output`s with no input from rdev's client are held and leave as ONE message, from the
    /// tab's timer, ON its control-client queue.
    func testTmuxOutputIsHeldAndCoalescedOnItsQueue() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let (tm, clock, queued) = heldManager()
        _ = tm.openTmux(sid); _ = payload(tm)
        settle(tm, sid, clock)
        let mark = rec.count
        _ = runner.run(["send-keys", "-t", sid, "for i in 1 2 3 4 5 6; do printf \"chunk$i \"; sleep 0.03; done; printf FIN''ISHED", "Enter"])
        waitFor("the pane printed it") { self.pane(sid).contains("FINISHED") }
        Thread.sleep(forTimeInterval: 0.3)
        tm.syncTmuxQueueForTests(sid)
        XCTAssertEqual(outputs(.tmux(sid), since: mark), [], "held: nobody typed into this tab through rdev")
        clock.advance(by: TermSendBuffer.hold)
        tm.syncTmuxQueueForTests(sid)
        let out = outputs(.tmux(sid), since: mark)
        XCTAssertEqual(out.count, 1, "ONE message for several %output lines")
        let text = String(decoding: out.first ?? [], as: UTF8.self)
        XCTAssertTrue(text.contains("chunk1 chunk2 chunk3 chunk4 chunk5 chunk6 FINISHED"), text.debugDescription)
        XCTAssertFalse(queued().isEmpty)
        XCTAssertFalse(queued().contains(false), "a flush emitted OFF the control client's queue")
    }

    /// Input to the tmux tab through rdev: its output goes out unheld — no clock moves here.
    func testTmuxOutputAfterInputIsSentAtOnce() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let (tm, clock, queued) = heldManager()
        _ = tm.openTmux(sid); _ = payload(tm)
        settle(tm, sid, clock)
        let mark = rec.count, sent = queued().count
        tm.write(Data("echo inter''active\r".utf8), toTerminal: .tmux(sid))
        rec.wait("the echo and the output arrive with the clock standing still") {
            self.rec.text(of: .tmux(sid), since: mark).contains("interactive")
        }
        XCTAssertGreaterThan(queued().count, sent)
        XCTAssertFalse(queued().dropFirst(sent).contains(false), "an unheld send emitted OFF the control client's queue")
    }

    /// A tmux tab's snapshot and its `closed` are BOUNDARIES: the held bytes go out first, and the timer
    /// sends nothing after them.
    func testTmuxSnapshotAndCloseFlushTheHeldBytesFirst() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let (tm, clock, _) = heldManager()
        _ = tm.openTmux(sid); _ = payload(tm)
        settle(tm, sid, clock)
        func kinds(_ since: Int) -> [String] {
            rec.all.dropFirst(since).map { e -> String in
                switch e {
                case .output: return "output"; case .snapshot: return "snapshot"; case .closed: return "closed"
                case .screen: return "screen"; case .history: return "history"
                }
            }
        }
        for boundary in ["snapshot", "closed"] {
            let mark = rec.count
            _ = runner.run(["send-keys", "-t", sid, "echo \(boundary)-HE''LD", "Enter"])
            waitFor("the pane printed it") { self.pane(sid).contains("\(boundary)-HELD") }
            Thread.sleep(forTimeInterval: 0.3)
            tm.syncTmuxQueueForTests(sid)
            XCTAssertEqual(kinds(mark), [], "held")
            if boundary == "snapshot" {
                tm.snapshot(.tmux(sid))
                rec.wait("the snapshot") { !self.rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
            } else {
                XCTAssertTrue(tm.close(.tmux(sid)))
            }
            XCTAssertEqual(kinds(mark), ["output", boundary])
            XCTAssertTrue(rec.text(of: .tmux(sid), since: mark).contains("\(boundary)-HELD"))
            clock.advance(by: TermSendBuffer.hold)
            tm.syncTmuxQueueForTests(sid)
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(kinds(mark), ["output", boundary], "nothing after the boundary")
        }
    }

    /// A timer is bound to the control client it was armed on. When that client is REPLACED (it exited;
    /// the session lives) the old timer finds a different token and sends nothing — and the tab must
    /// not keep waiting for it: its next held bytes arm a new timer on the new client.
    func testAReplacedControlClientsTabStillFlushes() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let (tm, clock, _) = heldManager()
        _ = tm.openTmux(sid); _ = payload(tm)
        settle(tm, sid, clock)
        _ = runner.run(["send-keys", "-t", sid, "echo arm''ed", "Enter"])
        waitFor("the pane printed it") { self.pane(sid).contains("armed") }
        Thread.sleep(forTimeInterval: 0.3)
        tm.syncTmuxQueueForTests(sid)
        XCTAssertEqual(clock.outstanding, 1, "the tab's timer is armed on its first client")
        let first = tm.tmuxClientInstanceForTests(sid)
        let names = runner.run(["list-clients", "-t", sid, "-F", "#{client_control_mode} #{client_name}"]).stdout
            .split(whereSeparator: \.isNewline).filter { $0.hasPrefix("1 ") }.map { String($0.dropFirst(2)) }
        XCTAssertEqual(names.count, 1)
        let mark = rec.count
        _ = runner.run(["detach-client", "-t", try XCTUnwrap(names.first)])
        waitFor("a new control client") { tm.tmuxClientInstanceForTests(sid).map { $0 != first } ?? false }
        rec.wait("its snapshot") { !self.rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
        clock.advance(by: TermSendBuffer.hold)                           // the OLD timer: a stale token
        Thread.sleep(forTimeInterval: 0.2)
        let after = rec.count
        _ = runner.run(["send-keys", "-t", sid, "echo after''wards", "Enter"])
        waitFor("the pane printed it") { self.pane(sid).contains("afterwards") }
        Thread.sleep(forTimeInterval: 0.3)
        tm.syncTmuxQueueForTests(sid)
        clock.advance(by: TermSendBuffer.hold)
        rec.wait("the new client's timer flushes it") { self.rec.text(of: .tmux(sid), since: after).contains("afterwards") }
    }

    // MARK: a flood of left-in queries while withheld

    // MARK: rename (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §3)

    /// The tab's title, polled (tmux reports a rename on the tab's control client, asynchronously).
    private func waitForTitle(_ tm: TerminalManager, _ sid: String, _ title: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        func now() -> String? { tm.descriptors().tabs.first { $0.id == .tmux(sid) }?.title }
        while now() != title && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(now(), title, file: file, line: line)
    }

    private func sessionName(_ sid: String) -> String? { runner.listSessions().first { $0.id == sid }?.name }

    /// `onTmuxError`'s calls — a rename's comes from off the caller's thread.
    private final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func note(_ e: String) { lock.withLock { seen.append(e) } }
        var all: [String] { lock.withLock { seen } }
    }

    /// Renaming a tmux tab renames its SESSION — every tmux client sees it — and the tab's label follows
    /// the way it follows a rename made anywhere else: `%session-renamed` on the tab's own control client.
    func testRenamingATmuxTabRenamesItsSession() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        XCTAssertNoThrow(try tm.openTmux(sid).get())
        _ = payload(tm)
        let errors = Errors()
        tm.onTmuxError = { s, reason in errors.note("\(s) \(reason)") }
        tm.renameTmux(sid, "build")
        waitForTitle(tm, sid, "build")
        XCTAssertEqual(sessionName(sid), "build")
        XCTAssertNil(tm.descriptors().tabs.first?.name, "a tmux tab never has a name of its own")
        XCTAssertEqual(errors.all, [])
    }

    /// The name is LITERAL. tmux format-expands `rename-session`'s name and its argv parse strips a
    /// trailing `;` (`TmuxList.renameArgument`); a name made of exactly those reaches the session and the
    /// tab as typed. Unescaped (the mutation run), this one became `1 $1  #[fg=red] ;x`: `#S` the old
    /// name, `#{session_id}` the id, `#(echo hi)` nothing, the trailing `;` gone.
    func testARenameIsTheLiteralName() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        XCTAssertNoThrow(try tm.openTmux(sid).get())
        _ = payload(tm)
        let name = "#S #{session_id} #(echo hi) #[fg=red] ;x;"
        tm.renameTmux(sid, name)
        waitForTitle(tm, sid, name)
        XCTAssertEqual(sessionName(sid), name)
    }

    /// tmux REFUSING the name — another session has it — is a `rename-failed` to the driver, and the
    /// session keeps its name.
    func testADuplicateNameIsRenameFailed() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        XCTAssertNoThrow(try tm.openTmux(sid).get())
        _ = payload(tm)
        let before = try XCTUnwrap(sessionName(sid))
        let failed = expectation(description: "rename-failed")
        tm.onTmuxError = { s, reason in if s == sid && reason == "rename-failed" { failed.fulfill() } }
        tm.renameTmux(sid, "keeper")                                   // setUp's session has that name
        wait(for: [failed], timeout: 10)
        XCTAssertEqual(sessionName(sid), before)
        XCTAssertEqual(tm.descriptors().tabs.first?.title, before)
    }

    /// A session that is gone cannot be renamed either: `rename-failed`.
    func testRenamingAGoneSessionIsRenameFailed() {
        let tm = manager()
        let failed = expectation(description: "rename-failed")
        tm.onTmuxError = { s, reason in if s == "$999" && reason == "rename-failed" { failed.fulfill() } }
        tm.renameTmux("$999", "x")
        wait(for: [failed], timeout: 10)
    }

    /// MEASUREMENT (opt-in, `RDEV_TMUX_FLOOD=<bytes>`): a pane floods OSC 4 queries tmux leaves for the
    /// client while the driver is PAUSED, so every read is withheld and the host answers each batch
    /// (one `display` round trip + `send-keys`). Does any command wait past the 5 s timeout that kills
    /// the tab's control client? Prints the numbers; asserts the client survived.
    func testMeasureALeftInQueryFloodWhilePaused() throws {
        guard let n = ProcessInfo.processInfo.environment["RDEV_TMUX_FLOOD"].flatMap(Int.init) else {
            throw XCTSkip("set RDEV_TMUX_FLOOD=<bytes> to measure")
        }
        let sink = ProcessInfo.processInfo.environment["RDEV_TMUX_FLOOD_SINK"] ?? NSTemporaryDirectory() + "rdev-flood-\(getpid()).in"
        try? FileManager.default.removeItem(atPath: sink)
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        _ = tm.openTmux(sid); _ = payload(tm)
        Thread.sleep(forTimeInterval: 0.5)
        let before = try XCTUnwrap(tm.tmuxClientInstanceForTests(sid))
        tm.pauseForwarding()
        let t0 = Date()
        _ = runner.run(["send-keys", "-t", sid,
                        "stty raw -echo; (yes \"$(printf '\\033]4;1;?\\007')\" | head -c \(n); printf flood''DONE) & cat > \(sink)",
                        "Enter"])
        var done: TimeInterval?, died: TimeInterval?, lastGrowth = Date(), lastSize = 0
        while Date().timeIntervalSince(t0) < 600 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = Date().timeIntervalSince(t0)
            if done == nil, pane(sid).contains("floodDONE") { done = now }
            if died == nil, tm.tmuxClientInstanceForTests(sid) != before { died = now }
            let size = ((try? FileManager.default.attributesOfItem(atPath: sink))?[.size] as? Int) ?? 0
            if size != lastSize { lastSize = size; lastGrowth = Date() }
            // `floodDONE` may wrap in a raw pane (no CR), so the end is also "answers stopped growing".
            if (done != nil || lastSize > 0), Date().timeIntervalSince(lastGrowth) > 10 { break }
        }
        let answers = lastSize / Array("\u{1b}]4;1;rgb:cccc/0000/0000\u{1b}\\".utf8).count
        print("[flood] bytes=\(n) queries=\(n / 10) done=\(done.map { String(format: "%.2fs", $0) } ?? "never") "
              + "answerBytes=\(lastSize) answers=\(answers) lastAnswerAt=\(String(format: "%.2fs", lastGrowth.timeIntervalSince(t0))) "
              + "clientReplaced=\(died.map { String(format: "%.2fs", $0) } ?? "no")")
        XCTAssertNil(died, "the tab's control client was killed by a command timeout")
        _ = runner.run(["send-keys", "-t", sid, "C-c", ""])
        try? FileManager.default.removeItem(atPath: sink)
    }

    // MARK: a paste the host types (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §4.1)

    private func catPane(bracketed: Bool) throws -> String {
        let setup = bracketed ? "printf '\\033[?2004h'; " : ""
        let r = runner.run(["new-session", "-d", "-P", "-F", "#{session_id}", "\(setup)echo rea''dy; cat -v"])
        XCTAssertEqual(r.status, 0)
        let sid = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        waitFor("the pane is up") { self.pane(sid).contains("ready") }
        if bracketed {
            waitFor("tmux saw ?2004") { self.runner.run(["display", "-p", "-t", sid, "#{bracket_paste_flag}"]).stdout.hasPrefix("1") }
        }
        return sid
    }

    /// A tmux tab that is NOT shown gets the paste, bracketed because ITS pane asked; a gone tab gets none.
    func testAPasteIsTypedIntoABackgroundTmuxTabBracketedPerItsPane() throws {
        let sid = try catPane(bracketed: true)
        let tm = manager()
        _ = tm.openTmux(sid)
        rec.wait("the first snapshot") { !rec.snapshots(of: .tmux(sid)).isEmpty }
        XCTAssertTrue(tm.open(cols: 80, rows: 24))                      // a plain tab becomes active
        defer { tm.close(.pty(1)) }
        XCTAssertTrue(tm.typePaste(["/p/x.png ", "/p/y.png "], into: .tmux(sid)))
        waitFor("each path is its own paste in the pane") {
            let p = self.pane(sid)
            return p.contains("^[[200~/p/x.png ^[[201~") && p.contains("^[[200~/p/y.png ^[[201~")
        }
        XCTAssertFalse(tm.typePaste(["/p/x.png "], into: .tmux("$999")), "a gone tab types nothing")
    }

    func testWithoutBracketedPasteTheTmuxPathIsTypedBare() throws {
        let sid = try catPane(bracketed: false)
        let tm = manager()
        _ = tm.openTmux(sid)
        rec.wait("the first snapshot") { !rec.snapshots(of: .tmux(sid)).isEmpty }
        XCTAssertTrue(tm.open(cols: 80, rows: 24))
        defer { tm.close(.pty(1)) }
        XCTAssertTrue(tm.typePaste(["/p/x.png "], into: .tmux(sid)))
        waitFor("the path arrives") { self.pane(sid).contains("/p/x.png") }
        XCTAssertFalse(pane(sid).contains("^[[200~"))
    }
}

// MARK: tabs that come back (docs/terminal.md, "Tabs that come back")

extension TerminalManagerTmuxTests {
    private func poll(_ what: String, timeout: TimeInterval = 10, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(cond(), what)
    }

    private func tempDir() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-tmux-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return try XCTUnwrap(realpath(url.path, &buf).map { String(cString: $0) })
    }

    /// A new tmux session starts where the active tab is, and a new tab after it starts where ITS pane is.
    func testANewTmuxSessionStartsWhereTheActiveTabIs() throws {
        let work = try tempDir()
        let tm = manager()
        tm.shell = "/bin/cat"
        defer { tm.closeAll() }
        XCTAssertTrue(tm.open(directory: work))
        poll("the shell started in its directory") { tm.savedTabs().tabs == [.pty(cwd: work, name: nil)] }
        let sid = try tm.newTmux().get()
        defer { _ = runner.killSession(sid) }
        poll("the session's pane started there too") { runner.panePath(sid) == work }
        XCTAssertEqual(tm.newTabDirectory(), work, "the active tmux tab's pane decides the next tab")
    }

    /// `×` on a tmux tab DETACHES; ⌘⇧T re-attaches the same session. A session that has ENDED meanwhile is
    /// skipped, never a failure.
    func testAClosedTmuxTabComesBackAttachedAndAnEndedOneIsSkipped() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        defer { tm.closeAll() }
        XCTAssertNoThrow(try tm.openTmux(sid).get())
        XCTAssertTrue(tm.closeRemembering(.tmux(sid)))
        XCTAssertTrue(runner.listSessions().contains { $0.id == sid }, "detached, not killed")
        XCTAssertEqual(tm.reopenClosed(), .reopened)
        XCTAssertEqual(tm.descriptors().activeId, .tmux(sid))
        XCTAssertTrue(tm.closeRemembering(.tmux(sid)))
        XCTAssertTrue(runner.killSession(sid))
        XCTAssertEqual(tm.reopenClosed(), .nothingClosed, "its session ended: nothing comes back")
    }

    /// The app's launch: a saved tmux tab whose session lives comes back; one whose session ended does not.
    /// No control client starts until a driver reports its grid — attached at 80×24 first, every restored
    /// session (and the program in it) would be resized twice — and then it attaches AT that grid.
    func testRestoredTmuxTabsWaitForTheDriversGrid() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let tm = manager()
        defer { tm.closeAll() }
        XCTAssertEqual(tm.restore(SavedTerminalTabs(tabs: [.tmux(session: "$99999"), .tmux(session: sid)], active: 1)), 1)
        XCTAssertEqual(tm.descriptors().tabs.map(\.id), [.tmux(sid)])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(tm.tmuxClientInstanceForTests(sid), "no client before a grid")
        tm.resizeAll(cols: 101, rows: 31)
        poll("the client starts at the driver's grid") { tm.tmuxClientInstanceForTests(sid) != nil }
        let mark = rec.count
        tm.snapshot(.tmux(sid))
        rec.wait("a snapshot") { !rec.snapshots(of: .tmux(sid), since: mark).isEmpty }
        XCTAssertEqual(rec.snapshots(of: .tmux(sid), since: mark).first?.size, TermGridSize(cols: 101, rows: 31))
    }
}
