import Foundation
import RdevCore

/// One serialized connection to the user's daemon, independent of any remote page's lifetime.
final class CodexAgentManager: AgentManager, @unchecked Sendable {
    typealias Reply = CodexSocket.Reply
    private let queue = DispatchQueue(label: "rdev.codex.manager")
    private let rpc: CodexRPC
    private var known: Set<String> = [], joined: Set<String> = []
    private var pending: [String: [String: Any]] = [:]
    private var settings: [String: [String: Any]] = [:]
    private var selected: String?
    private var available = false
    private var joining: Set<String> = []
    private let files = AgentFiles()
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onStatus: (String, String?, [String]) -> Void = { _,_,_ in }

    init(rpc: CodexRPC? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        self.rpc = rpc ?? CodexSocket(path: ProcessInfo.processInfo.environment["RDEV_CODEX_SOCKET"] ?? home + "/app-server-control/app-server-control.sock")
        self.rpc.onNotification = { [weak self] event in self?.queue.async { [weak self] in self?.notification(event) } }
        self.rpc.onRequest = { [weak self] event in self?.queue.async { [weak self] in self?.request(event) } }
        self.rpc.onDisconnect = { [weak self] in self?.queue.async { [weak self] in
            guard let self else { return }
            for id in self.known { self.onStatus(id, nil, []) }
            self.available = false; self.joined.removeAll(); self.joining.removeAll(); self.pending.removeAll()
            self.onEvent(["method":"xpromptvs/disconnected", "params":[:]])
        } }
    }
    func close() { queue.async { self.rpc.close(); self.files.close(preserveUsed:true) } }
    /// Trusted launch metadata may be read without searching first; it grants no runtime attachment.
    func restoreKnownTabs(_ ids:[String]) {
        queue.async { self.known.formUnion(ids.prefix(100).filter { TabKey.isAgent("agent:"+$0) }) }
    }
    func handle(_ command: AgentCommand, authorized: @escaping () -> Bool, reply: @escaping Reply) {
        queue.async {
            guard authorized() else { reply(.failure(CodexError.message("Control changed"))); return }
            if command.op == "start-service" { self.startService(authorized:authorized,reply:reply); return }
            self.rpc.connect { [weak self] result in self?.queue.async { [weak self] in
                guard let self else { return }
                guard authorized() else { reply(.failure(CodexError.message("Control changed"))); return }
                switch result {
                case .failure(let error): reply(.failure(error))
                case .success: self.available = true; self.execute(command, authorized: authorized, reply: reply)
                }
            } }
        }
    }
    private func call(_ method: String, _ params: [String: Any], authorized: @escaping () -> Bool, completion: @escaping Reply) {
        rpc.call(method: method, params: params, authorized: authorized) { [weak self] result in
            self?.queue.async {
                if case .success(let value) = result, let thread = params["threadId"] as? String { self?.files.remember(value,thread:thread);self?.rememberChildren(value) }
                completion(result)
            }
        }
    }
    /// Discover from loaded runtime state only; never scan saved threads or attach an executor.
    private func liveChildren(of parent: String, authorized: @escaping () -> Bool, reply: @escaping Reply) {
        var finished = false
        let deadline = Date().addingTimeInterval(15)
        func finish(_ result: Result<[String:Any],Error>) { guard !finished else { return }; finished = true; reply(result) }
        self.queue.asyncAfter(deadline:.now()+15) { finish(.failure(CodexError.message("Live subagent discovery timed out"))) }
        call("thread/loaded/list", ["limit":512], authorized:authorized) { result in
            guard !finished else { return }
            guard case .success(let value) = result else { finish(result); return }
            guard let ids = value["data"] as? [String], ids.count <= 512,
                  value["nextCursor"] as? String == nil else {
                finish(.failure(CodexError.message("The loaded Codex thread list is incomplete or exceeds 512 threads"))); return
            }
            var remaining = Array(Set(ids)).sorted(), inFlight = 0
            var rows: [[String:Any]] = []
            func fail(_ error: Error) { finish(.failure(error)) }
            func pump() {
                guard !finished else { return }
                guard authorized() else { fail(CodexError.message("Control changed")); return }
                guard Date() < deadline else { fail(CodexError.message("Live subagent discovery timed out")); return }
                if remaining.isEmpty && inFlight == 0 {
                    rows.sort { ($0["createdAt"] as? Double ?? 0, $0["id"] as? String ?? "") < ($1["createdAt"] as? Double ?? 0, $1["id"] as? String ?? "") }
                    self.known.formUnion(rows.compactMap { $0["id"] as? String })
                    finish(.success(["data":rows])); return
                }
                while inFlight < 4 && !remaining.isEmpty {
                    let id = remaining.removeFirst(); inFlight += 1
                    self.call("thread/read", ["threadId":id,"includeTurns":false], authorized:authorized) { result in
                        guard !finished else { return }; inFlight -= 1
                        guard case .success(let value) = result else {
                            if case .failure(let error) = result { fail(error) }; return
                        }
                        guard let thread = value["thread"] as? [String:Any], thread["id"] as? String == id else {
                            fail(CodexError.message("Codex returned mismatched thread metadata")); return
                        }
                        let spawn = ((thread["source"] as? [String:Any])?["subAgent"] as? [String:Any])?["thread_spawn"] as? [String:Any]
                        let parentID = thread["parentThreadId"] as? String ?? spawn?["parent_thread_id"] as? String
                        if parentID == parent, (thread["status"] as? [String:Any])?["type"] as? String == "active" {
                            var row: [String:Any] = ["id":id,"parentThreadId":parent]
                            for key in ["name","agentNickname","agentRole","cwd","source","status","createdAt","canAcceptDirectInput"] { if let field = thread[key] { row[key] = field } }
                            rows.append(row)
                        }
                        pump()
                    }
                }
            }
            pump()
        }
    }
    private func execute(_ command: AgentCommand, authorized: @escaping () -> Bool, reply: @escaping Reply) {
        let args = command.args, thread = command.thread ?? ""
        func fail(_ text: String) { reply(.failure(CodexError.message(text))) }
        func perform(_ method: String, _ params: [String: Any]) {
            call(method, params, authorized: authorized) { result in
                reply(result.map { AgentTranscript.filter($0, operation: command.op) })
            }
        }
        if command.op == "hello" {
            reply(.success(["available":available, "selected":selected as Any? ?? NSNull(), "joined":Array(joined), "pending":Array(pending.values), "settings":settings]))
            return
        }
        if command.op == "list" {
            // Interactive browsing must not trigger Codex's rollout scan-and-repair path. On a
            // large history that exceeds the RPC deadline even while the indexed query is fast.
            var params: [String:Any] = ["limit":30,"sortKey":"updated_at","sourceKinds":["cli","vscode","appServer"],"useStateDbOnly":true]
            for key in ["cursor","searchTerm"] { if let value = args[key] as? String { params[key] = value } }
            call("thread/list", params, authorized: authorized) { result in
                if case .success(let object) = result, let rows = object["data"] as? [[String:Any]] {
                    for row in rows { if let id = row["id"] as? String { self.known.insert(id) } }
                }
                reply(result)
            }; return
        }
        if command.op == "models" { perform("model/list", ["limit":100]); return }
        if command.op == "new-thread" {
            var params: [String:Any] = ["serviceName":"xpromptvs"]
            if let cwd = args["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count < 4096 { params["cwd"] = cwd }
            if let model = args["model"] as? String { params["model"] = model }
            call("thread/start", params, authorized: authorized) { result in self.adopt(result); reply(result) }; return
        }
        guard known.contains(thread) else { fail("Select a session returned by this host first"); return }
        switch command.op {
        case "children": liveChildren(of:thread,authorized:authorized,reply:reply)
        case "goal": perform("thread/goal/get", ["threadId":thread])
        case "record":
            guard let turn = args["turnId"] as? String, let item = args["itemId"] as? String else { fail("Missing transcript item"); return }
            perform("thread/items/read",["threadId":thread,"turnId":turn,"itemIds":[item]])
        case "asset", "asset-info":
            guard let item = args["item"] as? String, let path = args["path"] as? String else { fail("Missing image reference"); return }
            func send(_ path:String){
                guard authorized() else{fail("Control changed");return}
                do { var value=try command.op == "asset-info" ? files.info(thread:thread,item:item,path:path) : files.asset(thread:thread,item:item,path:path)
                    if args["path"] as? String != path{value["name"]="Sent image"};reply(.success(value))
                } catch { reply(.failure(error)) }
            }
            if path.hasPrefix("input:") {
                guard let index=Int(path.dropFirst(6)),(0..<32).contains(index),let turn=args["turnId"] as? String,!turn.isEmpty,turn.utf8.count<=128 else{fail("Missing sent image reference");return}
                if let cached=files.inlinePath(thread:thread,turn:turn,item:item,index:index){send(cached);return}
                call("thread/items/read",["threadId":thread,"turnId":turn,"itemIds":[item]],authorized:authorized){result in
                    guard authorized() else{fail("Control changed");return}
                    do {let path=try self.files.prepareInline(thread:thread,turn:turn,item:item,index:index,response:result.get());send(path)}catch{reply(.failure(error))}
                }
            } else { send(path) }
        case "read", "open-tab":
            if args["background"] as? Bool != true { selected = thread }
            perform("thread/read", ["threadId":thread,"includeTurns":false])
        case "history":
            // Page within one turn, carrying two independent opaque Codex cursors. Turn
            // metadata is cheap and also preserves failed/interrupted turns with no items.
            var cursor: [String:Any] = [:]
            if let encoded = args["cursor"] as? String {
                guard encoded.utf8.count <= 65_536, let data = Data(base64Encoded:encoded),
                      let value = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
                    fail("Refresh this session to restart history pagination"); return
                }
                cursor = value
            }
            var metadata: [String:Any] = ["threadId":thread,"limit":1,"sortDirection":"desc","itemsView":"notLoaded"]
            if let turnCursor = cursor["turn"] as? String { metadata["cursor"] = turnCursor }
            func load(_ turn: [String:Any], nextTurn: String?) {
                guard let turnID = turn["id"] as? String else { fail("Invalid history cursor"); return }
                var params: [String:Any] = ["threadId":thread,"turnId":turnID,"limit":50,"sortDirection":"desc"]
                if let itemCursor = cursor["item"] as? String { params["cursor"] = itemCursor }
                self.call("thread/items/list",params,authorized:authorized) { page in
                    reply(page.map { page in
                        var out = AgentTranscript.historyPage(page,latest:turn)
                        var next: [String:Any] = [:]
                        if let itemCursor = page["nextCursor"] as? String {
                            // Pin this turn even if another one starts while older items load.
                            next = ["current":turn,"item":itemCursor]
                            if let nextTurn { next["nextTurn"] = nextTurn }
                        } else if let nextTurn { next["turn"] = nextTurn }
                        out["nextCursor"] = next.isEmpty ? NSNull() : (try? JSONSerialization.data(withJSONObject:next).base64EncodedString()) as Any? ?? NSNull()
                        return out
                    })
                }
            }
            if let current = cursor["current"] as? [String:Any] {
                load(current,nextTurn:cursor["nextTurn"] as? String)
            } else {
                call("thread/turns/list",metadata,authorized:authorized) { result in
                    guard case .success(let value) = result else { reply(result); return }
                    guard var turn = (value["data"] as? [[String:Any]])?.first else {
                        reply(.success(["data":[],"nextCursor":NSNull()])); return
                    }
                    turn["items"] = nil
                    load(AgentTranscript.preview(turn),nextTurn:value["nextCursor"] as? String)
                }
            }
        case "items":
            var params: [String:Any] = ["threadId":thread,"limit":50,"sortDirection":"desc"]
            if let cursor = args["cursor"] { params["cursor"] = cursor }
            if let turn = args["turnId"] as? String { params["turnId"] = turn }
            perform("thread/items/list", params)
        case "join", "resume":
            call("thread/loaded/list", [:], authorized: authorized) { result in
                guard case .success(let value) = result, let ids = value["data"] as? [String] else { reply(result); return }
                func resume() {
                    guard authorized() else { fail("Control changed"); return }
                    self.joining.insert(thread)
                    self.call("thread/resume", ["threadId":thread,"excludeTurns":true], authorized: authorized) { result in
                        self.joining.remove(thread); self.adopt(result); reply(result)
                    }
                }
                if ids.contains(thread) { resume(); return }
                guard command.op == "resume" else {
                    fail("This session is not loaded in the shared Codex service. Select Resume to continue saved history."); return
                }
                // Check this session, not every unrelated Codex process on the Mac. Reading the
                // latest turn does not load it or execute anything. A missing/unknown state fails closed.
                self.call("thread/turns/list", ["threadId":thread,"limit":1,"sortDirection":"desc","itemsView":"summary"], authorized:authorized) { result in
                    guard case .success(let history) = result else { reply(result); return }
                    guard let turns = history["data"] as? [[String:Any]],
                          let status = turns.first?["status"] as? String,
                          ["completed","interrupted","failed"].contains(status) else {
                        fail("This session has an unfinished or unknown saved turn and cannot be resumed safely. Stop it in its original client first, or use Take over when it is loaded in the shared Codex service."); return
                    }
                    resume()
                }
            }
        default:
            guard joined.contains(thread) else { fail("Take over or resume this session before interacting"); return }
            switch command.op {
            case "compact":
                call("thread/read", ["threadId":thread,"includeTurns":false], authorized:authorized) { result in
                    guard case .success(let value) = result else { reply(result); return }
                    guard let metadata = value["thread"] as? [String:Any],
                          let status = metadata["status"] as? [String:Any], status["type"] as? String == "idle" else {
                        fail("Wait for the current turn to finish before compacting"); return
                    }
                    perform("thread/compact/start", ["threadId":thread])
                }
            case "send", "steer", "queue":
                guard let text = args["text"] as? String, text.utf8.count <= 128 * 1024 else { fail("Enter a message within 128 KiB"); return }
                var params: [String:Any] = ["threadId":thread,"input":[["type":"text","text":text,"text_elements":[]]],"clientUserMessageId":UUID().uuidString]
                do {
                    var input = params["input"] as! [[String:Any]]
                    input += try files.inputs(thread:thread,ids:args["attachments"] as? [String] ?? [])
                    guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || input.count > 1 else { fail("Enter a message or attach a file"); return }
                    params["input"] = input
                } catch { reply(.failure(error)); return }
                if command.op == "steer" {
                    guard let turn = args["turnId"] as? String, !turn.isEmpty else { fail("The current turn changed"); return }
                    params["expectedTurnId"] = turn
                }
                if command.op == "send" {
                    for key in ["model","effort"] { if let value = args[key] as? String { params[key] = value } }
                    if let plan = args["plan"] as? Bool, let model = settings[thread]?["model"] as? String {
                        params["collaborationMode"] = ["mode":plan ? "plan":"default", "settings":["model":model,"reasoning_effort":settings[thread]?["reasoningEffort"] ?? NSNull(),"developer_instructions":NSNull()]]
                    }
                }
                perform(command.op == "send" ? "turn/start" : command.op == "steer" ? "turn/steer" : "thread/queue/add", params)
            case "interrupt":
                guard let turn = args["turnId"] as? String, !turn.isEmpty else { fail("The current turn changed"); return }
                perform("turn/interrupt", ["threadId":thread,"turnId":turn])
            case "settings":
                var params: [String:Any] = ["threadId":thread]
                if let model = args["model"] as? String { params["model"] = model }
                if let effort = args["reasoningEffort"] as? String { params["effort"] = effort }
                if let plan = args["plan"] as? Bool {
                    guard let model = args["model"] as? String ?? settings[thread]?["model"] as? String else { fail("Read the current model before changing plan mode"); return }
                    params["collaborationMode"] = ["mode":plan ? "plan":"default", "settings":["model":model,"reasoning_effort":args["reasoningEffort"] ?? settings[thread]?["reasoningEffort"] ?? NSNull(),"developer_instructions":NSNull()]]
                }
                call("thread/settings/update", params,authorized:authorized) { result in
                    if case .success = result {
                        if let model = params["model"] { self.settings[thread,default:[:]]["model"] = model }
                        if let effort = params["effort"] { self.settings[thread,default:[:]]["reasoningEffort"] = effort }
                        if let mode = params["collaborationMode"] { self.settings[thread,default:[:]]["collaborationMode"] = mode }
                    }
                    reply(result)
                }
            case "queue-list": perform("thread/queue/list", ["threadId":thread])
            case "limits": perform("account/rateLimits/read",[:])
            case "queue-delete":
                guard let id = args["id"] as? String else { fail("Missing queued message"); return }
                perform("thread/queue/delete", ["threadId":thread,"queuedSubmissionId":id])
            case "goal-set", "goal-clear":
                var params = args; params["threadId"] = thread; params["origin"] = "user"
                perform(command.op == "goal-set" ? "thread/goal/set":"thread/goal/clear", params)
            case "answer": answer(command, authorized: authorized, reply: reply)
            case "upload": do { reply(.success(try files.upload(thread:thread,args:args))) } catch { reply(.failure(error)) }
            default: fail("This operation is not available with this Codex integration")
            }
        }
    }
    private func adopt(_ result: Result<[String:Any],Error>) {
        guard case .success(let response) = result, let thread = response["thread"] as? [String:Any], let id = thread["id"] as? String else { return }
        known.insert(id); joined.insert(id); selected = id; settings[id] = response
        if let status = thread["status"] as? [String:Any] { onStatus(id, status["type"] as? String, status["activeFlags"] as? [String] ?? []) }
    }
    private func rememberChildren(_ value: Any, depth: Int = 0) {
        guard depth < 12 else { return }
        if let array = value as? [Any] { for child in array.prefix(2000) { rememberChildren(child,depth:depth+1) }; return }
        guard let object = value as? [String:Any] else { return }
        if object["type"] as? String == "collabAgentToolCall" {
            for id in object["receiverThreadIds"] as? [String] ?? [] where !id.isEmpty && id.utf8.count <= 128 { known.insert(id) }
        }
        if object["type"] as? String == "subAgentActivity", let id = object["agentThreadId"] as? String, !id.isEmpty, id.utf8.count <= 128 { known.insert(id) }
        for(key,child)in object where ["thread","turn","turns","items","item","data"].contains(key) { rememberChildren(child,depth:depth+1) }
    }
    private func request(_ event: [String:Any]) {
        guard let params = event["params"] as? [String:Any], let thread = params["threadId"] as? String,
              joined.contains(thread) || joining.contains(thread), let id = event["id"] else { return }
        let key = Self.requestKey(id)
        guard pending.count < 128 else { onEvent(["method":"xpromptvs/resnapshot","params":[:]]); return }
        pending[key] = event; onEvent(["method":"xpromptvs/request", "params":["request":event,"key":key]])
    }
    private func notification(_ event: [String:Any]) {
        guard let method = event["method"] as? String else { return }
        let params = event["params"] as? [String:Any] ?? [:]
        let thread = params["threadId"] as? String ?? (params["thread"] as? [String:Any])?["id"] as? String
        if method == "thread/status/changed", let thread, known.contains(thread), let status = params["status"] as? [String:Any] {
            onStatus(thread, status["type"] as? String, status["activeFlags"] as? [String] ?? [])
        }
        if method == "serverRequest/resolved", let id = params["requestId"] { pending.removeValue(forKey:Self.requestKey(id)) }
        if let thread, joined.contains(thread) || joining.contains(thread) {
            if method == "thread/settings/updated", let runtime = params["threadSettings"] as? [String:Any] {
                settings[thread,default:[:]].merge(runtime) { _,new in new }
                if let effort = runtime["effort"] { settings[thread,default:[:]]["reasoningEffort"] = effort }
                if let sandbox = runtime["sandboxPolicy"] { settings[thread,default:[:]]["sandbox"] = sandbox }
            }
            files.remember(params,thread:thread)
            rememberChildren(params)
            if let child = (params["item"] as? [String:Any])?["receiverThreadIds"] as? [String] { known.formUnion(child) }
            onEvent(AgentTranscript.livePreview(event))
        }
    }
    private func startService(authorized: @escaping ()->Bool, reply: @escaping Reply) {
        let candidates = [ProcessInfo.processInfo.environment["RDEV_CODEX_BIN"], NSHomeDirectory()+"/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].compactMap{$0}
        guard authorized(), let path = candidates.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else { reply(.failure(CodexError.message("Install Codex on the host or set RDEV_CODEX_BIN"))); return }
        let process = Process(); process.executableURL = URL(fileURLWithPath:path); process.arguments = ["app-server","daemon","start"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in reply(process.terminationStatus == 0 ? .success([:]) : .failure(CodexError.message("Codex service did not start"))) }
        do { try process.run() } catch { reply(.failure(error)) }
        DispatchQueue.global().asyncAfter(deadline:.now()+20) { if process.isRunning { process.terminate() } }
    }
    static func requestKey(_ id: Any) -> String {
        if let string = id as? String { return "s:" + string }
        return String(describing:id)
    }
    private func answer(_ command: AgentCommand, authorized: @escaping ()->Bool, reply: @escaping Reply) {
        guard let key = command.args["request"] as? String, let event = pending[key], let id = event["id"],
              let params = event["params"] as? [String:Any], params["threadId"] as? String == command.thread,
              let method = event["method"] as? String, let result = command.args["result"] as? [String:Any], Self.validAnswer(method:method,params:params,result:result) else {
            reply(.failure(CodexError.message("This request was resolved, changed, or has an unsupported answer"))); return
        }
        // Reserve the request before the asynchronous socket write. A second click cannot answer it twice.
        pending.removeValue(forKey:key)
        rpc.answer(id:id,result:result,authorized:authorized) { [weak self] value in self?.queue.async {
            if case .failure = value {
                if let thread = command.thread { self?.joined.remove(thread) }
                self?.onEvent(["method":"xpromptvs/detached","params":["threadId":command.thread ?? ""]])
            }
            reply(value)
        } }
    }
    static func validAnswer(method: String, params: [String:Any], result: [String:Any]) -> Bool {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            guard let decision = result["decision"], Set(result.keys) == ["decision"],
                  let encoded = try? JSONSerialization.data(withJSONObject:[decision],options:.sortedKeys) else { return false }
            let allowed = params["availableDecisions"] as? [Any] ?? ["accept","acceptForSession","decline","cancel"]
            return allowed.contains { (try? JSONSerialization.data(withJSONObject:[$0],options:.sortedKeys)) == encoded }
        case "item/tool/requestUserInput":
            guard let answers = result["answers"] as? [String:[String:Any]], let questions = params["questions"] as? [[String:Any]] else { return false }
            let ids = Set(questions.compactMap { $0["id"] as? String })
            return Set(answers.keys) == ids && answers.values.allSatisfy { ($0["answers"] as? [String])?.allSatisfy { $0.utf8.count <= 65536 } == true }
        case "item/permissions/requestApproval":
            guard let permissions = result["permissions"] as? [String:Any], let requested = params["permissions"] as? [String:Any], ["turn","session"].contains(result["scope"] as? String ?? "") else { return false }
            return subset(permissions, of: requested)
        case "mcpServer/elicitation/request": return ["accept","decline","cancel"].contains(result["action"] as? String ?? "")
        default: return false
        }
    }
    private static func subset(_ value: Any, of requested: Any) -> Bool {
        if let dictionary = value as? [String:Any], let original = requested as? [String:Any] {
            return dictionary.allSatisfy { key, child in original[key].map { subset(child, of:$0) } ?? false }
        }
        if let array = value as? [Any], let original = requested as? [Any] { return array.allSatisfy { child in original.contains { subset(child,of:$0) } } }
        if let number = value as? NSNumber, number == false { return true }
        return (value as AnyObject).isEqual(requested)
    }
}
