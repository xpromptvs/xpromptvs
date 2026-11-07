import Foundation
import CryptoKit
import Security
import RdevCore
import ShellstormCore

struct HostUpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message=message }
    var errorDescription: String? { message }
}
struct HostReleaseManifest: Sendable {
    let release: ReleaseIdentity
    let url: URL
    let size: Int
    let sha256: String
    static func parse(_ object: Any, channel: ReleaseChannel) throws -> Self {
        guard let o=object as? [String:Any], let release=ReleaseIdentity.parse(o), release.published, release.channel==channel,
              let raw=o["artifactURL"] as? String, raw=="https://github.com/xpromptvs/xpromptvs/releases/download/\(channel.rawValue)-\(release.build)/Xpromptvs.dmg", let url=URL(string:raw),
              let size=ReleaseIdentity.buildNumber(o["size"]),size<=100*1024*1024,
              let sha=o["sha256"] as? String,sha.count==64,sha.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw HostUpdateFailure("The release manifest is invalid.") }
        return Self(release:release,url:url,size:size,sha256:sha)
    }
    static func origin(_ channel:ReleaseChannel)->String { channel == .public ? "https://app.xpromptvs.ai" : "https://staging.xpromptvs.ai" }
}
private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit:Int64
    init(limit:Int64){self.limit=limit}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){ if totalBytesWritten>limit || totalBytesExpectedToWrite>limit { downloadTask.cancel() } }
}
enum HostUpdateDownload {
    static func fetch(_ url:URL,limit:Int) async throws -> URL {
        let config=URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest=30; config.timeoutIntervalForResource=900
        let session=URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let (tmp,response)=try await session.download(from:url,delegate:UpdateDownloadDelegate(limit:Int64(limit)))
        guard (response as? HTTPURLResponse)?.statusCode==200 else { throw HostUpdateFailure("The update server is unavailable.") }
        let length=try tmp.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard length<=limit else { throw HostUpdateFailure("The download is too large.") }
        let saved=FileManager.default.temporaryDirectory.appendingPathComponent("rdev-update-"+UUID().uuidString)
        try FileManager.default.moveItem(at:tmp,to:saved);return saved
    }
    static func latest(_ channel:ReleaseChannel) async throws -> HostReleaseManifest {
        let tmp=try await fetch(URL(string:"https://raw.githubusercontent.com/xpromptvs/homebrew-tap/main/releases/"+channel.rawValue+".json")!,limit:16384)
        defer { try? FileManager.default.removeItem(at:tmp) }
        return try HostReleaseManifest.parse(JSONSerialization.jsonObject(with:Data(contentsOf:tmp)),channel:channel)
    }
    static func prepare(_ manifest:HostReleaseManifest,installed:URL) async throws {
        let cancellation=HomebrewCancellation()
        try await withTaskCancellationHandler { try await Task.detached {
            _ = try HomebrewUpdate.run(["update"],cancellation:cancellation)
            let cask=try HomebrewUpdate.cask(manifest.release.channel.rawValue)
            let info=try HomebrewUpdate.run(["info","--json=v2","--cask",cask],cancellation:cancellation)
            try HomebrewUpdate.validateInfo(info,channel:manifest.release.channel.rawValue,installed:installed.path,version:"\(manifest.release.version),\(manifest.release.build)",sha256:manifest.sha256,url:manifest.url.absoluteString)
            // Homebrew checks the cask checksum and caches the artifact before the host quits.
            _ = try HomebrewUpdate.run(["fetch","--cask",cask],cancellation:cancellation)
        }.value } onCancel: {cancellation.cancel()}
    }
    static func verify(_ app:URL,release:ReleaseIdentity) throws {
        guard ReleaseIdentity.bundled(Bundle(url:app) ?? .main)==release else { throw HostUpdateFailure("The archive contains a different release.") }
        try command("/usr/bin/codesign",["--verify","--deep","--strict","-R", "identifier \"ai.xpromptvs.app\" and anchor apple generic and certificate leaf[subject.OU] = \"2543RQRGJ8\"",app.path])
        try command("/usr/sbin/spctl",["--assess","--type","execute",app.path])
        guard let bundle=Bundle(url:app),let architectures=bundle.executableArchitectures,architectures.contains(NSNumber(value:0x0100000c)) else { throw HostUpdateFailure("The update cannot run on this Mac.") }
        if let minimum=bundle.object(forInfoDictionaryKey:"LSMinimumSystemVersion") as? String {
            let parts=minimum.split(separator:".").compactMap{Int($0)}
            guard !parts.isEmpty,ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion:parts[0],minorVersion:parts.count>1 ? parts[1]:0,patchVersion:parts.count>2 ? parts[2]:0)) else { throw HostUpdateFailure("The update requires a newer macOS version.") }
        }
    }
    static func command(_ path:String,_ args:[String]) throws { _ = try commandOutput(path,args) }
    static func commandOutput(_ path:String,_ args:[String]) throws -> String {
        let process=Process(),pipe=Pipe(); process.executableURL=URL(fileURLWithPath:path);process.arguments=args;process.standardInput=FileHandle.nullDevice;process.standardOutput=pipe;process.standardError=pipe
        try process.run()
        let deadline=DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+60,execute:deadline)
        let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();deadline.cancel()
        guard process.terminationStatus==0 else { throw HostUpdateFailure("Update verification failed (\(URL(fileURLWithPath:path).lastPathComponent)).") }
        return String(decoding:data.prefix(16384),as:UTF8.self)
    }
}
