#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "RouteSimulator.h"
@class LSSettings;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LSSessionMode) {
    LSSessionModeOff,
    LSSessionModeStatic,
    LSSessionModeMoving,
    LSSessionModePaused
};

FOUNDATION_EXPORT NSNotificationName const LSSessionDidChangeNotification;

// Immutable, coherent host-facing state. Safe to read on a manager's delivery thread.
@interface LSSessionSnapshot : NSObject
@property (nonatomic, readonly) LSSessionMode mode;
@property (nonatomic, readonly, nullable) CLLocation *location;
// Changes across activation boundaries; preserves legacy history during replacements.
@property (nonatomic, readonly) uint64_t generation;
@property (nonatomic, readonly) BOOL fluctuationEnabled;
@property (nonatomic, readonly) double fluctuationRadius;
@end

@interface LSSessionController : NSObject
@property (class, nonatomic, readonly) LSSessionController *shared;
@property (nonatomic, readonly) LSSessionSnapshot *snapshot;
@property (nonatomic, readonly, nullable) MKRoute *retainedRoute;

- (BOOL)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate;
- (BOOL)startRoute:(MKRoute *)route transportMode:(LSTransportMode)mode customSpeedKmh:(double)speed;
- (BOOL)updateTransportMode:(LSTransportMode)mode customSpeedKmh:(double)speed;
- (BOOL)saveSettings:(LSSettings *)settings;
- (void)pause;
- (void)resume;
- (void)stopAndHold;
- (void)disable;
@end

NS_ASSUME_NONNULL_END
