import Foundation
import XCTest
import RdevCore
import RdevTermCorpus
@testable import RdevHostKit

final class TermWireSharedTests: XCTestCase {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [Data] = []
        func add(_ d: Data) { lock.lock(); defer { lock.unlock() }; messages.append(d) }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return messages }
    }
    func testConcurrentEmissionsHaveOneStartAndConsecutiveSequences() throws {
        let sent = Sent()
        let wire = TermWire(epoch: 93, deliver: { sent.add($0) })
        DispatchQueue.concurrentPerform(iterations: 32) { i in wire.emit(.closed(.pty(i))) }
        wire.begin()
        let messages = try sent.all.map(TermWireMessage.decode)
        XCTAssertEqual(messages.count, 33)
        guard case let .start(epoch, compressed) = messages[0] else { return XCTFail("START must lead") }
        XCTAssertEqual(epoch, 93)
        let decoder = try TermZstdInflater()
        XCTAssertEqual(try decoder.push(compressed, maximumOutput: 32), Data(0..<32))
        for (index, message) in messages.dropFirst().enumerated() {
            guard case let .data(e, sequence, size, compressed) = message else { return XCTFail("duplicate START") }
            XCTAssertEqual(e, 93); XCTAssertEqual(sequence, UInt64(index))
            XCTAssertEqual(TermFrame.decode(try decoder.push(compressed, maximumOutput: Int(size)))?.kind, .closed)
        }
    }
    func testRefusedSnapshotIsNotBuiltAndWireStopsOnceOverloaded() {
        let failed = expectation(description: "overload"); failed.assertForOverFulfill = true
        let sent = Sent()
        let wire = TermWire(epoch: 1, messageCeiling: 2048, maximumBytes: 4096,
                            deliver: { sent.add($0) }, failed: { reason in
            if case .overloaded = reason { failed.fulfill() } else { XCTFail("wrong failure") }
        })
        XCTAssertFalse(wire.emit(.snapshot(.pty(1), .init(cols: 80, rows: 24), Array(repeating: 65, count: 5000))))
        XCTAssertFalse(wire.emit(.output(.pty(1), [65])))
        wait(for: [failed], timeout: 2)
        XCTAssertLessThanOrEqual(sent.all.count, 1)
    }
    func testUnknownTabCannotTakeQueryOwnershipAndRetirementFencesFutureOutput() {
        let wire = TermWire(epoch: 1, deliver: { _ in })
        XCTAssertFalse(wire.emit(.output(.pty(1), [27,91,54,110])))
        XCTAssertTrue(wire.emit(.snapshot(.pty(1), .init(cols: 80, rows: 24), [])))
        XCTAssertTrue(wire.emit(.output(.pty(1), [27,91,54,110])))
        wire.retire()
        XCTAssertFalse(wire.emit(.output(.pty(1), [27,91,54,110])))
    }
    func testClosureAfterCapacityCheckStopsTheNextRecord() {
        final class Transport: @unchecked Sendable {
            var closed = false
            var messages: [Data] = []
            func send(_ bytes: Data) {
                messages.append(bytes)
                if messages.count == 2 { closed = true } // closes during the first DATA send
            }
        }
        let transport = Transport()
        let failed = expectation(description: "transport failure")
        let pacer = SharedTermPacer(path: TermPath(), deps: .init(send: { transport.send($0) },
            buffered: { transport.closed ? nil : 0 }, now: { 0 }, schedule: { _, _ in }, activeTab: { nil }),
            epoch: 1, messageCeiling: 2048, failed: { reason in
                if case .transport = reason { failed.fulfill() } else { XCTFail("wrong failure") }
            })
        let wire = TermWire(epoch: 1, messageCeiling: 2048, pacer: pacer)
        XCTAssertTrue(wire.emit(.snapshot(.pty(1), .init(cols: 80, rows: 24), Array(repeating: 65, count: 10_000))), "admitted bytes may already have reached the client; retirement must not turn this into a host-answer refusal")
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(transport.messages.count, 2)
        XCTAssertEqual(pacer.queuedBytes, 0)
        XCTAssertFalse(wire.emit(.output(.pty(1), [66])))
    }
}
