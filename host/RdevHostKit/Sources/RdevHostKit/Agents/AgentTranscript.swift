import Foundation

/// Presentation-only cleanup. Codex history and live lifecycle events remain authoritative.
enum AgentTranscript {
    private static let metadata: Set<String> = ["id", "type", "status", "turnId", "startedAtMs", "completedAtMs", "startedAt", "completedAt", "durationMs", "_turn", "_order"]

    /// Keep the wire working set small. The exact record remains in Codex and is fetched by
    /// `record` only when requested; presentation truncation never changes daemon history.
    static func preview(_ item: [String:Any]) -> [String:Any] {
        var item=item
        if item["type"] as? String == "userMessage",let inputs=item["content"] as? [[String:Any]] {
            item["content"]=inputs.enumerated().map { index,input -> [String:Any] in
                guard input["type"] as? String == "image",let url=input["url"] as? String,url.hasPrefix("data:image/") else{return input}
                // Resolve pixels from the authoritative exact item only when its slot is visible.
                return ["type":"image","_assetPath":"input:\(index)"]
            }
        }
        var trimmed = false
        func bound(_ value: Any, depth: Int) -> Any {
            if let text = value as? String, text.utf8.count > 8192 {
                trimmed = true
                return String(text.prefix(1024)) + "\n… [preview truncated] …\n" + String(text.suffix(1024))
            }
            if depth > 8 { trimmed = true; return NSNull() }
            if let array = value as? [Any] {
                if array.count > 32 { trimmed = true }
                return array.prefix(32).map { bound($0, depth:depth + 1) }
            }
            if let object = value as? [String:Any] {
                return object.mapValues { bound($0, depth:depth + 1) }
            }
            return value
        }
        var out = bound(item, depth:0) as! [String:Any]
        if trimmed { out["_truncated"] = true }
        if let data = try? JSONSerialization.data(withJSONObject:out), data.count > 32_768 {
            out = ["id":item["id"] ?? "", "type":item["type"] ?? "unknown", "_truncated":true,
                   "_preview":String((String(data:data,encoding:.utf8) ?? "").prefix(4096))]
            if let status = item["status"] { out["status"] = status }
        }
        return out
    }

    /// Codex item pages are newest-first, including within a turn. Preserve that turn order
    /// while restoring chronological items for the renderer, without loading full turns.
    static func historyPage(_ response: [String:Any], latest: [String:Any]?) -> [String:Any] {
        var out = response, turns: [[String:Any]] = [], indices: [String:Int] = [:]
        for entry in response["data"] as? [[String:Any]] ?? [] {
            guard let turn = entry["turnId"] as? String, var item = entry["item"] as? [String:Any] else { continue }
            if isEmptyReasoning(item) { continue }
            for key in ["startedAtMs","completedAtMs"] where item[key] == nil { item[key] = entry[key] }
            let index: Int
            if let existing = indices[turn] { index = existing }
            else {
                index = turns.count; indices[turn] = index
                var metadata: [String:Any] = latest?["id"] as? String == turn ? latest! : ["id":turn]
                metadata["items"] = [[String:Any]](); turns.append(metadata)
            }
            var items = turns[index]["items"] as! [[String:Any]]
            items.insert(preview(item),at:0); turns[index]["items"] = items
        }
        if let latest, let id = latest["id"] as? String, indices[id] == nil {
            var metadata = latest; metadata["items"] = [[String:Any]](); turns.insert(metadata,at:0)
        }
        out["data"] = turns
        return out
    }

    static func livePreview(_ event: [String:Any]) -> [String:Any] {
        var out = event
        guard var params = event["params"] as? [String:Any] else { return event }
        if let item = params["item"] as? [String:Any] { params["item"] = preview(item) }
        if var turn = params["turn"] as? [String:Any], let items = turn["items"] as? [[String:Any]] {
            turn["items"] = items.suffix(50).map { preview($0) }; params["turn"] = turn
        }
        out["params"] = params; return out
    }

    static func isEmptyReasoning(_ item: [String:Any]) -> Bool {
        guard item["type"] as? String == "reasoning" else { return false }
        // Partial records and unknown content must remain available for explicit retrieval.
        return !item.contains { key, value in !metadata.contains(key) && hasContent(value) }
    }

    private static func hasContent(_ value: Any, depth: Int = 0) -> Bool {
        if value is NSNull { return false }
        if depth > 16 { return true }
        if let text = value as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let array = value as? [Any] { return array.contains { hasContent($0, depth: depth + 1) } }
        if let object = value as? [String:Any] { return object.values.contains { hasContent($0, depth: depth + 1) } }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        return true
    }

    static func filter(_ response: [String:Any], operation: String) -> [String:Any] {
        guard operation == "history" || operation == "items", let data = response["data"] as? [Any] else { return response }
        var out = response
        if operation == "history" {
            out["data"] = data.map { value -> Any in
                guard var turn = value as? [String:Any], let items = turn["items"] as? [Any] else { return value }
                turn["items"] = items.filter { item in
                    guard let item = item as? [String:Any] else { return true }
                    return !isEmptyReasoning(item)
                }
                return turn
            }
        } else {
            out["data"] = data.filter { value in
                guard let entry = value as? [String:Any] else { return true }
                return !isEmptyReasoning((entry["item"] as? [String:Any]) ?? entry)
            }
        }
        return out
    }
}
