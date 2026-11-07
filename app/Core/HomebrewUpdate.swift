import Foundation
public final class HomebrewCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    private var process:Process?
    public init() {}
    public func check() throws {lock.lock();defer{lock.unlock()};if cancelled{throw CancellationError()}}
    public func attach(_ process:Process) {lock.lock();self.process=process;let stop=cancelled;lock.unlock();if stop && process.isRunning{process.terminate()}}
    public func detach() {lock.lock();process=nil;lock.unlock()}
    public func cancel() {lock.lock();cancelled=true;let current=process;lock.unlock();if let current,current.isRunning{current.terminate()}}
}
/// The requester never chooses a command, cask, URL, or installation path.
public enum HomebrewUpdate {
    public struct Failure: LocalizedError {
        public var errorDescription:String? { "This app must be updated locally using its matching Homebrew cask." }
        public init() {}
    }
    public static func cask(_ channel:String) throws -> String {
        switch channel {case "public":return "xpromptvs/tap/xpromptvs";case "staging":return "xpromptvs/tap/xpromptvs-staging";default:throw Failure()}
    }
    public static func validateInfo(_ data:Data,channel:String,installed:String,version:String,sha256:String,url:String) throws {
        let name=try cask(channel)
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let casks=object["casks"] as? [[String:Any]],casks.count==1,let c=casks.first,
              c["full_token"] as? String==name,let previous=c["installed"] as? String,!previous.isEmpty,
              c["version"] as? String==version,c["sha256"] as? String==sha256,c["url"] as? String==url,
              let artifacts=c["artifacts"] as? [[String:Any]],
              artifacts.contains(where:{ $0["app"] != nil && ($0["target"] as? String).map{URL(fileURLWithPath:$0).resolvingSymlinksInPath().path==URL(fileURLWithPath:installed).resolvingSymlinksInPath().path} == true }) else {throw Failure()}
    }
    public static func executable() throws -> String {
        // The product is arm64. Never resolve a remote-controlled PATH or invoke a shell.
        let path="/opt/homebrew/bin/brew"
        guard FileManager.default.isExecutableFile(atPath:path) else{throw Failure()};return path
    }
    public static func run(_ arguments:[String],timeout:TimeInterval=900,cancellation:HomebrewCancellation?=nil) throws -> Data {
        try cancellation?.check()
        let output=FileManager.default.temporaryDirectory.appendingPathComponent("brew-update-"+UUID().uuidString)
        FileManager.default.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600])
        let handle=try FileHandle(forWritingTo:output)
        defer{try? handle.close();try? FileManager.default.removeItem(at:output)}
        let p=Process();p.executableURL=URL(fileURLWithPath:try executable());p.arguments=arguments
        p.standardInput=FileHandle.nullDevice;p.standardOutput=handle;p.standardError=FileHandle.nullDevice
        p.environment=["HOME":NSHomeDirectory(),"USER":NSUserName(),"PATH":"/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin","HOMEBREW_NO_AUTO_UPDATE":"1","HOMEBREW_NO_INSTALL_CLEANUP":"1","HOMEBREW_NO_ANALYTICS":"1","NONINTERACTIVE":"1"]
        try p.run();cancellation?.attach(p)
        defer{cancellation?.detach()}
        let deadline=DispatchWorkItem{if p.isRunning {p.terminate()}}
        DispatchQueue.global().asyncAfter(deadline:.now()+timeout,execute:deadline)
        p.waitUntilExit();deadline.cancel()
        try cancellation?.check()
        guard (try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=2*1024*1024 else{throw Failure()}
        let data=try Data(contentsOf:output)
        guard p.terminationStatus==0,data.count<=2*1024*1024 else{throw Failure()};return data
    }
}
