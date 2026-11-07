import Foundation
import ShellstormCore
import XCTest

/// The bridge socket's outbound queue: ORDER BY CALL, a batch per flush, the close LAST and ONCE
/// (docs/desktop-app.md, "The bridge socket").
final class FrameQueueTests: XCTestCase {
    private func frame(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) } }
    private func number(_ d: Data) -> Int { Int(d.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) }

    func testFramesLeaveInTheOrderTheyWereAppendedAcrossFlushes() {
        let q = FrameQueue()
        var out: [Int] = []
        for n in 0..<200 {
            _ = q.append(frame(n))
            if n % 7 == 3 { out += q.drain().frames.map(number) }
        }
        out += q.drain().frames.map(number)
        XCTAssertEqual(out, Array(0..<200))
    }

    func testOneFlushIsScheduledUntilItDrains() {
        let q = FrameQueue()
        XCTAssertTrue(q.append(frame(1)), "the first frame schedules a flush")
        XCTAssertFalse(q.append(frame(2)), "one is pending")
        XCTAssertFalse(q.append(frame(3)))
        XCTAssertEqual(q.drain().frames.count, 3)
        XCTAssertTrue(q.append(frame(4)), "after a drain the next frame schedules again")
    }

    func testTheCloseFollowsTheFramesAndEndsTheQueue() {
        let q = FrameQueue()
        _ = q.append(frame(1)); _ = q.append(frame(2))
        XCTAssertFalse(q.close(), "a flush is already pending, and it carries the close")
        let first = q.drain()
        XCTAssertEqual(first.frames.map(number), [1, 2])
        XCTAssertTrue(first.close)
        XCTAssertFalse(q.append(frame(3)), "nothing is sent after the close")
        let second = q.drain()
        XCTAssertEqual(second.frames.count, 0)
        XCTAssertFalse(second.close, "the close is handed out ONCE")
    }

    func testACloseOnAnEmptyQueueSchedulesAFlushOnce() {
        let q = FrameQueue()
        XCTAssertTrue(q.close())
        XCTAssertFalse(q.close(), "idempotent")
        XCTAssertEqual(q.drain().close, true)
    }

    func testDiscardDropsEverythingTheCloseIncluded() {
        let q = FrameQueue()
        _ = q.append(frame(1)); _ = q.close()
        q.discard()
        let d = q.drain()
        XCTAssertEqual(d.frames.count, 0)
        XCTAssertFalse(d.close, "the page is gone: nobody reads a close")
        XCTAssertFalse(q.append(frame(2)))
        XCTAssertFalse(q.close())
    }

    /// `TermWire` sends one wire's frames from several threads: each caller's own frames stay in order.
    func testConcurrentAppendsKeepEachCallersOrder() {
        let q = FrameQueue()
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<500 { _ = q.append(frame(t * 10_000 + i)) }
        }
        let all = q.drain().frames.map(number)
        XCTAssertEqual(all.count, 4000)
        for t in 0..<8 {
            let mine = all.filter { $0 / 10_000 == t }.map { $0 % 10_000 }
            XCTAssertEqual(mine, Array(0..<500), "thread \(t)'s frames were reordered")
        }
    }
}
