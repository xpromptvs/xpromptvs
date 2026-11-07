import Foundation
import RdevCore

protocol AgentManager: AnyObject {
    var onEvent: ([String:Any])->Void { get set }
    var onStatus: (String,String?,[String])->Void { get set }
    func handle(_ command:AgentCommand,authorized:@escaping ()->Bool,reply:@escaping CodexSocket.Reply)
    func restoreKnownTabs(_ ids:[String])
    func close()
}

/// Provider identity is part of the tab id. Existing Codex ids remain byte-for-byte unchanged.
final class AgentProviders: AgentManager, @unchecked Sendable {
    static func make(enabled: Bool = ProductFeatures.graphicalAgents,
                     codex: () -> AgentManager = { CodexAgentManager() },
                     claude: () -> AgentManager = { ClaudeAgentManager() }) -> AgentProviders? {
        guard enabled else { return nil }
        return AgentProviders(codex: codex(), claude: claude())
    }
    private let codex: AgentManager
    private let claude: AgentManager
    var onEvent: ([String:Any])->Void = {_ in}
    var onStatus: (String,String?,[String])->Void = {_,_,_ in}
    init(codex:AgentManager = CodexAgentManager(),claude:AgentManager = ClaudeAgentManager()) {
        self.codex=codex;self.claude=claude
        for (provider,manager) in [("codex",codex),("claude",claude)] {
            manager.onEvent = { [weak self] event in
                if event["method"] as? String == "xpromptvs/disconnected" { self?.onEvent(["method":"xpromptvs/provider-disconnected","params":["provider":provider]]) }
                else { self?.onEvent(event) }
            }
            manager.onStatus = { [weak self] id,status,flags in self?.onStatus(id,status,flags) }
        }
    }
    func restoreKnownTabs(_ ids:[String]) { codex.restoreKnownTabs(ids.filter{!$0.hasPrefix("claude:")});claude.restoreKnownTabs(ids.filter{$0.hasPrefix("claude:")}) }
    func close(){codex.close();claude.close()}
    func handle(_ command:AgentCommand,authorized:@escaping ()->Bool,reply:@escaping CodexSocket.Reply){
        if command.thread?.hasPrefix("claude:") == true || command.args["provider"] as? String == "claude" { claude.handle(command,authorized:authorized,reply:reply);return }
        guard command.op == "hello" || (command.op == "list" && command.args["cursor"] == nil) else { codex.handle(command,authorized:authorized,reply:reply);return }
        let lock=NSLock();var results:[String:Result<[String:Any],Error>]=[:]
        for (name,manager) in [("codex",codex),("claude",claude)] {
            manager.handle(command,authorized:authorized){result in
                let snapshot=lock.withLock { ()->[String:Result<[String:Any],Error>]? in results[name]=result;return results.count==2 ? results:nil }
                guard let snapshot else{return}
                var values:[String:[String:Any]]=[:]
                for(name,result) in snapshot {if case .success(let value)=result{values[name]=value}}
                guard !values.isEmpty else {reply(snapshot["claude"]!);return}
                if command.op == "list" {
                    var out=values["codex"] ?? [:];out["data"]=(values["codex"]?["data"] as? [Any] ?? [])+(values["claude"]?["data"] as? [Any] ?? []);reply(.success(out))
                } else {
                    var out=values["codex"] ?? [:];out["available"]=true
                    for key in ["joined","pending"] {out[key]=(values["codex"]?[key] as? [Any] ?? [])+(values["claude"]?[key] as? [Any] ?? [])}
                    var settings=values["codex"]?["settings"] as? [String:Any] ?? [:];settings.merge(values["claude"]?["settings"] as? [String:Any] ?? [:]){_,new in new};out["settings"]=settings
                    out["providers"]=Array(values.keys);reply(.success(out))
                }
            }
        }
    }
}
