import Foundation
import XCTest
@testable import RdevCore

final class TermRawQueueTests: XCTestCase {
    func testAdmissionRefusesBeforeBuildingAndRetiresAllStorage() throws {
        let q = TermRawQueue(maximumBytes: 20, maximumRecords: 10)
        let batch = try XCTUnwrap(TermRawBatch(tab: "a", size: nil, bytes: Array(repeating: 65, count: 19), kinds: (.output,.output), messageCeiling: 2048))
        XCTAssertEqual(q.admit(rawBytes: 20, recordCount: 1, build: { batch }).0, .accepted)
        var built = false
        XCTAssertEqual(q.admit(rawBytes: 1, recordCount: 1, build: { built = true; return batch }).0, .overloaded)
        XCTAssertFalse(built)
        XCTAssertEqual(q.retainedBytes, 0)
        XCTAssertEqual(q.recordCount, 0)
        XCTAssertEqual(q.admit(rawBytes: 0, recordCount: 1, build: { batch }).0, .retired)
    }
    func testBackingIsChargedUntilItsLastRecordLeaves() throws {
        let q = TermRawQueue(maximumBytes: 10_000, maximumRecords: 10)
        let batch = try XCTUnwrap(TermRawBatch(tab: "a", size: nil, bytes: Array(repeating: 65, count: 4000), kinds: (.output,.output), messageCeiling: 2048))
        XCTAssertEqual(batch.recordCount, 3)
        XCTAssertEqual(q.admit(rawBytes: 4001, recordCount: 3, build: { batch }).0, .accepted)
        q.releaseRecord(of: batch); XCTAssertEqual(q.retainedBytes, 4001); XCTAssertEqual(q.recordCount, 2)
        q.releaseRecord(of: batch); XCTAssertEqual(q.retainedBytes, 4001)
        q.releaseRecord(of: batch); XCTAssertEqual(q.retainedBytes, 0); XCTAssertEqual(q.recordCount, 0)
    }
    func testRecordCountAndBuildMismatchAreIndependentlyBounded() throws {
        let q = TermRawQueue(maximumBytes: 10_000, maximumRecords: 1)
        let batch = try XCTUnwrap(TermRawBatch(tab: "a", size: nil, bytes: [], kinds: (.output,.output), messageCeiling: 2048))
        XCTAssertEqual(q.admit(rawBytes: 2, recordCount: 1, build: { batch }).0, .invalid)
        XCTAssertEqual(q.retainedBytes, 0)
        XCTAssertEqual(q.admit(rawBytes: 1, recordCount: 1, build: { batch }).0, .accepted)
        var built = false
        XCTAssertEqual(q.admit(rawBytes: 1, recordCount: 1, build: { built = true; return batch }).0, .overloaded)
        XCTAssertFalse(built)
    }
    func testProductionLimitsRefuseBeforeAllocatingPayloadOrDescriptors() {
        for (bytes, records) in [(64 * 1024 * 1024 + 1, 1), (1, 65_537)] {
            let q = TermRawQueue()
            var built = false
            XCTAssertEqual(q.admit(rawBytes: bytes, recordCount: records, build: {
                built = true; return nil
            }).0, .overloaded)
            XCTAssertFalse(built)
        }
    }
}
