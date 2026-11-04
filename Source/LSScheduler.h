#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "RouteSimulator.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const LSSchedulerDidChangeNotification;

// A start (and optional stop) set for later: hold a place, or play a route (#20).
@interface LSSchedule : NSObject
@property (nonatomic, readonly) BOOL isRoute;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSDate *startDate;
// When set, LSpoof turns off at this time.
@property (nonatomic, readonly, nullable) NSDate *endDate;
@property (nonatomic, readonly) BOOL repeatsDaily;
// Started, and waiting for its end time.
@property (nonatomic, readonly) BOOL isActive;
// "Route “Commute” starts at 08:00, turns off at 09:00, every day"
- (NSString *)summary;
@end

// Starts a scheduled location or route while the app is running. iOS only lets an app run
// on time when it is open or allowed to keep running in the background; a start found late
// when the app comes back still applies a held place, but skips a route that is more than
// 15 minutes late.
@interface LSScheduler : NSObject
@property (class, nonatomic, readonly) LSScheduler *shared;
@property (nonatomic, readonly, nullable) LSSchedule *schedule;

// Restores the saved schedule and starts watching the clock. Main thread.
- (void)activate;
- (BOOL)scheduleLocation:(CLLocationCoordinate2D)coordinate name:(NSString *)name radiusOverride:(double)radius
                   start:(NSDate *)start end:(nullable NSDate *)end repeatsDaily:(BOOL)daily;
- (BOOL)scheduleRoute:(LSRoute *)route options:(LSPlaybackOptions *)options name:(NSString *)name
                start:(NSDate *)start end:(nullable NSDate *)end repeatsDaily:(BOOL)daily;
- (void)cancel;
// A message about a start that ran late or was skipped, returned once.
- (nullable NSString *)takeNotice;
@end

NS_ASSUME_NONNULL_END
