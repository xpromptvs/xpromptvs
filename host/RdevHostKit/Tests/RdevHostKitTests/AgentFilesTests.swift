import XCTest
@testable import RdevHostKit

final class AgentFilesTests: XCTestCase {
    func testSentImageCacheEvictsOldFilesAndTheirReadGrants() throws {
        let files=AgentFiles();defer{files.close()};var first=""
        for i in 0..<65 {
            let item="sent-\(i)"
            let response:[String:Any]=["data":[["turnId":"turn","item":["id":item,"type":"userMessage","content":[["type":"image","url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="]]]]]]
            let path=try files.prepareInline(thread:"t",turn:"turn",item:item,index:0,response:response);if i==0{first=path}
        }
        XCTAssertNil(files.inlinePath(thread:"t",turn:"turn",item:"sent-0",index:0))
        XCTAssertFalse(FileManager.default.fileExists(atPath:first))
        XCTAssertThrowsError(try files.asset(thread:"t",item:"sent-0",path:first))
        XCTAssertNotNil(files.inlinePath(thread:"t",turn:"turn",item:"sent-64",index:0))
    }
    func testClaudeSentImageReadsTheExactUserMessageAndNeverFetchesURLs() throws {
        let files=AgentFiles();defer{files.close()}
        let input:[String:Any]=["type":"image","source":["type":"base64","media_type":"image/png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="]]
        let response:[String:Any]=["data":[["uuid":"sent","type":"user","message":["content":[input]]]]]
        XCTAssertThrowsError(try files.prepareClaudeInline(thread:"claude:t",turn:"turn",item:"other",index:0,response:response))
        let path=try files.prepareClaudeInline(thread:"claude:t",turn:"turn",item:"sent",index:0,response:response)
        XCTAssertEqual(try files.info(thread:"claude:t",item:"sent",path:path)["width"] as? Int,1)
        let external:[String:Any]=["data":[["uuid":"external","type":"user","message":["content":[["type":"image","source":["type":"url","url":"https://example.com/image.png"]]]]]]]
        XCTAssertThrowsError(try files.prepareClaudeInline(thread:"claude:t",turn:"turn",item:"external",index:0,response:external))
    }
    func testSentImageCacheRequiresTheExactReturnedTurnItemAndInput() throws {
        let files=AgentFiles();defer{files.close()}
        let png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        let response:[String:Any]=["data":[["turnId":"turn","item":["id":"sent","type":"userMessage","content":[["type":"image","url":"data:image/png;base64,"+png]]]]]]
        XCTAssertThrowsError(try files.prepareInline(thread:"t",turn:"other",item:"sent",index:0,response:response))
        XCTAssertThrowsError(try files.prepareInline(thread:"t",turn:"turn",item:"other",index:0,response:response))
        XCTAssertThrowsError(try files.prepareInline(thread:"t",turn:"turn",item:"sent",index:1,response:response))
        let path=try files.prepareInline(thread:"t",turn:"turn",item:"sent",index:0,response:response)
        XCTAssertEqual(files.inlinePath(thread:"t",turn:"turn",item:"sent",index:0),path)
        XCTAssertNil(files.inlinePath(thread:"other",turn:"turn",item:"sent",index:0))
        XCTAssertEqual(try files.info(thread:"t",item:"sent",path:path)["width"] as? Int,1)
    }
    func testImageInfoReadsDimensionsWithoutSendingPixelsAndRequiresTheReportedPath() throws {
        let files=AgentFiles();defer{files.close()}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        try png.write(to:url);defer{try? FileManager.default.removeItem(at:url)}
        XCTAssertThrowsError(try files.info(thread:"t",item:"image",path:url.path))
        files.remember(["id":"image","type":"imageView","path":url.path],thread:"t")
        XCTAssertThrowsError(try files.info(thread:"other",item:"image",path:url.path))
        let info=try files.info(thread:"t",item:"image",path:url.path)
        XCTAssertEqual(info["width"] as? Int,1);XCTAssertEqual(info["height"] as? Int,1)
        XCTAssertEqual(info["mime"] as? String,"image/png");XCTAssertNil(info["data"])
        XCTAssertEqual((info["blurhash"] as? String)?.count,22)
        let handle=try FileHandle(forWritingTo:url);try handle.truncate(atOffset:32*1024*1024+1);try handle.close()
        XCTAssertThrowsError(try files.info(thread:"t",item:"image",path:url.path))
        try Data("not an image".utf8).write(to:url)
        XCTAssertThrowsError(try files.info(thread:"t",item:"image",path:url.path))
        try FileManager.default.removeItem(at:url)
        XCTAssertThrowsError(try files.info(thread:"t",item:"image",path:url.path))
    }
    func testAttachmentChunksAreExactAndBoundToTheirThread() throws {
        let files = AgentFiles(); defer { files.close() }
        let id = UUID().uuidString
        _ = try files.upload(thread:"t",args:["upload":id,"seq":0,"name":"../é.txt","data":Data("hello é\n".utf8).base64EncodedString(),"last":true])
        XCTAssertThrowsError(try files.inputs(thread:"other",ids:[id]))
        let input = try XCTUnwrap(try files.inputs(thread:"t",ids:[id]).first)
        let path = try XCTUnwrap(input["path"] as? String)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),Data("hello é\n".utf8))
        XCTAssertThrowsError(try files.upload(thread:"t",args:["upload":id,"seq":0,"name":"x","data":"", "last":true]))
    }
    func testHostAssetReadsRequireAnActualImageItemPath() throws {
        let files = AgentFiles(); defer { files.close() }
        XCTAssertThrowsError(try files.asset(thread:"t",item:"invented",path:"/etc/passwd"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        try Data([1,2,3]).write(to:url); defer {try? FileManager.default.removeItem(at:url)}
        files.remember(["data":[["id":"turn","items":[["id":"image","type":"imageView","path":url.path]]]]],thread:"t")
        XCTAssertThrowsError(try files.asset(thread:"other",item:"image",path:url.path))
        let asset = try files.asset(thread:"t",item:"image",path:url.path)
        XCTAssertEqual(asset["data"] as? String,"AQID")
    }
    func testFilesReferencedByAgentInputSurviveHostClientClose() throws {
        let files=AgentFiles();defer{files.close()};let id=UUID().uuidString
        _=try files.upload(thread:"t",args:["upload":id,"seq":0,"name":"note.txt","data":Data("keep".utf8).base64EncodedString(),"last":true])
        let path=try XCTUnwrap(try files.inputs(thread:"t",ids:[id]).first?["path"] as? String)
        files.close(preserveUsed:true)
        files.close(preserveUsed:true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
    }
}
