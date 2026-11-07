import Foundation
import RdevCore
import RdevWorkspaceKit

/// Session lifetime owner. All AX/display operations run off main on one serial queue.
final class AppWorkspaceCoordinator: @unchecked Sendable {
    private let queue=DispatchQueue(label:"rdev.apps.placement")
    private let lock=NSLock()
    private var native:RWKWorkspace?
    private var quitting=false
    private var captureError:String?
    private var identities:[String:[AnyHashable:Any]]=[:]
    private var tokens:[String:String]=[:]
    private var state=WorkspaceSnapshot()
    private var display:UInt32=0
    private let source="apps:"+UUID().uuidString
    private var timer:DispatchSourceTimer?
    var onStateChanged:(@Sendable(WorkspaceSnapshot)->Void)?
    func displayID(for sourceID:String)->UInt32? {lock.withLock {state.source==sourceID && display != 0 ? display : nil}}
    func snapshot()->WorkspaceSnapshot {lock.withLock {state}}
    func captureStatus(_ error:String?) {
        queue.async { [self] in
            let previous=captureError;captureError=error;var next=snapshot()
            if let error {next.error=error;next.availability="failed"}
            else if next.error==previous {next.error=nil;next.availability="available"}
            lock.withLock {state=next};onStateChanged?(next)
        }
    }
    func request(_ action:String,app:String?,completion:@escaping @Sendable(WorkspaceSnapshot)->Void) {
        queue.async { [self] in
            var next=snapshot()
            if action=="quit",native==nil {quitting=true;next.error=nil;completion(next);return}
            do {
                if action=="quit" {quitting=true}
                if action=="add",next.recoveryCount>0 {throw NSError(domain:"Apps",code:3,userInfo:[NSLocalizedDescriptionKey:"Restore unresolved app windows before adding more applications"])}
                if action=="add",quitting {throw NSError(domain:"Apps",code:2,userInfo:[NSLocalizedDescriptionKey:"Host is quitting"])}
                // Keep live restoration callable if this gate changes while an owner still exists.
                // A disabled request must not construct an adapter, display or journal.
                let cleanup = native != nil && ["remove", "restore-all", "quit"].contains(action)
                guard cleanup || (ApplicationCaptureFeature.enabled && ProcessInfo.processInfo.environment["RDEV_APPS_EXPERIMENTAL"]=="1") else{completion(next);return}
                if native==nil {
                    let root=ProcessInfo.processInfo.environment["RDEV_APPS_JOURNAL_DIR"].map {URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Xpromptvs/ExperimentalApps",isDirectory:true)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    native=try RWKWorkspace(journalURL:root.appendingPathComponent("placement.json"))
                }
                guard let native else{return}
                var inventory:[WorkspaceApp]=[]
                for identity in RWKWorkspace.runningApplications() {
                    let key="\(identity["pid"] ?? ""):\(identity["generation"] ?? "")"
                    let token=tokens[key] ?? UUID().uuidString;tokens[key]=token;identities[token]=identity
                    inventory.append(WorkspaceApp(id:token,name:identity["name"] as? String ?? "Application",bundleID:identity["bundle"] as? String,processID:(identity["pid"] as? NSNumber)?.int32Value))
                }
                next.applications=inventory
                if action != "list" || next.error==nil {next.availability="available";next.error=nil}
                if action=="add" || action=="remove" {
                    guard let app,let identity=identities[app],let description=(inventory.first(where:{$0.id==app}) ?? (action=="remove" ? next.members.first(where:{$0.app.id==app})?.app : nil)) else{throw NSError(domain:"Apps",code:1,userInfo:[NSLocalizedDescriptionKey:"Application instance is no longer available"])}
                    if action=="add" {try native.createDisplay();try native.addApplication(identity);next.members.removeAll{$0.app.id==app};next.members.append(WorkspaceMember(app:description,phase:"shared"))}
                    else {try native.removeApplication(identity);next.members.removeAll{$0.app.id==app};if next.members.isEmpty {try native.restoreAll()}}
                } else if action=="restore-all" || action=="quit" {try native.restoreAll();next.members=[]}
                if next.error==nil {next.recoveryCount=0}
                next.source=next.members.isEmpty ? nil : source
                lock.withLock {display=native.displayID;state=next}
                if timer==nil {
                    let timer=DispatchSource.makeTimerSource(queue:queue);timer.schedule(deadline:.now()+1,repeating:1)
                    timer.setEventHandler { [weak self] in
                        guard let self,!self.snapshot().members.isEmpty else{return}
                        do {try self.native?.reconcile()}catch {
                            var s=self.snapshot();s.error=error.localizedDescription;s.availability="failed"
                            s.members=s.members.map {member in member.phase=="shared" ? WorkspaceMember(app:member.app,phase:"failed",error:s.error) : member}
                            self.lock.withLock{self.state=s};self.onStateChanged?(s)
                        }
                    };self.timer=timer;timer.resume()
                }
            } catch {
                FileHandle.standardError.write(Data("[workspace-placement] action=\(action) error=\(error.localizedDescription)\n".utf8))
                if action=="quit" {quitting=false}
                next.error=error.localizedDescription;next.availability="failed"
                if native==nil,let count=(error as NSError).userInfo["unresolvedCount"] as? Int {next.recoveryCount=count}
                if (action=="add" || action=="remove"),let app,
                   let description=next.applications.first(where:{$0.id==app}) ?? next.members.first(where:{$0.app.id==app})?.app {
                    next.members.removeAll{$0.app.id==app}
                    next.members.append(WorkspaceMember(app:description,phase:"failed",error:next.error))
                }
                if let native {
                    next.recoveryCount=native.snapshot.filter {row in
                        guard ["recorded","moved"].contains(row["state"] as? String ?? ""),let identity=row["application"] as? [AnyHashable:Any] else{return false}
                        return !next.members.contains {member in
                            guard member.phase=="shared",let expected=identities[member.app.id] else{return false}
                            return RWKSameProcess(expected,identity)
                        }
                    }.count
                    lock.withLock {display=native.displayID}
                }
                lock.withLock{state=next}
            }
            completion(snapshot())
        }
    }
}
