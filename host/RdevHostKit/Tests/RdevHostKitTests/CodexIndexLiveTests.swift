import XCTest
import RdevCore
@testable import RdevHostKit

/// Opt-in, read-only qualification against the host's existing Codex index. Never resumes a thread.
final class CodexIndexLiveTests: XCTestCase {
    func testExistingDaemonReturnsIndexedSessionsThroughNativeManager() throws {
        guard ProcessInfo.processInfo.environment["RDEV_CODEX_INDEX_CHECK"] == "1" else {
            throw XCTSkip("Set RDEV_CODEX_INDEX_CHECK=1 to read the existing host Codex index")
        }
        let manager = CodexAgentManager()
        defer { manager.close() }
        let command = try XCTUnwrap(AgentCommand.parse(["v":1,"id":"index-check","op":"list","args":[:]]))
        let done = expectation(description:"indexed sessions")
        manager.handle(command,authorized:{true}) { result in
            switch result {
            case .success(let value):
                let rows = value["data"] as? [[String:Any]]
                XCTAssertNotNil(rows)
                XCTAssertFalse(rows?.isEmpty ?? true,"Qualification expects an existing host with saved sessions")
            case .failure(let error): XCTFail("Indexed native listing failed: \(error.localizedDescription)")
            }
            done.fulfill()
        }
        wait(for:[done],timeout:15)
    }
    func testExistingDaemonLiveChildrenAreActiveAndBelongToKnownParent() throws {
        guard ProcessInfo.processInfo.environment["RDEV_CODEX_INDEX_CHECK"] == "1" else { throw XCTSkip("Read-only host qualification is opt-in") }
        let manager=CodexAgentManager();defer{manager.close()}
        let done=expectation(description:"live child runtime snapshot")
        let list=try XCTUnwrap(AgentCommand.parse(["v":1,"id":"list-live-parents","op":"list"]))
        manager.handle(list,authorized:{true}){result in
            guard case .success(let value)=result,let rows=value["data"]as?[[String:Any]],let parent=rows.first?["id"]as?String else {XCTFail("No populated parent index");done.fulfill();return}
            guard let command=AgentCommand.parse(["v":1,"id":"live-child-check","op":"children","thread":parent])else{XCTFail("Scoped child command rejected");done.fulfill();return}
            manager.handle(command,authorized:{true}){result in
                switch result {
                case .success(let value):
                    guard let children=value["data"]as?[[String:Any]]else{XCTFail("Invalid child snapshot");done.fulfill();return}
                    for child in children {XCTAssertEqual(child["parentThreadId"]as?String,parent);XCTAssertEqual((child["status"]as?[String:Any])?["type"]as?String,"active")}
                    print("Qualified native live child snapshot: \(children.count) active children")
                case .failure(let error):XCTFail(error.localizedDescription)
                }
                done.fulfill()
            }
        }
        wait(for:[done],timeout:20)
    }

}
