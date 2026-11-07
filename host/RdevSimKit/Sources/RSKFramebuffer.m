#import "RSKInternal.h"

static NSString *const kScreenRegister =
    @"registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:";

@interface RSKFramebuffer ()
@property (nonatomic, readwrite, copy) NSString *callbackPath;
@end

@implementation RSKFramebuffer {
    id _descriptor;   // the main display's ROCKRemoteProxy
    NSUUID *_token;
    BOOL _attached;
}

/// The main display: the IO port whose descriptor renders an IOSurface and has `state.displayClass == 0`.
static id mainDisplay(id device) {
    NSArray *ports = RSKGet(RSKGet(device, @"io"), @"ioPorts");
    for (id port in ports) {
        id descriptor = RSKGet(port, @"descriptor");
        if (![descriptor respondsToSelector:NSSelectorFromString(@"framebufferSurface")]) continue;
        id state = RSKGet(descriptor, @"state");
        if (![state respondsToSelector:NSSelectorFromString(@"displayClass")]) continue;
        unsigned short cls = ((unsigned short (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"displayClass"));
        if (cls == 0) return descriptor;
    }
    return nil;
}

+ (instancetype)attachToDevice:(NSString *)udid inSet:(RSKDeviceSet *)set queue:(dispatch_queue_t)queue
                surfaceChanged:(void (^)(IOSurfaceRef))surfaceChanged framePresented:(void (^)(void))framePresented
             propertiesChanged:(void (^)(void))propertiesChanged error:(NSError **)error {
    id device = [set deviceObject:udid];
    if (!device) { if (error) *error = RSKMakeError(RSKErrorNoSuchDevice, udid); return nil; }
    if (((unsigned long long (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"state")) != 3) {
        if (error) *error = RSKMakeError(RSKErrorNotBooted, udid);
        return nil;
    }
    RSKFramebuffer *fb = [self new];
    fb->_token = [NSUUID UUID];
    __block BOOL found = NO;
    BOOL ok = RSKGuard(error, @"attaching to the main display", ^{
        id d = mainDisplay(device);
        if (!d) return;
        found = YES;
        fb->_descriptor = d;
        if ([d respondsToSelector:NSSelectorFromString(kScreenRegister)]) {
            fb->_callbackPath = @"screen";
            ((void (*)(id, SEL, NSUUID *, dispatch_queue_t, void (^)(void), void (^)(id, id), void (^)(id)))objc_msgSend)(
                d, NSSelectorFromString(kScreenRegister), fb->_token, queue,
                ^{ framePresented(); },
                ^(id surface, id masked) { surfaceChanged((__bridge IOSurfaceRef)surface); },
                ^(id properties) { propertiesChanged(); });
        } else {
            fb->_callbackPath = @"legacy";
            ((void (*)(id, SEL, NSUUID *, void (^)(id)))objc_msgSend)(
                d, NSSelectorFromString(@"registerCallbackWithUUID:ioSurfacesChangeCallback:"), fb->_token,
                ^(id surface) { dispatch_async(queue, ^{ surfaceChanged((__bridge IOSurfaceRef)surface); }); });
            ((void (*)(id, SEL, NSUUID *, void (^)(NSArray *)))objc_msgSend)(
                d, NSSelectorFromString(@"registerCallbackWithUUID:damageRectanglesCallback:"), fb->_token,
                ^(NSArray *rects) { dispatch_async(queue, ^{ framePresented(); }); });
        }
        fb->_attached = YES;
        // The surface the display ALREADY holds — the callbacks report changes, and a static screen has none.
        id now = RSKGet(d, @"framebufferSurface");
        if (now) dispatch_async(queue, ^{ surfaceChanged((__bridge IOSurfaceRef)now); });
    });
    if (!ok) return nil;
    if (!found) { if (error) *error = RSKMakeError(RSKErrorNoScreen, udid); return nil; }
    return fb;
}

- (void)detach {
    if (!_attached) return;
    _attached = NO;
    id d = _descriptor;
    NSUUID *token = _token;
    RSKGuard(NULL, @"detaching", ^{
        if ([self.callbackPath isEqualToString:@"screen"]) {
            ((void (*)(id, SEL, NSUUID *))objc_msgSend)(d, NSSelectorFromString(@"unregisterScreenCallbacksWithUUID:"), token);
        } else {
            ((void (*)(id, SEL, NSUUID *))objc_msgSend)(d, NSSelectorFromString(@"unregisterIOSurfacesChangeCallbackWithUUID:"), token);
            ((void (*)(id, SEL, NSUUID *))objc_msgSend)(d, NSSelectorFromString(@"unregisterDamageRectanglesCallbackWithUUID:"), token);
        }
    });
}

- (void)dealloc { [self detach]; }

@end
