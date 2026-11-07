import Foundation

/// Restart metadata only: no executor, transcript, attachment, runtime status or approval state.
/// Terminal positions refer to indices in the same saved file, since PTY ids change on restart.
public struct SavedAgentTabs:Equatable,Sendable {
    public let tabs:[SessionAgent]
    public let selected:String?
    public let showing:Bool
    public let order:[String]

    public init(state:SessionState,terminalIDs:[String]) {
        tabs=state.agents.map { SessionAgent(id:$0.id,title:$0.title,cwd:$0.cwd,name:$0.name) }
        selected=state.selectedAgent;showing=state.view.surface == .agents
        order=state.tabOrder.compactMap { key in
            if TabKey.isAgent(key) { return key }
            return terminalIDs.firstIndex(of:key).map { "terminal:\($0)" }
        }
    }
    var object:[String:Any] {
        var result:[String:Any]=["tabs":tabs.map { tab -> [String:Any] in
            var row:[String:Any]=["id":tab.id,"title":tab.title,"cwd":tab.cwd]
            if let name=tab.name {row["name"]=name};return row
        },"showing":showing,"order":order]
        if let selected {result["selected"]=selected};return result
    }
    init?(object:[String:Any],terminalIndices:[Int:Int]) {
        guard let rows=object["tabs"] as? [Any],rows.count<=100 else{return nil}
        var state=SessionState()
        for row in rows {
            guard let row=row as? [String:Any],let id=row["id"] as? String,
                  let title=row["title"] as? String,let cwd=row["cwd"] as? String else{continue}
            _=state.openAgent(id,title:title,cwd:cwd)
            if let name=row["name"] as? String {_=state.setAgentName(id,name)}
        }
        let decodedTabs=state.agents;tabs=decodedTabs
        selected=(object["selected"] as? String).flatMap { id in decodedTabs.contains { $0.id==id } ? id:nil } ?? decodedTabs.first?.id
        showing=object["showing"] as? Bool ?? false
        order=(object["order"] as? [String] ?? []).prefix(400).compactMap { key in
            if TabKey.isAgent(key),decodedTabs.contains(where: {"agent:"+$0.id==key}) {return key}
            guard key.hasPrefix("terminal:"),let old=Int(key.dropFirst(9)),let index=terminalIndices[old] else{return nil}
            return "terminal:\(index)"
        }
    }
}
