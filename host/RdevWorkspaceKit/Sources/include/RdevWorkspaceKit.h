#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * _Nullable RWKProcessGeneration(pid_t pid);
FOUNDATION_EXPORT BOOL RWKSameProcess(NSDictionary *expected, NSDictionary *actual);
FOUNDATION_EXPORT CGRect RWKClampFrame(CGRect frame, CGRect bounds);
FOUNDATION_EXPORT CGRect RWKInitialFrame(CGRect original, CGRect workspace, NSUInteger index);
/// Experimental macOS 27 adapter. All calls must be serialized on one BACKGROUND queue.
/// Never launches apps, changes minimization, or resolves cold journals by numeric window ID.
@interface RWKWorkspace : NSObject
- (nullable instancetype)initWithJournalURL:(NSURL *)url error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly) CGRect displayBounds;
/// Identities contain pid, generation (kernel launch timestamp), bundle, name.
+ (NSArray<NSDictionary *> *)runningApplications;
@property(nonatomic, readonly) NSArray<NSDictionary *> *snapshot;
- (BOOL)createDisplayWithError:(NSError **)error;
- (BOOL)addApplication:(NSDictionary *)identity error:(NSError **)error;
/// Caller schedules a bounded backstop (e.g. once/second). New ordinary windows are placed.
- (BOOL)reconcileWithError:(NSError **)error;
- (BOOL)removeApplication:(NSDictionary *)identity error:(NSError **)error;
/// Retains display when any restoration is unresolved. Retry this method after failure.
- (BOOL)restoreAllWithError:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
