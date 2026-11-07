import Foundation
import XCTest
@testable import RdevCore
import RdevTermCorpus

final class TermZstdTests: XCTestCase {
    func testCommittedWireVectorsAreFresh() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("protocol/fixtures/term-zstd-wire.json")
        XCTAssertEqual(try Data(contentsOf: path), try TermZstdVectors.json())
    }

    // Ending a frame per record, or buffering a tiny flush, breaks the live wire.
    func testInitializerThenOneByteDecodesWithoutAnotherArrival() throws {
        let encoder = try TermZstdEncoder()
        let decoder = try TermZstdInflater()
        let bootstrap = Data(0..<32)
        XCTAssertEqual(try decoder.push(encoder.flush(bootstrap), maximumOutput: 32), bootstrap)
        XCTAssertEqual(try decoder.push(encoder.flush(Data([65])), maximumOutput: 1), Data([65]))
        XCTAssertEqual(try decoder.push(encoder.flush(Data([66])), maximumOutput: 1), Data([66]))
    }

    // Oversized codec output would violate the transport message limit after scheduling.
    func testEveryRecordSizeFitsBothMessageCeilings() throws {
        var seed: UInt32 = 0x12345678
        var random = Data()
        for _ in 0..<8064 {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            random.append(UInt8(truncatingIfNeeded: seed))
        }
        for ceiling in [2048, 8192] {
            let encoder = try TermZstdEncoder()
            let decoder = try TermZstdInflater()
            _ = try decoder.push(encoder.flush(Data(0..<32)), maximumOutput: 32)
            for size in 1...(ceiling - 128) {
                let raw = Data(random.prefix(size))
                let compressed = try encoder.flush(raw)
                XCTAssertLessThanOrEqual(compressed.count + 25, ceiling)
                XCTAssertEqual(try decoder.push(compressed, maximumOutput: size), raw)
            }
        }
    }

    func testInterleavedRecordsDecodeExactly() throws {
        let encoder = try TermZstdEncoder()
        let decoder = try TermZstdInflater()
        for bytes in [Data(0..<32), Data("pty:1 hello".utf8), Data("pty:2 world".utf8), Data("pty:1 hello again".utf8)] {
            XCTAssertEqual(try decoder.push(encoder.flush(bytes), maximumOutput: bytes.count), bytes)
        }
    }

    func testReceiverRejectsDecodedOutputBeyondItsBound() throws {
        let encoder = try TermZstdEncoder()
        let decoder = try TermZstdInflater()
        let compressed = try encoder.flush(Data(repeating: 65, count: 8192))
        XCTAssertThrowsError(try decoder.push(compressed, maximumOutput: 16))
    }
}
