import XCTest
import RdevCore
@testable import RdevHostKit
final class ClaudeAgentManagerTests:XCTestCase {
    func testAttachmentUploadDoesNotStartHelperAndSendResolvesOnlyOwnThreadFiles() throws {
        guard let node=["/opt/homebrew/bin/node","/usr/local/bin/node"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else{throw XCTSkip("Node is optional on build hosts")}
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let script=dir.appendingPathComponent("upload.mjs"),log=dir.appendingPathComponent("request.json")
        let path=String(data:try JSONSerialization.data(withJSONObject:log.path,options:.fragmentsAllowed),encoding:.utf8)!
        try """
        import readline from 'node:readline';import fs from 'node:fs';
        for await(const line of readline.createInterface({input:process.stdin})){const m=JSON.parse(line);fs.writeFileSync(\(path),JSON.stringify(m));process.stdout.write(JSON.stringify({id:m.id,result:{}})+'\\n');}
        """.write(to:script,atomically:true,encoding:.utf8)
        let manager=ClaudeAgentManager(helper:script.path,node:node,cli:"/bin/false");defer{manager.close()}
        manager.restoreKnownTabs(["claude:one","claude:two"])
        func perform(_ op:String,_ thread:String,_ args:[String:Any]) throws -> Result<[String:Any],Error> {
            let done=expectation(description:op);var result:Result<[String:Any],Error> = .failure(CodexError.message("No reply"))
            let command=try XCTUnwrap(AgentCommand.parse(["v":1,"id":UUID().uuidString,"op":op,"thread":thread,"args":args]))
            manager.handle(command,authorized:{true}){result=$0;done.fulfill()};wait(for:[done],timeout:5);return result
        }
        let id=UUID().uuidString
        _=try perform("upload","claude:one",["upload":id,"name":"notes.txt","seq":0,"data":Data("notes".utf8).base64EncodedString(),"last":true]).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath:log.path))
        XCTAssertThrowsError(try perform("send","claude:two",["text":"wrong thread","attachments":[id]]).get())
        _=try perform("send","claude:one",["text":"read","attachments":[id]]).get()
        let row=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:log)) as? [String:Any])
        XCTAssertEqual(row["op"] as? String,"send")
        let input=try XCTUnwrap(((row["args"] as? [String:Any])?["attachments"] as? [[String:Any]])?.first)
        XCTAssertEqual(input["type"] as? String,"mention")
        let file=try XCTUnwrap(input["path"] as? String);XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:file)),Data("notes".utf8))
        // The fixture never runs an executor; remove its marked-used file explicitly.
        try FileManager.default.removeItem(atPath:file)
    }
    func testSentImageUsesReadOnlyRecordAndCachesPixelsWithoutAnExecutor() throws {
        guard let node=["/opt/homebrew/bin/node","/usr/local/bin/node"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else{throw XCTSkip("Node is optional on build hosts")}
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let script=dir.appendingPathComponent("images.mjs"),log=dir.appendingPathComponent("ops.json")
        let fixture="""
        import readline from 'node:readline';import fs from 'node:fs';
        for await(const line of readline.createInterface({input:process.stdin})){
         const m=JSON.parse(line);fs.appendFileSync(\(String(data:try JSONSerialization.data(withJSONObject:log.path,options:.fragmentsAllowed),encoding:.utf8)!),m.op+'\\n');
         const result={data:[{uuid:'sent',type:'user',message:{content:[{type:'image',source:{type:'base64',media_type:'image/png',data:'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='}}]}}]};
         process.stdout.write(JSON.stringify({id:m.id,result})+'\\n');
        }
        """
        try fixture.write(to:script,atomically:true,encoding:.utf8)
        let manager=ClaudeAgentManager(helper:script.path,node:node,cli:"/bin/false");defer{manager.close()}
        manager.restoreKnownTabs(["claude:test"])
        func perform(_ op:String) throws -> [String:Any] {
            let done=expectation(description:op);var result:Result<[String:Any],Error> = .failure(CodexError.message("No response"))
            let command=try XCTUnwrap(AgentCommand.parse(["v":1,"id":UUID().uuidString,"op":op,"thread":"claude:test","args":["item":"sent","path":"input:0","turnId":"turn"]]))
            manager.handle(command,authorized:{true}){result=$0;done.fulfill()};wait(for:[done],timeout:5);return try result.get()
        }
        XCTAssertEqual(try perform("asset-info")["name"] as? String,"Sent image")
        XCTAssertNotNil(try perform("asset")["data"])
        XCTAssertEqual(try String(contentsOf:log,encoding:.utf8),"record\n")
    }
    func testHelperClosingStdinFailsRequestWithoutKillingHost() throws {
        guard let node=["/opt/homebrew/bin/node","/usr/local/bin/node"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else{throw XCTSkip("Node is optional on build hosts")}
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("claude-pipe-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let script=dir.appendingPathComponent("closed.mjs");try "import fs from 'node:fs';fs.closeSync(0);setTimeout(()=>process.exit(0),100);".write(to:script,atomically:true,encoding:.utf8)
        let manager=ClaudeAgentManager(helper:script.path,node:node,cli:"/bin/false");defer{manager.close()}
        let command=try XCTUnwrap(AgentCommand.parse(["v":1,"id":"closed-input","op":"new-thread","args":["provider":"claude","cwd":"/"+String(repeating:"x",count:128*1024)]]))
        let failed=expectation(description:"closed helper input reports failure")
        manager.handle(command,authorized:{true}){result in if case .success=result{XCTFail("closed helper cannot answer")};failed.fulfill()}
        wait(for:[failed],timeout:5)
    }
}
