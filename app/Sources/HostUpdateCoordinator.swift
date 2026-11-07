import AppKit
import RdevCore
import RdevHostKit
import RdevAppHost
import ShellstormCore

@MainActor final class HostUpdateCoordinator {
    private let host:HostController
    private let profile:AppProfile
    private let environment:ShellEnvironment
    private let release=ReleaseIdentity.bundled()
    private var available:HostReleaseManifest?
    private var state=HostUpdateState()
    private var task:Task<Void,Never>?
    private var replies:[HostUpdates.Reply]=[]
    private var lastStatus:Data?
    private var refreshTask:Task<Void,Never>?
    init(host:HostController,profile:AppProfile,environment:ShellEnvironment){
        self.host=host;self.profile=profile;self.environment=environment
        guard AppDistribution.official else {
            SharingHost.shared.hostUpdates.configure(release:nil, allowed:false, available:nil, handler:nil)
            return
        }
        host.updateSettingsChanged = { [weak self] in self?.settingsChanged() }
        publish()
        refreshTask=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,let release=self.release else{return}
                if let latest=try? await HostUpdateDownload.latest(release.channel) {self.available=latest;self.publish()}
                try? await Task.sleep(for:.seconds(300))
            }
        }
    }
    private var allowed:Bool { AppSettings.read(dir:profile.directory).allowRemoteUpdates }
    private func publish(){
        let handler: HostUpdates.Handler = { [weak self] request, requester, reply in
            Task<Void, Never> { @MainActor in
                guard let self else { return }
                self.request(request, requester: requester, reply: reply)
            }
        }
        SharingHost.shared.hostUpdates.configure(release:release, allowed:allowed, available:available?.release.build, handler:release?.published == true && (try? HomebrewUpdate.executable()) != nil ? handler : nil)
    }
    private func authorized(_ requester:HostUpdateRequester) -> Bool {
        guard let identity=E2EHost.shared.service(base:environment.signalingBase).identity,
              case .success(let loaded)=identity.load() else{return false}
        return requester.isAuthorized(root:loaded.trustedRootID,revoked:loaded.record.revokedDeviceIDs)
    }
    private func settingsChanged(){if !allowed { state.cancel();if state.phase != .restarting {task?.cancel()} };publish()}
    private func emit(_ phase:String,error:String?=nil){
        guard let id=state.requestID.flatMap(UUID.init(uuidString:)) else{return}
        let data=HostUpdates.status(id,phase:phase,target:available?.release.build,error:error);lastStatus=data
        for reply in replies {reply(data)}
    }
    private func request(_ request:HostUpdateRequest,requester:HostUpdateRequester,reply:@escaping HostUpdates.Reply){
        let owner=requester.deviceID.map{String(format:"%02x",$0)}.joined(),id=request.requestId.uuidString
        if let data=try? Data(contentsOf:profile.directory.appendingPathComponent("update-pending.json")),
           let paths=try? JSONDecoder().decode([String:String].self,from:data),let path=paths["journal"],
           let journal=try? HostUpdateJournal.read(URL(fileURLWithPath:path)),journal.owner==owner,journal.requestID==id {
            let phase:[String:String]=["succeeded":"succeeded","failed":"failed","cancelled":"cancelled","installing":"restarting","launching":"restarting","recovering":"restarting"]
            if let status=phase[journal.phase] {reply(HostUpdates.status(request.requestId,phase:status,target:journal.targetBuild,error:journal.error));return}
        }
        guard task==nil || state.requestID==id else{
            reply(HostUpdates.status(request.requestId,phase:"failed",error:"The previous update is still finishing."));return
        }
        if task==nil && state.phase.terminal && state.requestID != id {state=HostUpdateState();replies=[];lastStatus=nil}
        guard allowed,state.begin(id:id,owner:owner) else{reply(HostUpdates.status(request.requestId,phase:"failed",error:"An update is already running or remote updates are disabled."));return}
        if replies.count<32 {replies.append(reply)}
        if let lastStatus {reply(lastStatus)}
        guard task==nil,!state.phase.terminal else{return}
        task=Task { [weak self] in
            guard let self else{return}
            defer{self.task=nil}
            var journalURL:URL?
            do{
                guard let release=self.release else{throw HostUpdateFailure("Install the current host manually first.")}
                self.emit("checking")
                let manifest=try await HostUpdateDownload.latest(release.channel);self.available=manifest;self.publish()
                guard manifest.release.build>release.build,manifest.release.build>=request.minimumBuild else{throw HostUpdateFailure("The matching host update is not available yet.")}
                let installed=Bundle.main.bundleURL.resolvingSymlinksInPath(),parent=installed.deletingLastPathComponent()
                guard FileManager.default.isWritableFile(atPath:parent.path),!installed.path.contains("/AppTranslocation/") else{throw HostUpdateFailure("This installation needs a local update with administrator access.")}
                let dir=parent.appendingPathComponent(".xpromptvs-update-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                // Homebrew caches the verified download before the app quits.
                self.state.advance(.downloading);self.emit("downloading")
                try await HostUpdateDownload.prepare(manifest,installed:installed)
                try Task.checkCancellation()
                self.state.advance(.verifying);self.emit("verifying")
                let authorized=self.authorized(requester)
                guard self.allowed,authorized else{throw HostUpdateFailure("Remote update permission changed.")}
                let helper=dir.appendingPathComponent("XpromptvsUpdate")
                try FileManager.default.copyItem(at:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/XpromptvsUpdate"),to:helper)
                let token=UUID().uuidString,url=dir.appendingPathComponent("journal.json");journalURL=url
                var journal=HostUpdateJournal(token:token,requestID:id,owner:owner,installed:installed.path,channel:release.channel.rawValue,targetBuild:manifest.release.build,oldPID:ProcessInfo.processInfo.processIdentifier,oldLaunch:NSRunningApplication.current.launchDate?.timeIntervalSince1970 ?? 0,profile:ProcessInfo.processInfo.environment["RDEV_APP_PROFILE"],wasSharing:self.host.isSharing,phase:"prepared")
                journal.pairingCarrier = self.host.updatePairingCarrier
                journal.caskVersion = "\(manifest.release.version),\(manifest.release.build)"
                journal.artifactSHA256 = manifest.sha256
                journal.artifactURL = manifest.url.absoluteString
                journal.environment = ProcessInfo.processInfo.environment.filter { ["RDEV_APP_PROFILE","RDEV_E2E_STORE","RDEV_SIGNALING","RDEV_E2E_ORIGIN"].contains($0.key) }
                try journal.write(to:url)
                try JSONEncoder().encode(["journal":url.path]).write(to:self.profile.directory.appendingPathComponent("update-pending.json"),options:.atomic)
                let label="ai.xpromptvs.update."+token.lowercased()
                let plist:[String:Any]=["Label":label,"ProgramArguments":[helper.path,url.path,token],"RunAtLoad":true,"ThrottleInterval":30,"ProcessType":"Interactive","StandardOutPath":dir.appendingPathComponent("installer.log").path,"StandardErrorPath":dir.appendingPathComponent("installer.log").path]
                let job=dir.appendingPathComponent("job.plist");try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:job,options:.atomic)
                try HostUpdateDownload.command("/bin/launchctl",["bootstrap","gui/\(getuid())",job.path])
                let deadline=Date().addingTimeInterval(10)
                while Date()<deadline, (try? HostUpdateJournal.read(url).phase) != "waiting" {try await Task.sleep(for:.milliseconds(100))}
                guard (try? HostUpdateJournal.read(url).phase)=="waiting" else{throw HostUpdateFailure("The independent installer did not start.")}
                try Task.checkCancellation()
                guard self.state.commit(allowed:self.allowed,authorized:self.authorized(requester)) else{throw HostUpdateFailure("Remote update permission changed.")}
                journal.phase="committed";try journal.write(to:url);self.emit("restarting")
                NSApp.terminate(nil)
            }catch{
                if let journalURL,var j=try? HostUpdateJournal.read(journalURL),j.phase != "committed" {j.phase="cancelled";j.pairingCarrier=nil;try? j.write(to:journalURL)}
                let cancelled=error is CancellationError || self.state.phase == .cancelled
                self.state.finish(cancelled ? .cancelled:.failed)
                self.emit(cancelled ? "cancelled":"failed",error:error.localizedDescription)
            }
        }
    }
    /// A new app acknowledges only its own exact installation and the installer's one-use context.
    func acknowledgeRestart() async {
        let args=CommandLine.arguments
        guard let i=args.firstIndex(of:"--rdev-update-journal"),i+1<args.count,
              let t=args.firstIndex(of:"--rdev-update-token"),t+1<args.count else{return}
        let url=URL(fileURLWithPath:args[i+1])
        guard let j=try? HostUpdateJournal.read(url),j.token==args[t+1],j.installed==Bundle.main.bundleURL.resolvingSymlinksInPath().path,
              j.channel==release?.channel.rawValue,["launching","recovering"].contains(j.phase),
              j.phase=="recovering" || j.targetBuild==release?.build else{return}
        if j.wasSharing { await host.startSharing(restoringCarrier:j.pairingCarrier);guard host.isSharing else{return} }
        let ack:[String:Any]=["token":j.token,"build":release?.build ?? 0,"pid":ProcessInfo.processInfo.processIdentifier]
        if let data=try? JSONSerialization.data(withJSONObject:ack){try? data.write(to:url.deletingLastPathComponent().appendingPathComponent("ready.json"),options:.atomic)}
    }
}
