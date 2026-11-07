#import "RSKInternal.h"
#import <dlfcn.h>
#import <stdatomic.h>

typedef xpc_object_t (*RSKEndpointFromPort)(mach_port_t, uint64_t, uint64_t);
typedef xpc_connection_t (*RSKConnectionFromEndpoint)(xpc_object_t);
typedef void (*RSKEnableSim2Host)(xpc_connection_t);

@implementation RSKHIDConnection {
    xpc_connection_t _connection;
    atomic_bool _invalidated;
    BOOL _scroll;
}

- (BOOL)invalidated { return atomic_load(&_invalidated); }

+ (instancetype)connectToDevice:(NSString *)udid inSet:(RSKDeviceSet *)set attempts:(NSInteger)attempts error:(NSError **)error {
    return [self connectToDevice:udid inSet:set attempts:attempts scroll:NO error:error];
}

+ (instancetype)connectScrollToDevice:(NSString *)udid inSet:(RSKDeviceSet *)set error:(NSError **)error {
    return [self connectToDevice:udid inSet:set attempts:1 scroll:YES error:error];
}

+ (instancetype)connectToDevice:(NSString *)udid inSet:(RSKDeviceSet *)set attempts:(NSInteger)attempts scroll:(BOOL)scroll error:(NSError **)error {
    RSKEndpointFromPort endpointFromPort = (RSKEndpointFromPort)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    RSKConnectionFromEndpoint fromEndpoint = (RSKConnectionFromEndpoint)dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
    RSKEnableSim2Host enableSim2Host = (RSKEnableSim2Host)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!endpointFromPort || !fromEndpoint || !enableSim2Host) {
        if (error) *error = RSKMakeError(RSKErrorUnavailable, @"libxpc has no _4sim entry points");
        return nil;
    }
    NSError *last = nil;
    for (NSInteger attempt = 1; attempt <= MAX(attempts, 1); attempt++) {
        if (attempt > 1) [NSThread sleepForTimeInterval:4];
        id device = [set deviceObject:udid];
        if (!device) { if (error) *error = RSKMakeError(RSKErrorNoSuchDevice, udid); return nil; }
        __block unsigned int port = 0;
        __block NSError *lookupError = nil;
        if (!RSKGuard(&last, @"looking up the digitizer", ^{
            NSError *e = nil;
            port = ((unsigned int (*)(id, SEL, NSString *, NSError **))objc_msgSend)(
                device, NSSelectorFromString(@"lookup:error:"), scroll ? @"com.apple.coredevice.feature.remote.universalhidservice" : RSKDigitizerService, &e);
            lookupError = e;
        })) continue;
        if (!port) {
            // 405 is "the guest vends no such service" — permanent, so no retry (idb: isServiceUnsupported).
            if (lookupError.code == 405) {
                if (error) *error = RSKMakeError(RSKErrorServiceUnavailable, lookupError.localizedDescription);
                return nil;
            }
            last = lookupError ?: RSKMakeError(RSKErrorNotBooted, udid);
            continue;
        }
        xpc_connection_t c = fromEndpoint(endpointFromPort(port, 0, 0));
        if (!c) { last = RSKMakeError(RSKErrorUnavailable, @"no connection from the endpoint"); continue; }
        enableSim2Host(c);
        RSKHIDConnection *h = [self new];
        h->_connection = c;
        h->_scroll = scroll;
        __weak RSKHIDConnection *weak = h;
        xpc_connection_set_event_handler(c, ^(xpc_object_t event) {
            if (event == XPC_ERROR_CONNECTION_INVALID) {
                RSKHIDConnection *s = weak;
                if (s) atomic_store(&s->_invalidated, true);
            }
        });
        xpc_connection_resume(c);
        // LIVENESS: a barrier keyboard message the guest must ANSWER (≈190 ms measured). Asynchronous with a
        // deadline: the synchronous form waits forever on a guest that never replies.
        dispatch_semaphore_t answered = dispatch_semaphore_create(0);
        __block BOOL alive = NO;
        xpc_connection_send_message_with_reply(c, scroll ? RSKScrollReadyMessage() : RSKKeyboardMessage(0, NO, YES),
                                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
            alive = scroll ? RSKScrollReplySupportsTouchscreen(reply) : xpc_get_type(reply) == XPC_TYPE_DICTIONARY;
            dispatch_semaphore_signal(answered);
        });
        if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0 && alive) return h;
        [h close];
        last = RSKMakeError(RSKErrorTimeout, @"the digitizer did not answer its liveness barrier");
    }
    if (error) *error = last;
    return nil;
}

- (void)send:(xpc_object_t)message {
    if (atomic_load(&_invalidated) || !_connection) return;
    xpc_connection_send_message(_connection, message);
}

- (void)sendScrollTouch:(RSKScrollTouchPhase)phase point:(CGPoint)point {
    if (!_scroll) return;
    [self send:RSKScrollDigitizerMessage(phase, point)];
    if (phase == RSKScrollTouchPhaseCancel) [self send:RSKScrollDigitizerMessage(RSKScrollTouchPhaseClear, point)];
}

- (void)close {
    if (!_connection) return;
    atomic_store(&_invalidated, true);
    xpc_connection_cancel(_connection);
    _connection = nil;
}

- (void)dealloc { [self close]; }

@end
