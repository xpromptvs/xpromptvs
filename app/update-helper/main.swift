import AppKit
import Foundation
import Security
import RdevCore
import ShellstormCore
import UpdateInstaller

struct Failure: Error { let reason:String }
func check(_ url:URL,channel:String,build:Int?) throws {
    var code:SecStaticCode?,requirement:SecRequirement?
    let rule="identifier \"ai.xpromptvs.app\" and anchor apple generic and certificate leaf[subject.OU] = \"2543RQRGJ8\""
    guard SecStaticCodeCreateWithPath(url as CFURL,[],&code)==errSecSuccess,
          SecRequirementCreateWithString(rule as CFString,[],&requirement)==errSecSuccess,
          let code,SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSCheckAllArchitectures|kSecCSStrictValidate|kSecCSCheckNestedCode),requirement)==errSecSuccess,
          let bundle=Bundle(url:url),let release=ReleaseIdentity.bundled(bundle),release.channel.rawValue==channel,
          build==nil || release.build==build else {throw Failure(reason:"signature-or-release")}
}
func run() throws {
    guard CommandLine.arguments.count==3 else{throw Failure(reason:"arguments")}
    let url=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL, token=CommandLine.arguments[2]
    let root=url.deletingLastPathComponent(),fm=FileManager.default
    let attrs=try fm.attributesOfItem(atPath:root.path)
    guard attrs[.ownerAccountID] as? UInt32 == getuid(), (attrs[.posixPermissions] as? Int ?? 0)&0o077==0 else{throw Failure(reason:"private-directory")}
    var j=try HostUpdateJournal.read(url)
    let installed=URL(fileURLWithPath:j.installed).standardizedFileURL
    guard j.token==token,UUID(uuidString:token) != nil,j.oldPID>1,j.oldLaunch>0,
          root.deletingLastPathComponent().path==installed.deletingLastPathComponent().path else{throw Failure(reason:"journal")}
    let ackURL=root.appendingPathComponent("ready.json")
    let launchAndConfirm: (URL) throws -> Void = { candidate in
        try? fm.removeItem(at:ackURL)
        let launchTime=Date()
        let config=NSWorkspace.OpenConfiguration();config.createsNewApplicationInstance=true
        config.arguments=["--rdev-update-journal",url.path,"--rdev-update-token",token]
        config.environment=j.environment ?? [:]
        if let profile=j.profile {config.environment["RDEV_APP_PROFILE"]=profile}
        var opened=false,launchError:Error?
        NSWorkspace.shared.openApplication(at:candidate,configuration:config){ _,error in launchError=error;opened=true }
        let deadline=Date().addingTimeInterval(90)
        while Date()<deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            if opened,let launchError{throw launchError}
            if let data=try? Data(contentsOf:ackURL),let ack=try? JSONSerialization.jsonObject(with:data) as? [String:Any],ack["token"] as? String==token,
               let pid=ack["pid"] as? Int32,let app=NSRunningApplication(processIdentifier:pid),!app.isTerminated,app.bundleURL?.resolvingSymlinksInPath().path==installed.path {
                let current=try HostUpdateJournal.read(url)
                if current.phase=="recovering" || ack["build"] as? Int==j.targetBuild {return}
            }
        }
        // Stop only this failed launch before trying to reopen the remaining installation.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier:"ai.xpromptvs.app") where app.bundleURL?.resolvingSymlinksInPath().path==installed.path && (app.launchDate ?? .distantPast)>=launchTime {
            app.terminate();Thread.sleep(forTimeInterval:2);if !app.isTerminated{app.forceTerminate()}
        }
        Thread.sleep(forTimeInterval:15)
        throw Failure(reason:"startup-timeout")
    }
    if ["succeeded","rolled-back","failed","cancelled"].contains(j.phase) {return}
    guard ["prepared","waiting","committed"].contains(j.phase),
          let version=j.caskVersion,let sha=j.artifactSHA256,let artifact=j.artifactURL else{throw Failure(reason:"journal-phase")}
    let cask=try HomebrewUpdate.cask(j.channel)
    let validateCask = {
        let info=try HomebrewUpdate.run(["info","--json=v2","--cask",cask])
        try HomebrewUpdate.validateInfo(info,channel:j.channel,installed:j.installed,version:version,sha256:sha,url:artifact)
    }
    try validateCask()
    if j.phase != "committed" {j.phase="waiting";try j.write(to:url)}
    let commitDeadline=Date().addingTimeInterval(30)
    while Date()<commitDeadline {
        j=try HostUpdateJournal.read(url)
        if j.phase=="committed" {break}
        guard j.phase=="waiting" else{throw Failure(reason:"cancelled")}
        Thread.sleep(forTimeInterval:0.1)
    }
    guard j.phase=="committed" else{throw Failure(reason:"commit-timeout")}
    let quitDeadline=Date().addingTimeInterval(30)
    while Date()<quitDeadline,let old=NSRunningApplication(processIdentifier:j.oldPID),!old.isTerminated {
        guard old.bundleURL?.resolvingSymlinksInPath().path==installed.path,abs((old.launchDate?.timeIntervalSince1970 ?? 0)-j.oldLaunch)<0.01 else{throw Failure(reason:"pid-reused")}
        Thread.sleep(forTimeInterval:0.1)
    }
    if let old=NSRunningApplication(processIdentifier:j.oldPID),!old.isTerminated {throw Failure(reason:"host-did-not-quit")}
    Thread.sleep(forTimeInterval:15)

    try Installer.upgrade(journalURL:url,upgrade:{
        try validateCask()
        _ = try HomebrewUpdate.run(["upgrade","--cask",cask])
    },verify:{try check($0,channel:j.channel,build:j.targetBuild)},verifyRemaining:{try check($0,channel:j.channel,build:nil)},launchAndConfirm:launchAndConfirm)
}
do {try run()} catch {
    fputs("Host update failed: \(error)\n",stderr)
    if CommandLine.arguments.count==3 {
        let url=URL(fileURLWithPath:CommandLine.arguments[1])
        if var journal=try? HostUpdateJournal.read(url),journal.token==CommandLine.arguments[2] {
            journal.phase="failed";journal.error="The update helper failed. Check this Mac locally.";journal.pairingCarrier=nil
            try? journal.write(to:url)
        }
    }
    // Never replay a failed Homebrew invocation independently of its own lock and receipts.
    exit(0)
}
