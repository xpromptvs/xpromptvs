import XCTest
import RdevTermCorpus
@testable import RdevCore

/// A LINK, simulated: bytes handed to "pion" leave at `bytesPerSecond`, one after another, and each frame is
/// acknowledged a round trip after its last byte left. `buffered` is what pion's `bufferedAmount` reports: handed and
/// not yet acknowledged.
private final class Link: @unchecked Sendable {
    let bytesPerSecond: Double
    let rttNanos: UInt64
    private(set) var now: UInt64 = 0
    private var freeAt: UInt64 = 0
    private var acks: [(at: UInt64, bytes: Int)] = []
    private var timers: [(at: UInt64, f: @Sendable () -> Void)] = []
    private(set) var sent: [Data] = []
    /// When each frame sent reached the far end (its last byte left, plus half the round trip).
    private(set) var deliveredAt: [UInt64] = []
    private(set) var handedAt: [UInt64] = []
    private(set) var maxBuffered = 0
    init(kbps: Double, rttMs: Double) { bytesPerSecond = kbps * 1000 / 8; rttNanos = UInt64(rttMs * 1e6) }

    var buffered: Int { acks.filter { $0.at > now }.reduce(0) { $0 + $1.bytes } }
    func send(_ d: Data) {
        sent.append(d)
        handedAt.append(now)
        let start = max(now, freeAt)
        freeAt = start + UInt64(Double(d.count) / bytesPerSecond * 1e9)
        deliveredAt.append(freeAt + rttNanos / 2)
        acks.append((freeAt + rttNanos, d.count))
        maxBuffered = max(maxBuffered, buffered)
    }
    func schedule(_ after: UInt64, _ f: @escaping @Sendable () -> Void) { timers.append((now + after, f)) }
    /// Run every timer due by `t`, in order.
    func advance(to t: UInt64) {
        while let next = timers.enumerated().min(by: { $0.element.at < $1.element.at }), next.element.at <= t {
            timers.remove(at: next.offset)
            now = max(now, next.element.at)
            next.element.f()
        }
        now = max(now, t)
    }
    /// Move the clock without running any timer (no poll happens).
    func setNow(_ t: UInt64) { now = max(now, t) }
    /// When the last byte handed so far is acknowledged.
    var allAckedAt: UInt64 { acks.map(\.at).max() ?? 0 }
}

