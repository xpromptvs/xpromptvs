import Foundation
import XCTest
@testable import RdevCore
import RdevTermCorpus

final class SharedTermPacerTests: XCTestCase {
    final class Rig: @unchecked Sendable {
        var held: Int? = 16_384
        var sent: [Data] = []
        var timers: [@Sendable () -> Void] = []
        var active: String? = "a"
        lazy var pacer = SharedTermPacer(path: TermPath(), deps: .init(
            send: { [self] d in sent.append(d); if held != nil { held! += d.count } },
            buffered: { [self] in held }, now: { 1 },
            schedule: { [self] _, f in timers.append(f) }, activeTab: { [self] in active }),
            epoch: 7, messageCeiling: 2048, failed: { _ in })
        @discardableResult
        func add(_ tab: String, _ bytes: [UInt8], _ lane: SharedTermPacer.Lane = .regular) -> TermAdmission {
            let size = lane == .snapshot || lane == .history ? TermGridSize(cols: 80, rows: 24) : nil
            let kinds: (TermFrameKind, TermFrameKind) = lane == .snapshot ? (.screenChunk,.screenEnd)
                : lane == .history ? (.historyChunk,.historyEnd) : (.output,.output)
            let batch = TermRawBatch(tab: tab, size: size, bytes: bytes, kinds: kinds, messageCeiling: 2048)!
            return pacer.admit(tab: tab, lane: lane, rawBytes: batch.retainedBytes,
                               recordCount: batch.recordCount, build: { batch })
        }
        func tick() { let work = timers; timers = []; for f in work { f() } }
        func drain() {
            for _ in 0..<100 where !timers.isEmpty { held = 0; tick() }
            XCTAssertTrue(timers.isEmpty)
        }
        func records() throws -> [TermFrame] {
            let decoder = try TermZstdInflater()
            var records: [TermFrame] = []; var seq: UInt64 = 0
            for message in sent {
                XCTAssertLessThanOrEqual(message.count, 2048)
                switch try TermWireMessage.decode(message) {
                case let .start(epoch, compressed):
                    XCTAssertEqual(epoch, 7)
                    XCTAssertEqual(try decoder.push(compressed, maximumOutput: 32), Data(0..<32))
                case let .data(epoch, sequence, size, compressed):
                    XCTAssertEqual(epoch, 7); XCTAssertEqual(sequence, seq); seq += 1
                    let raw = try decoder.push(compressed, maximumOutput: Int(size))
                    XCTAssertEqual(raw.count, Int(size))
                    records.append(try XCTUnwrap(TermFrame.decode(raw)))
                }
            }
            return records
        }
    }
    func testFastHistoryMakesAcknowledgedProgressWithoutTheOneSecondTimer() throws {
        final class Transport: @unchecked Sendable {
            let sender = FastDelivery(generation: Data(repeating: 7, count: 16))
            let receiver = FastDelivery(generation: Data(repeating: 7, count: 16))
            var packets: [FastData.Record] = []
            var timers: [@Sendable () -> Void] = []
            var blocked = true
            func send(_ bytes: Data) {
                guard case let .accepted(effects) = sender.send(0, message: bytes, nowMs: 0) else { return XCTFail("send refused") }
                for effect in effects { if case let .transmit(record) = effect { packets.append(record) } }
            }
            func deliver() -> Int {
                let pending = packets; packets = []; var acknowledgements = 0
                for packet in pending {
                    for effect in receiver.receive(packet, nowMs: 0, ackDelayMs: 1000) {
                        if case let .transmit(ack) = effect {
                            acknowledgements += 1; _ = sender.receive(ack, nowMs: 0)
                        }
                    }
                }
                return acknowledgements
            }
            func tick() { let pending = timers; timers = []; for timer in pending { timer() } }
        }
        let t = Transport()
        let p = SharedTermPacer(path: TermPath(minimumBytes: 8192), deps: .init(
            send: { t.send($0) }, buffered: { t.blocked ? 8192 : t.sender.bufferedAmount(0) }, now: { 1 },
            schedule: { _, f in t.timers.append(f) }, activeTab: { "a" }),
            epoch: 1, messageCeiling: 2048, failed: { _ in XCTFail("wire failed") })
        var seed: UInt32 = 12345
        let bytes: [UInt8] = (0..<30_000).map { _ in
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return UInt8(truncatingIfNeeded: seed)
        }
        let batch = try XCTUnwrap(TermRawBatch(tab: "a", size: .init(cols: 80, rows: 24), bytes: bytes,
            kinds: (.historyChunk,.historyEnd), messageCeiling: 2048))
        XCTAssertEqual(p.admit(tab: "a", lane: .history, rawBytes: batch.retainedBytes,
            recordCount: batch.recordCount, build: { batch }), .accepted)
        t.blocked = false; t.tick()
        XCTAssertGreaterThan(p.queuedBytes, 0)
        // The spare lane reserves 2 KiB inside its 4 KiB allowance. Compressed records
        // cannot reach a 4 KiB ACK threshold; waiting for the timer stalls every batch.
        XCTAssertGreaterThan(t.deliver(), 0, "history must release pacing capacity without the delayed ACK timer")
        for _ in 0..<30 where p.queuedBytes > 0 { t.tick(); _ = t.deliver() }
        XCTAssertEqual(p.queuedBytes, 0, "history makes progress without advancing a one-second ACK timer")
    }
    func testSharedDecodeFollowsPriorityOrderAndFourRecordFairness() throws {
        let r = Rig(); r.pacer.begin()
        for i in 0..<10 { r.add("b", Array(repeating: UInt8(i + 40), count: 1800)) }
        for i in 0..<10 { r.add("a", Array(repeating: UInt8(i + 80), count: 1800)) }
        XCTAssertTrue(r.sent.isEmpty)
        r.drain()
        let frames = try r.records()
        XCTAssertEqual(Array(frames.prefix(5).map(\.tab)), ["a","a","a","a","b"])
        for tab in ["a","b"] {
            XCTAssertEqual(frames.filter { $0.tab == tab }.map { $0.payload }, (0..<10).map { Array(repeating: UInt8($0 + (tab == "a" ? 80 : 40)), count: 1800) })
        }
        XCTAssertEqual(r.pacer.queuedBytes, 0)
    }
    func testCanceledHistoryNeverEntersSharedContext() throws {
        let r = Rig(); r.pacer.begin()
        r.add("b", Array(repeating: 90, count: 10_000), .history)
        r.add("b", [83], .snapshot)
        r.add("a", [65])
        r.drain()
        let frames = try r.records()
        XCTAssertFalse(frames.contains { $0.kind == .historyChunk || $0.kind == .historyEnd })
        XCTAssertEqual(frames.filter { $0.tab == "b" }.flatMap(\.payload), [83])
        XCTAssertEqual(r.pacer.queuedBytes, 0)
    }
    func testHistoryGetsEighthOpportunityAndWaitsForScreen() throws {
        let r = Rig(); r.pacer.begin()
        r.add("b", [83], .snapshot)
        r.add("b", Array(repeating: 72, count: 10_000), .history)
        for _ in 0..<20 { r.add("a", [65]) }
        r.drain()
        let frames = try r.records()
        XCTAssertEqual(frames[7].kind, .historyChunk)
        XCTAssertLessThan(frames.firstIndex { $0.kind == .screenEnd }!, 7)
    }
    func testHistoryWaitsForAllTwelveScreenRecords() throws {
        for screenTab in ["a", "b"] {
            let r = Rig(); r.pacer.begin()
            let otherTab = screenTab == "a" ? "b" : "a"
            r.add(screenTab, Array(repeating: 83, count: 22_000), .snapshot)
            r.add(screenTab, Array(repeating: 72, count: 10_000), .history)
            for _ in 0..<60 { r.add(otherTab, [65]) }
            r.drain()
            let frames = try r.records()
            let screen = frames.indices.filter { frames[$0].kind == .screenChunk || frames[$0].kind == .screenEnd }
            let history = frames.indices.filter { frames[$0].kind == .historyChunk || frames[$0].kind == .historyEnd }
            XCTAssertEqual(screen.count, 12)
            let screenEnd = try XCTUnwrap(frames.firstIndex { $0.kind == .screenEnd })
            XCTAssertFalse(history.isEmpty)
            XCTAssertTrue(history.allSatisfy { $0 > screenEnd }, "history preceded screen end for tab \(screenTab)")
            XCTAssertTrue(frames.prefix(screenEnd).contains { $0.tab == otherTab })
        }
    }
    func testReservesWholeCeilingBeforeEncodingTinyEcho() throws {
        let r = Rig(); r.pacer.begin(); r.held = 0; r.tick()
        let startCount = r.sent.count
        r.held = 16_384 - 2048 + 1
        r.add("a", [65]); XCTAssertEqual(r.sent.count, startCount)
        r.held = 16_384 - 2048; r.tick()
        XCTAssertEqual(r.sent.count, startCount + 1)
        XCTAssertEqual(try r.records().last?.payload, [65])
    }
    func testRetireReleasesRawStorageAndStopsPendingDrain() {
        let r = Rig(); r.pacer.begin(); r.add("a", Array(repeating: 65, count: 10_000))
        XCTAssertEqual(r.pacer.queuedBytes, 10_001)
        r.pacer.retire(); r.drain()
        XCTAssertEqual(r.pacer.queuedBytes, 0); XCTAssertTrue(r.sent.isEmpty)
        XCTAssertEqual(r.add("a", [65]), .retired)
    }
    func testPartlyDeliveredHistoryCanBeCanceledWithoutDamagingNextRecord() throws {
        let r = Rig(); r.pacer.begin(); r.add("b", [83], .snapshot)
        // Incompressible history fills half the budget after a few records.
        var seed: UInt32 = 12345
        let bytes: [UInt8] = (0..<30_000).map { _ in
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return UInt8(truncatingIfNeeded: seed)
        }
        r.add("b", bytes, .history); r.held = 0; r.tick()
        let before = try r.records()
        XCTAssertTrue(before.contains { $0.kind == .historyChunk })
        XCTAssertFalse(before.contains { $0.kind == .historyEnd })
        r.held = 16_384
        r.add("b", [78], .snapshot); r.add("a", [65])
        r.drain()
        let frames = try r.records()
        XCTAssertEqual(frames.filter { $0.kind == .historyChunk }.count,
                       before.filter { $0.kind == .historyChunk }.count)
        XCTAssertEqual(frames.last { $0.tab == "b" }?.payload, [78])
        XCTAssertEqual(frames.last { $0.tab == "a" }?.payload, [65])
    }
    func testUnavailableTransportRetiresBeforeCodecAllocation() {
        let r = Rig(); r.held = nil; r.pacer.begin()
        XCTAssertTrue(r.sent.isEmpty); XCTAssertEqual(r.pacer.allocatedCodecBytes, 0)
        XCTAssertEqual(r.add("a", [65]), .retired)
    }
    func testOverloadRefusesWholeBatchBeforeBuildAndNotifiesOnce() {
        let failure = expectation(description: "overload"); failure.assertForOverFulfill = true
        let pacer = SharedTermPacer(path: TermPath(), deps: .init(send: { _ in XCTFail("blocked") },
            buffered: { 16_384 }, now: { 1 }, schedule: { _, _ in }, activeTab: { nil }),
            epoch: 1, messageCeiling: 2048, maximumBytes: 4096, maximumRecords: 2,
            failed: { reason in if case .overloaded = reason { failure.fulfill() } else { XCTFail("wrong failure") } })
        var built = false
        XCTAssertEqual(pacer.admit(tab: "a", lane: .regular, rawBytes: 2049, recordCount: 2,
                                  build: { built = true; return nil }), .overloaded)
        XCTAssertFalse(built); XCTAssertEqual(pacer.queuedBytes, 0)
        XCTAssertEqual(pacer.admit(tab: "a", lane: .regular, rawBytes: 1, recordCount: 1,
                                  build: { built = true; return nil }), .retired)
        wait(for: [failure], timeout: 2)
    }
    func testOneAndTenTabsKeepOneCodecAndReleaseAllRawBacking() throws {
        for count in [1, 10] {
            let r = Rig(); r.pacer.begin()
            let bytes = Array(repeating: UInt8(65), count: 1024 * 1024)
            for i in 0..<count { XCTAssertEqual(r.add("tab-\(i)", bytes), .accepted) }
            let queued = r.pacer.queuedBytes
            XCTAssertEqual(queued, count * (bytes.count + 5))
            XCTAssertEqual(r.pacer.allocatedCodecBytes, 0, "no encoder before capacity")
            r.drain()
            XCTAssertEqual(r.pacer.queuedBytes, 0)
            XCTAssertLessThan(r.pacer.allocatedCodecBytes, 4 * 1024 * 1024, "one codec regardless of tab count")
            let frames = try r.records()
            for i in 0..<count {
                XCTAssertEqual(frames.filter { $0.tab == "tab-\(i)" }.flatMap(\.payload), bytes)
            }
            print("shared-zstd tabs=\(count) rawQueuePeak=\(queued) codecBytes=\(r.pacer.allocatedCodecBytes) wireBytes=\(r.sent.reduce(0) { $0 + $1.count })")
        }
    }

}
