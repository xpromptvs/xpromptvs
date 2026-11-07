import Foundation
import XCTest
import RdevCore
import RdevTermCorpus

final class TermWireFixtureTests: XCTestCase {
    func testCommittedFixtureIsFreshAndEveryRecordDecodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures")
        let fresh = TermCorpus.wireFixture()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("term-wire.bin")), fresh.bin)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("term-wire.json")), fresh.expected)
        var offset = 0, sequence: UInt64 = 0, epoch: UInt64 = 0
        var decoder: TermZstdInflater?
        var payloads: [String: [Data]] = [:], mid: Set<String> = [], closed: [String] = []
        while offset < fresh.bin.count {
            let b = fresh.bin
            let n = b[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }; offset += 4
            let message = try TermWireMessage.decode(Data(b[offset..<(offset+n)])); offset += n
            switch message {
            case let .start(e, compressed):
                XCTAssertGreaterThan(e, epoch); epoch = e; sequence = 0; mid = []
                decoder = try TermZstdInflater()
                XCTAssertEqual(try decoder!.push(compressed, maximumOutput: 32), Data(0..<32))
            case let .data(e, seq, length, compressed):
                XCTAssertEqual(e, epoch); XCTAssertEqual(seq, sequence); sequence += 1
                let raw = try XCTUnwrap(decoder).push(compressed, maximumOutput: Int(length))
                let f = try XCTUnwrap(TermFrame.decode(raw))
                let history = f.kind == .historyChunk || f.kind == .historyEnd
                let key = f.tab + (history ? "#history" : "")
                switch f.kind {
                case .closed: closed.append(f.tab)
                case .wireStart: XCTFail("nested START")
                case .output: payloads[key]![payloads[key]!.count - 1].append(contentsOf: f.payload)
                default:
                    if !mid.contains(key) { payloads[key, default: []].append(Data()) }
                    payloads[key]![payloads[key]!.count - 1].append(contentsOf: f.payload)
                    if f.kind == .snapshotChunk || f.kind == .screenChunk || f.kind == .historyChunk { mid.insert(key) } else { mid.remove(key) }
                }
            }
        }
        struct Expected: Decodable { let generations: [String:[String]]; let closed: [String] }
        let want = try JSONDecoder().decode(Expected.self, from: fresh.expected)
        XCTAssertEqual(payloads.mapValues { $0.map { String(decoding: $0, as: UTF8.self) } }, want.generations)
        XCTAssertEqual(closed, want.closed)
    }
}
