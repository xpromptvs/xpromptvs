#import "RdevWorkspaceKit.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <dlfcn.h>

// Private API stays in this exception boundary, never in the host's Swift models.
@interface CGVirtualDisplayDescriptor : NSObject
@property unsigned int vendorID, productID, serialNum, serialNumber;
@property(copy) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide, maxPixelsHigh;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong) dispatch_queue_t queue;
@end
@interface CGVirtualDisplayMode : NSObject
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(copy) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly) CGDirectDisplayID displayID;
- (id)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static BOOL fail(NSError **error, NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"RdevWorkspaceKit" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
// WindowServer's temporary headless screen disappears when the first CGVirtualDisplay appears.
// This exact vendor/model pair was measured before/after on the macOS 27 headless mini.
static BOOL RWKIsHeadlessFallback(CGDirectDisplayID did) {
    return CGDisplayVendorNumber(did)==0x756e6b6e && CGDisplayModelNumber(did)==0x76697274;
}
static BOOL RWKOnline(CGDirectDisplayID did) {
    CGDirectDisplayID ids[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return NO;
    for(uint32_t i=0;i<count;i++)if(ids[i]==did)return YES;
    return NO;
}
static CGVirtualDisplay *RWKCreateDisplay(NSString *name,unsigned int product,CGSize size,NSError **error) {
    CGVirtualDisplayDescriptor *d=[NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    if(!d){fail(error,@"Virtual display API unavailable.");return nil;}
    unsigned int requestedSerial=arc4random();
    d.name=name;d.vendorID=505;d.productID=product;d.serialNum=requestedSerial;d.serialNumber=d.serialNum;
    d.maxPixelsWide=size.width;d.maxPixelsHigh=size.height;
    d.sizeInMillimeters=CGSizeMake(size.width*338.0/1280,size.height*211.0/800);
    d.redPrimary=CGPointMake(.64,.33);d.greenPrimary=CGPointMake(.3,.6);d.bluePrimary=CGPointMake(.15,.06);
    d.whitePoint=CGPointMake(.3127,.329);d.queue=dispatch_get_main_queue();
    CGVirtualDisplay *display=[[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
    CGVirtualDisplaySettings *settings=[NSClassFromString(@"CGVirtualDisplaySettings") new];settings.hiDPI=0;
    id mode=[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:size.width height:size.height refreshRate:60];
    if(!display||!settings||!mode){fail(error,@"Virtual display API incomplete.");return nil;}
    settings.modes=@[mode];if(![display applySettings:settings]){fail(error,@"Virtual display settings refused.");return nil;}
    CGDirectDisplayID did=display.displayID;
    if(!did){fail(error,@"Virtual display has no identity.");return nil;}
    BOOL ready=NO;
    for(int i=0;i<80;i++){
        if(RWKOnline(did)&&CGSizeEqualToSize(CGDisplayBounds(did).size,size)){ready=YES;break;}
        [NSThread sleepForTimeInterval:.025];
    }
    if(!ready){fail(error,@"Virtual display did not become online at the requested size.");return nil;}
    if([NSProcessInfo.processInfo.environment[@"RDEV_INSTRUMENTS"] isEqualToString:@"1"])
        fprintf(stderr,"[workspace-display] id=%u product=%u requestedSerial=%u legacySerial=%u nativeSerial=%u active=%u asleep=%u\n",did,product,requestedSerial,d.serialNum,CGDisplaySerialNumber(did),CGDisplayIsActive(did),CGDisplayIsAsleep(did));
    return display;
}
BOOL RWKSameProcess(NSDictionary *a, NSDictionary *b) {
    for(NSString *key in @[@"pid",@"generation",@"bundle"])
        if(!a[key] || ![a[key] isEqual:b[key]])return NO;
    return [a[@"pid"] isKindOfClass:NSNumber.class] && [a[@"pid"] intValue]>0 &&
        [a[@"generation"] isKindOfClass:NSString.class] && [a[@"generation"] length]>0 &&
        [a[@"bundle"] isKindOfClass:NSString.class];
}
CGRect RWKClampFrame(CGRect r,CGRect b) {
    r.size.width=MIN(r.size.width,b.size.width);r.size.height=MIN(r.size.height,b.size.height);
    r.origin.x=MAX(b.origin.x,MIN(r.origin.x,CGRectGetMaxX(b)-r.size.width));
    r.origin.y=MAX(b.origin.y,MIN(r.origin.y,CGRectGetMaxY(b)-r.size.height));return r;
}
CGRect RWKInitialFrame(CGRect original, CGRect workspace, NSUInteger index) {
    CGRect bounds=CGRectInset(workspace,24,44);
    // Reserve visible titlebar/body edges for the other selected applications, even when an
    // original window is larger than the virtual display and otherwise clamps to the same origin.
    original.size.width=MIN(original.size.width,1000);
    original.size.height=MIN(original.size.height,620);
    original.origin=CGPointMake(bounds.origin.x+36*(index%6),bounds.origin.y+16*(index%6));
    return RWKClampFrame(original,bounds);
}
NSString *RWKProcessGeneration(pid_t pid) {
    struct proc_bsdinfo info={0};
    if(pid<=0 || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return nil;
    return [NSString stringWithFormat:@"%llu:%llu",info.pbi_start_tvsec,info.pbi_start_tvusec];
}
static NSDictionary *identity(pid_t pid) {
    struct proc_bsdinfo info={0};
    if(pid<=0 || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return nil;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!app || app.terminated)return nil;
    return @{@"pid":@(pid),@"generation":[NSString stringWithFormat:@"%llu:%llu",info.pbi_start_tvsec,info.pbi_start_tvusec],@"bundle":app.bundleIdentifier?:@"",@"name":app.localizedName?:@"Application"};
}
static id readAX(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef value=NULL;
    if(AXUIElementCopyAttributeValue(el,attr,&value)!=kAXErrorSuccess)return nil;
    return CFBridgingRelease(value);
}
static CGRect frameAX(AXUIElementRef el) {
    CGPoint p;CGSize s;id pv=readAX(el,kAXPositionAttribute),sv=readAX(el,kAXSizeAttribute);
    if(!pv||!sv||CFGetTypeID((__bridge CFTypeRef)pv)!=AXValueGetTypeID()||CFGetTypeID((__bridge CFTypeRef)sv)!=AXValueGetTypeID()||
       !AXValueGetValue((__bridge AXValueRef)pv,kAXValueCGPointType,&p)||!AXValueGetValue((__bridge AXValueRef)sv,kAXValueCGSizeType,&s)||
       !isfinite(p.x)||!isfinite(p.y)||!isfinite(s.width)||!isfinite(s.height)||s.width<=0||s.height<=0)return CGRectNull;
    return (CGRect){p,s};
}
static BOOL equalFrame(CGRect a,CGRect b) {
    return !CGRectIsNull(a)&&fabs(a.origin.x-b.origin.x)<2&&fabs(a.origin.y-b.origin.y)<2&&fabs(a.size.width-b.size.width)<2&&fabs(a.size.height-b.size.height)<2;
}
static NSArray *numbers(CGRect r){return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
static CGRect rectangle(NSArray *a){return CGRectMake([a[0] doubleValue],[a[1] doubleValue],[a[2] doubleValue],[a[3] doubleValue]);}
static BOOL windowID(AXUIElementRef el,CGWindowID *wid) {
    typedef AXError (*Fn)(AXUIElementRef,CGWindowID *);
    static Fn fn;static dispatch_once_t once;dispatch_once(&once,^{fn=(Fn)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");});
    @try {return fn && fn(el,wid)==kAXErrorSuccess && *wid!=0;} @catch(NSException *e){return NO;}
}
static NSDictionary *cgWindow(CGWindowID wid) {
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    for(NSDictionary *w in list)if([w[(id)kCGWindowNumber] unsignedIntValue]==wid)return w;
    return nil;
}
static CGRect visibleBounds(CGDirectDisplayID did,CGDirectDisplayID excluded) {
    __block CGRect result=CGRectNull;
    void (^lookup)(void)=^{
        NSScreen *fallback=nil;
        for(NSScreen *s in NSScreen.screens){
            CGDirectDisplayID sid=[s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            if(sid==excluded)continue;
            if(!fallback)fallback=s;
            if(sid==did){fallback=s;break;}
        }
        if(fallback){NSRect r=fallback.visibleFrame;r.origin.y=CGDisplayBounds(CGMainDisplayID()).size.height-NSMaxY(r);result=r;}
    };
    if(NSThread.isMainThread)lookup();
    else {
        // terminateLater can be entered from a main-dispatch block; that serial queue cannot
        // re-enter while AppKit waits. Run-loop work still executes in its nested event loop.
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes,NSDefaultRunLoopMode,NSModalPanelRunLoopMode,NSEventTrackingRunLoopMode] block:^{lookup();dispatch_semaphore_signal(done);}];
        CFRunLoopWakeUp(CFRunLoopGetMain());
        if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))!=0)return CGRectNull;
    }
    return result;
}

@interface RWKRecord:NSObject
@property(strong) id element;
@property(strong) NSMutableDictionary *data;
@end
@implementation RWKRecord @end
@interface RWKWorkspace ()
@property(strong) NSURL *journal;
@property(strong) CGVirtualDisplay *nativeDisplay;
// Headless return desktop. Kept through Restore All, released only with this session owner.
// All placements are restored before normal app teardown releases it back to WindowServer fallback.
@property(strong) CGVirtualDisplay *nativeHomeDisplay;
@property(strong) NSMutableArray<RWKRecord *> *records;
@property(strong) NSMutableDictionary<NSString *,NSDictionary *> *members;
@property(nonatomic,readwrite) CGDirectDisplayID displayID;
@property(nonatomic) NSUInteger windowListDiagnosticCount;
@end
@implementation RWKWorkspace
- (instancetype)initWithJournalURL:(NSURL *)url error:(NSError **)error {
    if(!(self=[super init]))return nil;
    if(!url.isFileURL){fail(error,@"Workspace journal must be a local file.");return nil;}
    _journal=url;_records=[NSMutableArray new];_members=[NSMutableDictionary new];
    if([[NSFileManager defaultManager] fileExistsAtPath:url.path]){
        NSData *data=[NSData dataWithContentsOfURL:url options:0 error:error];if(!data)return nil;
        id saved=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
        if(![saved isKindOfClass:NSArray.class]){fail(error,@"Malformed workspace journal; refusing placement.");return nil;}
        NSUInteger unresolved=0;
        for(id row in saved)if(![row isKindOfClass:NSDictionary.class] || ![@[@"restored",@"closed"] containsObject:row[@"state"]])unresolved++;
        if(unresolved){
            if(error)*error=[NSError errorWithDomain:@"RdevWorkspaceKit" code:1 userInfo:@{
                NSLocalizedDescriptionKey:@"Unresolved workspace journal from an earlier host process. Cold restoration is unavailable; restore windows manually before archiving this journal.",
                @"unresolvedCount":@(unresolved)}];return nil;
        }
    }
    return self;
}
+ (NSArray<NSDictionary *> *)runningApplications {
    NSMutableArray *result=[NSMutableArray new];
    for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications){
        if(app.processIdentifier==getpid()||app.activationPolicy!=NSApplicationActivationPolicyRegular)continue;
        NSDictionary *value=identity(app.processIdentifier);if(value)[result addObject:value];
    }
    return result;
}
- (NSArray<NSDictionary *> *)snapshot {NSMutableArray *a=[NSMutableArray new];for(RWKRecord *r in self.records)[a addObject:[r.data copy]];return a;}
- (CGRect)displayBounds{return self.displayID?CGDisplayBounds(self.displayID):CGRectNull;}
- (BOOL)save:(NSError **)error {
    NSURL *directory=[self.journal URLByDeletingLastPathComponent];
    if(![[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.snapshot options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:self.journal options:NSDataWritingAtomic error:error];
}
- (BOOL)createDisplayWithError:(NSError **)error {
    if(NSThread.isMainThread)return fail(error,@"Workspace display creation requires a serial background queue.");
    if(self.displayID)return YES;
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=27)return fail(error,@"Apps workspace is experimental and currently restricted to macOS 27.");
    @try {
        if(!self.nativeHomeDisplay){
            CGDirectDisplayID ids[32];uint32_t count=0;
            if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return fail(error,@"Home display inventory unavailable.");
            if(count==1 && RWKIsHeadlessFallback(ids[0])){
                CGSize size=CGDisplayBounds(ids[0]).size;
                if(!isfinite(size.width)||!isfinite(size.height)||size.width<320||size.height<200||
                   size.width>8192||size.height>8192)return fail(error,@"Headless home display size is unavailable.");
                CGVirtualDisplay *home=RWKCreateDisplay(@"Xpromptvs Home (Experimental)",79,size,error);
                if(!home)return NO;
                self.nativeHomeDisplay=home;
            }
        }
        CGVirtualDisplay *display=RWKCreateDisplay(@"Xpromptvs Apps (Experimental)",78,CGSizeMake(1280,800),error);
        if(!display)return NO;
        CGDirectDisplayID did=display.displayID;
        self.nativeDisplay=display;self.displayID=did;
    } @catch(NSException *e){return fail(error,[@"Virtual display exception: " stringByAppendingString:e.reason?:@"unknown"]);}
    return YES;
}
- (NSString *)key:(NSDictionary *)app {return [NSString stringWithFormat:@"%@/%@",app[@"pid"],app[@"generation"]];}
- (BOOL)valid:(RWKRecord *)r {
    AXUIElementRef el=(__bridge AXUIElementRef)r.element;pid_t pid=0;CGWindowID wid=0;
    NSDictionary *expected=r.data[@"application"],*actual=identity([expected[@"pid"] intValue]);
    if(!actual||!RWKSameProcess(expected,actual)||AXUIElementGetPid(el,&pid)!=kAXErrorSuccess||pid!=[expected[@"pid"] intValue]||!windowID(el,&wid)||wid!=[r.data[@"window"] unsignedIntValue])return NO;
    NSDictionary *cg=cgWindow(wid);
    return cg && [cg[(id)kCGWindowOwnerPID] intValue]==pid && !CGRectIsNull(frameAX(el));
}
- (BOOL)apply:(RWKRecord *)r frame:(CGRect)frame state:(NSString *)state error:(NSError **)error {
    AXUIElementRef el=(__bridge AXUIElementRef)r.element;
    id minimized=readAX(el,kAXMinimizedAttribute);
    if(![self valid:r]||![minimized isKindOfClass:NSNumber.class]||[minimized boolValue])return fail(error,@"Window identity changed, is inaccessible, or is minimized; placement refused.");
    NSString *previous=r.data[@"state"];
    r.data[@"state"]=@"recorded";if(![self save:error]){r.data[@"state"]=previous;return NO;}
    AXValueRef pos=AXValueCreate(kAXValueCGPointType,&frame.origin),size=AXValueCreate(kAXValueCGSizeType,&frame.size);
    // Moving to the destination display first avoids resizing against the workspace's smaller bounds.
    AXError p=AXUIElementSetAttributeValue(el,kAXPositionAttribute,pos);[NSThread sleepForTimeInterval:.05];
    AXError s=AXUIElementSetAttributeValue(el,kAXSizeAttribute,size),p2=AXUIElementSetAttributeValue(el,kAXPositionAttribute,pos);
    CFRelease(pos);CFRelease(size);
    BOOL matched=NO;
    for(int i=0;i<10;i++){if([self valid:r]&&equalFrame(frameAX(el),frame)){matched=YES;break;}[NSThread sleepForTimeInterval:.025];}
    if(p!=kAXErrorSuccess||s!=kAXErrorSuccess||p2!=kAXErrorSuccess||!matched)return fail(error,@"Application refused window placement/readback; restoration remains pending.");
    r.data[@"state"]=state;
    if([self save:error])return YES;r.data[@"state"]=@"recorded";return NO;
}
- (BOOL)closed:(RWKRecord *)r {
    NSDictionary *app=r.data[@"application"],*live=identity([app[@"pid"] intValue]);
    // A different process generation cannot own the retained window. No mutation of its replacement.
    if(live && !RWKSameProcess(app,live))return YES;
    if(!live && kill([app[@"pid"] intValue],0)==-1 && errno==ESRCH)return YES;
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    if(!all)return NO;
    for(NSDictionary *w in all)if([w[(id)kCGWindowNumber] isEqual:r.data[@"window"]])return NO;
    return YES;
}
- (BOOL)restore:(RWKRecord *)r error:(NSError **)error {
    if([@[@"restored",@"closed"] containsObject:r.data[@"state"]])return YES;
    if([self closed:r]){
        r.data[@"state"]=@"closed";
        if([self save:error])return YES;r.data[@"state"]=@"recorded";return NO;
    }
    CGDirectDisplayID did=[r.data[@"returnDisplay"] unsignedIntValue];
    CGRect bounds=visibleBounds(did,self.displayID);
    if(CGRectIsNull(bounds))return fail(error,@"No physical display available for restoration.");
    CGRect frame=rectangle(r.data[@"returnFrame"]);
    // Existing geometry is preserved on its original display. A disconnected display is clamped.
    if(!CGDisplayIsOnline(did))frame=RWKClampFrame(frame,bounds);
    return [self apply:r frame:frame state:@"restored" error:error];
}
- (BOOL)collectAndMove:(NSDictionary *)app error:(NSError **)error {
    if(!RWKSameProcess(app,identity([app[@"pid"] intValue])))return fail(error,@"Application process changed; select its new instance.");
    for(RWKRecord *r in self.records)
        if(RWKSameProcess(r.data[@"application"],app)&&[r.data[@"state"] isEqual:@"recorded"])
            return fail(error,@"This application has unresolved placement; restore it before adding again.");
    pid_t pid=[app[@"pid"] intValue];AXUIElementRef axApp=AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(axApp,.25);
    CFTypeRef rawWindows=NULL;
    CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
    AXError listResult=kAXErrorCannotComplete;
    unsigned int attempts=0;
    // Display reconfiguration can briefly make a responsive app's AX server busy. Retry only
    // this transient error, before journaling/moving anything, with the same process incarnation.
    for(;attempts<4;){
        if(!RWKSameProcess(app,identity(pid))){CFRelease(axApp);return fail(error,@"Application process changed while listing windows.");}
        attempts++;
        listResult=AXUIElementCopyAttributeValue(axApp,kAXWindowsAttribute,&rawWindows);
        if(listResult!=kAXErrorCannotComplete || attempts==4)break;
        if(rawWindows){CFRelease(rawWindows);rawWindows=NULL;}
        [NSThread sleepForTimeInterval:.025];
    }
    double durationMS=(CFAbsoluteTimeGetCurrent()-began)*1000;
    CFRelease(axApp);
    id windows=CFBridgingRelease(rawWindows);
    BOOL isArray=[windows isKindOfClass:NSArray.class];
    NSUInteger count=isArray?[windows count]:0;
    BOOL sameIdentity=RWKSameProcess(app,identity(pid));
    if([NSProcessInfo.processInfo.environment[@"RDEV_INSTRUMENTS"] isEqualToString:@"1"] && self.windowListDiagnosticCount<120 &&
       (self.windowListDiagnosticCount<20 || listResult!=kAXErrorSuccess || !isArray || count>32 || !sameIdentity)) {
        self.windowListDiagnosticCount++;
        CFTypeID rowType=isArray&&count?CFGetTypeID((__bridge CFTypeRef)[windows objectAtIndex:0]):0;
        fprintf(stderr,"[workspace-placement] AXWindows pid=%d display=%u result=%d attempts=%u durationMS=%.2f array=%d count=%lu valueType=%lu firstRowType=%lu expectedAXType=%lu identitySame=%d\n",
            pid,self.displayID,listResult,attempts,durationMS,isArray,(unsigned long)count,
            (unsigned long)(windows?CFGetTypeID((__bridge CFTypeRef)windows):0),
            (unsigned long)rowType,(unsigned long)AXUIElementGetTypeID(),sameIdentity);
    }
    if(!sameIdentity)return fail(error,@"Application process changed while listing windows.");
    if(listResult!=kAXErrorSuccess)return fail(error,[NSString stringWithFormat:@"Application window list unavailable (AX error %d).",listResult]);
    if(!isArray)return fail(error,@"Application window list returned an invalid accessibility value.");
    if(count>32)return fail(error,@"Application exceeds the experimental 32-window limit.");
    NSMutableArray<RWKRecord *> *fresh=[NSMutableArray new];
    RWKRecord *anchor=nil;
    for(RWKRecord *r in self.records)if(RWKSameProcess(r.data[@"application"],app)&&![ @[@"restored",@"closed"] containsObject:r.data[@"state"]]){anchor=r;break;}
    for(id value in windows){
        if(CFGetTypeID((__bridge CFTypeRef)value)!=AXUIElementGetTypeID())return fail(error,@"Invalid accessibility window list.");
        AXUIElementRef el=(__bridge AXUIElementRef)value;AXUIElementSetMessagingTimeout(el,.25);
        id role=readAX(el,kAXRoleAttribute),subrole=readAX(el,kAXSubroleAttribute);
        // Sheets/dialogs follow their parent. Fullscreen/minimized standard windows are refused.
        if(![role isEqual:(id)kAXWindowRole]||![subrole isEqual:(id)kAXStandardWindowSubrole])continue;
        BOOL known=NO;
        for(RWKRecord *r in self.records)if(RWKSameProcess(r.data[@"application"],app)&&CFEqual((__bridge CFTypeRef)r.element,el)&&![@[@"closed",@"restored"] containsObject:r.data[@"state"]]){known=YES;break;}
        if(known)continue;
        CGRect original=frameAX(el);CGWindowID wid=0;pid_t owner=0;
        id mini=readAX(el,kAXMinimizedAttribute),fullscreen=readAX(el,CFSTR("AXFullScreen"));
        Boolean positionSettable=false,sizeSettable=false;
        if(CGRectIsNull(original)||!windowID(el,&wid)||AXUIElementGetPid(el,&owner)!=kAXErrorSuccess||owner!=pid||
           ![mini isKindOfClass:NSNumber.class]||[mini boolValue]||[fullscreen boolValue]||
           AXUIElementIsAttributeSettable(el,kAXPositionAttribute,&positionSettable)!=kAXErrorSuccess||!positionSettable||
           AXUIElementIsAttributeSettable(el,kAXSizeAttribute,&sizeSettable)!=kAXErrorSuccess||!sizeSettable)
            return fail(error,@"An ordinary window is minimized, fullscreen, inaccessible, or not movable. No new windows were moved.");
        NSDictionary *cg=cgWindow(wid);
        if(!cg||[cg[(id)kCGWindowOwnerPID] intValue]!=pid||[cg[(id)kCGWindowLayer] intValue]!=0||![cg[(id)kCGWindowIsOnscreen] boolValue])return fail(error,@"Window owner, ordinary-window layer, or current-Space visibility could not be established.");
        CGDirectDisplayID displays[16];uint32_t count=0;
        if(CGGetDisplaysWithRect(original,16,displays,&count)!=kCGErrorSuccess||count==0)return fail(error,@"Window has no known original display.");
        CGDirectDisplayID originalDisplay=displays[0];
        RWKRecord *r=[RWKRecord new];r.element=value;
        r.data=[@{@"application":app,@"window":@(wid),@"original":numbers(original),@"display":@(originalDisplay),@"minimized":mini,@"returnFrame":numbers(original),@"returnDisplay":@(originalDisplay),@"state":@"restored",@"identityMode":@"retained-ax-only"} mutableCopy];
        // For windows born in the workspace, use the application's first physical-display anchor.
        if(originalDisplay==self.displayID){
            RWKRecord *home=anchor?:fresh.firstObject;
            if(!home || [home.data[@"returnDisplay"] unsignedIntValue]==self.displayID)return fail(error,@"Workspace-born window has no physical-display restoration anchor.");
            CGDirectDisplayID homeID=[home.data[@"returnDisplay"] unsignedIntValue];CGRect visible=visibleBounds(homeID,self.displayID);
            if(CGRectIsNull(visible))return fail(error,@"New window has no restoration display.");
            CGRect target=original,base=rectangle(home.data[@"returnFrame"]);
            target.origin=CGPointMake(base.origin.x+32*(fresh.count+1),base.origin.y+32*(fresh.count+1));
            r.data[@"returnFrame"]=numbers(RWKClampFrame(target,visible));r.data[@"returnDisplay"]=@(homeID);
        }
        [fresh addObject:r];
    }
    if(!anchor && fresh.count==0)return fail(error,@"No ordinary movable windows are available for this application.");
    if(!fresh.count)return YES;
    [self.records addObjectsFromArray:fresh];
    // All originals are journaled up front. Untouched records remain restored; apply marks
    // each touched record pending BEFORE mutation. Rollback therefore skips untouched windows.
    if(![self save:error]){[self.records removeObjectsInArray:fresh];return NO;}
    NSUInteger index=0;
    for(RWKRecord *existing in self.records)if([existing.data[@"state"] isEqual:@"moved"])index++;
    for(RWKRecord *r in fresh){
        CGRect target=RWKInitialFrame(rectangle(r.data[@"original"]),self.displayBounds,index++);
        if(![self apply:r frame:target state:@"moved" error:error]){
            NSError *moveError=error?*error:nil;BOOL rollback=YES;
            for(RWKRecord *undo in fresh)if(![self restore:undo error:nil])rollback=NO;
            return fail(error,[NSString stringWithFormat:@"%@ %@",moveError.localizedDescription?:@"Placement failed.",rollback?@"New windows restored.":@"Some restoration remains pending; retry Restore All."]);
        }
    }
    return YES;
}
- (BOOL)addApplication:(NSDictionary *)app error:(NSError **)error {
    if(NSThread.isMainThread)return fail(error,@"Workspace placement requires a serial background queue.");
    if(!RWKSameProcess(app,app)||[app[@"pid"] intValue]==getpid())return fail(error,@"Invalid application identity or host-own application.");
    NSRunningApplication *running=[NSRunningApplication runningApplicationWithProcessIdentifier:[app[@"pid"] intValue]];
    if(running.activationPolicy!=NSApplicationActivationPolicyRegular||!RWKSameProcess(app,identity(running.processIdentifier)))return fail(error,@"Only the selected live foreground application is eligible.");
    if(!AXIsProcessTrusted())return fail(error,@"Accessibility permission is required for window placement.");
    if(![self createDisplayWithError:error])return NO;
    if(![self collectAndMove:app error:error])return NO;
    self.members[[self key:app]]=app;return YES;
}
- (BOOL)reconcileWithError:(NSError **)error {
    if(NSThread.isMainThread)return fail(error,@"Workspace reconciliation requires a serial background queue.");
    BOOL ok=YES;
    for(NSDictionary *app in self.members.allValues)if(![self collectAndMove:app error:error])ok=NO;
    return ok;
}
- (BOOL)removeApplication:(NSDictionary *)app error:(NSError **)error {
    if(NSThread.isMainThread)return fail(error,@"Workspace restoration requires a serial background queue.");
    if(!RWKSameProcess(app,app))return fail(error,@"Invalid application identity.");
    // Stop reconciliation immediately, even when restoration needs a retry.
    [self.members removeObjectForKey:[self key:app]];BOOL ok=YES;
    for(RWKRecord *r in self.records)if(RWKSameProcess(r.data[@"application"],app)&&![self restore:r error:error])ok=NO;
    return ok;
}
- (BOOL)restoreAllWithError:(NSError **)error {
    if(NSThread.isMainThread)return fail(error,@"Workspace restoration requires a serial background queue.");
    [self.members removeAllObjects];BOOL ok=YES;
    for(RWKRecord *r in self.records)if(![self restore:r error:error])ok=NO;
    if(!ok)return NO;
    @try {self.nativeDisplay=nil;self.displayID=0;} @catch(NSException *e){return fail(error,@"Virtual display release failed.");}
    return YES;
}
@end
