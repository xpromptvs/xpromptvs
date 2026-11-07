import XCTest
@testable import RdevHostKit

final class AgentTranscriptTests: XCTestCase {
    func testSentImagePixelsBecomeScopedReferencesBeforePreviewTruncation() throws {
        let item:[String:Any]=["id":"sent","type":"userMessage","content":[["type":"text","text":"Look"],["type":"image","url":"data:image/png;base64,"+String(repeating:"A",count:100_000)]]]
        let preview=AgentTranscript.preview(item),content=try XCTUnwrap(preview["content"] as? [[String:Any]])
        XCTAssertEqual(content[1]["_assetPath"] as? String,"input:1");XCTAssertNil(content[1]["url"])
        XCTAssertNil(preview["_truncated"]);XCTAssertLessThan(try JSONSerialization.data(withJSONObject:preview).count,1024)
    }
    func testItemPagesKeepCursorChronologyAndBoundLargeRecords() throws {
        let huge = String(repeating: "🦊", count: 100_000)
        let page: [String:Any] = ["data":[
            ["turnId":"t", "item":["id":"b","type":"commandExecution","aggregatedOutput":huge]],
            ["turnId":"t", "startedAtMs":123,"item":["id":"a","type":"agentMessage","text":"first"]]
        ],"nextCursor":"older"]
        let result = AgentTranscript.historyPage(page, latest:["id":"t","status":"inProgress"])
        let turn = try XCTUnwrap((result["data"] as? [[String:Any]])?.first)
        let items = try XCTUnwrap(turn["items"] as? [[String:Any]])
        XCTAssertEqual(items.compactMap {$0["id"] as? String},["a","b"])
        XCTAssertEqual(items[0]["startedAtMs"] as? Int,123)
        XCTAssertEqual(turn["status"] as? String,"inProgress")
        XCTAssertEqual(result["nextCursor"] as? String,"older")
        XCTAssertEqual(items[1]["_truncated"] as? Bool,true)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject:result).count,65_536)
    }
    func testLargeLiveSnapshotsAreBoundedButFullRecordRetrievalIsUntouched() throws {
        let item: [String:Any] = ["id":"large","type":"commandExecution","status":"completed","aggregatedOutput":String(repeating:"output",count:100_000)]
        let event: [String:Any] = ["method":"item/completed","params":["threadId":"thread","turnId":"turn","item":item]]
        let preview = AgentTranscript.livePreview(event)
        let params = try XCTUnwrap(preview["params"] as? [String:Any])
        XCTAssertEqual((params["item"] as? [String:Any])?["_truncated"] as? Bool,true)
        XCTAssertEqual(params["threadId"] as? String,"thread")
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject:preview).count,32_768)
        XCTAssertEqual(AgentTranscript.filter(["data":[item]],operation:"record")["data"] as? NSArray,[item] as NSArray)
    }
    func testOnlyEmptyUnexpandableReasoningIsRemoved() {
        for item: [String:Any] in [
            ["id":"r","type":"reasoning","summary":[],"content":[]],
            ["id":"r","type":"reasoning","summary":[" \n"],"content":[],"text":"\t"],
            ["id":"r","type":"reasoning","status":"completed","summary":[],"content":[]],
            ["id":"r","type":"reasoning","summary":[],"content":[],"startedAtMs":1793722173939,"completedAtMs":1793722173939]
        ] { XCTAssertTrue(AgentTranscript.isEmptyReasoning(item)) }
        for item: [String:Any] in [
            ["id":"r","type":"reasoning","summary":["Visible summary"],"content":[]],
            ["id":"r","type":"reasoning","summary":[],"content":["Visible detail"]],
            ["id":"r","type":"reasoning","text":"Live delta"],
            ["id":"r","type":"reasoning","summary":[],"_truncated":true],
            ["id":"r","type":"reasoning","summary":[],"contentCount":2],
            ["id":"r","type":"reasoning","futureContent":["Preserve new fields"]],
            ["id":"m","type":"agentMessage","text":""]
        ] { XCTAssertFalse(AgentTranscript.isEmptyReasoning(item)) }
    }
    func testHistoryKeepsTurnMetadataAndCursorsAndItemListKeepsEntryMetadata() {
        let empty:[String:Any] = ["id":"empty","type":"reasoning","summary":[],"content":[]]
        let full:[String:Any] = ["id":"full","type":"reasoning","summary":["Why"],"content":[]]
        let response:[String:Any] = ["data":[["id":"t","status":"completed","durationMs":32,"items":[empty,full]]],"nextCursor":"next","backwardsCursor":"back"]
        let filtered=AgentTranscript.filter(response,operation:"history")
        let turn=(filtered["data"] as! [[String:Any]])[0]
        XCTAssertEqual(turn["id"] as? String,"t");XCTAssertEqual(turn["status"] as? String,"completed")
        XCTAssertEqual(turn["durationMs"] as? Int,32);XCTAssertEqual((turn["items"] as! [[String:Any]]).compactMap{$0["id"] as? String},["full"])
        XCTAssertEqual(filtered["nextCursor"] as? String,"next");XCTAssertEqual(filtered["backwardsCursor"] as? String,"back")
        let entries=AgentTranscript.filter(["data":[["turnId":"t","startedAtMs":123,"item":empty],["turnId":"t","startedAtMs":456,"item":full]],"nextCursor":"next"],operation:"items")
        let kept=entries["data"] as! [[String:Any]]
        XCTAssertEqual(kept.count,1);XCTAssertEqual(kept[0]["startedAtMs"] as? Int,456)
        XCTAssertEqual(AgentTranscript.filter(response,operation:"record")["data"] as? NSArray,response["data"] as? NSArray)
    }
}
