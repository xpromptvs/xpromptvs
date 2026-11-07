import XCTest
import RdevCore
@testable import RdevHostKit
private final class ProviderStub:AgentManager {
    var onEvent:([String:Any])->Void={_ in};var onStatus:(String,String?,[String])->Void={_,_,_ in}
    var ids:[String]=[],ops:[String]=[];var response:[String:Any]=[:];var fail=false
    func restoreKnownTabs(_ ids:[String]){self.ids=ids}
    func close(){}
    func handle(_ c:AgentCommand,authorized:@escaping()->Bool,reply:@escaping CodexSocket.Reply){ops.append(c.op);reply(fail ? .failure(CodexError.message("unavailable")):.success(response))}
}
final class AgentProvidersTests:XCTestCase {
    func testDisabledProvidersNeverConstructExecutors() {
        var created = 0
        let p = AgentProviders.make(enabled: false, codex: { created += 1; return ProviderStub() }, claude: { created += 1; return ProviderStub() })
        XCTAssertNil(p)
        XCTAssertEqual(created, 0)
    }

    private func command(_ op:String,_ thread:String?=nil,_ args:[String:Any]=[:])->AgentCommand {
        var row:[String:Any]=["v":1,"id":"test","op":op,"args":args];row["thread"]=thread
        return AgentCommand.parse(row)!
    }
    func testProviderNamespaceAndRestoreNeverReachOtherExecutor(){
        let a=ProviderStub(),b=ProviderStub(),p=AgentProviders(codex:a,claude:b)
        p.restoreKnownTabs(["codex-id","claude:uuid"]);XCTAssertEqual(a.ids,["codex-id"]);XCTAssertEqual(b.ids,["claude:uuid"])
        p.handle(command("read","claude:uuid"),authorized:{true}){_ in};XCTAssertEqual(a.ops,[]);XCTAssertEqual(b.ops,["read"])
        p.handle(command("new-thread",nil,["provider":"claude","cwd":"/tmp"]),authorized:{true}){_ in};XCTAssertEqual(b.ops,["read","new-thread"])
    }
    func testDiscoveryAndHelloStillWorkWhenCodexIsUnavailable(){
        let a=ProviderStub(),b=ProviderStub(),p=AgentProviders(codex:a,claude:b);a.fail=true;b.response=["data":[["id":"claude:id"]]]
        p.handle(command("list"),authorized:{true}){r in let value=try! r.get();XCTAssertEqual(value["data"] as? [[String:String]],[["id":"claude:id"]])}
        b.response=["joined":["claude:id"],"pending":[["id":"request"]],"settings":["claude:id":["model":"sonnet"]]]
        p.handle(command("hello"),authorized:{true}){r in let v=try! r.get();XCTAssertEqual(v["joined"] as? [String],["claude:id"]);XCTAssertEqual((v["pending"] as? [Any])?.count,1)}
    }
    func testDisconnectNamesItsProviderInsteadOfInvalidatingEverySession(){
        let a=ProviderStub(),b=ProviderStub(),p=AgentProviders(codex:a,claude:b)
        p.onEvent={e in XCTAssertEqual(e["method"] as? String,"xpromptvs/provider-disconnected");XCTAssertEqual((e["params"] as? [String:String])?["provider"],"codex")}
        a.onEvent(["method":"xpromptvs/disconnected"])
    }
}
