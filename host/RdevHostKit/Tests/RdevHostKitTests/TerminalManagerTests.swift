import XCTest
import RdevCore
@testable import RdevHostKit

final class TerminalManagerTests: XCTestCase {
    /// A keystroke or an attach against an EMPTY pool creates nothing — since 2026-09-25 a shell
    /// starts only on an explicit request.
    func testEmptyPoolStaysEmpty() {
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.write(Data("ls\r".utf8), toTerminal: .pty(1))
        XCTAssertTrue(tm.descriptors().tabs.isEmpty)
        XCTAssertTrue(tm.isEmpty)
    }

    /// The last tab closes; nothing takes its place.
    func testLastTabCloses() {
        let tm = TerminalManager(cols: 80, rows: 24)
        XCTAssertTrue(tm.open(cols: 80, rows: 24))
        XCTAssertTrue(tm.close(.pty(1)))
        XCTAssertTrue(tm.isEmpty)
    }

    /// A plain shell also starts at the grid the driver REPORTED, not a hard-coded 80x24 that the
    /// client's size then corrects a moment later (a SIGWINCH and a redraw for nothing).
    func testAPlainShellOpensAtTheReportedGrid() {
        let rec = EmissionRecorder()
        let tm = manager(rec)
        tm.resizeAll(cols: 117, rows: 33)                             // the driver's fit, no tab yet
        XCTAssertTrue(tm.open())
        tm.snapshot(.pty(1))
        rec.wait("the tab's snapshot") { !rec.snapshots(of: .pty(1)).isEmpty }
        XCTAssertEqual(rec.snapshots(of: .pty(1)).last?.size, TermGridSize(cols: 117, rows: 33))
        XCTAssertTrue(tm.close(.pty(1)))
    }

    // MARK: live tabs — every plain tab streams, a snapshot sits at an exact stream position

    private func manager(_ rec: EmissionRecorder) -> TerminalManager {
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.onEmit = rec.record
        return tm
    }

    private func keys(_ tm: TerminalManager, _ s: String, into id: TermTabID) {
        tm.write(Data(s.utf8), toTerminal: id)
    }

