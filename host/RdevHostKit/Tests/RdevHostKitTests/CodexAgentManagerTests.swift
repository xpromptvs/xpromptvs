import XCTest
import RdevCore
import CoreVideo
@testable import RdevHostKit

private final class AgentRPCFixture: CodexRPC {
    var onNotification: ([String:Any])->Void = { _ in }
    var onRequest: ([String:Any])->Void = { _ in }
    var onDisconnect: ()->Void = {}
    var calls: [(String,[String:Any])] = []
    var connectHook: ((@escaping CodexSocket.Reply)->Void)?
    var heldAnswer: CodexSocket.Reply?
    var holdFirstAnswer = false
    var loadedIDs = ["live"]
    var threadMetadata: [String:[String:Any]] = [:]
    var failReads = false
    var holdReads = false
    var latestTurnStatus = "completed"
    var historyFailure = false
    var emptyItemPages = false
    var turnPages: [String:[String:Any]] = [:]
    var extraHistoryItems: [[String:Any]] = []
    func connect(completion: @escaping CodexSocket.Reply) { if let connectHook { connectHook(completion) } else { completion(.success([:])) } }
    func call(method: String, params: [String:Any], authorized: @escaping ()->Bool, completion: @escaping CodexSocket.Reply) {
        guard authorized() else { completion(.failure(CodexError.message("stale"))); return }
        calls.append((method,params))
        switch method {
        case "thread/loaded/list": completion(.success(["data":loadedIDs]))
        case "thread/read":
            if holdReads { return }
            if failReads { completion(.failure(CodexError.message("metadata unavailable"))); return }
            let id=params["threadId"] as? String ?? ""
            completion(.success(["thread":threadMetadata[id] ?? ["id":id,"status":["type":"idle"]]]))
        case "thread/list": completion(.success(["data":[["id":"live","status":["type":"active"]],["id":"saved","status":["type":"notLoaded"]]]]))
        case "thread/resume": completion(.success(["thread":["id":params["threadId"] ?? "live","status":["type":"active"]]]))
        case "thread/items/list":
            if emptyItemPages { completion(.success(["data":[],"nextCursor":NSNull()])); return }
            let items: [[String:Any]] = [["id":"spawn","type":"collabAgentToolCall","receiverThreadIds":["child"]],["id":"activity","type":"subAgentActivity","agentThreadId":"activity-child"]] + extraHistoryItems
            completion(.success(["data":items.reversed().map { ["turnId":"turn","item":$0] },"nextCursor":"older-items"]))
        case "thread/items/read":completion(.success(["data":extraHistoryItems.map{["turnId":params["turnId"] ?? "turn","item":$0]}]))
        case "thread/turns/list":
            if let page = turnPages[params["cursor"] as? String ?? "first"] { completion(.success(page)); return }
            if historyFailure { completion(.failure(CodexError.message("history unavailable"))); return }
            let items: [[String:Any]] = [["id":"spawn","type":"collabAgentToolCall","receiverThreadIds":["child"]],["id":"activity","type":"subAgentActivity","agentThreadId":"activity-child"]] + extraHistoryItems
            completion(.success(["data":[["id":"turn","status":latestTurnStatus,"items":items]]]))
        default: completion(.success([:]))
        }
    }
    func answer(id: Any, result: [String:Any], authorized: @escaping ()->Bool, completion: @escaping CodexSocket.Reply) {
        if authorized() { calls.append(("answer",result)); if holdFirstAnswer && heldAnswer == nil { heldAnswer=completion } else {completion(.success([:]))} }
        else { completion(.failure(CodexError.message("stale"))) }
    }
    func close() {}
}

final class CodexAgentManagerTests: XCTestCase {
    func testUnavailableAgentsReplyToDriverWithoutAnExecutor() throws {
        let pool=TerminalManager(cols:80,rows:24),hub=ChannelHub(terminals:pool,injector:nil,encoder:AgentTestVideo())
        defer { pool.closeAll() }
        let peer=AgentTestPeer("driver"),done=expectation(description:"controlled refusal")
        peer.onMessage = { message in
            if message["t"] as? String == "agent-response" {
                XCTAssertNotNil(message["id"] as? String)
                XCTAssertNotNil(message["error"] as? String)
                done.fulfill()
            }
        }
        hub.register(clientId:peer.clientId,peer:peer,claim:true)
        hub.receive(.agent(try command("hello")),from:peer)
        wait(for:[done],timeout:3)
    }

