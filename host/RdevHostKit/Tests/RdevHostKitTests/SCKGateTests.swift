import XCTest
@testable import RdevHostKit

/// **A preview screenshot and a capture start never overlap** (`SCKGate`, 2026-10-07): a sibling capture stopping while a
/// stream starts kills it with `-3805`, and a palette's previews are a batch of captures that start and stop.
final class SCKGateTests: XCTestCase {
    /// Opens when told, and records who got in when.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ e: String) { lock.withLock { events.append(e) } }
        var all: [String] { lock.withLock { events } }
    }

    private func settle() async { for _ in 0 ..< 20 { await Task.yield() } ; try? await Task.sleep(nanoseconds: 20_000_000) }

    func testStillsShareTheGateAndAStartWaitsForThemAll() async {
        let gate = SCKGate()
        let log = Log()
        await gate.enter(.still); log.add("still 1 in")
        await gate.enter(.still); log.add("still 2 in")
        let start = Task { await gate.enter(.start); log.add("start in") }
        await settle()
        var s = await gate.state
        XCTAssertEqual(s.holders, 2)
        XCTAssertEqual(s.waiting, 1, "the start waits")
        await gate.leave(); log.add("still 1 out")
        await settle()
        XCTAssertFalse(log.all.contains("start in"), "one still is still running")
        await gate.leave(); log.add("still 2 out")
        await start.value
        XCTAssertEqual(log.all.last, "start in")
        s = await gate.state
        XCTAssertEqual(s.kind, .start)
        await gate.leave()
    }

    /// A long preview batch cannot starve a pick: once a start waits, a NEW still queues behind it.
    func testAStillArrivingBehindAWaitingStartWaitsItsTurn() async {
        let gate = SCKGate()
        let log = Log()
        await gate.enter(.still)
        let start = Task { await gate.enter(.start); log.add("start in") }
        await settle()
        let late = Task { await gate.enter(.still); log.add("late still in") }
        await settle()
        let waiting = await gate.state.waiting
        XCTAssertEqual(waiting, 2)
        await gate.leave()                              // the first still ends
        await start.value
        await settle()
        XCTAssertEqual(log.all, ["start in"], "the late still waits for the start")
        await gate.leave()                              // the start ends
        await late.value
        XCTAssertEqual(log.all, ["start in", "late still in"])
        await gate.leave()
    }

    /// Starts share it too — several windows restored at once start together.
    func testStartsShareTheGate() async {
        let gate = SCKGate()
        await gate.enter(.start)
        await gate.enter(.start)
        let s = await gate.state
        XCTAssertEqual(s.holders, 2)
        await gate.leave(); await gate.leave()
        let after = await gate.state
        XCTAssertNil(after.kind)
    }

    func testRunReleasesOnAThrow() async {
        struct Boom: Error {}
        let gate = SCKGate()
        do { try await gate.run(.still) { throw Boom() } } catch {}
        let s = await gate.state
        XCTAssertEqual(s.holders, 0)
        XCTAssertNil(s.kind)
    }
}
