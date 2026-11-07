import Foundation

enum AgentDelivery {
    static let chunkSize = 16384
    static let maxBytes = 64 * 1024 * 1024
}

/// Bounded, paced transfers. Queued transcripts never follow a replaced driver connection.
final class AgentSender: @unchecked Sendable {
    private let queue = DispatchQueue(label:"rdev.agents.delivery")
    private let lock = NSLock()
    private var reserved = 0
    func send(_ object: [String:Any], authorized: @escaping ()->Bool, buffered: @escaping ()->Int?, deliver: @escaping (Bool,Data)->Void) {
        guard authorized(), let data = try? JSONSerialization.data(withJSONObject:object) else { return }
        func error(_ message: String) {
            guard authorized() else { return }
            var response: [String:Any] = ["t":"agent-event","epoch":object["epoch"] ?? "", "event":["method":"xpromptvs/resnapshot","params":["error":message]]]
            if let id = object["id"] { response = ["t":"agent-response","id":id,"epoch":object["epoch"] ?? "","error":message] }
            if let bytes = try? JSONSerialization.data(withJSONObject:response) { deliver(false,bytes) }
        }
        guard data.count <= AgentDelivery.maxBytes else { error("Agent response exceeds 64 MiB; request a smaller history page"); return }
        if data.count <= AgentDelivery.chunkSize { if authorized() { deliver(false,data) }; return }
        guard lock.withLock({ if reserved + data.count > AgentDelivery.maxBytes { return false }; reserved += data.count; return true }) else { error("Agent transfers are busy; reload this history page"); return }
        let transfer = UUID().uuidString, count = (data.count + AgentDelivery.chunkSize - 1) / AgentDelivery.chunkSize
        let deadline = Date().addingTimeInterval(20)
        var seq = 0
        func release() { self.lock.withLock { self.reserved -= data.count } }
        @Sendable func pump() {
            guard authorized(), Date() < deadline, let held = buffered() else { release(); return }
            if held > 1024 * 1024 { self.queue.asyncAfter(deadline:.now()+0.01,execute:pump); return }
            for _ in 0..<16 {
                guard seq < count, authorized() else { release(); return }
                let start = seq * AgentDelivery.chunkSize
                let chunk: [String:Any] = ["t":"agent-chunk","v":1,"transfer":transfer,"epoch":object["epoch"] ?? "", "seq":seq,"count":count,"total":data.count,"data":data.subdata(in:start..<min(data.count,start+AgentDelivery.chunkSize)).base64EncodedString()]
                if let bytes = try? JSONSerialization.data(withJSONObject:chunk) { deliver(true,bytes) }
                seq += 1
                if seq == count { release(); return }
            }
            self.queue.asyncAfter(deadline:.now()+0.001,execute:pump)
        }
        queue.async(execute:pump)
    }
}
