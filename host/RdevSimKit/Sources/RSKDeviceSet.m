#import "RSKInternal.h"
#import <dlfcn.h>

NSErrorDomain const RSKErrorDomain = @"ai.xpromptvs.RdevSimKit";

NSError *RSKMakeError(RSKErrorCode code, NSString *what) {
    return [NSError errorWithDomain:RSKErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: what}];
}

BOOL RSKGuard(NSError **error, NSString *what, void (NS_NOESCAPE ^body)(void)) {
    @try {
        body();
        return YES;
    } @catch (NSException *e) {
        if (error) *error = RSKMakeError(RSKErrorException, [NSString stringWithFormat:@"%@: %@ (%@)", what, e.name, e.reason]);
        return NO;
    }
}

@interface RSKDeviceInfo ()
@property (nonatomic, readwrite, copy) NSString *udid, *name, *runtimeName;
@property (nonatomic, readwrite) NSInteger state;
@property (nonatomic, readwrite) CGSize screenPixels;
@property (nonatomic, readwrite) double screenScale;
@end
@implementation RSKDeviceInfo
@end

static NSString *const kIOSRuntimePrefix = @"com.apple.CoreSimulator.SimRuntime.iOS-";

/// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0", for a runtime object with no `name`.
static NSString *runtimeNameFromIdentifier(NSString *identifier) {
    NSString *tail = [identifier substringFromIndex:kIOSRuntimePrefix.length];
    return [@"iOS " stringByAppendingString:[tail stringByReplacingOccurrencesOfString:@"-" withString:@"."]];
}

@interface RSKDeviceSet ()
@property (nonatomic, readwrite, copy) NSString *coreSimulatorVersion;
@end

@implementation RSKDeviceSet {
    id _set;   // SimDeviceSet
}

+ (instancetype)loadWithDeveloperDir:(NSString *)developerDir error:(NSError **)error {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    });
    if (!handle) {
        if (error) *error = RSKMakeError(RSKErrorUnavailable, @"CoreSimulator is not installed");
        return nil;
    }
    Class contextClass = NSClassFromString(@"SimServiceContext");
    SEL shared = NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:");
    if (![contextClass respondsToSelector:shared]) {
        if (error) *error = RSKMakeError(RSKErrorUnavailable, @"SimServiceContext has no shared context");
        return nil;
    }
    __block id set = nil;
    __block NSError *inner = nil;
    BOOL ok = RSKGuard(error, @"loading the device set", ^{
        NSError *e = nil;
        id context = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(contextClass, shared, developerDir, &e);
        if (!context) { inner = e; return; }
        set = ((id (*)(id, SEL, NSError **))objc_msgSend)(context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &e);
        if (!set) inner = e;
    });
    if (!ok) return nil;
    if (!set) {
        if (error) *error = inner ?: RSKMakeError(RSKErrorUnavailable, @"no default device set");
        return nil;
    }
    RSKDeviceSet *s = [self new];
    s->_set = set;
    s->_coreSimulatorVersion = [[NSBundle bundleForClass:contextClass] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    return s;
}

- (NSArray *)rawDevices {
    return RSKGet(_set, @"availableDevices") ?: RSKGet(_set, @"devices") ?: @[];   // availableDevices: UNMEASURED
}

- (NSArray<RSKDeviceInfo *> *)iOSDevicesWithError:(NSError **)error {
    NSMutableArray<RSKDeviceInfo *> *out = [NSMutableArray array];
    BOOL ok = RSKGuard(error, @"listing devices", ^{
        for (id d in [self rawDevices]) {
            NSString *runtimeID = RSKGet(d, @"runtimeIdentifier");                // UNMEASURED
            if (![runtimeID isKindOfClass:NSString.class] || ![runtimeID hasPrefix:kIOSRuntimePrefix]) continue;
            NSUUID *uuid = RSKGet(d, @"UDID");
            id type = RSKGet(d, @"deviceType");
            if (!uuid || !type) continue;
            RSKDeviceInfo *info = [RSKDeviceInfo new];
            info.udid = uuid.UUIDString;
            info.name = RSKGet(d, @"name") ?: info.udid;
            NSString *runtimeName = RSKGet(RSKGet(d, @"runtime"), @"name");      // UNMEASURED
            info.runtimeName = [runtimeName isKindOfClass:NSString.class] ? runtimeName : runtimeNameFromIdentifier(runtimeID);
            info.state = (NSInteger)((unsigned long long (*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(@"state"));
            info.screenPixels = ((CGSize (*)(id, SEL))objc_msgSend)(type, NSSelectorFromString(@"mainScreenSize"));
            info.screenScale = ((float (*)(id, SEL))objc_msgSend)(type, NSSelectorFromString(@"mainScreenScale"));
            [out addObject:info];
        }
    });
    return ok ? out : nil;
}

- (id)deviceObject:(NSString *)udid {
    __block id found = nil;
    RSKGuard(NULL, @"finding a device", ^{
        for (id d in [self rawDevices]) {
            if ([[(NSUUID *)RSKGet(d, @"UDID") UUIDString] isEqualToString:udid]) { found = d; return; }
        }
    });
    return found;
}

- (void)bootDevice:(NSString *)udid queue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion {
    id d = [self deviceObject:udid];
    if (!d) { dispatch_async(queue, ^{ completion(RSKMakeError(RSKErrorNoSuchDevice, udid)); }); return; }
    NSError *thrown = nil;
    BOOL ok = RSKGuard(&thrown, @"booting", ^{
        ((void (*)(id, SEL, NSDictionary *, dispatch_queue_t, void (^)(NSError *)))objc_msgSend)(
            d, NSSelectorFromString(@"bootAsyncWithOptions:completionQueue:completionHandler:"), @{}, queue, completion);
    });
    if (!ok) dispatch_async(queue, ^{ completion(thrown); });
}

- (void)shutdownDevice:(NSString *)udid queue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion {
    id d = [self deviceObject:udid];
    if (!d) { dispatch_async(queue, ^{ completion(RSKMakeError(RSKErrorNoSuchDevice, udid)); }); return; }
    NSError *thrown = nil;
    BOOL ok = RSKGuard(&thrown, @"shutting down", ^{
        ((void (*)(id, SEL, dispatch_queue_t, void (^)(NSError *)))objc_msgSend)(
            d, NSSelectorFromString(@"shutdownAsyncWithCompletionQueue:completionHandler:"), queue, completion);
    });
    if (!ok) dispatch_async(queue, ^{ completion(thrown); });
}

@end
