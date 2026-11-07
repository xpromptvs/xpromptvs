import Foundation
import Darwin
import RdevCore

/// One SDK helper, many retained Claude processes. It is owned by HostSession, never by a tab.
final class ClaudeAgentManager: AgentManager, @unchecked Sendable {
    private let queue=DispatchQueue(label:"rdev.claude.manager")
    private let writes=DispatchQueue(label:"rdev.claude.writes")
    private var process:Process?
    private var input:FileHandle?
    private var output:Pipe?,errors:Pipe?
    private var buffer=Data()
    private var pending:[String:CodexSocket.Reply]=[:]
    private var known=Set<String>()
    private var closed=false
    private let files=AgentFiles()
    private var generation=UUID()
    private let helper:String?,node:String?,cli:String?
    var onEvent:([String:Any])->Void={_ in}
    var onStatus:(String,String?,[String])->Void={_,_,_ in}
    init(helper:String?=nil,node:String?=nil,cli:String?=nil){
        let env=ProcessInfo.processInfo.environment
        self.helper=helper ?? env["RDEV_CLAUDE_HELPER"] ?? Bundle.main.resourceURL?.appendingPathComponent("agents/claude-helper.mjs").path
        func executable(_ override:String?,_ name:String)->String? {
            let paths=[override,NSHomeDirectory()+"/.local/bin/"+name,"/opt/homebrew/bin/"+name,"/usr/local/bin/"+name,"/usr/bin/"+name]+(env["PATH"] ?? "").split(separator:":").map{String($0)+"/"+name}
            return paths.compactMap{$0}.first{FileManager.default.isExecutableFile(atPath:$0)}
        }
        self.node=node ?? executable(env["RDEV_NODE_BIN"],"node");self.cli=cli ?? executable(env["RDEV_CLAUDE_BIN"],"claude")
    }
    func restoreKnownTabs(_ ids:[String]){queue.async{self.known.formUnion(ids.prefix(100))}}
    func close(){queue.async{self.closed=true;self.files.close(preserveUsed:true);self.input?.closeFile();self.input=nil;let p=self.process;self.queue.asyncAfter(deadline:.now()+1){if p?.isRunning == true{p?.terminate()}}}}
    func handle(_ command:AgentCommand,authorized:@escaping ()->Bool,reply:@escaping CodexSocket.Reply){queue.async{
        guard authorized(),!self.closed else{reply(.failure(CodexError.message("Control changed")));return}
        if let id=command.thread,!self.known.contains(id){reply(.failure(CodexError.message("Select a Claude session returned by this host first")));return}
        if command.op=="asset"||command.op=="asset-info"{self.asset(command,authorized:authorized,reply:reply);return}
        if command.op=="upload" {
            do{reply(.success(try self.files.upload(thread:command.thread!,args:command.args)))}catch{reply(.failure(error))};return
        }
        var arguments=command.args
        if command.op=="send"||command.op=="queue" {
            guard arguments["attachments"]==nil||arguments["attachments"] is [String] else{reply(.failure(CodexError.message("Invalid attachments")));return}
            do{arguments["attachments"]=try self.files.inputs(thread:command.thread!,ids:arguments["attachments"] as? [String] ?? [])}catch{reply(.failure(error));return}
        }
        do{try self.start()}catch{reply(.failure(error));return}
        guard self.pending.count<32 else{reply(.failure(CodexError.message("Too many pending Claude requests")));return}
        let id=UUID().uuidString;self.pending[id]={result in
            if case .success(let value)=result {
                if let rows=value["data"] as? [[String:Any]],["list","children"].contains(command.op) {self.known.formUnion(rows.compactMap{$0["id"] as? String})}
                if let thread=value["thread"] as? [String:Any],let id=thread["id"] as? String {self.known.insert(id)}
            }
            reply(result)
        }
        var row:[String:Any]=["id":id,"op":command.op,"args":arguments]
        if let thread=command.thread{row["thread"]=thread}
        guard let data=try? JSONSerialization.data(withJSONObject:row) else{self.finish(id,.failure(CodexError.message("Invalid Claude request")));return}
        let handle=self.input
        self.writes.async {
            guard authorized() else {self.queue.async{self.finish(id,.failure(CodexError.message("Control changed")))};return}
            do{try handle?.write(contentsOf:data+Data([10]))}catch{self.queue.async{self.finish(id,.failure(error))}}
        }
        self.queue.asyncAfter(deadline:.now()+20){self.finish(id,.failure(CodexError.message("Claude request timed out; check its state before retrying")))}
    }}
    private func asset(_ command:AgentCommand,authorized:@escaping ()->Bool,reply:@escaping CodexSocket.Reply){
        let args=command.args
        guard let thread=command.thread,let item=args["item"] as? String,let path=args["path"] as? String,path.hasPrefix("input:"),
              let index=Int(path.dropFirst(6)),(0..<32).contains(index),let turn=args["turnId"] as? String,!turn.isEmpty,turn.utf8.count<=128 else{reply(.failure(CodexError.message("Missing sent image reference")));return}
        func send(_ path:String){
            guard authorized(),!self.closed else{reply(.failure(CodexError.message("Control changed")));return}
            do{var value=try command.op=="asset-info" ? self.files.info(thread:thread,item:item,path:path):self.files.asset(thread:thread,item:item,path:path);value["name"]="Sent image";reply(.success(value))}catch{reply(.failure(error))}
        }
        if let cached=files.inlinePath(thread:thread,turn:turn,item:item,index:index){send(cached);return}
        guard let record=AgentCommand.parse(["v":1,"id":UUID().uuidString,"op":"record","thread":thread,"args":["turnId":turn,"itemId":item]]) else{reply(.failure(CodexError.message("Invalid image reference")));return}
        handle(record,authorized:authorized){result in
            guard authorized(),!self.closed else{reply(.failure(CodexError.message("Control changed")));return}
            do{send(try self.files.prepareClaudeInline(thread:thread,turn:turn,item:item,index:index,response:result.get()))}catch{reply(.failure(error))}
        }
    }
    private func finish(_ id:String,_ result:Result<[String:Any],Error>){pending.removeValue(forKey:id)?(result)}
    private func start() throws {
        if process?.isRunning == true{return}
        if process != nil { disconnected() }
        guard let helper,FileManager.default.fileExists(atPath:helper),let node,let cli else {throw CodexError.message("Claude sessions require Node.js and Claude Code installed on the host. Rebuild Xpromptvs if its SDK helper is missing.")}
        let p=Process(),stdin=Pipe(),stdout=Pipe(),stderr=Pipe()
        let epoch=UUID();generation=epoch
        p.executableURL=URL(fileURLWithPath:node);p.arguments=[helper,cli];p.standardInput=stdin;p.standardOutput=stdout;p.standardError=stderr
        var env=ProcessInfo.processInfo.environment;env["PATH"]=[URL(fileURLWithPath:node).deletingLastPathComponent().path,NSHomeDirectory()+"/.local/bin","/opt/homebrew/bin","/usr/local/bin",env["PATH"] ?? "/usr/bin:/bin"].joined(separator:":");p.environment=env
        stdout.fileHandleForReading.readabilityHandler={ [weak self] handle in let data=handle.availableData;self?.queue.async{guard self?.generation==epoch else{return};self?.receive(data)} }
        // SDK diagnostics never enter the transcript and must be drained to avoid pipe backpressure.
        stderr.fileHandleForReading.readabilityHandler={handle in _=handle.availableData}
        p.terminationHandler={ [weak self] _ in self?.queue.async{guard self?.generation==epoch else{return};self?.disconnected()} }
        // A helper that exits while a write is queued must return EPIPE, never signal the host.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try p.run();process=p;input=stdin.fileHandleForWriting;output=stdout;errors=stderr;buffer=Data()
    }
    private func receive(_ data:Data){
        buffer.append(data)
        guard buffer.count<=64*1024*1024 else{process?.terminate();disconnected();return}
        while let newline=buffer.firstIndex(of:10){let line=Data(buffer[..<newline]);buffer.removeSubrange(...newline)
            guard let row=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else{continue}
            if let event=row["event"] as? [String:Any] {
                if let params=event["params"] as? [String:Any],let id=params["threadId"] as? String,let status=params["status"] as? [String:Any],event["method"] as? String=="thread/status/changed" {onStatus(id,status["type"] as? String,status["activeFlags"] as? [String] ?? [])}
                onEvent(event)
            }else if let id=row["id"] as? String {
                if let error=row["error"] as? String{finish(id,.failure(CodexError.message(error)))}else{finish(id,.success(row["result"] as? [String:Any] ?? [:]))}
            }
        }
    }
    private func disconnected(){
        output?.fileHandleForReading.readabilityHandler=nil;errors?.fileHandleForReading.readabilityHandler=nil
        process=nil;input=nil;output=nil;errors=nil;buffer=Data();let callbacks=pending.values;pending.removeAll()
        for callback in callbacks{callback(.failure(CodexError.message("Claude SDK helper disconnected")))}
        for id in known{onStatus(id,nil,[])};onEvent(["method":"xpromptvs/disconnected","params":[:]])
    }
}
