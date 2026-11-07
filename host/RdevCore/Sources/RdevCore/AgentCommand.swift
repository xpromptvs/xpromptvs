import Foundation

/// Explicit operations, not a tunnel to Codex's filesystem/process/auth RPCs.
public struct AgentCommand: Equatable, Sendable {
    public let id: String
    public let op: String
    public let thread: String?
    public let epoch: String?
    public let arguments: Data
    public var args: [String: Any] { (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:] }
    private static let fields: [String: Set<String>] = [
        "open-tab": [], "select-tab": [], "close-tab": [],
        "hello": [], "children": [], "list": ["cursor", "searchTerm"], "read": ["background"],
        "history": ["cursor"], "items": ["cursor", "turnId"], "record": ["turnId","itemId"], "join": [], "resume": [],
        "send": ["text", "attachments", "model", "effort", "plan"], "steer": ["text", "turnId", "attachments"],
        "queue": ["text", "attachments"], "queue-list": [], "queue-delete": ["id"], "interrupt": ["turnId"], "compact": [],
        "answer": ["request", "result"], "models": ["provider"], "limits": [], "settings": ["model", "reasoningEffort", "plan"],
        "goal": [], "goal-set": ["objective", "tokenBudget", "status"], "goal-clear": [],
        "new-thread": ["cwd", "model", "provider"], "start-service": [],
        "upload": ["upload", "name", "seq", "data", "last", "image"], "asset": ["item", "path", "turnId"], "asset-info": ["item", "path", "turnId"]
    ]
    private static let unscoped: Set<String> = ["hello", "list", "models", "new-thread", "start-service"]
    public static func parse(_ object: [String: Any]) -> AgentCommand? {
        guard object["v"] as? Int == 1, let id = object["id"] as? String, validID(id),
              let op = object["op"] as? String, let allowed = fields[op] else { return nil }
        let args = object["args"] as? [String: Any] ?? [:]
        guard Set(args.keys).isSubset(of: allowed), JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args), data.count <= 256 * 1024 else { return nil }
        let thread = object["thread"] as? String
        guard unscoped.contains(op) || thread.map(validID) == true else { return nil }
        let epoch = object["epoch"] as? String
        guard epoch == nil || epoch.map(validID) == true else { return nil }
        return AgentCommand(id: id, op: op, thread: thread, epoch: epoch, arguments: data)
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
