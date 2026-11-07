// RdevSimKit — an iOS Simulator's device set, main display and HID, reached at RUNTIME.
//
// NOTHING HERE LINKS CORESIMULATOR. It is dlopen'd from /Library/Developer/PrivateFrameworks on first use, and
// every class and selector is looked up by name, so a Mac without Xcode builds, launches and simply lists no
// simulators — and a CoreSimulatorService that misbehaves fails THIS module's calls, never the host
// (docs/superpowers/specs/2026-10-13-simulator-sources-design.md; the removal spec's first reason was a wedged
// service killing the host through `exit(1)`).
//
// EVERY PRIVATE CALL IS INSIDE @try/@catch. The objects CoreSimulator hands out are remote proxies
// (ROCKRemoteProxy) that THROW — `valueForKey:` on one raised NSUnknownKeyException on 2026-10-13 — and Swift
// cannot catch an Objective-C exception. That is why this shim is Objective-C at all.
//
// Wire shapes and the lookup sequence are idb's (facebook/idb, MIT: FBSimulatorControl/HID, XPC, Framebuffer),
// re-measured on Xcode 27.1 / CoreSimulator 1174.9.2 / iOS 27.0.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <xpc/xpc.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const RSKErrorDomain;
typedef NS_ERROR_ENUM(RSKErrorDomain, RSKErrorCode) {
    RSKErrorUnavailable = 1,        // CoreSimulator missing, or a class or selector it no longer has
    RSKErrorNoSuchDevice = 2,
    RSKErrorNotBooted = 3,
    RSKErrorNoScreen = 4,
    RSKErrorServiceUnavailable = 5, // the guest vends no such service (SimError 405)
    RSKErrorException = 6,          // a private call threw; the description carries its name and reason
    RSKErrorTimeout = 7,
};

/// One device, as plain values copied out of CoreSimulator under a guard.
@interface RSKDeviceInfo : NSObject
@property (nonatomic, readonly, copy) NSString *udid;          // uppercase UUID
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *runtimeName;   // "iOS 27.0"
@property (nonatomic, readonly) NSInteger state;               // SimDevice.state: 1 shutdown 2 booting 3 booted 4 shutting down
@property (nonatomic, readonly) CGSize screenPixels;           // portrait, native
@property (nonatomic, readonly) double screenScale;
@end

@interface RSKDeviceSet : NSObject
/// Loads CoreSimulator (once per process) and the default device set for `developerDir` (`xcode-select -p`).
+ (nullable instancetype)loadWithDeveloperDir:(NSString *)developerDir error:(NSError **)error;
@property (nonatomic, readonly, copy) NSString *coreSimulatorVersion;
/// Every AVAILABLE device on an iOS runtime (iPhone and iPad), in CoreSimulator's order.
- (nullable NSArray<RSKDeviceInfo *> *)iOSDevicesWithError:(NSError **)error;
- (void)bootDevice:(NSString *)udid queue:(dispatch_queue_t)queue completion:(void (^)(NSError *_Nullable error))completion;
- (void)shutdownDevice:(NSString *)udid queue:(dispatch_queue_t)queue completion:(void (^)(NSError *_Nullable error))completion;
@end

/// A booted device's MAIN display (descriptor `displayClass == 0`). Every callback runs on the queue given.
@interface RSKFramebuffer : NSObject
+ (nullable instancetype)attachToDevice:(NSString *)udid
                                  inSet:(RSKDeviceSet *)set
                                  queue:(dispatch_queue_t)queue
                         surfaceChanged:(void (^)(IOSurfaceRef _Nullable surface))surfaceChanged
                         framePresented:(void (^)(void))framePresented
                      propertiesChanged:(void (^)(void))propertiesChanged
                                  error:(NSError **)error;
/// "screen" (SimScreen's per-frame callbacks) or "legacy" (the damage-rectangle callbacks).
@property (nonatomic, readonly, copy) NSString *callbackPath;
/// Idempotent.
- (void)detach;
@end

typedef NS_ENUM(uint64_t, RSKTouchPhase) {
    RSKTouchPhaseStart = 0,
    RSKTouchPhasePosition = 1,
    RSKTouchPhaseEnd = 2,
};

FOUNDATION_EXPORT NSString *const RSKDigitizerService;   // com.apple.coredevice.feature.remote.hid.digitizer

/// The DTUHID dictionaries, exactly as `dtuhidd` decodes them ({messageType, isBarrier, featureIdentifier,
/// payload}); points are 0…1 in the NATIVE frame. Pure — the tests read them back.
FOUNDATION_EXPORT xpc_object_t RSKDigitizerMessage(RSKTouchPhase phase, CGPoint one, BOOL hasTwo, CGPoint two);
FOUNDATION_EXPORT xpc_object_t RSKKeyboardMessage(uint32_t usage, BOOL down, BOOL barrier);
FOUNDATION_EXPORT xpc_object_t RSKButtonMessage(uint16_t page, uint16_t usage, BOOL down);

/// Universal HID's digitizer report, NOT Indigo's three-value eventType. Cancel carries the real contact-cancel bit;
/// a zero-contact clear must follow it before reusing the contact (see native-trackpad experiment report).
typedef NS_ENUM(uint64_t, RSKScrollTouchPhase) {
    RSKScrollTouchPhaseContact,
    RSKScrollTouchPhaseEnd,
    RSKScrollTouchPhaseCancel,
    RSKScrollTouchPhaseClear,
};
FOUNDATION_EXPORT xpc_object_t RSKScrollDigitizerMessage(RSKScrollTouchPhase phase, CGPoint point);
FOUNDATION_EXPORT xpc_object_t RSKScrollReadyMessage(void);
FOUNDATION_EXPORT BOOL RSKScrollReplySupportsTouchscreen(xpc_object_t reply);

@interface RSKHIDConnection : NSObject
/// BLOCKS: up to `attempts` liveness barriers of ≤ 4 s each, 4 s apart (idb's numbers). Call off the main thread.
+ (nullable instancetype)connectToDevice:(NSString *)udid
                                   inSet:(RSKDeviceSet *)set
                                attempts:(NSInteger)attempts
                                   error:(NSError **)error;
/// Separate universal-HID connection for cancellable scrolling. Same bounded, off-main liveness contract.
+ (nullable instancetype)connectScrollToDevice:(NSString *)udid
                                       inSet:(RSKDeviceSet *)set
                                       error:(NSError **)error;
/// Only on connectScrollToDevice's connection. A cancel and its zero-contact clear are sent together, in order.
- (void)sendScrollTouch:(RSKScrollTouchPhase)phase point:(CGPoint)point;
/// In order, never blocking. Dropped once `invalidated`.
- (void)send:(xpc_object_t)message;
/// The connection died (the device shut down or rebooted). Never reused; connect again.
@property (nonatomic, readonly) BOOL invalidated;
- (void)close;
@end

NS_ASSUME_NONNULL_END
