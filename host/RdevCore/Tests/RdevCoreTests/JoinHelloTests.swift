import XCTest
@testable import RdevCore
import RdevTermCorpus

/// WHAT A CLIENT SAYS AS IT JOINS, AND THE SCREEN ITS OFFER CARRIES (docs/sources-and-focus.md, "The offer carries the
/// tab bar", "The join intent"): the app_hello of its `client-confirm` names its join intent and its terminal grid, the
/// grid read as its `resize` would be — and anything else is no grid and no intent, never a refusal; the offer's
/// `term-screen` decodes back to the emitter's bytes.
final class JoinHelloTests: XCTestCase {
    func testFastDataNegotiationIsExplicitAndVersioned() {
        XCTAssertEqual(JoinHello.parse(Array(#"{"intent":"connect","fastData":1}"#.utf8)).fastData, 1)
        for json in [#"{"fastData":true}"#, #"{"fastData":2}"#, #"{}"#] {
            XCTAssertNil(JoinHello.parse(Array(json.utf8)).fastData)
        }
        let hello = JoinHello(grid: .init(cols: 80, rows: 24), intent: .connect, fastData: 1)
        XCTAssertEqual(JoinHello.parse(hello.encoded()), hello)
    }

    private func parse(_ s: String) -> TermGridSize? { JoinHello.parse(Array(s.utf8)).grid }

    func testAGridIsRead() {
        XCTAssertEqual(parse(#"{"grid":{"cols":120,"rows":40}}"#), TermGridSize(cols: 120, rows: 40))
        XCTAssertEqual(parse(#"{"grid":{"rows":1,"cols":500},"later":true}"#), TermGridSize(cols: 500, rows: 1),
                       "the bounds `resize` takes, and a field this build does not know is ignored")
    }

    func testAnythingElseIsNoGrid() {
        for s in ["", "not json", "[]", "{}", #"{"grid":null}"#, #"{"grid":{"cols":120}}"#,
                  #"{"grid":{"cols":0,"rows":40}}"#, #"{"grid":{"cols":120,"rows":501}}"#,
                  #"{"grid":{"cols":120.5,"rows":40}}"#, #"{"grid":{"cols":true,"rows":40}}"#,
                  #"{"grid":{"cols":"120","rows":40}}"#, #"{"grid":{"cols":-3,"rows":40}}"#] {
            XCTAssertNil(parse(s), s)
        }
    }

    /// THE JOIN INTENT, said inside the session (docs/sources-and-focus.md, "The join intent"): `connect` or
    /// `reconnect`; anything else is none, and none claims nothing — the grid beside it read on its own.
    func testTheJoinIntentIsRead() {
        func intent(_ s: String) -> JoinIntent? { JoinHello.parse(Array(s.utf8)).intent }
        XCTAssertEqual(intent(#"{"intent":"connect","grid":{"cols":120,"rows":40}}"#), .connect)
        XCTAssertEqual(intent(#"{"intent":"reconnect"}"#), .reconnect)
        for s in [#"{"intent":"steal"}"#, #"{"intent":true}"#, #"{"grid":{"cols":120,"rows":40}}"#, "", "[]"] {
            XCTAssertNil(intent(s), s)
        }
        XCTAssertEqual(JoinHello.parse(Array(#"{"intent":"connect","grid":{"cols":0,"rows":40}}"#.utf8)),
                       JoinHello(grid: nil, intent: .connect), "a bad grid costs the intent nothing")
    }

    func testWhatAClientWritesIsWhatTheHostReads() {
        for hello in [JoinHello(grid: TermGridSize(cols: 98, rows: 31), intent: .connect),
                      JoinHello(grid: nil, intent: .reconnect), JoinHello(grid: TermGridSize(cols: 5, rows: 2))] {
            XCTAssertEqual(JoinHello.parse(hello.encoded()), hello)
            XCTAssertLessThanOrEqual(hello.encoded().count, E2EWire.appHelloMax)
        }
        XCTAssertEqual(JoinHello().encoded(), [], "nothing to say, no bytes")
    }

    func testTheOffersScreenDecodesBackToTheEmittersBytes() throws {
        let bytes = Array("\u{1b}[?1049l\u{1b}[H\u{1b}[2Jhello, \u{1b}[32mworld\u{1b}[0m".utf8)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: termScreenJSON(id: .pty(3), size: TermGridSize(cols: 120, rows: 40), bytes: bytes)) as? [String: Any])
        XCTAssertEqual(obj["t"] as? String, "term-screen")
        XCTAssertEqual(obj["id"] as? String, "pty:3")
        XCTAssertEqual(obj["cols"] as? Int, 120)
        XCTAssertEqual(obj["rows"] as? Int, 40)
        let packed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(obj["data"] as? String)))
        XCTAssertEqual(try TermInflater().decompress(Array(packed)), bytes, "one raw-DEFLATE stream, as the terminal channel's")
    }
}
