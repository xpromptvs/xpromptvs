import XCTest
import RdevCore
@testable import RdevHostKit

/// THE HOST'S BELL (docs/terminal.md, "The bell"), for a `pty:` tab: the device-query rule applied to BEL.
/// A BEL in output that REACHES the driver's xterm.js is the client's to ring; one in output that reaches no
/// client context — a hidden driver's PAUSE, a resume's gap, no wire — is the host's, and the driver hears it
/// as a `term-bell`, at most once per withheld stretch. Without it a command finishing while the page was in
/// the background marked nothing: the resume re-sends the tab as a snapshot, and a snapshot never rings.
/// A tab with no shell behind it (`openDetachedForTests`), fed on its serial path (`feedForTests`).
final class TerminalBellTests: XCTestCase {
    private var clock = ManualClock()
    private var rec = EmissionRecorder()
    private let lock = NSLock()
    private var rung: [TermTabID] = []

    private func manager(emit: ((TermEmission) -> Bool)? = nil) -> TerminalManager {
        clock = ManualClock(); rec = EmissionRecorder()
        lock.withLock { rung = [] }
        let c = clock
        let tm = TerminalManager(cols: 80, rows: 24, clock: { c.now }, schedule: { c.schedule(after: $0, $1) })
        tm.onEmit = emit ?? rec.record
        tm.onBell = { [weak self] id in self?.lock.withLock { self?.rung.append(id) } }
        return tm
    }
    private var bells: [TermTabID] { lock.withLock { rung } }
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func output(since: Int) -> String {
        rec.all.dropFirst(since).map { if case .output(_, let x) = $0 { return String(decoding: x, as: UTF8.self) }; return "" }.joined()
    }

    func testABellInOutputThatReachedTheDriverIsTheClientsToRing() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        let mark = rec.count
        tm.feedForTests(id, b("done\u{07}"))
        XCTAssertEqual(bells, [], "the driver's xterm.js rang it")
        XCTAssertTrue(output(since: mark).contains("\u{07}"), "and the BEL went to it at once")
    }

    func testABellWhileThePauseIsInForceIsTheHostsOncePerStretch() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.pauseForwarding()
        tm.feedForTests(id, b("build finished\u{07}"))
        tm.feedForTests(id, b("\u{07}\u{07}"))
        XCTAssertEqual(bells, [id], "one term-bell for the whole withheld stretch")
        tm.resumeForwarding()                                     // the tab's snapshot: the stretch is over
        tm.feedForTests(id, b("seen\u{07}"))
        XCTAssertEqual(bells, [id], "reached again: the client's")
        tm.pauseForwarding()
        tm.feedForTests(id, b("\u{07}"))
        XCTAssertEqual(bells, [id, id], "a new stretch rings again")
    }

    /// The resume's SNAPSHOT alone ends the stretch — no output has to reach the client first.
    func testTheResumesSnapshotEndsTheStretch() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.pauseForwarding()
        tm.feedForTests(id, b("\u{07}"))
        tm.resumeForwarding()
        tm.pauseForwarding()
        tm.feedForTests(id, b("\u{07}"))
        XCTAssertEqual(bells, [id, id])
    }

    /// The commonest BEL in a stream ends a TITLE — no bell, paused or not (SwiftTerm's own parse).
    func testABELThatEndsAnOSCIsNoBell() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.pauseForwarding()
        tm.feedForTests(id, b("\u{1b}]0;~/src\u{07}"))
        tm.feedForTests(id, b("\u{1b}]2;vim"))
        tm.feedForTests(id, b(" file\u{07}"))                     // the title split across two reads
        XCTAssertEqual(bells, [])
        tm.feedForTests(id, b("\u{1b}[1\u{07}m"))                  // executed inside a CSI: a bell
        XCTAssertEqual(bells, [id])
    }

    /// Forwarded, but the emission reached no context the driver decodes (a new wire before the tab's
    /// snapshot, no wire): the host's, by the emission's own result.
    func testABellInOutputThatReachedNoContextIsTheHosts() throws {
        let tm = manager(emit: { _ in false })
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.feedForTests(id, b("x\u{07}"))
        tm.feedForTests(id, b("y\u{07}"))
        XCTAssertEqual(bells, [id])
    }

    /// A BEL is never HELD by the send buffer (as a query is not): held, a pause would DROP it with the
    /// buffer, and neither side would ring it.
    func testABellIsNeverHeldSoAPauseCannotDropIt() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        let mark = rec.count
        tm.feedForTests(id, b("plain output"))
        XCTAssertEqual(output(since: mark), "", "precondition: ordinary output is held")
        tm.feedForTests(id, b("done\u{07}"))
        XCTAssertEqual(output(since: mark), "plain outputdone\u{07}", "the bell went at once, the held bytes ahead of it")
        tm.pauseForwarding()
        XCTAssertEqual(bells, [], "it reached the driver: the client rang it, the host must not")
    }

    func testAClosedTabRingsNothing() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.pauseForwarding()
        XCTAssertTrue(tm.close(id))
        tm.feedForTests(id, b("\u{07}"))
        XCTAssertEqual(bells, [])
    }
}
