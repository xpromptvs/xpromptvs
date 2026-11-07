import XCTest
@testable import RdevCore

final class SourceInputMessageTests: XCTestCase {
    private func parse(_ text: String) -> InboundMessage? { parseInbound(Data(text.utf8)) }

    func testSharedSourceInputWireFixture() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/source-input.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for accepted in [true, false] {
            let rows = try XCTUnwrap(fixture[accepted ? "valid" : "invalid"] as? [[String: Any]])
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                let message = try JSONSerialization.data(withJSONObject: try XCTUnwrap(row["message"]))
                let parsed = parseInbound(message)
                if accepted {
                    guard case .sourceInput? = parsed else { XCTFail("\(row["name"] ?? "unnamed"): not source input"); continue }
                } else { XCTAssertNil(parsed, "\(row["name"] ?? "unnamed")") }
            }
        }
    }

    func testCapabilityIsExplicitVersionOne() {
        XCTAssertEqual(parse(#"{"t":"source-input-capabilities","v":1}"#), .sourceInput(.capabilities))
        for value in ["null", "true", "2", "1.5", #""1""#] {
            XCTAssertNil(parse("{\"t\":\"source-input-capabilities\",\"v\":\(value)}"))
        }
        XCTAssertNil(parse(#"{"t":"source-input-capabilities"}"#))
    }

    func testFocusRequestNamesItsSourceAndCorrelationNonce() {
        XCTAssertEqual(parse(#"{"t":"source-focus","source":"win:42","request":"focus-a"}"#),
                       .sourceInput(.focus(source: "win:42", request: "focus-a")))
        XCTAssertEqual(parse(#"{"t":"source-focus","source":null,"request":"terminal"}"#),
                       .sourceInput(.focus(source: nil, request: "terminal")))
        XCTAssertNil(parse(#"{"t":"source-focus","request":"missing-source"}"#))
        XCTAssertNil(parse(#"{"t":"source-focus","source":"win:42"}"#))
        XCTAssertNil(parse(#"{"t":"source-focus","source":"win:42","request":""}"#))
    }

    func testInputEnvelopeRequiresSourceLeaseAndAnInputOnlyPayload() {
        XCTAssertEqual(parse(#"{"t":"source-input","source":"win:42","lease":"route-a","event":{"t":"win-keys-release"}}"#),
                       .sourceInput(.input(source: "win:42", lease: "route-a", event: .winKeysRelease)))
        XCTAssertNil(parse(#"{"t":"source-input","source":"win:42","event":{"t":"win-keys-release"}}"#))
        XCTAssertNil(parse(#"{"t":"source-input","source":"win:42","lease":"","event":{"t":"win-keys-release"}}"#))
        XCTAssertNil(parse(#"{"t":"source-input","lease":"route-a","event":{"t":"win-keys-release"}}"#))
        for event in [#"{"t":"kill-tmux","session":"$1"}"#, #"{"t":"source-focus","source":"win:1","request":"x"}"#, #"{"t":"source-input","source":"win:1","lease":"a","event":{"t":"win-keys-release"}}"#] {
            XCTAssertNil(parse("{\"t\":\"source-input\",\"source\":\"win:42\",\"lease\":\"route-a\",\"event\":\(event)}"))
        }
    }

    func testWireStringBoundsUseUTF8Bytes() {
        func decode(_ object: [String: Any]) -> InboundMessage? { parseInbound(try! JSONSerialization.data(withJSONObject: object)) }
        XCTAssertNil(decode(["t": "source-focus", "source": String(repeating: "s", count: 257), "request": "a"]))
        XCTAssertNil(decode(["t": "source-focus", "source": "win:1", "request": String(repeating: "é", count: 33)]))
        XCTAssertNil(decode(["t": "source-input", "source": "win:1", "lease": String(repeating: "a", count: 129), "event": ["t": "win-keys-release"]]))
        XCTAssertNotNil(decode(["t": "source-focus", "source": "win:1", "request": String(repeating: "a", count: 64)]))
    }

    func testWindowlessAndTrustedLocalNativePoliciesCannotUpgradeTheirPresentation() throws {
        let capabilities = try XCTUnwrap(parse(#"{"t":"source-input-capabilities","v":1}"#))
        let focus = try XCTUnwrap(parse(#"{"t":"source-focus","source":"sim:00000000-0000-0000-0000-000000000001","request":"a"}"#))
        let input = try XCTUnwrap(parse(#"{"t":"source-input","source":"sim:00000000-0000-0000-0000-000000000001","lease":"a","event":{"t":"win-keys-release"}}"#))
        for message in [capabilities, focus, input] {
            XCTAssertFalse(WindowlessPolicy.permits(message))
            XCTAssertFalse(NativeSimulatorPolicy.permits(message, focusedSource: "sim:00000000-0000-0000-0000-000000000001"))
        }
    }
}
