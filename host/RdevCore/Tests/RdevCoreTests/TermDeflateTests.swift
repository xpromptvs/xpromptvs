import XCTest
@testable import RdevCore
import RdevTermCorpus

/// One raw-DEFLATE stream per tab, flushed per message: each message decodes as soon as it arrives,
/// later messages compress against earlier ones, and decoding needs THAT tab's context.
final class TermDeflateTests: XCTestCase {
    func testManySmallMessagesRoundTripInOrderEachDecodableOnArrival() throws {
        let d = TermDeflater(), i = TermInflater()
        for n in 0..<500 {
            let msg = Array("line \(n) of the prompt output\r\n".utf8)
            XCTAssertEqual(try i.decompress(d.compress(msg)), msg, "message \(n)")
        }
    }

    func testRepetitionCompresses() {
        let d = TermDeflater()
        let msg = Array(String(repeating: "\u{1b}[38;5;174m─\u{1b}[0m", count: 200).utf8)
        _ = d.compress(msg)
        XCTAssertLessThan(d.compress(msg).count, msg.count / 20, "the second copy is a back-reference")
    }

    func testAnEmptyMessageCostsOnlyTheFlushMarker() {
        XCTAssertLessThanOrEqual(TermDeflater().compress([]).count, 5)
    }

    /// MUTATION PROOF for the per-tab rule: tab B's second message references B's history, so A's
    /// context cannot decode it.
    func testDecodingWithTheWrongTabsContextFails() throws {
        let a = TermDeflater(), b = TermDeflater()
        let ia = TermInflater()
        let shared = Array(String(repeating: "abcdefgh", count: 64).utf8)
        _ = try ia.decompress(a.compress(Array("unrelated".utf8)))
        _ = b.compress(shared)
        let second = b.compress(shared)                                   // mostly a back-reference into B
        let decoded = try? ia.decompress(second)
        XCTAssertNotEqual(decoded, shared, "A's context must not decode B's stream")
    }

    func testCorruptInputThrows() {
        XCTAssertThrowsError(try TermInflater().decompress([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    }
}
