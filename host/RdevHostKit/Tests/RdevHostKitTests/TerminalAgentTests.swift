import XCTest
import RdevCore
@testable import RdevHostKit

/// AN AGENT'S ACTIVITY, READ OFF A `pty:` TAB'S SCREEN — WHERE AN AGENT RUNS (docs/terminal.md, "An agent's activity"):
/// output schedules one look at the tab — its foreground, then its emulator — and the tab list carries what it says. A
/// tab with no shell behind it (`openDetachedForTests`), fed on its serial path (`feedForTests`); the looks are run by
/// hand (`agentSchedule`) and its foreground is what the test says (`foregroundAgent`).
final class TerminalAgentTests: XCTestCase {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    /// The agent in the tab's foreground, as the test sets it.
    private var running: String? = "codex"

    private func manager() -> TerminalManager {
        let c = ManualClock()
        let tm = TerminalManager(cols: 80, rows: 24, clock: { c.now }, schedule: { c.schedule(after: $0, $1) })
        tm.onEmit = { _ in true }
        tm.agentSchedule = { [weak self] _, work in self?.lock.withLock { self?.pending.append(work) } }
        tm.foregroundAgent = { [weak self] _ in self?.lock.withLock { self?.running } }
        return tm
    }
    /// The reads scheduled so far, run as their timers would run them.
    private func runReads() { let w = lock.withLock { let p = pending; pending = []; return p }; w.forEach { $0() } }
    private var scheduled: Int { lock.withLock { pending.count } }
    private func agent(_ tm: TerminalManager, _ id: TermTabID) -> AgentActivity.State? { tm.descriptors().tabs.first { $0.id == id }?.agent }
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testKindChangesWhileBothAgentsAreIdleAndClearsOnExit() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        for kind in ["claude", "codex"] {
            lock.withLock { running = kind }
            tm.feedForTests(id, b("\u{1b}[2J\u{1b}[Hprompt"))
            runReads()
            XCTAssertEqual(tm.descriptors().tabs.first { $0.id == id }?.agentKind, kind)
            XCTAssertEqual(agent(tm, id), .idle)
        }
        lock.withLock { running = nil }
        tm.feedForTests(id, b("\r\n$ "))
        runReads()
        XCTAssertNil(tm.descriptors().tabs.first { $0.id == id }?.agentKind)
    }

    func testAnAgentAtWorkIsSeenAndSoIsTheEndOfItsTurn() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(id, b("• Working (3s • esc to interrupt)\r\n\r\n› Ask Codex to do anything"))
        XCTAssertNil(agent(tm, id), "not before its screen is read")
        runReads()
        XCTAssertEqual(agent(tm, id), .working)
        tm.feedForTests(id, b("\u{1b}[2J\u{1b}[H  Worked for 3s\r\n\r\n› Ask Codex to do anything"))
        runReads()
        XCTAssertEqual(agent(tm, id), .idle, "the status line erased: the turn is over")
    }

    /// Codex's TITLE spinning (OSC 0) is it working, whatever its screen shows — a description too long for the pane.
    func testCodexsSpinningTitleIsWorking() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(id, b("\u{1b}]0;⠋ Exploring the codebase | repo\u{07}• Investigating why the planner drops its cache"))
        runReads()
        XCTAssertEqual(agent(tm, id), .working)
        tm.feedForTests(id, b("\u{1b}]0;Exploring the codebase | repo\u{07}\r\n› Ask Codex to do anything"))
        runReads()
        XCTAssertEqual(agent(tm, id), .idle, "the frame gone from its title, no status line")
    }

    /// THE FALSE POSITIVE RULED OUT: the words on screen with no agent in the foreground — a grep, a log, a document.
    func testTheHintWithNoAgentInTheForegroundIsNothing() throws {
        lock.withLock { running = nil }
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(id, b("• Working (3s • esc to interrupt)\r\n$ "))
        runReads()
        XCTAssertNil(agent(tm, id))
    }

    func testAnAgentAtItsPromptIsIdleAndItsExitTakesTheStateAway() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(id, b("› Ask Codex to do anything"))
        runReads()
        XCTAssertEqual(agent(tm, id), .idle, "before its first turn")
        lock.withLock { running = nil }
        tm.feedForTests(id, b("\r\n$ "))
        runReads()
        XCTAssertNil(agent(tm, id), "it exited: the shell's prompt")
    }

    func testAPlainShellHasNoAgent() throws {
        lock.withLock { running = nil }
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(id, b("$ ls\r\nREADME.md  web\r\n$ "))
        runReads()
        XCTAssertNil(agent(tm, id))
    }

    /// A busy tab is read once per window, however much it prints; the first output after a read schedules the next.
    func testOutputSchedulesOneReadAtATime() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        for i in 0..<20 { tm.feedForTests(id, b("line \(i)\r\n")) }
        XCTAssertEqual(scheduled, 1)
        runReads()
        XCTAssertEqual(scheduled, 0, "a quiet tab is never read")
        tm.feedForTests(id, b("more\r\n"))
        XCTAssertEqual(scheduled, 1)
    }

    /// The state goes out in the tab list (the debounced broadcast a title change rides).
    func testAChangeGoesOutInTheTabList() throws {
        lock.withLock { running = "claude" }
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        let changed = expectation(description: "the tab list changed")
        changed.assertForOverFulfill = false
        tm.onTabsChanged = { changed.fulfill() }
        tm.feedForTests(id, b("✻ Thinking… (esc to interrupt)"))
        runReads()
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(agent(tm, id), .working)
    }

    func testAClosedTabsReadDoesNothing() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(id, b("• Working (3s • esc to interrupt)"))
        _ = tm.close(id)
        runReads()
        XCTAssertNil(tm.descriptors().tabs.first { $0.id == id })
    }
}

/// WHAT RUNS IN A GROUP, from the kernel's table (`ForegroundProcesses`): its arguments as `ps` reads them, its executable.
final class ForegroundProcessesTests: XCTestCase {
    func testTheKernelSaysWhatRunsInAGroupAndWhichAgentItIs() throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)                                   // a group of its own, as a job is
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("codex"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, &attr, argv, nil), 0)
        defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        let procs = ForegroundProcesses.inGroup(pid)
        XCTAssertEqual(procs.map(\.pid), [pid])
        XCTAssertEqual(procs.first?.argv, ["codex", "30"], "its arguments, as ps reads them")
        XCTAssertEqual(procs.first?.path, "/bin/sleep")
        XCTAssertEqual(procs.first.flatMap { AgentProcess.kind(argv: $0.argv, path: $0.path) }, "codex")
        XCTAssertEqual(ForegroundProcesses.inGroup(0), [], "no group, nothing")
        XCTAssertEqual(ForegroundProcesses.onTerminal("/dev/no-such-tty"), [])
    }
}
