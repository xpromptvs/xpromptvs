// Experimental product compositor. Admission expiry preserves healthy capture generations.
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import RdevCore
import RdevWorkspacePacking

struct CompositionFrame {
    let buffer:CVPixelBuffer
    var pts:Int64
    let screenRect:CGRect?
    let boundingRect:CGRect?
    let windowLocal:Bool
    let contentRect:CGRect?
    let contentScale:CGFloat
    let scaleFactor:CGFloat
    var shadowBuffer:CVPixelBuffer?=nil
    var captureGeneration:UUID?=nil
    var validationPTS:Int64=0
}

private final class CompositionShadowOutput:NSObject,SCStreamOutput {
    let receive:(CVPixelBuffer,Int64)->Void
    init(receive:@escaping(CVPixelBuffer,Int64)->Void){self.receive=receive}
    func stream(_ stream:SCStream,didOutputSampleBuffer sample:CMSampleBuffer,of type:SCStreamOutputType){
        guard type == .screen,let buffer=sample.imageBuffer,
              let a=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              a.first?[.status] as? Int == SCFrameStatus.complete.rawValue else{return}
        receive(buffer,Int64(sample.presentationTimeStamp.seconds*1_000_000_000))
    }
}

final class CompositionLayer: NSObject, SCStreamOutput, SCStreamDelegate {
    let id: UInt32
    let popup: Bool
    var nativeCaptureCount:Int {nativeShadows ? 2 : 1}
    private let windowLocal:Bool
    private let nativeShadows:Bool
    private var shadowStream:SCStream?
    private var shadowOutput:CompositionShadowOutput?
    private var latestBody:CompositionFrame?
    private var latestShadow:CVPixelBuffer?
    private var shadowPTS:Int64=0
    private var stream: SCStream?
    private let lifecycleLock=NSLock()
    private var stopped=false
    private let sampleQueue=DispatchQueue(label:"workspace.layer.samples")
    private let validateSize:((UInt32,CGSize?,Int64)->Bool)?
    private let asyncValidation=true
    private let validationQueue=DispatchQueue(label:"workspace.layer.validation",qos:.userInteractive)
    // sampleQueue owns the mailbox; a blocked query never creates an unbounded sample backlog.
    private var validationMailbox=LatestValidationMailbox<CompositionFrame>()
    private var validationStopped=false
    private var loggedSample=false
    private var loggedAcceptance=false
    private let diagnosticsEnabled=ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1"
    private let onStopped: (Error) -> Void
    private let receive: (UInt32, CompositionFrame) -> Void
    init(window: SCWindow, display: SCDisplay, validateSize:((UInt32,CGSize?,Int64)->Bool)?=nil, onStopped:@escaping(Error)->Void, receive: @escaping (UInt32, CompositionFrame) -> Void) {
        id=window.windowID; popup=window.windowLayer == 101;windowLocal=true;self.receive=receive;self.onStopped=onStopped
        self.validateSize=validateSize
        nativeShadows=false
        super.init()
        let cfg=SCStreamConfiguration()
        cfg.width=windowLocal ? Int(ceil(window.frame.width)) : 1280
        cfg.height=windowLocal ? Int(ceil(window.frame.height)) : 800
        cfg.pixelFormat=kCVPixelFormatType_32BGRA;cfg.colorSpaceName=CGColorSpace.itur_709;cfg.showsCursor=false;cfg.shouldBeOpaque=false
        cfg.queueDepth=8;cfg.includeChildWindows=false;cfg.ignoreShadowsSingleWindow=true
        cfg.minimumFrameInterval=CMTime(value:63,timescale:64*60)
        let filter=windowLocal ? SCContentFilter(desktopIndependentWindow:window) : SCContentFilter(display:display,including:[window])
        filter.includeMenuBar=false
        let stream=SCStream(filter:filter,configuration:cfg,delegate:self);self.stream=stream
        do {try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:sampleQueue)}
        catch {onStopped(error);return}
        Task { [weak self] in
            await SCKGate.shared.enter(.start)
            do {
                if let self,!self.lifecycleLock.withLock({self.stopped}) {
                    try await stream.startCapture()
                    if self.diagnosticsEnabled {FileHandle.standardError.write(Data("[workspace-layer-frame] id=\(self.id) start complete\n".utf8))}
                }
                await SCKGate.shared.leave()
            } catch {await SCKGate.shared.leave();self?.onStopped(error)}
        }
        if nativeShadows {
            let shadowConfig=SCStreamConfiguration()
            shadowConfig.width=1280;shadowConfig.height=800;shadowConfig.pixelFormat=kCVPixelFormatType_32BGRA
            shadowConfig.showsCursor=false;shadowConfig.shouldBeOpaque=false;shadowConfig.queueDepth=8
            shadowConfig.includeChildWindows=false;shadowConfig.capturesShadowsOnly=true
            shadowConfig.minimumFrameInterval=CMTime(value:63,timescale:64*60)
            let shadowFilter=SCContentFilter(display:display,including:[window]);shadowFilter.includeMenuBar=false
            let shadow=SCStream(filter:shadowFilter,configuration:shadowConfig,delegate:self)
            let sink=CompositionShadowOutput{[weak self] buffer,pts in
                guard let self,pts>=self.shadowPTS else{return};self.latestShadow=buffer;self.shadowPTS=pts;self.emit()
            }
            shadowOutput=sink;shadowStream=shadow
            do {try shadow.addStreamOutput(sink,type:.screen,sampleHandlerQueue:sampleQueue)}catch{onStopped(error);return}
            Task { [weak self] in
                await SCKGate.shared.enter(.start)
                do {
                    if let self,!self.lifecycleLock.withLock({self.stopped}) {try await shadow.startCapture()}
                    await SCKGate.shared.leave()
                } catch {await SCKGate.shared.leave();self?.onStopped(error)}
            }
        }
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sample:CMSampleBuffer,of type:SCStreamOutputType) {
        if type == .screen, diagnosticsEnabled, !loggedSample {
            loggedSample=true
            let metadata=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]]
            FileHandle.standardError.write(Data("[workspace-layer-frame] id=\(id) first sample status=\(String(describing: metadata?.first?[.status]))\n".utf8))
        }
        guard type == .screen,let image=sample.imageBuffer,
              let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else{return}
        func rect(_ key:SCStreamFrameInfo)->CGRect? {
            guard let dictionary=attachments.first?[key] as? [String:Any] else{return nil}
            return CGRect(dictionaryRepresentation:dictionary as CFDictionary)
        }
        var frame=CompositionFrame(buffer:image,pts:Int64(sample.presentationTimeStamp.seconds*1_000_000_000),screenRect:rect(.screenRect),boundingRect:rect(.boundingRect),windowLocal:windowLocal,contentRect:rect(.contentRect),contentScale:(attachments.first?[.contentScale] as? NSNumber).map {CGFloat($0.doubleValue)} ?? 1,scaleFactor:(attachments.first?[.scaleFactor] as? NSNumber).map {CGFloat($0.doubleValue)} ?? 1)
        frame.validationPTS=frame.pts
        if asyncValidation,validateSize != nil,windowLocal {
            guard !validationStopped else{return}
            if let next=validationMailbox.submit(frame){validateAsynchronously(next)}
            return
        }
        if let validateSize,windowLocal,!validateSize(id,frame.screenRect?.size,frame.validationPTS){return}
        accept(frame)
    }
    private func validateAsynchronously(_ frame:CompositionFrame){
        validationQueue.async {[weak self] in
            guard let self else{return}
            let accepted=self.validateSize?(self.id,frame.screenRect?.size,frame.validationPTS) ?? false
            self.sampleQueue.async {[weak self] in
                guard let self,!self.validationStopped else{return}
                if accepted {self.accept(frame)}
                if let next=self.validationMailbox.complete(){self.validateAsynchronously(next)}
            }
        }
    }
    private func accept(_ frame:CompositionFrame){
        if diagnosticsEnabled,!loggedAcceptance {
            loggedAcceptance=true
            FileHandle.standardError.write(Data("[workspace-layer-frame] id=\(id) first accepted screen=\(String(describing:frame.screenRect)) content=\(String(describing:frame.contentRect))\n".utf8))
        }
        if latestBody.map({frame.pts >= $0.pts}) ?? true {latestBody=frame;emit()}
    }
    private func emit(){
        guard var frame=latestBody else{return}
        frame.shadowBuffer=latestShadow;frame.pts=max(frame.pts,shadowPTS);receive(id,frame)
    }
    func stream(_ stream:SCStream,didStopWithError error:Error){onStopped(error)}
    func stop(completion:@escaping()->Void = {}){
        lifecycleLock.withLock {stopped=true}
        sampleQueue.async {[weak self] in
            self?.validationStopped=true;self?.validationMailbox.cancel();self?.latestBody=nil
        }
        let captures=[stream,shadowStream].compactMap {$0};stream=nil;shadowStream=nil
        guard !captures.isEmpty else{completion();return}
        Task {
            await SCKGate.shared.enter(.still)
            for capture in captures {try? await capture.stopCapture()}
            await SCKGate.shared.leave()
            DispatchQueue.main.async(execute:completion)
        }
    }
}

