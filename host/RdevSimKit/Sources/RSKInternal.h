#import "RdevSimKit.h"
#import <objc/message.h>

NS_ASSUME_NONNULL_BEGIN

NSError *RSKMakeError(RSKErrorCode code, NSString *what);

/// Runs `body`; an Objective-C exception becomes `RSKErrorException` in `*error` and NO.
BOOL RSKGuard(NSError *_Nullable *_Nullable error, NSString *what, void (NS_NOESCAPE ^body)(void));

/// `[target selector]` returning an object, or nil when `target` does not respond. NOT KVC: a proxy throws on KVC.
static inline id _Nullable RSKGet(id _Nullable target, NSString *selector) {
    SEL s = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, s);
}

@interface RSKDeviceSet (Internal)
/// The SimDevice for `udid`, or nil.
- (nullable id)deviceObject:(NSString *)udid;
@end

NS_ASSUME_NONNULL_END