    func testGoalReadsDoNotTakeOverAndExplicitMutationsCarryUserOrigin() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc);defer{manager.close()}
        manager.restoreKnownTabs(["saved"])
        _=try perform(manager,command("goal",thread:"saved")).get()
        XCTAssertEqual(rpc.calls.last?.0,"thread/goal/get")
        XCTAssertFalse(rpc.calls.contains{$0.0=="thread/resume"})
        XCTAssertThrowsError(try perform(manager,command("goal-set",thread:"saved",args:["objective":"No implicit takeover"])).get())
        _=try perform(manager,command("list")).get();_=try perform(manager,command("join",thread:"live")).get()
        _=try perform(manager,command("goal-set",thread:"live",args:["objective":"Finish the feature","status":"active"])).get()
        XCTAssertEqual(rpc.calls.last?.0,"thread/goal/set");XCTAssertEqual(rpc.calls.last?.1["origin"] as? String,"user")
        XCTAssertEqual(rpc.calls.last?.1["objective"] as? String,"Finish the feature");XCTAssertNil(rpc.calls.last?.1["tokenBudget"])
        _=try perform(manager,command("goal-clear",thread:"live")).get()
        XCTAssertEqual(rpc.calls.last?.0,"thread/goal/clear");XCTAssertEqual(rpc.calls.last?.1["origin"] as? String,"user")
    }
    func testSentImageMetadataReadsTheExactItemAndPixelsReuseItsCache() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc);defer{manager.close()}
        rpc.extraHistoryItems=[["id":"sent","type":"userMessage","content":[["type":"image","url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="]]]]
        manager.restoreKnownTabs(["live"])
        let args:[String:Any]=["item":"sent","path":"input:0","turnId":"turn"]
        let info=try perform(manager,command("asset-info",thread:"live",args:args)).get()
        XCTAssertEqual(info["name"] as? String,"Sent image");XCTAssertEqual((info["blurhash"] as? String)?.count,22)
        let read=try XCTUnwrap(rpc.calls.last);XCTAssertEqual(read.0,"thread/items/read")
        XCTAssertEqual(read.1["threadId"] as? String,"live");XCTAssertEqual(read.1["turnId"] as? String,"turn");XCTAssertEqual(read.1["itemIds"] as? [String],["sent"])
        let count=rpc.calls.count
        XCTAssertNotNil(try perform(manager,command("asset",thread:"live",args:args)).get()["data"])
        XCTAssertEqual(rpc.calls.count,count)
        XCTAssertThrowsError(try perform(manager,command("asset",thread:"live",args:args),authorized:{false}).get())
    }
    func testImageMetadataUsesTheExactHistoryReferenceWithoutExecutorRPCs() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!.write(to:url)
        defer{try? FileManager.default.removeItem(at:url);manager.close()}
        manager.restoreKnownTabs(["live"])
        let args:[String:Any]=["item":"image","path":url.path]
        XCTAssertThrowsError(try perform(manager,command("asset-info",thread:"live",args:args)).get())
        rpc.extraHistoryItems=[["id":"image","type":"imageView","path":url.path]]
        _=try perform(manager,command("history",thread:"live")).get()
        let before=rpc.calls.count
        let info=try perform(manager,command("asset-info",thread:"live",args:args)).get()
        XCTAssertEqual(info["width"] as? Int,1);XCTAssertNil(info["data"])
        XCTAssertEqual(rpc.calls.count,before)
        XCTAssertThrowsError(try perform(manager,command("asset-info",thread:"live",args:args),authorized:{false}).get())
    }
    func testHistoryRetainsOlderEmptyOutcomesWithoutLoadingWholeTurns() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        rpc.emptyItemPages=true
        rpc.turnPages=[
            "first":["data":[["id":"new","status":"completed","items":[]]],"nextCursor":"previous-turn"],
            "previous-turn":["data":[["id":"old","status":"failed","error":["message":"Provider failed"],"items":[]]]]
        ]
        manager.restoreKnownTabs(["live"])
        let first=try perform(manager,command("history",thread:"live")).get()
        let cursor=try XCTUnwrap(first["nextCursor"] as? String)
        let older=try perform(manager,command("history",thread:"live",args:["cursor":cursor])).get()
        let turn=try XCTUnwrap((older["data"] as? [[String:Any]])?.first)
        XCTAssertEqual(turn["id"] as? String,"old")
        XCTAssertEqual(turn["status"] as? String,"failed")
        XCTAssertEqual((turn["error"] as? [String:Any])?["message"] as? String,"Provider failed")
        XCTAssertTrue(older["nextCursor"] is NSNull)
        XCTAssertTrue(rpc.calls.filter {$0.0 == "thread/turns/list"}.allSatisfy {$0.1["itemsView"] as? String == "notLoaded"})
    }
    func testRestoredTabCanReadWithoutSearchAndDoesNotResumeAnExecutor() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        manager.restoreKnownTabs(["live"])
        _=try perform(manager,command("read",thread:"live")).get()
        XCTAssertEqual(rpc.calls.last?.0,"thread/read")
        XCTAssertFalse(rpc.calls.contains {$0.0 == "thread/resume" || $0.0 == "turn/start"})
        XCTAssertThrowsError(try perform(manager,command("send",thread:"live",args:["text":"hi"])).get())
    }
    func testCompactRequiresAttachmentAndIdleStateAndUsesExactThread() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        _ = try perform(manager, command("list")).get()
        XCTAssertThrowsError(try perform(manager, command("compact",thread:"live")).get())
        XCTAssertFalse(rpc.calls.contains { $0.0 == "thread/compact/start" })
        _ = try perform(manager, command("join",thread:"live")).get()
        rpc.threadMetadata["live"] = ["id":"live","status":["type":"active"]]
        XCTAssertThrowsError(try perform(manager, command("compact",thread:"live")).get())
        XCTAssertFalse(rpc.calls.contains { $0.0 == "thread/compact/start" })
        rpc.threadMetadata["live"] = ["id":"live","status":["type":"idle"]]
        _ = try perform(manager, command("compact",thread:"live")).get()
        let call = try XCTUnwrap(rpc.calls.last)
        XCTAssertEqual(call.0,"thread/compact/start")
        XCTAssertEqual(Set(call.1.keys),["threadId"])
        XCTAssertEqual(call.1["threadId"] as? String,"live")
    }
    private func command(_ op: String, thread: String? = nil, args: [String:Any] = [:]) throws -> AgentCommand {
        var object: [String:Any] = ["v":1,"id":UUID().uuidString,"op":op,"args":args]
        if let thread { object["thread"] = thread }
        return try XCTUnwrap(AgentCommand.parse(object))
    }
    private func perform(_ manager: CodexAgentManager, _ command: AgentCommand, authorized: @escaping ()->Bool = {true}) -> Result<[String:Any],Error> {
        let done = expectation(description: command.op)
        var value: Result<[String:Any],Error> = .failure(CodexError.message("no response"))
        manager.handle(command, authorized: authorized) { value = $0; done.fulfill() }
        wait(for:[done],timeout:3)
        return value
    }
    func testSessionBrowserUsesIndexWithoutScanningRolloutsAndPreservesFilters() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        _ = try perform(manager, command("list",args:["cursor":"next-page","searchTerm":"render"])).get()
        let call = try XCTUnwrap(rpc.calls.last)
        XCTAssertEqual(call.0,"thread/list")
        XCTAssertEqual(call.1["useStateDbOnly"] as? Bool,true)
        XCTAssertEqual(call.1["cursor"] as? String,"next-page")
        XCTAssertEqual(call.1["searchTerm"] as? String,"render")
    }

    func testHistoryResponseFiltersEmptyReasoningAtTheHostBoundary() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc: rpc)
        rpc.extraHistoryItems = [["id":"empty","type":"reasoning","summary":[],"content":[]],
                                 ["id":"useful","type":"reasoning","summary":["Keep this explanation"],"content":[]]]
        _ = try perform(manager, command("list")).get()
        let response = try perform(manager, command("history", thread:"live")).get()
        let turn = try XCTUnwrap((response["data"] as? [[String:Any]])?.first)
        let ids = try XCTUnwrap(turn["items"] as? [[String:Any]]).compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["spawn", "activity", "useful"])
        XCTAssertEqual(turn["status"] as? String, "completed")
        let cursor = try XCTUnwrap(response["nextCursor"] as? String)
        let metadata = try XCTUnwrap(rpc.calls.first {$0.0 == "thread/turns/list"})
        XCTAssertEqual(metadata.1["limit"] as? Int,1)
        XCTAssertEqual(metadata.1["itemsView"] as? String,"notLoaded")
        let page = try XCTUnwrap(rpc.calls.last)
        XCTAssertEqual(page.0,"thread/items/list")
        XCTAssertEqual(page.1["limit"] as? Int,50)
        _ = try perform(manager,command("history",thread:"live",args:["cursor":cursor])).get()
        XCTAssertEqual(rpc.calls.last?.1["cursor"] as? String,"older-items")
        XCTAssertEqual(rpc.calls.filter {$0.0 == "thread/turns/list"}.count,1)
    }

    func testRuntimeStatusIsReportedWithoutAVisibleJoinedViewAndClearedOnDisconnect() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc: rpc)
        _ = try perform(manager, command("list")).get()
        let working = expectation(description: "actual runtime status")
        let unknown = expectation(description: "disconnect clears status")
        manager.onStatus = { id, status, flags in
            guard id == "live" else { return }
            if status == "active" { XCTAssertEqual(flags, ["waitingOnApproval"]); working.fulfill() }
            if status == nil { unknown.fulfill() }
        }
        rpc.onNotification(["method":"thread/status/changed", "params":["threadId":"live", "status":["type":"active", "activeFlags":["waitingOnApproval"]]]])
        wait(for: [working], timeout: 2)
        rpc.onDisconnect()
        wait(for: [unknown], timeout: 2)
        XCTAssertFalse(rpc.calls.contains { $0.0 == "thread/resume" })
    }
    func testLiveChildrenExcludeIdleSavedAndUnrelatedThreadsWithoutResuming() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        rpc.loadedIDs = ["live","working","waiting","idle","unrelated"]
        rpc.threadMetadata = [
            "working":["id":"working","parentThreadId":"live","agentNickname":"Ada","status":["type":"active","activeFlags":[]]],
            "waiting":["id":"waiting","parentThreadId":"live","agentNickname":"Grace","status":["type":"active","activeFlags":["waitingOnApproval"]]],
            "idle":["id":"idle","parentThreadId":"live","status":["type":"idle"]],
            "saved-child":["id":"saved-child","parentThreadId":"live","status":["type":"active"]],
            "unrelated":["id":"unrelated","parentThreadId":"other","status":["type":"active"]]
        ]
        _ = try perform(manager, command("list")).get()
        let result = try perform(manager, command("children",thread:"live")).get()
        let rows = try XCTUnwrap(result["data"] as? [[String:Any]])
        XCTAssertEqual(Set(rows.compactMap{$0["id"] as? String}),["working","waiting"])
        _ = try perform(manager, command("read",thread:"working",args:["background":true])).get()
        XCTAssertFalse(rpc.calls.contains{$0.0=="thread/resume" || $0.0=="turn/start"})
        XCTAssertFalse(rpc.calls.contains{$0.0=="thread/read" && $0.1["threadId"] as? String=="saved-child"})
    }
    func testLiveChildDeadlineRepliesEvenWhenMetadataNeverReturns() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        _ = try perform(manager,command("list")).get();rpc.holdReads=true
        let done=expectation(description:"live scan deadline")
        manager.handle(try command("children",thread:"live"),authorized:{true}){result in
            if case .success=result{XCTFail("stalled metadata accepted")}
            done.fulfill()
        }
        wait(for:[done],timeout:18)
    }
    func testLiveChildrenFailClosedWhenMetadataCannotBeReadOrLoadedListExceedsCap() throws {
        for tooMany in [false,true] {
            let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
            if tooMany { rpc.loadedIDs=(0...512).map{"thread-\($0)"} } else { rpc.failReads=true }
            _ = try perform(manager,command("list")).get()
            if case .success = perform(manager,try command("children",thread:"live")){XCTFail("incomplete live snapshot accepted")}
            if tooMany { XCTAssertFalse(rpc.calls.contains{$0.0=="thread/read"}) }
            XCTAssertFalse(rpc.calls.contains{$0.0=="thread/resume"})
        }
    }
    func testUnknownParentCannotEnumerateLiveChildren() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        if case .success = perform(manager,try command("children",thread:"unknown")){XCTFail("unknown parent accepted")}
        XCTAssertTrue(rpc.calls.isEmpty)
    }
    func testJoiningUsesExactLiveThreadAndPreservesConfiguration() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc: rpc)
        _ = try perform(manager, command("list")).get()
        _ = try perform(manager, command("join",thread:"live")).get()
        let call = try XCTUnwrap(rpc.calls.last)
        XCTAssertEqual(call.0,"thread/resume")
        XCTAssertEqual(call.1["threadId"] as? String,"live")
        XCTAssertEqual(Set(call.1.keys),["threadId","excludeTurns"])
    }
    func testUnjoinedThreadAndRevokedDriverCannotExecuteInput() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        if case .success = perform(manager, try command("send",thread:"other",args:["text":"hi"])) { XCTFail("unjoined accepted") }
        if case .success = perform(manager, try command("list"),authorized:{false}) { XCTFail("revoked accepted") }
        XCTAssertFalse(rpc.calls.contains { $0.0 == "turn/start" || $0.0 == "thread/list" })
    }
    func testJoinDoesNotSilentlyResumeASavedSession() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        _ = try perform(manager, command("list")).get()
        if case .success = perform(manager, try command("join",thread:"saved")) { XCTFail("unsafe resume accepted") }
        XCTAssertFalse(rpc.calls.contains { $0.0 == "thread/resume" })
    }
    func testStoppedSavedSessionCanResumeWithoutForking() throws {
        for status in ["completed","interrupted","failed"] {
            let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
            rpc.latestTurnStatus = status
            _ = try perform(manager, command("list")).get()
            let result = try perform(manager, command("resume",thread:"saved")).get()
            XCTAssertEqual((result["thread"] as? [String:Any])?["id"] as? String,"saved")
            XCTAssertEqual(rpc.calls.last?.0,"thread/resume")
            XCTAssertEqual(rpc.calls.last?.1["threadId"] as? String,"saved")
        }
    }
    func testSavedSessionUsesItsLatestTurnInsteadOfUnrelatedHostProcesses() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        _ = try perform(manager, command("list")).get()
        _ = try perform(manager, command("resume",thread:"saved")).get()
        XCTAssertEqual(rpc.calls.last?.0,"thread/resume")
        XCTAssertTrue(rpc.calls.contains { $0.0 == "thread/turns/list" && $0.1["threadId"] as? String == "saved" && $0.1["limit"] as? Int == 1 })
    }
    func testSavedSessionWithAnUnfinishedOrUnknownTurnIsRefused() throws {
        for status in ["inProgress","futureStatus",""] {
            let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
            rpc.latestTurnStatus = status
            _ = try perform(manager, command("list")).get()
            if case .success = perform(manager, try command("resume",thread:"saved")) { XCTFail("unfinished/unknown saved session accepted: \(status)") }
            XCTAssertFalse(rpc.calls.contains { $0.0 == "thread/resume" })
        }
    }
    func testSavedSessionDoesNotResumeWhenHistoryCannotBeChecked() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        rpc.historyFailure = true
        _ = try perform(manager, command("list")).get()
        if case .success = perform(manager, try command("resume",thread:"saved")) { XCTFail("unknown execution state accepted") }
        XCTAssertFalse(rpc.calls.contains { $0.0 == "thread/resume" })
    }
    func testBackgroundAgentMetadataReadDoesNotChangeSelectedSession() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        _ = try perform(manager, command("list")).get()
        _ = try perform(manager, command("read",thread:"saved")).get()
        _ = try perform(manager, command("read",thread:"live",args:["background":true])).get()
        let hello = try perform(manager, command("hello")).get()
        XCTAssertEqual(hello["selected"] as? String,"saved")
        XCTAssertFalse(rpc.calls.contains { $0.0 == "thread/resume" })
    }
    func testPermissionAnswersCannotGrantMoreThanRequested() {
        XCTAssertFalse(CodexAgentManager.validAnswer(method:"item/permissions/requestApproval",params:["permissions":["network":["enabled":false]]],result:["permissions":["network":["enabled":true]],"scope":"session"]))
        XCTAssertTrue(CodexAgentManager.validAnswer(method:"item/permissions/requestApproval",params:["permissions":["network":["enabled":true]]],result:["permissions":[:],"scope":"turn"]))
    }
    func testMixedApprovalChoicesNeverBroadenTheOfferedPermissions() {
        let rule:[String:Any] = ["acceptWithExecpolicyAmendment":["execpolicy_amendment":["echo"]]]
        let params:[String:Any] = ["availableDecisions":[rule,"decline"]]
        XCTAssertFalse(CodexAgentManager.validAnswer(method:"item/commandExecution/requestApproval",params:params,result:["decision":"accept"]))
        XCTAssertTrue(CodexAgentManager.validAnswer(method:"item/commandExecution/requestApproval",params:params,result:["decision":rule]))
        XCTAssertFalse(CodexAgentManager.validAnswer(method:"item/commandExecution/requestApproval",params:params,result:["decision":["acceptWithExecpolicyAmendment":["execpolicy_amendment":["rm"]]]]))
    }
    func testUnknownOrAlreadyResolvedRequestCannotBeAnswered() throws {
        let rpc = AgentRPCFixture(), manager = CodexAgentManager(rpc:rpc)
        _ = try perform(manager, command("list")).get()
        _ = try perform(manager, command("join",thread:"live")).get()
        let request: [String:Any] = ["id":77,"method":"item/commandExecution/requestApproval","params":["threadId":"live","turnId":"turn","itemId":"item"]]
        rpc.onRequest(request)
        rpc.onNotification(["method":"serverRequest/resolved","params":["threadId":"live","requestId":77]])
        let answer = try command("answer",thread:"live",args:["request":"77","result":["decision":"accept"]])
        if case .success = perform(manager, answer) { XCTFail("resolved request accepted") }
        XCTAssertFalse(rpc.calls.contains { $0.0 == "answer" })
    }
    func testHubDropsAQueuedRequestWhenTheDriverChanges() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        let waiting=expectation(description:"connect held"),pool=TerminalManager(cols:80,rows:24)
        let hub=ChannelHub(terminals:pool,injector:nil,encoder:AgentTestVideo());hub.installAgents(manager)
        let first=AgentTestPeer("first"),second=AgentTestPeer("second")
        var resume: CodexSocket.Reply?
        rpc.connectHook={completion in resume=completion;waiting.fulfill()}
        hub.register(clientId:first.clientId,peer:first,claim:true)
        hub.receive(.agent(try command("hello")),from:first)
        wait(for:[waiting],timeout:3)
        hub.register(clientId:second.clientId,peer:second,claim:true)
        resume?(.success([:]))
        _=perform(manager,try command("hello"),authorized:{false})
        XCTAssertFalse(first.messages.contains{$0["t"] as? String=="agent-response"})
        XCTAssertTrue(rpc.calls.isEmpty)
        manager.close();pool.closeAll()
    }
    func testAnApprovalCannotBeAnsweredTwiceWhileDeliveryIsPending() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        _=try perform(manager,command("list")).get();_=try perform(manager,command("join",thread:"live")).get()
        rpc.onRequest(["id":77,"method":"item/commandExecution/requestApproval","params":["threadId":"live","turnId":"turn","itemId":"item"]])
        rpc.holdFirstAnswer=true
        let answer=try command("answer",thread:"live",args:["request":"77","result":["decision":"accept"]])
        let first=expectation(description:"first answer completes")
        manager.handle(answer,authorized:{true}){_ in first.fulfill()}
        _=perform(manager,try command("hello"),authorized:{false})
        if case .success=perform(manager,answer){XCTFail("duplicate approval was sent")}
        rpc.heldAnswer?(.success([:]));wait(for:[first],timeout:3)
        XCTAssertEqual(rpc.calls.filter{$0.0=="answer"}.count,1)
    }
    func testHubRefusesPassiveAndWrongEpochAgentRequests() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        let pool=TerminalManager(cols:80,rows:24),hub=ChannelHub(terminals:pool,injector:nil,encoder:AgentTestVideo())
        hub.installAgents(manager)
        let first=AgentTestPeer("driver"),second=AgentTestPeer("passive")
        hub.register(clientId:first.clientId,peer:first,claim:true);hub.register(clientId:second.clientId,peer:second,claim:false)
        hub.receive(.agent(try command("hello")),from:second)
        hub.receive(.agent(try command("list")),from:first) // Missing negotiated epoch must be refused.
        _=perform(manager,try command("hello"),authorized:{false})
        XCTAssertTrue(rpc.calls.isEmpty);XCTAssertFalse(second.messages.contains{$0["t"] as? String=="agent-response"})
        manager.close();pool.closeAll()
    }
    func testHistoricalSubagentReferencesCanBeReadWithoutAnUnrelatedRootListing() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        _=try perform(manager,command("list")).get();_=try perform(manager,command("history",thread:"live")).get()
        _=try perform(manager,command("read",thread:"child")).get()
        _=try perform(manager,command("read",thread:"activity-child")).get()
        XCTAssertEqual(rpc.calls.filter{$0.0=="thread/read"}.compactMap{$0.1["threadId"] as? String},["child","activity-child"])
    }
    func testRuntimeSettingsFromAnotherCodexClientAreKeptForReconnect() throws {
        let rpc=AgentRPCFixture(),manager=CodexAgentManager(rpc:rpc)
        _=try perform(manager,command("list")).get();_=try perform(manager,command("join",thread:"live")).get()
        let runtime:[String:Any] = ["disabledPluginIds":[],"cwd":"/live","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":["type":"readOnly"],"activePermissionProfile":NSNull(),"model":"new-model","modelProvider":"openai","serviceTier":NSNull(),"effort":"high","summary":NSNull(),"collaborationMode":["mode":"plan","settings":["model":"new-model","reasoning_effort":"high","developer_instructions":NSNull()]],"multiAgentMode":"explicitRequestOnly","personality":NSNull()]
        rpc.onNotification(["method":"thread/settings/updated","params":["threadId":"live","threadSettings":runtime]])
        let hello=try perform(manager,command("hello")).get()
        let settings=try XCTUnwrap((hello["settings"] as? [String:[String:Any]])?["live"])
        XCTAssertEqual(settings["model"] as? String,"new-model");XCTAssertEqual(settings["reasoningEffort"] as? String,"high")
    }
}

private final class AgentTestPeer: ClientConnection {
    let clientId:String;init(_ id:String){clientId=id}
    var mediaPeer:PionPeer?{nil};var presentation:ClientPresentation{.nativeSimulators}
    private let lock=NSLock();private var received:[[String:Any]]=[]
    var messages:[[String:Any]]{lock.withLock{received}}
    var onMessage:(([String:Any])->Void)?
    func send(_ channel:PionChannel,_ data:Data){guard let bytes=unwrapMessage(data),let message=try? JSONSerialization.jsonObject(with:bytes)as?[String:Any]else{return};lock.withLock{received.append(message)};onMessage?(message)}
}
private final class AgentTestVideo: VideoEncoding, @unchecked Sendable {
    var codec:NegotiatedCodec{.av1}
    func encode(_ pixelBuffer:CVPixelBuffer,ptsNs:Int64){};func addSink(_ sink:any VideoTrackSink){};func removeSink(_ sink:any VideoTrackSink){};func removeAllSinks(){}
    func requestKeyframe(){};func setFps(_ v:Int){};func setBitrate(_ v:Int){};func setCrop(_ v:CropRect){};func invalidate(){}
}