    func testOpeningAPlainTabEmitsItsSnapshotFirst() {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open(cols: 70, rows: 20))
        defer { tm.close(.pty(1)) }
        guard case .snapshot(.pty(1), let size, let bytes)? = rec.all.first else { return XCTFail("first emission: \(rec.all)") }
        XCTAssertEqual(size, TermGridSize(cols: 70, rows: 20))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasPrefix("\u{1b}[!p\u{1b}[?7h"))
    }

    /// The ACTIVE tab's device queries are answered by the driver's xterm.js while a wire is bound —
    /// except while the driver is PAUSED (hidden): nothing reaches xterm.js then, and the resume's
    /// snapshot carries no query, so an app that asked during the pause would wait for good. The host
    /// answers while paused, and stops again once resumed (or xterm.js would answer a second time).
    func testTheHostAnswersTheActiveTabsDeviceQueriesOnlyWhileTheDriverIsPaused() {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open(cols: 80, rows: 24))
        defer { tm.close(.pty(1)) }
        tm.setDriverDecodesWire(true, generation: 1)
        tm.snapshot(.pty(1))                  // a new wire holds no tab until its snapshot (the binder's snapshotAll)
        // DSR 5n: a terminal answers ESC[0n. `R=<length of the reply read>`, 3 when answered, 0 when not.
        let ask = "bash -c 'printf \"\\033[5n\"; IFS= read -rs -t 2 -d n r; echo \"R\"=\"${#r}\"'\r"
        rec.wait("the prompt") { tm.hostText(.pty(1)).contains("$") || tm.hostText(.pty(1)).contains("%") || rec.count > 1 }
        Thread.sleep(forTimeInterval: 0.5)

        func n(_ k: String) -> Int { tm.hostText(.pty(1)).components(separatedBy: k).count - 1 }
        keys(tm, ask, into: .pty(1))
        rec.wait("unpaused: the driver's xterm.js owns the reply, the host stays silent") { n("R=0") == 1 }
        XCTAssertEqual(n("R=3"), 0)

        tm.pauseForwarding()
        keys(tm, ask, into: .pty(1))
        rec.wait("paused: the host answers") { n("R=3") == 1 }

        tm.resumeForwarding()
        keys(tm, ask, into: .pty(1))
        rec.wait("resumed: silent again") { n("R=0") == 2 }
        XCTAssertEqual(n("R=3"), 1, "resumed: the host must not answer beside xterm.js")
    }

    /// Final review I1(a): a resume clears the pause, then snapshots the tabs ONE AFTER ANOTHER. Until
    /// the active tab's own snapshot its output is not forwarded — so xterm.js cannot see a query in
    /// it — and the host must answer. Held inside the resume at the tab ahead of it.
    func testADeviceQueryOnTheActiveTabDuringTheResumeIsAnsweredByTheHost() {
        let rec = EmissionRecorder(), tm = TerminalManager(cols: 80, rows: 24)
        var armed = false, answered: String?
        tm.onEmit = { [unowned tm] e in
            rec.record(e)
            if armed, case .snapshot(.pty(1), _, _) = e {           // tab 1 re-serialized; tab 2 (active) not yet
                armed = false
                answered = askDSR(tm, .pty(2))
            }
            return true
        }
        XCTAssertTrue(tm.open(cols: 80, rows: 24)); XCTAssertTrue(tm.open(cols: 80, rows: 24))
        defer { tm.close(.pty(1)); tm.close(.pty(2)) }
        tm.setDriverDecodesWire(true, generation: 1)
        waitForPrompt(tm, .pty(2))
        tm.pauseForwarding()
        armed = true
        tm.resumeForwarding()
        XCTAssertEqual(answered, "R=3", "not yet forwarded: nobody else can answer it")
    }

    func testABackgroundTabKeepsStreaming() {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open()); XCTAssertTrue(tm.open())
        defer { tm.close(.pty(1)); tm.close(.pty(2)) }
        XCTAssertTrue(tm.switchTo(.pty(1)))
        keys(tm, "sleep 1; echo back''ground\r", into: .pty(1))
        XCTAssertTrue(tm.switchTo(.pty(2)))                                   // tab 1 is now in the background
        rec.wait("tab 1's output arrives while tab 2 is active") { rec.text(of: .pty(1)).contains("background") }
    }

    /// REVIEW FOCUS 1: snapshot + the output after it == the host's own screen, while printing flat out.
    /// And, deterministically, every emission is made ON the tab's serial path: from inside the hook,
    /// the tab's `serial` cannot be taken. Output emitted after `serial` is released could be overtaken
    /// by a snapshot that already contains it (those bytes would arrive twice); the probe sees that on
    /// every chunk, without having to win the race.
    func testSnapshotAndLiveOutputComposeToTheHostScreen() throws {
        let rec = EmissionRecorder(), tm = TerminalManager(cols: 80, rows: 24)
        let probe = NSLock(); var onPath = 0, offPath = 0
        tm.onEmit = { [unowned tm] e in
            if case .output(let id, _) = e {
                let held = tm.serialIsHeld(id)
                probe.lock(); if held { onPath += 1 } else { offPath += 1 }; probe.unlock()
            }
            return rec.record(e)
        }
        XCTAssertTrue(tm.open(cols: 60, rows: 12))
        defer { tm.close(.pty(1)) }
        // The loop STOPS between its halves (`read`), so `mark` is taken before the second half can
        // exist and "DONE" can only land after it. Taking `mark` after seeing the stream start, as this
        // test once did, lost to a descheduled test thread: the whole loop could finish first, and
        // nothing after `mark` ever said DONE however long it waited.
        keys(tm, "for i in $(seq 1 2000); do echo \"line $i $i $i\"; done; read -r; "
                 + "for i in $(seq 2001 4000); do echo \"line $i $i $i\"; done; echo DO''NE\r", into: .pty(1))
        rec.wait("the first half printed") { rec.text(of: .pty(1)).contains("line 2000 2000 2000") }
        let mark = rec.count
        keys(tm, "\r", into: .pty(1))                                         // release the second half
        // Snapshot while it streams if the scheduler lets us; the check holds wherever it lands.
        let streaming = Date().addingTimeInterval(5)
        while !rec.text(of: .pty(1), since: mark).contains("line 2100 ") && Date() < streaming {
            Thread.sleep(forTimeInterval: 0.005)
        }
        tm.snapshot(.pty(1))
        rec.wait("the loop finished") { rec.text(of: .pty(1), since: mark).contains("DONE") }
        // 4000 lines of history: each capture goes as its SCREEN, then its HISTORY — the full snapshot of the same
        // capture (docs/terminal.md, "Scrollback comes after the screen"). The live bytes follow the screen, and the
        // client rebuilds from the history plus exactly those, which is what this composes.
        let starts: (TermEmission) -> Bool = { e in
            switch e { case .snapshot(.pty(1), _, _), .screen(.pty(1), _, _): return true; default: return false }
        }
        let full: ([TermEmission], Int) -> (TermGridSize, [UInt8])? = { events, i in
            if case .snapshot(_, let size, let b) = events[i] { return (size, b) }
            guard case .screen = events[i], i + 1 < events.count, case .history(.pty(1), let size, let b) = events[i + 1] else { return nil }
            return (size, b)
        }
        let snapIndex = try XCTUnwrap(rec.all.indices.dropFirst(mark).first { starts(rec.all[$0]) })
        // The reference: a second snapshot. The replica gets exactly the output BETWEEN the two, so
        // output after the reference (a late prompt redraw) cannot land in one and not the other.
        tm.snapshot(.pty(1))
        let refIndex = try XCTUnwrap(rec.all.indices.dropFirst(snapIndex + 1).first { starts(rec.all[$0]) })
        let events = rec.all
        XCTAssertTrue({ if case .screen = events[snapIndex] { return true }; return false }(), "a long history goes after its screen")
        guard let (size, snapBytes) = full(events, snapIndex), let (_, refBytes) = full(events, refIndex) else { return XCTFail("snapshots") }
        let replica = Terminal(cols: size.cols, rows: size.rows)
        _ = replica.feed(snapBytes)
        _ = replica.feed(events[(snapIndex + 1)..<refIndex].flatMap { e -> [UInt8] in
            if case .output(.pty(1), let b) = e { return b }; return []
        })
        let host = Terminal(cols: 60, rows: 12)
        _ = host.feed(refBytes)
        XCTAssertEqual(replica.snapshot().normal.lines, host.snapshot().normal.lines,
                       "nothing lost or doubled between the snapshot and the live bytes after it")
        probe.lock(); let (on, off) = (onPath, offPath); probe.unlock()
        XCTAssertGreaterThan(on, 0, "the probe ran")
        XCTAssertEqual(off, 0, "output emitted OFF the tab's serial path")
    }

    /// Final review M1: a `pty:` capture walks up to 5000 lines of cells under that tab's `serial` ALONE,
    /// never the manager's `lock` — which is every keystroke's and every other tab's feed's. From INSIDE
    /// the capture, another thread feeds tab 2 and types into it; both must complete while tab 1's
    /// capture is still running (its `serial` still held). A capture under `lock` blocks them until the
    /// capture ends, and the bounded wait sees that as a timeout rather than hanging.
    func testAPlainCaptureHoldsOnlyItsTabsSerialNotTheManagersLock() {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open()); XCTAssertTrue(tm.open())
        defer { tm.close(.pty(1)); tm.close(.pty(2)) }
        tm.snapshot(.pty(2))                                                  // tab 2 streams
        let probe = NSLock()
        var ran = 0, completed = false, inTime = false, serialHeld = false
        tm.duringCaptureForTests = { [unowned tm] id in
            guard id == .pty(1) else { return }
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let held = tm.serialIsHeld(.pty(1))
                tm.feedForTests(.pty(2), Array("other tab fed\r\n".utf8))    // another tab's feed
                tm.write(Data(" ".utf8), toTerminal: .pty(2))                 // a keystroke to another tab
                let fed = tm.hostText(.pty(2)).contains("other tab fed")      // tab 2's emulator has it
                probe.lock(); serialHeld = held; completed = fed; probe.unlock()
                done.signal()
            }
            let ok = done.wait(timeout: .now() + 3) == .success
            probe.lock(); ran += 1; inTime = ok; probe.unlock()
        }
        tm.snapshot(.pty(1))
        tm.duringCaptureForTests = nil
        probe.lock(); defer { probe.unlock() }
        XCTAssertEqual(ran, 1, "the hook ran inside tab 1's capture")
        XCTAssertTrue(serialHeld, "tab 1's serial is held for the capture")
        XCTAssertTrue(inTime, "another tab's feed and keystroke completed DURING the capture")
        XCTAssertTrue(completed, "tab 2's emulator took the feed")
    }

    func testPauseStopsEveryTabAndResumeSnapshotsEachThenStreams() {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open()); XCTAssertTrue(tm.open())
        defer { tm.close(.pty(1)); tm.close(.pty(2)) }
        tm.pauseForwarding()
        let mark = rec.count
        keys(tm, "echo while''hidden\r", into: .pty(2))
        // The HOST emulator has it (a fresh login shell may take seconds to get there under load) —
        // so the next line checks output that EXISTS and was not forwarded, not merely none yet.
        rec.wait("the paused tab ran the command") { tm.hostText(.pty(2)).contains("whilehidden") }
        XCTAssertEqual(rec.output(of: .pty(2), since: mark), [], "nothing is forwarded while paused")
        tm.resumeForwarding()
        rec.wait("a snapshot per tab") { rec.snapshots(of: .pty(1), since: mark).count == 1 && rec.snapshots(of: .pty(2), since: mark).count == 1 }
        XCTAssertTrue(String(decoding: rec.snapshots(of: .pty(2), since: mark)[0].bytes, as: UTF8.self).contains("whilehidden"))
        let after = rec.count
        keys(tm, "echo after''wards\r", into: .pty(2))
        rec.wait("live output flows again") { rec.text(of: .pty(2), since: after).contains("afterwards") }
    }

    func testASnapshotWhilePausedIsNotEmitted() {
        let rec = EmissionRecorder(), tm = manager(rec)
        tm.pauseForwarding()
        XCTAssertTrue(tm.open())
        defer { tm.close(.pty(1)) }
        XCTAssertTrue(rec.snapshots(of: .pty(1)).isEmpty, "the resume snapshots it")
        tm.clearPause(); tm.snapshotAll()
        XCTAssertEqual(rec.snapshots(of: .pty(1)).count, 1)
    }

    /// The region and origin mode an app set before its last clear survive — there is no replay to
    /// lose them any more; the snapshot IS the state.
    func testASnapshotCarriesTheRegionAndOriginMode() throws {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open(cols: 80, rows: 24))
        defer { tm.close(.pty(1)) }
        keys(tm, "printf '\\033[3;12r\\033[?6h\\033[2J\\033[5;1HQZ''X'; sleep 30\r", into: .pty(1))
        rec.wait("the app drew") { rec.text(of: .pty(1)).contains("QZX") }
        let mark = rec.count
        tm.snapshot(.pty(1))
        let bytes = try XCTUnwrap(rec.snapshots(of: .pty(1), since: mark).first?.bytes)
        let t = Terminal(cols: 80, rows: 24)
        _ = t.feed(bytes)
        let s = t.snapshot()
        XCTAssertEqual([s.normal.scrollTop, s.normal.scrollBottom], [2, 11])
        XCTAssertTrue(s.modes.origin)
        XCTAssertEqual([s.cursor.x, s.cursor.y], [3, 6], "after QZX on region row 5 (absolute row 7)")
    }

    func testClosingEmitsClosedAndNothingAfterIt() {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open())
        keys(tm, "while true; do echo spam; sleep 0.01; done\r", into: .pty(1))
        rec.wait("spam flows") { rec.text(of: .pty(1)).contains("spam") }
        XCTAssertTrue(tm.close(.pty(1)))
        Thread.sleep(forTimeInterval: 0.5)
        let all = rec.all
        let closedAt = try? XCTUnwrap(all.lastIndex { if case .closed(.pty(1)) = $0 { return true }; return false })
        XCTAssertNotNil(closedAt)
        XCTAssertFalse(all.dropFirst((closedAt ?? 0) + 1).contains { if case .output(.pty(1), _) = $0 { return true }; return false })
    }

    func testResizeAllResizesEveryPlainTab() {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open()); XCTAssertTrue(tm.open())
        defer { tm.close(.pty(1)); tm.close(.pty(2)) }
        tm.resizeAll(cols: 101, rows: 31)
        let mark = rec.count
        tm.snapshotAll()
        XCTAssertEqual(rec.snapshots(of: .pty(1), since: mark).first?.size, TermGridSize(cols: 101, rows: 31))
        XCTAssertEqual(rec.snapshots(of: .pty(2), since: mark).first?.size, TermGridSize(cols: 101, rows: 31))
    }

    /// A tab whose shell exits LEAVES the pool, with its `closed` — or the session would restore a
    /// dead tab to every client that connects (host-session-state spec).
    func testATabWhoseShellExitsLeavesThePool() {
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.shell = "/usr/bin/true"
        let rec = EmissionRecorder(); tm.onEmit = rec.record
        XCTAssertTrue(tm.open())
        let deadline = Date().addingTimeInterval(5)
        while !tm.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(tm.isEmpty, "a tab whose shell ended is gone")
        XCTAssertEqual(rec.closed().count, 1, "and the driver's wire was told")
    }

    /// Stop Sharing: every shell is KILLED, not orphaned (`RdevHostRuntime.stop` used to drop the
    /// manager with its shells still running).
    func testClosingEverythingKillsEveryShell() {
        let tm = TerminalManager(cols: 80, rows: 24)
        tm.shell = "/bin/cat"
        XCTAssertTrue(tm.open()); XCTAssertTrue(tm.open())
        let pids = tm.shellPIDsForTests()
        XCTAssertEqual(pids.count, 2)
        tm.closeAll()
        XCTAssertTrue(tm.isEmpty)
        let deadline = Date().addingTimeInterval(5)
        while pids.contains(where: { kill($0, 0) == 0 }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(pids.contains(where: { kill($0, 0) == 0 }), "every shell is dead and reaped")
    }

    // MARK: names and the bar's order (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md)

    /// Counts `onTabsChanged` — called synchronously on the caller's thread by everything below.
    private final class Announcements: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func note() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    /// A `pty:` tab's name goes into the pool and out on the next `term-list` — announced ONLY when it
    /// changed, since every announcement is a `term-list` to every client.
    func testRenamingAPtyTabAnnouncesOnlyARealChange() throws {
        let tm = TerminalManager(cols: 80, rows: 24)
        let a = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        let said = Announcements()
        tm.onTabsChanged = { said.note() }
        XCTAssertTrue(tm.rename(a, "build"))
        XCTAssertEqual(tm.descriptors().tabs.first?.name, "build")
        XCTAssertEqual(said.count, 1)
        XCTAssertFalse(tm.rename(a, "build"), "the same name")
        XCTAssertFalse(tm.rename(.pty(9), "x"), "an unknown tab")
        XCTAssertFalse(tm.rename(a, "a\tb"), "a control character")
        XCTAssertEqual(said.count, 1, "nothing changed: nothing announced")
        XCTAssertTrue(tm.rename(a, ""))
        XCTAssertNil(tm.descriptors().tabs.first?.name, "\"\" clears")
        XCTAssertEqual(said.count, 2)
    }

    /// The pool takes the bar's order (`arrange`), or moves one tab (`move`, the harness's `move-tab`);
    /// the active tab stays, and only a real change is announced.
    func testArrangeAndMoveReorderThePoolAndAnnounceOnlyARealChange() throws {
        let tm = TerminalManager(cols: 80, rows: 24)
        let a = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        let b = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        let c = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))   // active
        let said = Announcements()
        tm.onTabsChanged = { said.note() }
        XCTAssertTrue(tm.arrange([c, a, b]))
        XCTAssertEqual(tm.descriptors().tabs.map(\.id), [c, a, b])
        XCTAssertEqual(tm.descriptors().activeId, c, "the active tab stays")
        XCTAssertFalse(tm.arrange([c, a, b]), "the same order")
        XCTAssertTrue(tm.move(c, before: nil))
        XCTAssertEqual(tm.descriptors().tabs.map(\.id), [a, b, c])
        XCTAssertFalse(tm.move(c, before: c), "before the tab itself")
        XCTAssertFalse(tm.move(.pty(9), before: nil), "an unknown tab")
        XCTAssertFalse(tm.move(a, before: .pty(9)), "an unknown before")
        XCTAssertEqual(said.count, 2)
    }

    // MARK: a paste the host types (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §4.1)

    /// §4.1: a paste names the tab it was MADE into — typed there even when another tab is shown, and
    /// bracketed only when THAT tab's program asked (?2004). Two pieces are two pastes.
    func testAPasteIsTypedIntoTheNamedBackgroundTabBracketedPerItsOwnMode() throws {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open()); XCTAssertTrue(tm.open())
        defer { tm.close(.pty(1)); tm.close(.pty(2)) }
        XCTAssertTrue(tm.switchTo(.pty(1)))
        keys(tm, "printf '\\033[?2004h'; echo rea''dy; cat -v\r", into: .pty(1))
        rec.wait("tab 1's program turned ?2004 on") { rec.text(of: .pty(1)).contains("ready") }
        XCTAssertTrue(tm.switchTo(.pty(2)))                                   // tab 1 is now in the background
        XCTAssertTrue(tm.typePaste(["/p/x.png ", "/p/y.png "], into: .pty(1)))
        rec.wait("each path arrives as its own bracketed paste") {
            let t = rec.text(of: .pty(1))
            return t.contains("^[[200~/p/x.png ^[[201~") && t.contains("^[[200~/p/y.png ^[[201~")
        }
        XCTAssertFalse(tm.typePaste(["/p/x.png "], into: .pty(999)), "a gone tab types nothing")
    }

    func testWithoutBracketedPasteThePathIsTypedBare() throws {
        let rec = EmissionRecorder(), tm = manager(rec)
        XCTAssertTrue(tm.open())
        defer { tm.close(.pty(1)) }
        keys(tm, "echo rea''dy; cat -v\r", into: .pty(1))
        rec.wait("cat is running") { rec.text(of: .pty(1)).contains("ready") }
        XCTAssertTrue(tm.typePaste(["/p/x.png "], into: .pty(1)))
        rec.wait("the path arrives") { rec.text(of: .pty(1)).contains("/p/x.png ") }
        XCTAssertFalse(rec.text(of: .pty(1)).contains("^[[200~"), "?2004 was never asked for")
    }
}
