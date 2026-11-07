import XCTest
@testable import RdevCore

final class TermClipboardTests: XCTestCase {
    func testTmuxBufferNotificationSurvivesSplitReadsAndRejectsMalformedNames() {
        var parser = TmuxControlParser()
        XCTAssertEqual(parser.feed(Array("%paste-buffer-chan".utf8)),[])
        XCTAssertEqual(parser.feed(Array("ged buffer-17\n".utf8)),[.pasteBufferChanged(name:"buffer-17")])
        XCTAssertEqual(parser.feed(Array("%paste-buffer-changed \n%paste-buffer-changed bad\u{1b}name\n".utf8)),[])
    }
    func testChunksPreserveUnicodeAndTrailingNewlinesAndCarryTheWireGeneration() throws {
        let bytes = Data((String(repeating:"é🙂",count:3000)+"\n\n").utf8)
        let messages = termClipboardJSON(term:.tmux("$2"),epoch:7,copy:"fixture",bytes:bytes)
        XCTAssertGreaterThan(messages.count,1)
        var decoded = Data()
        for (i,data) in messages.enumerated() {
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            XCTAssertEqual(message["term"] as? String,"tmux:$2")
            XCTAssertEqual(message["epoch"] as? String,"7")
            XCTAssertEqual(message["seq"] as? Int,i)
            XCTAssertLessThan(data.count,16*1024)
            decoded.append(try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(message["data"] as? String))))
        }
        XCTAssertEqual(decoded,bytes)
    }
    func testBinaryOversizeAndNonTmuxPayloadsAreRejected() {
        XCTAssertTrue(termClipboardJSON(term:.tmux("$1"),epoch:1,copy:"fixture",bytes:Data([0xff])).isEmpty)
        XCTAssertTrue(termClipboardJSON(term:.tmux("$1"),epoch:1,copy:"fixture",bytes:Data(repeating:65,count:1_048_577)).isEmpty)
        XCTAssertTrue(termClipboardJSON(term:.pty(1),epoch:1,copy:"fixture",bytes:Data("x".utf8)).isEmpty)
    }
}
