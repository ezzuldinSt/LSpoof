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

// A route that stopped part-way, because the app quit or after Stop and hold, and can go on
// from there (#20). Immutable.
@interface LSResumeOffer : NSObject
@property (nonatomic, readonly) LSRoute *route;
// The speed, motion and waits it was playing with.
@property (nonatomic, readonly) LSPlaybackOptions *options;
@property (nonatomic, readonly) double covered;
@property (nonatomic, readonly) double remainingDistance;
// Seconds left at those options, including the rest of a wait; NAN when unknown.
@property (nonatomic, readonly) NSTimeInterval remainingTime;
@end

@interface LSSessionController : NSObject
@property (class, nonatomic, readonly) LSSessionController *shared;
@property (nonatomic, readonly) LSSessionSnapshot *snapshot;
@property (nonatomic, readonly, nullable) LSRoute *retainedRoute;
// Set while the held location is where the retained route stopped part-way. Main thread.
@property (nonatomic, readonly, nullable) LSResumeOffer *resumeOffer;

- (BOOL)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate;
// radius: NAN uses the global wander setting, 0 turns wandering off here, otherwise meters.
- (BOOL)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate radiusOverride:(double)radius;
- (BOOL)startRoute:(LSRoute *)route options:(LSPlaybackOptions *)options;
// Applies to the playing route right away: speed, motion style, waits.
- (BOOL)updatePlaybackOptions:(LSPlaybackOptions *)options;
// The playing route again with other leg settings on the same path (LSRoute routeWithLegSpeeds:);
// playback carries on from where it is.
- (BOOL)updatePlayingRoute:(LSRoute *)route;
// One step faster (direction > 0) or slower; recorded pace steps its multiplier, and a leg
// with its own speed steps that speed.
- (BOOL)nudgeSpeed:(NSInteger)direction;
- (BOOL)saveSettings:(LSSettings *)settings;
// Reads the route the previous launch was playing, once, after launch. The held location
// stays as it is; when the route decodes it becomes the retained route with a resume offer,
// and when it doesn't it is dropped quietly. Main thread.
- (void)restorePersistedRoute;
// Continues the offered route from its checkpoint, with the options it was playing with.
- (BOOL)resumeRoute;
- (void)pause;
- (void)resume;
- (void)stopAndHold;
- (void)disable;
@end

NS_ASSUME_NONNULL_END
