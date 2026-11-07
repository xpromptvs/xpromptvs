import XCTest
import RdevCore
@testable import RdevHostKit

/// THE SCREEN AN OFFER CARRIES (docs/sources-and-focus.md, "The offer carries the tab bar"): a tab's screen alone,
/// captured BESIDE the wire — nothing emitted, nothing of its forwarding changed — at once when the tab was not just
/// resized, and after a resize only once the program's redraw has settled (first byte within 60 ms, then 16 ms of
/// quiet, 150 ms at most), unless the deadline comes first. Detached tabs fed on their serial path; time is a
/// `ManualClock`.
final class TerminalScreenPreviewTests: XCTestCase {
    private let clock = ManualClock()
    private let lock = NSLock()
    private var emissions = 0

    private func manager() -> TerminalManager {
        let c = clock
        let tm = TerminalManager(cols: 80, rows: 24, clock: { c.now }, schedule: { c.schedule(after: $0, $1) })
        tm.onEmit = { [weak self] _ in self?.lock.withLock { self?.emissions += 1 }; return true }
        return tm
    }
    private var emitted: Int { lock.withLock { emissions } }

    /// What `screenPreview` handed back, and how many times.
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [TerminalManager.Screen?] = []
        func add(_ s: TerminalManager.Screen?) { lock.withLock { got.append(s) } }
        var calls: Int { lock.withLock { got.count } }
        var screen: TerminalManager.Screen? { lock.withLock { got.first ?? nil } }
        var text: String { screen.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "" }
    }
    private func preview(_ tm: TerminalManager, _ id: TermTabID, within ms: UInt64 = 300) -> Result {
        let r = Result()
        tm.screenPreview(id, within: ms * 1_000_000) { r.add($0) }
        return r
    }
    private func ms(_ n: UInt64) { clock.advance(by: n * 1_000_000) }
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testAnUnresizedTabsScreenIsTakenAtOnceWithoutItsScrollbackAndBesideTheWire() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 20, rows: 5))
        tm.feedForTests(id, b((0..<30).map { String(format: "L%02d", $0) }.joined(separator: "\r\n")))
        let before = emitted
        let r = preview(tm, id)
        XCTAssertEqual(r.calls, 1, "at once: no resize to wait for")
        XCTAssertEqual(r.screen?.size, TermGridSize(cols: 20, rows: 5))
        XCTAssertTrue(r.text.contains("L29") && r.text.contains("L25"), "the screen")
        XCTAssertFalse(r.text.contains("L24") || r.text.contains("L00"), "and nothing scrolled off it")
        XCTAssertEqual(emitted, before, "nothing went on the wire")
        tm.feedForTests(id, b("\r\nafter"))
        ms(10)                                                  // past the send buffer's hold
        XCTAssertGreaterThan(emitted, before, "and the tab streams on as before")
        ms(400)
        XCTAssertEqual(r.calls, 1, "once: the deadline finds it done")
    }

    func testAfterAResizeItWaitsForTheRedrawToGoQuiet() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.resizeAll(cols: 100, rows: 30)
        let r = preview(tm, id)
        ms(10)
        XCTAssertEqual(r.calls, 0)
        tm.feedForTests(id, b("\u{1b}[H\u{1b}[2Jredrawn at 100x30"))
        ms(12)
        XCTAssertEqual(r.calls, 0, "12 ms of quiet is not 16")
        ms(8)
        XCTAssertEqual(r.calls, 1)
        XCTAssertEqual(r.screen?.size, TermGridSize(cols: 100, rows: 30), "at the grid it was resized to")
        XCTAssertTrue(r.text.contains("redrawn at 100x30"), "with the redraw in it")
    }

    func testAProgramThatDoesNotRedrawIsTakenWhenItsFirstByteIsLate() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.resizeAll(cols: 100, rows: 30)
        let r = preview(tm, id)
        ms(56)
        XCTAssertEqual(r.calls, 0)
        ms(8)
        XCTAssertEqual(r.calls, 1, "no byte within 60 ms: there is no redraw coming")
    }

    func testAProgramThatNeverGoesQuietIsTakenAtTheSettleMax() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.resizeAll(cols: 100, rows: 30)
        let r = preview(tm, id)
        for n in 0..<17 {
            tm.feedForTests(id, b("tick \(n)\r\n"))
            ms(8)
        }
        XCTAssertEqual(r.calls, 0, "136 ms, still printing")
        ms(16)
        XCTAssertEqual(r.calls, 1, "150 ms: taken as it stands")
    }

    func testTheDeadlineComesFirstAndNothingFollowsIt() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        tm.resizeAll(cols: 100, rows: 30)
        let r = preview(tm, id, within: 40)
        for n in 0..<5 { tm.feedForTests(id, b("busy \(n)\r\n")); ms(8) }   // still redrawing at 40 ms
        XCTAssertEqual(r.calls, 1)
        XCTAssertNil(r.screen, "nothing within the deadline")
        ms(200)
        XCTAssertEqual(r.calls, 1, "and the settle that came later hands back nothing more")
    }

    func testAGoneTabHasNoScreen() throws {
        let tm = manager()
        let id = try XCTUnwrap(tm.openDetachedForTests(cols: 80, rows: 24))
        _ = tm.close(id)
        let r = preview(tm, id)
        XCTAssertEqual(r.calls, 1)
        XCTAssertNil(r.screen)
    }
}