final class WorkspaceCompositor {
    private var loggedCatalogIDs = Set<UInt32>()
    private let validationLock=NSLock()
    private let sizeLeaseSeconds:Double=0.100
    private var sizeLeases:[UUID:ResizeRejectionLease]=[:]
    private var admissionCutoffs:[UUID:Int64]=[:]
    private var sizeLeaseIDs:[UUID:UInt32]=[:]
    private var loggedValidation = Set<UUID>() // under validationLock; bounded instrument output
    private let lock=NSLock()
    private let queue=DispatchQueue(label:"workspace.compose")
    private let context=CIContext(options:[.useSoftwareRenderer:false])
    private let output:(CVPixelBuffer,CVPixelBuffer?,Int64)->Void
    private let onFailure:(String)->Void
    private let carriesMask=true
    private let derivedShadows=true
    private var layers:[UInt32:CompositionLayer]=[:]
    private var frameStore=CompositionFrameStore<CompositionFrame>()
    private var sceneFence=CompositionSceneFence()
    private var obsoleteCompositions=0
    private var missingGeometry=0
    private var absentSince:[UInt32:Double]=[:]
    private var retiring:[UInt32:CompositionLayer]=[:]
    private var reclaimed=0
    private var rejectedCallbacks=0
    private var unexpectedStops=0
    private var expectedWindowClosures=0
    private var restartedStreams=0
    private var generations:[UInt32:UUID]=[:]
    private var startedAt:[UInt32:Double]=[:]
    private var recovery:[UInt32:CaptureRestart]=[:]
    private var retryAfter:[UInt32:Double]=[:]
    private var blocked:Set<UInt32>=[]
    private let reclaim=true
    private var order:[UInt32]=[]
    private var rects:[UInt32:CGRect]=[:]
    private var pending:(CVPixelBuffer,Int64)?
    private var latestBase:(CVPixelBuffer,Int64)?
    private var timer:DispatchSourceTimer?
    private var stopped=false
    private var pool:CVPixelBufferPool?
    private var shadowCache:[UInt32:(key:String,image:CIImage)]=[:]
    private var shadowCacheHits=0
    private var shadowCacheMisses=0
    private var shadowRenderFailures=0
    private var coalesced=0
    private var origin=CGPoint.zero
    private var menuHeight:CGFloat=0
    init(onFailure:@escaping(String)->Void,output:@escaping(CVPixelBuffer,CVPixelBuffer?,Int64)->Void){
        self.output=output;self.onFailure=onFailure
        CVPixelBufferPoolCreate(nil,nil,[kCVPixelBufferWidthKey:1280,kCVPixelBufferHeightKey:800,
            kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&pool)
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:1.0/60)
        timer.setEventHandler {[weak self] in self?.expireResizeLeases();self?.drain()};self.timer=timer;timer.resume()
    }
    // Main queue: all eligible display windows, independent of selected-app membership.
    func update(content:SCShareableContent,display:SCDisplay,origin:CGPoint,menuHeight:CGFloat){
        let list=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        let byID=Dictionary(uniqueKeysWithValues:content.windows.map {($0.windowID,$0)})
        var windows:[SCWindow]=[]
        let bounds=CGRect(origin:origin,size:CGSize(width:1280,height:800))
        let logCatalog = ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1"
        for info in list {
            guard let id=info[kCGWindowNumber as String] as? UInt32,let w=byID[id],
                  let app=w.owningApplication,
                  !SelfCapture.isOwnWindow(ownerPID:app.processID,selfPID:ProcessInfo.processInfo.processIdentifier),
                  w.windowLayer != Int(CGWindowLevelForKey(.mainMenuWindow)),
                  w.frame.width>0,w.frame.height>0,w.frame.intersects(bounds) else {continue}
            let background = WorkspaceBackgroundPolicy.excludes(bundleID: app.bundleIdentifier,
                layer: w.windowLayer, frame: w.frame, display: bounds)
            if logCatalog, loggedCatalogIDs.count < 100, loggedCatalogIDs.insert(id).inserted {
                let line = "[workspace-layer] id=\(id) pid=\(app.processID) bundle=\(app.bundleIdentifier) layer=\(w.windowLayer) frame=\(w.frame) background=\(background)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            guard !background else { continue }
            windows.append(w)
        }
        guard windows.count <= 48 else {onFailure("Workspace has more than 48 visible native layers");return}
        // Window-local capture allocates the entire native window, including its off-display part.
        // Bound that allocation explicitly in this experimental fixed-size workspace.
        guard windows.allSatisfy({ $0.frame.width.isFinite && $0.frame.height.isFinite &&
            $0.frame.width <= 3840 && $0.frame.height <= 2160 }) else {
            onFailure("Workspace native window exceeds the experimental 3840×2160 capture limit");return
        }
        lock.lock()
        let newOrder=windows.map(\.windowID),newRects=Dictionary(uniqueKeysWithValues:windows.map {($0.windowID,$0.frame)})
        if self.origin != origin || order != newOrder || rects != newRects || self.menuHeight != menuHeight {
            sceneFence.invalidate()
            if let base=latestBase {pending=base}
        }
        self.origin=origin;self.menuHeight=menuHeight;order=newOrder;rects=newRects;lock.unlock()
        let all=CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]]
        let existing=all.map {Set($0.compactMap {$0[kCGWindowNumber as String] as? UInt32})}
        let now=CFAbsoluteTimeGetCurrent()
        for id in layers.keys {
            if existing == nil || existing!.contains(id){absentSince.removeValue(forKey:id)}
            else if absentSince[id] == nil {absentSince[id]=now}
        }
        if reclaim {
            for id in Array(layers.keys) where now-(absentSince[id] ?? now)>0.5 {
                guard let layer=layers.removeValue(forKey:id) else{continue}
                absentSince.removeValue(forKey:id);retiring[id]=layer
                if let retiredGeneration=generations.removeValue(forKey:id) {
                    validationLock.lock();sizeLeases.removeValue(forKey:retiredGeneration);sizeLeaseIDs.removeValue(forKey:retiredGeneration);admissionCutoffs.removeValue(forKey:retiredGeneration);validationLock.unlock()
                }
                startedAt.removeValue(forKey:id)
                recovery.removeValue(forKey:id);retryAfter.removeValue(forKey:id);blocked.remove(id)
                lock.lock();frameStore.retire(id);sceneFence.invalidate();lock.unlock()
                layer.stop {[weak self] in DispatchQueue.main.async {
                    guard let self else{return};self.retiring.removeValue(forKey:id);self.reclaimed += 1
                }}
            }
        }
        let newWindows=windows.filter {layers[$0.windowID] == nil && retiring[$0.windowID] == nil}
        // Hidden live windows retain their streams and retiring streams still own native resources.
        // Counting only visible windows silently omitted new windows at capacity.
        guard layers.count+retiring.count+newWindows.count <= 48 else {
            onFailure("Workspace capture capacity is exhausted by active and retiring native layers");return
        }
        for window in newWindows {
            guard !blocked.contains(window.windowID),now >= (retryAfter[window.windowID] ?? 0) else{continue}
            if recovery[window.windowID]?.attempts ?? 0 > 0 {restartedStreams += 1}
            retryAfter.removeValue(forKey:window.windowID)
            lock.lock();let generation=frameStore.begin(window.windowID);lock.unlock()
            generations[window.windowID]=generation;startedAt[window.windowID]=now
            let seconds=sizeLeaseSeconds
            do {
                validationLock.lock();sizeLeases[generation]=ResizeRejectionLease(timeout:seconds);sizeLeaseIDs[generation]=window.windowID;validationLock.unlock()
            }
            layers[window.windowID]=CompositionLayer(window:window,display:display,validateSize: { [weak self] id,size,pts in self?.validateCaptureSize(id,generation:generation,ownerPID:window.owningApplication?.processID,size,pts:pts) ?? false },onStopped:{[weak self] error in
                DispatchQueue.main.async {self?.layerFailed(window.windowID,generation:generation,error:error)}
            }){[weak self] id,frame in
                guard let self else{return};self.lock.lock()
                var frame=frame;frame.captureGeneration=generation
                guard !self.stopped,self.frameStore.receive(frame,id:id,generation:generation,timestamp:frame.validationPTS) else{self.rejectedCallbacks += 1;self.lock.unlock();return}
                self.lock.unlock()
                self.layerChanged(pts:frame.pts)
            }
        }
    }
    // Main queue, fenced to the capture generation which actually failed.
    private func layerFailed(_ id:UInt32,generation:UUID,error:Error){
        guard !stopped,generations[id]==generation,let layer=layers.removeValue(forKey:id) else{return}
        generations.removeValue(forKey:id)
        validationLock.lock();sizeLeases.removeValue(forKey:generation);sizeLeaseIDs.removeValue(forKey:generation);admissionCutoffs.removeValue(forKey:generation);validationLock.unlock()
        let began=startedAt.removeValue(forKey:id),now=CFAbsoluteTimeGetCurrent()
        lock.lock();frameStore.retire(id);sceneFence.invalidate();pending=latestBase;lock.unlock()
        retiring[id]=layer
        let all=CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]]
        let gone=all.map {!$0.contains(where:{$0[kCGWindowNumber as String] as? UInt32 == id})} ?? false
        let code=(error as NSError).code
        if gone {
            expectedWindowClosures += 1
            recovery.removeValue(forKey:id);retryAfter.removeValue(forKey:id);blocked.remove(id)
        } else {
            unexpectedStops += 1
            var policy=recovery[id] ?? CaptureRestart()
            if let delay=policy.next(code:code,ranFor:began.map {now-$0}) {retryAfter[id]=now+delay}
            else {blocked.insert(id)}
            recovery[id]=policy
        }
        print("COMPOSITOR stopped \(id) gone=\(gone) retry=\(retryAfter[id] != nil) \(error)")
        layer.stop {[weak self] in DispatchQueue.main.async {
            guard let self else{return};self.retiring.removeValue(forKey:id);self.reclaimed += 1
        }}
    }
    func submit(base:CVPixelBuffer,pts:Int64){
        lock.lock();guard !stopped else{lock.unlock();return}
        latestBase=(base,max(pts,latestBase?.1 ?? pts))
        if pending != nil {coalesced += 1};pending=latestBase
        lock.unlock()
    }
    private func layerChanged(pts:Int64){
        lock.lock()
        guard !stopped,let base=latestBase else{lock.unlock();return}
        latestBase=(base.0,max(base.1,pts))
        if pending != nil {coalesced += 1};pending=latestBase
        lock.unlock()
    }
    private func drain(){
        while true {
            lock.lock()
            guard let (base,_)=pending else{lock.unlock();return}
            pending=nil;let ids=order,frames=frameStore.frames,origin=self.origin,revision=sceneFence.revision,menuHeight=self.menuHeight
            lock.unlock()
            var composed=CIImage(color:.clear).cropped(to:CGRect(x:0,y:0,width:1280,height:800))
            shadowCache=shadowCache.filter {ids.contains($0.key)}
            var used=0
            var hitRects=[CGRect(x:0,y:0,width:1280,height:menuHeight)]
            for id in ids.reversed(){
                guard let frame=frames[id] else{continue}
                let buffer=frame.buffer
                var layer=CIImage(cvPixelBuffer:buffer)
                if frame.windowLocal {
                    guard let rect=frame.screenRect,let content=frame.contentRect,rect.width>0,rect.height>0,
                          content.width>0,content.height>0,frame.contentScale>0,frame.scaleFactor>0 else{missingGeometry += 1;continue}
                    let surface=content.applying(CGAffineTransform(scaleX:frame.scaleFactor,y:frame.scaleFactor))
                    let bodySize=CGSize(width:rect.width*frame.contentScale*frame.scaleFactor,height:rect.height*frame.contentScale*frame.scaleFactor)
                    let body=CGRect(origin:surface.origin,size:bodySize)
                    let from=CGPoint(x:body.minX,y:CGFloat(CVPixelBufferGetHeight(buffer))-body.maxY)
                    layer=layer.transformed(by:CGAffineTransform(translationX:-from.x,y:-from.y))
                        .transformed(by:CGAffineTransform(scaleX:rect.width/body.width,y:rect.height/body.height))
                        .transformed(by:CGAffineTransform(translationX:rect.minX-origin.x,y:800-(rect.maxY-origin.y)))
                }
                if carriesMask {
                    guard frame.windowLocal,let rect=frame.screenRect else{missingGeometry += 1;continue}
                    hitRects.append(rect.offsetBy(dx:-origin.x,dy:-origin.y))
                }
                if let shadow=frame.shadowBuffer {composed=CIImage(cvPixelBuffer:shadow).composited(over:composed)}
                if derivedShadows,frame.windowLocal,let rect=frame.screenRect {
                    let bodyRect=CGRect(x:rect.minX-origin.x,y:800-(rect.maxY-origin.y),width:rect.width,height:rect.height)
                    let signature=RdevWorkspaceAlphaSignature(buffer)
                    let key="\(rect.width),\(rect.height),\(frame.contentScale),\(frame.scaleFactor),\(CVPixelBufferGetWidth(buffer)),\(CVPixelBufferGetHeight(buffer)),\(String(describing:frame.contentRect)),\(signature)"
                    let localShadow:CIImage
                    if signature==0 {localShadow=CIImage(color:.clear).cropped(to:.zero);shadowRenderFailures += 1}
                    else if let cached=shadowCache[id],cached.key==key {localShadow=cached.image;shadowCacheHits += 1}
                    else {
                        let localBody=layer.transformed(by:CGAffineTransform(translationX:-bodyRect.minX,y:-bodyRect.minY))
                        let black=localBody.applyingFilter("CIColorMatrix",parameters:[
                            "inputRVector":CIVector(x:0,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:0,z:0,w:0),
                            "inputBVector":CIVector(x:0,y:0,z:0,w:0),"inputAVector":CIVector(x:0,y:0,z:0,w:0.45)])
                        let cutout=CIImage(color:CIColor(red:0,green:0,blue:0,alpha:1)).cropped(to:CGRect(origin:.zero,size:rect.size))
                        let shadow=black.applyingFilter("CIGaussianBlur",parameters:["inputRadius":10])
                            .applyingFilter("CISourceOutCompositing",parameters:[kCIInputBackgroundImageKey:cutout])
                        let extent=CGRect(x:-40,y:-40,width:ceil(rect.width)+80,height:ceil(rect.height)+80)
                        if let image=context.createCGImage(shadow,from:extent) {
                            localShadow=CIImage(cgImage:image).transformed(by:CGAffineTransform(translationX:-40,y:-40))
                            shadowCache[id]=(key,localShadow);shadowCacheMisses += 1
                        } else {
                            localShadow=CIImage(color:.clear).cropped(to:.zero);shadowRenderFailures += 1
                        }
                    }
                    composed=localShadow.transformed(by:CGAffineTransform(translationX:bodyRect.minX,y:bodyRect.minY)).composited(over:composed)
                }
                composed=layer.composited(over:composed);used += 1
            }
            // Existing application stream supplies only the native menu-bar band, not app content.
            let bar=CIImage(cvPixelBuffer:base).cropped(to:CGRect(x:0,y:800-menuHeight,width:1280,height:menuHeight))
            composed=bar.composited(over:composed)
            var result:CVPixelBuffer?
            guard let pool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&result)==kCVReturnSuccess,let result else{onFailure("Workspace composition allocation failed");return}
            context.render(composed,to:result,bounds:CGRect(x:0,y:0,width:1280,height:800),colorSpace:CGColorSpace(name:CGColorSpace.itur_709))
            expireResizeLeases()
            lock.lock();let obsolete=stopped || !sceneFence.accepts(revision);lock.unlock()
            if obsolete {obsoleteCompositions += 1;return}
            // The timestamp represents assembly of this composite scene, not one layer's older PTS.
            let scenePTS=Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds*1_000_000_000)
            let mask=carriesMask ? WorkspaceHitMask.make(regions:hitRects) : nil
            if carriesMask && mask == nil {onFailure("Workspace input-mask allocation failed");return}
            // Mask construction and diagnostic readback can cross the lease deadline too.
            expireResizeLeases()
            lock.lock();let stillCurrent = !stopped && sceneFence.accepts(revision);lock.unlock()
            guard stillCurrent else{obsoleteCompositions += 1;return}
            output(result,mask,scenePTS)
            return
        }
    }
    // Compose queue watchdog invalidates pixels and hit state, not a healthy SCStream.
    private func expireResizeLeases(){
        let now=ProcessInfo.processInfo.systemUptime
        var expirations:[(UInt32,UUID)]=[]
        validationLock.lock()
        for generation in Array(sizeLeases.keys) {
            guard var lease=sizeLeases[generation],let id=sizeLeaseIDs[generation] else{continue}
            if lease.takeExpiry(now:now) {expirations.append((id,generation));admissionCutoffs[generation]=Int64(now*1_000_000_000)}
            sizeLeases[generation]=lease
        }
        validationLock.unlock()
        for (id,generation) in expirations {
            lock.lock()
            _ = frameStore.discard(id,generation:generation,before:Int64(now*1_000_000_000))
            // Even if a newer frame won the store race, an IN-FLIGHT composite may still hold
            // its expired predecessor. Keep the fresh store entry but invalidate that snapshot.
            sceneFence.invalidate();pending=latestBase
            lock.unlock()
        }
    }
    private func validateCaptureSize(_ id:UInt32,generation:UUID,ownerPID:Int32?,_ captured:CGSize?,pts:Int64)->Bool {
        let started=ProcessInfo.processInfo.systemUptime
        validationLock.lock()
        guard var lease=sizeLeases[generation] else{validationLock.unlock();return false}
        if lease.expired,pts>(admissionCutoffs[generation] ?? Int64.max) {lease=ResizeRejectionLease(timeout:lease.timeout)}
        _=lease.observe(accepted:false,now:started);sizeLeases[generation]=lease
        validationLock.unlock()
        if lease.expired {return false}
        let info=CGWindowListCopyWindowInfo(.optionIncludingWindow,id) as? [[String:Any]] ?? []
        let window=info.first{($0[kCGWindowNumber as String] as? UInt32)==id}
        let current=(window?[kCGWindowBounds as String] as? [String:Any]).flatMap{CGRect(dictionaryRepresentation:$0 as CFDictionary)?.size}
        let currentPID=window?[kCGWindowOwnerPID as String] as? Int32
        var accepted=current != nil && current==captured && currentPID==ownerPID && !SelfCapture.isOwnWindow(ownerPID:currentPID,selfPID:ProcessInfo.processInfo.processIdentifier)
        validationLock.lock()
        if pts <= (admissionCutoffs[generation] ?? 0) {accepted=false}
        if var currentLease=sizeLeases[generation] {accepted=currentLease.observe(accepted:accepted,now:ProcessInfo.processInfo.systemUptime);sizeLeases[generation]=currentLease}
        else {accepted=false}
        let logValidation = ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1" && loggedValidation.count < 100 && loggedValidation.insert(generation).inserted
        validationLock.unlock()
        if logValidation {FileHandle.standardError.write(Data("[workspace-layer-validation] id=\(id) captured=\(String(describing:captured)) current=\(String(describing:current)) pid=\(String(describing:currentPID)) expectedPID=\(String(describing:ownerPID)) accepted=\(accepted)\n".utf8))}
        return accepted
    }
    /// Used by the injector immediately before posting. Clear an expired admission even if the
    /// compose queue has not yet produced/encoded its transparent replacement frame.
    func acceptsInput(x: Double, y: Double) -> Bool {
        expireResizeLeases()
        lock.lock(); defer { lock.unlock() }
        guard !stopped, latestBase != nil else { return false }
        if y >= 0 && y < menuHeight && x >= 0 && x < 1280 { return true }
        let point = CGPoint(x: x + origin.x, y: y + origin.y)
        return order.contains { id in frameStore.frames[id]?.screenRect?.contains(point) == true }
    }
    // Called on main; callbacks and compositor output are fenced before native stops complete.
    func stop(){
        timer?.cancel();timer=nil
        lock.lock();stopped=true;pending=nil;latestBase=nil;lock.unlock()
        validationLock.lock();sizeLeases.removeAll();sizeLeaseIDs.removeAll();admissionCutoffs.removeAll();validationLock.unlock()
        for layer in layers.values{layer.stop()};layers.removeAll()
        for layer in retiring.values{layer.stop()};retiring.removeAll()
    }
}
