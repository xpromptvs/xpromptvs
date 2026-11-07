import Foundation
import XCTest
@testable import RdevCore

final class TermRawBatchTests: XCTestCase {
    func testRawChunkingPreservesPayloadAndEndKind() throws {
        let payload = Data(repeating: 65, count: 5000)
        let batch = try XCTUnwrap(TermRawBatch(tab: "pty:1", size: .init(cols: 80, rows: 24),
            bytes: Array(payload), kinds: (.screenChunk, .screenEnd), messageCeiling: 2048))
        XCTAssertEqual(batch.recordCount, 3)
        var joined = Data()
        for i in 0..<batch.recordCount {
            let raw = batch.record(at: i)
            XCTAssertLessThanOrEqual(raw.count, 1920)
            XCTAssertEqual(raw[0], i == 2 ? 8 : 7)
            XCTAssertEqual(Array(raw[7..<11]), [0,80,0,24])
            joined.append(raw.dropFirst(11))
        }
        XCTAssertEqual(joined, payload)
        XCTAssertEqual(batch.retainedBytes, 5005)
    }
    func testMalformedTabOrUnusableCeilingIsRefusedBeforeChunking() {
        XCTAssertNil(TermRawBatch(tab: "", size: nil, bytes: [], kinds: (.output,.output), messageCeiling: 2048))
        XCTAssertNil(TermRawBatch(tab: String(repeating: "x", count: 256), size: nil, bytes: [], kinds: (.output,.output), messageCeiling: 2048))
        XCTAssertNil(TermRawBatch(tab: "pty:1", size: nil, bytes: [], kinds: (.output,.output), messageCeiling: 100))
    }
    func testEmptySnapshotStillHasAnEndRecord() throws {
        let b = try XCTUnwrap(TermRawBatch(tab: "pty:1", size: .init(cols: 80, rows: 24), bytes: [], kinds: (.snapshotChunk,.snapshotEnd), messageCeiling: 2048))
        XCTAssertEqual(b.recordCount, 1)
        XCTAssertEqual(Array(b.record(at: 0)), [2,5,112,116,121,58,49,0,80,0,24])
    }
    func testGridFieldsClampInsteadOfWrapping() throws {
        let batch = try XCTUnwrap(TermRawBatch(tab: "a", size: .init(cols: 65536, rows: -1), bytes: [],
            kinds: (.snapshotChunk,.snapshotEnd), messageCeiling: 2048))
        XCTAssertEqual(TermFrame.decode(batch.record(at: 0))?.size, .init(cols: 65535, rows: 0))
    }
}