final class TermPacerTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private var seed: UInt64 = 1
    private func noise(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in seed = seed &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: seed >> 56) }
    }
    private func pacer(_ link: Link, active: String? = nil, path: TermPath = TermPath(), ceiling: Int = 8192,
                       capacity: Int = TermPath.ceilingBytes) -> SharedTermPacer {
        SharedTermPacer(path: path, deps: .init(send: { link.send($0) }, buffered: { link.buffered },
            now: { link.now }, schedule: { link.schedule($0,$1) }, activeTab: { active }),
            epoch: 1, messageCeiling: ceiling, capacity: capacity, failed: { _ in XCTFail("unexpected wire failure") })
    }
    private func enqueue(_ p: SharedTermPacer, _ tab: String, _ bytes: [UInt8], ceiling: Int = 8192) {
        let batch = TermRawBatch(tab: tab, size: nil, bytes: bytes, kinds: (.output,.output), messageCeiling: ceiling)!
        XCTAssertEqual(p.admit(tab: tab, lane: .regular, rawBytes: batch.retainedBytes, recordCount: batch.recordCount,
                               build: { batch }), .accepted)
    }
    private func records(_ link: Link) throws -> [(index: Int, frame: TermFrame)] {
        let decoder = try TermZstdInflater(); var frames: [(Int,TermFrame)] = []; var sequence: UInt64 = 0
        for (i, d) in link.sent.enumerated() {
            switch try TermWireMessage.decode(d) {
            case let .start(_, compressed): XCTAssertEqual(try decoder.push(compressed, maximumOutput: 32), Data(0..<32))
            case let .data(_, seq, length, compressed):
                XCTAssertEqual(seq, sequence); sequence += 1
                frames.append((i, try XCTUnwrap(TermFrame.decode(try decoder.push(compressed, maximumOutput: Int(length))))))
            }
        }
        return frames
    }
    func testPacerObservesTheFinalAckBeforeAnIdleBurst() throws {
        let link = Link(kbps: 100, rttMs: 50), path = TermPath(minimumBytes: 8192)
        let p = pacer(link, path: path, ceiling: 2048)
        enqueue(p, "a", noise(100), ceiling: 2048)
        XCTAssertEqual(p.queuedBytes, 0, "raw queue is empty while transport still holds bytes")
        link.advance(to: 500 * ms)
        let base = try XCTUnwrap(path.baseDelayNanos, "observe the final ACK even without queued raw records")
        XCTAssertLessThan(base, 100 * ms)
        XCTAssertEqual(path.outstandingCount, 0)
        // An idle interval is not an RTT; the completed ACK has already been sampled.
        link.advance(to: 20_000 * ms)
        enqueue(p, "a", noise(100), ceiling: 2048)
        XCTAssertEqual(path.baseDelayNanos, base)
    }
    func testASlowLinkHoldsTheBurstHereNotInTransport() throws {
        let link = Link(kbps: 100, rttMs: 50), path = TermPath()
        let p = pacer(link, path: path)
        let inputs = (0..<15).map { _ in noise(8048) }
        for bytes in inputs { enqueue(p, "b", bytes) }
        XCTAssertGreaterThan(p.queuedBytes, 90 * 1024)
        link.advance(to: 15_000 * ms)
        XCTAssertEqual(try records(link).map { $0.frame.payload }, inputs)
        XCTAssertLessThanOrEqual(link.maxBuffered, TermPath.floorBytes + 8192)
        XCTAssertEqual(path.spanResetCount, 0)
    }
    func testSmallerTransportFloorStillGrowsWithMeasuredCapacity() throws {
        let path = TermPath(minimumBytes: 8192), link = Link(kbps: 100000, rttMs: 50)
        let p = pacer(link, path: path, ceiling: 2048)
        for _ in 0..<1024 { enqueue(p, "a", noise(1900), ceiling: 2048) }
        link.advance(to: 10_000 * ms)
        XCTAssertEqual(try records(link).count, 1024)
        XCTAssertGreaterThan(link.maxBuffered, 8192)
        XCTAssertTrue(link.sent.allSatisfy { $0.count <= 2048 })
    }
    func testTransportCapacityBoundsTheAdaptiveBudget() throws {
        let link = Link(kbps: 1_000_000, rttMs: 10)
        let p = pacer(link, capacity: 16 * 1024)
        for _ in 0..<1024 { enqueue(p, "a", noise(8048)) }
        link.advance(to: 10_000 * ms)
        XCTAssertEqual(try records(link).count, 1024)
        XCTAssertLessThanOrEqual(link.maxBuffered, 16 * 1024)
    }
    func testALongRoundTripFastPathIsNotHeldToATrickle() throws {
        let link = Link(kbps: 50_000, rttMs: 300)
        let p = pacer(link)
        for _ in 0..<1000 { enqueue(p, "b", noise(8048)) }
        link.advance(to: 30_000 * ms)
        XCTAssertEqual(try records(link).count, 1000)
        XCTAssertLessThan(link.allAckedAt, 6_000 * ms)
    }
    func testSustainedLoadDoesNotRatchetTheBudget() throws {
        let link = Link(kbps: 100, rttMs: 50), path = TermPath()
        let p = pacer(link, active: "a", path: path)
        var echoes: [UInt64] = []; var t: UInt64 = 0; var nextEcho: UInt64 = 2000 * ms
        while t < 90_000 * ms {
            enqueue(p, "b", noise(1200))
            if t >= nextEcho { echoes.append(link.now); enqueue(p, "a", [65]); nextEcho += 5000 * ms }
            t += 80 * ms; link.advance(to: t)
        }
        let sentEchoes = try records(link).filter { $0.frame.tab == "a" }.map(\.index)
        XCTAssertEqual(sentEchoes.count, echoes.count)
        let delays = zip(echoes, sentEchoes).map { Double(link.deliveredAt[$1] - $0) / 1e9 }
        let early = delays.prefix(4).max() ?? 0, late = delays.suffix(6).max() ?? 0
        XCTAssertLessThan(late, 2.0)
        XCTAssertLessThan(late, early + 0.5)
        XCTAssertLessThan(Double(path.baseDelayNanos ?? 0) / 1e9, 0.3)
    }
    func testAnIdleChannelSendsAtOnceAndKeepsNoBookkeeping() {
        let path = TermPath()
        final class Counter: @unchecked Sendable { var sent = 0 }
        let counter = Counter()
        let p = SharedTermPacer(path: path, deps: .init(send: { _ in counter.sent += 1 }, buffered: { 0 },
            now: { 0 }, schedule: { _, _ in }, activeTab: { nil }), epoch: 1, messageCeiling: 8192, failed: { _ in XCTFail() })
        for _ in 0..<10_000 { enqueue(p, "a", [1,2,3]) }
        XCTAssertEqual(counter.sent, 10_001) // START + each record, synchronously
        XCTAssertLessThanOrEqual(path.outstandingCount, 1)
    }
    func testAnAcknowledgedCountThatGoesBackwardsNeitherTrapsNorInflatesTheBudget() {
        let path = TermPath()
        path.handed(10_000, now: 0, heldBefore: 0)
        XCTAssertEqual(path.budget(now: 10 * ms, buffered: 10_000), TermPath.initialBytes)
        XCTAssertEqual(path.budget(now: 520 * ms, buffered: 0), TermPath.initialBytes)   // nothing waited: no rate yet
        path.handed(1_000, now: 540 * ms, heldBefore: 0)
        // The transport reports 1_004 held of the 1_000 handed: acknowledged 9_996, below the 10_000 read before.
        XCTAssertEqual(path.budget(now: 550 * ms, buffered: 1_004), TermPath.initialBytes)   // the span starts again: no rate, the initial budget
        // The first reading has aged out of the span, and a rate is due again: a span from 10_000 down to 9_996 would
        // read as 2⁶⁴ bytes in 140 ms.
        let budget = path.budget(now: 660 * ms, buffered: 1_004)
        XCTAssertEqual(budget, TermPath.initialBytes, "a count that went backwards must not become a rate")
        XCTAssertEqual(path.spanResetCount, 1, "the one backwards reading is counted; a healthy path counts none")
    }
    func testTheBudgetBoundNeverTraps() {
        XCTAssertEqual(TermPath.bounded(.nan), TermPath.ceilingBytes)
        XCTAssertEqual(TermPath.bounded(.infinity), TermPath.ceilingBytes)
        XCTAssertEqual(TermPath.bounded(-.infinity), TermPath.floorBytes, "a negative infinity is below the floor")
        XCTAssertEqual(TermPath.bounded(1e300), TermPath.ceilingBytes)
        XCTAssertEqual(TermPath.bounded(Double(Int.max) * 4), TermPath.ceilingBytes)
        XCTAssertEqual(TermPath.bounded(-1e300), TermPath.floorBytes)
        XCTAssertEqual(TermPath.bounded(-1), TermPath.floorBytes)
        XCTAssertEqual(TermPath.bounded(0), TermPath.floorBytes)
        XCTAssertEqual(TermPath.bounded(100_000), 100_000)
        XCTAssertEqual(TermPath.bounded(Double(TermPath.ceilingBytes) + 1), TermPath.ceilingBytes)
    }
}
