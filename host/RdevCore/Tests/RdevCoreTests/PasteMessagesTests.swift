import XCTest
@testable import RdevCore

/// The paste/drop wire (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §3), held to
/// `protocol/fixtures/paste-messages.json` — the vectors the TypeScript builders produce
/// (`web/test/paste-wire.test.ts`). The client never sends what the host would drop.
final class PasteMessagesTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/paste-messages.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func parse(_ obj: Any) throws -> InboundMessage? {
        parseInbound(try JSONSerialization.data(withJSONObject: obj))
    }

    func testEveryBuiltMessageParses() throws {
        let built = try XCTUnwrap(try fixture()["built"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(built.count, 8, "a near-empty fixture would pass every assertion below")
        for c in built { XCTAssertNotNil(try parse(c["wire"]!), "\(c["wire"]!)") }
    }

    func testEveryMalformedMessageIsDropped() throws {
        let bad = try XCTUnwrap(try fixture()["malformed"] as? [Any])
        XCTAssertGreaterThanOrEqual(bad.count, 20)
        for m in bad { XCTAssertNil(try parse(m), "\(m)") }
    }

    func testOversizeParsesAndIsRefusedTooLarge() throws {
        let big = try XCTUnwrap(try fixture()["tooLarge"] as? [Any])
        XCTAssertEqual(big.count, 3)
        for m in big {
            guard case .pasteBegin(let b)? = try parse(m) else { return XCTFail("does not parse: \(m)") }
            XCTAssertEqual(PasteLimits.check(b.items), .tooLarge, "\(m)")
        }
    }

    func testTheBeginCarriesItsTargetItemsAndPoint() throws {
        let m = try parse(["t": "paste-begin", "id": "p3", "to": ["win": "win:4711"], "at": ["x": 0.42, "y": 0.17],
                           "items": [["kind": "file", "name": "a.png", "type": "image/png", "size": 10]]])
        XCTAssertEqual(m, .pasteBegin(PasteBegin(id: "p3", to: .window(source: "win:4711", at: PastePoint(x: 0.42, y: 0.17)),
                                                 items: [.file(name: "a.png", type: "image/png", size: 10)])))
        XCTAssertEqual(try parse(["t": "paste-begin", "id": "p5", "to": ["term": "tmux:$2"],
                                  "items": [["kind": "file", "name": "", "type": "", "size": 1]]]),
                       .pasteBegin(PasteBegin(id: "p5", to: .terminal(.tmux("$2")), items: [.file(name: "", type: "", size: 1)])))
    }

    func testAPieceAtTheLimitParsesAndOnePastItDoesNot() throws {
        let at = Data(repeating: 7, count: PasteLimits.chunkBytes).base64EncodedString()
        let past = Data(repeating: 7, count: PasteLimits.chunkBytes + 1).base64EncodedString()
        XCTAssertEqual(try parse(["t": "paste-data", "id": "p", "item": 0, "seq": 3, "data": at]),
                       .pasteData(id: "p", item: 0, seq: 3, bytes: Data(repeating: 7, count: PasteLimits.chunkBytes)))
        XCTAssertNil(try parse(["t": "paste-data", "id": "p", "item": 0, "seq": 3, "data": past]))
    }

    func testThirtyThreeItemsAndA256ByteNameAreMalformed() throws {
        let item: [String: Any] = ["kind": "file", "name": "a", "type": "", "size": 1]
        XCTAssertNotNil(try parse(["t": "paste-begin", "id": "a", "to": ["term": "pty:1"], "items": Array(repeating: item, count: 32)]))
        XCTAssertNil(try parse(["t": "paste-begin", "id": "a", "to": ["term": "pty:1"], "items": Array(repeating: item, count: 33)]))
        let name255 = "a" + String(repeating: "é", count: 127), name256 = String(repeating: "é", count: 128)
        XCTAssertEqual(name255.utf8.count, 255); XCTAssertEqual(name256.utf8.count, 256)
        let named = { (n: String) -> [String: Any] in ["t": "paste-begin", "id": "a", "to": ["term": "pty:1"],
                                                      "items": [["kind": "file", "name": n, "type": "", "size": 1]]] }
        XCTAssertNotNil(try parse(named(name255)))
        XCTAssertNil(try parse(named(name256)))
    }

    func testTheCapsAreTheSpecs() {
        XCTAssertEqual(PasteLimits.chunkBytes, 16384)
        XCTAssertEqual(PasteLimits.fileMaxBytes, 1_073_741_824)
        XCTAssertEqual(PasteLimits.textMaxBytes, 4_194_304)
        XCTAssertEqual(PasteLimits.totalMaxBytes, 1_073_741_824)
        XCTAssertEqual(PasteLimits.maxItems, 32)
        XCTAssertNil(PasteLimits.check([.file(name: "a", type: "", size: 1_073_741_824)]))
        XCTAssertEqual(PasteLimits.check([.file(name: "a", type: "", size: 1_073_741_825)]), .tooLarge)
        XCTAssertNil(PasteLimits.check([.text(size: 4_194_304)]))
    }

    func testTheRepliesAreExactly() throws {
        // A delivery's START, acknowledged (2026-10-02): the client sends no piece before it.
        let accepted = try JSONSerialization.jsonObject(with: pasteAcceptedJSON(id: "p1")) as? [String: String]
        XCTAssertEqual(accepted, ["t": "paste-accepted", "id": "p1"])
        let done = try JSONSerialization.jsonObject(with: pasteDoneJSON(id: "p1", how: .drop)) as? [String: String]
        XCTAssertEqual(done, ["t": "paste-done", "id": "p1", "how": "drop"])
        let err = try JSONSerialization.jsonObject(with: pasteErrorJSON(id: "p1", reason: .noTarget)) as? [String: String]
        XCTAssertEqual(err, ["t": "paste-error", "id": "p1", "reason": "no-target"])
        XCTAssertEqual(PasteError.allCases.map(\.rawValue).sorted(),
                       ["busy", "disk", "failed", "malformed", "no-target", "not-driver", "too-large"])
    }
}
