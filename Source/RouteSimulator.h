#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import "LSRoute.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LSTransportMode) {
    LSTransportModeWalking,
    LSTransportModeCycling,
    LSTransportModeDriving,
    LSTransportModeCustom
};

typedef NS_ENUM(NSInteger, LSAccelerationProfile) {
    LSAccelerationGentle,
    LSAccelerationNormal,
    LSAccelerationSporty
};

// How a route is played: speed, motion style and waits. Can change while it plays.
@interface LSPlaybackOptions : NSObject <NSCopying>
@property (nonatomic) LSTransportMode mode;
@property (nonatomic) double customSpeedKmh;
@property (nonatomic) BOOL smooth;
@property (nonatomic) LSAccelerationProfile accelerationProfile;
@property (nonatomic) NSTimeInterval stopDwell;
// Follow a recorded track's own timing, scaled by paceMultiplier.
@property (nonatomic) BOOL recordedPace;
@property (nonatomic) double paceMultiplier;
// Preset speeds (5, 15, 50 km/h) map to walking, cycling and driving.
+ (instancetype)optionsWithSpeedKmh:(double)kmh;
- (double)speedKmh;
- (double)speedMetersPerSecond;
- (BOOL)isValid;
// Property list form, used to keep a scheduled route's options.
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)optionsFromDictionary:(nullable id)dictionary;
@end

@class LSRouteSimulator;

@protocol LSRouteSimulatorDelegate <NSObject>
- (void)routeSimulator:(LSRouteSimulator *)simulator
   didUpdateCoordinate:(CLLocationCoordinate2D)coordinate
               heading:(CLLocationDirection)heading;
- (void)routeSimulatorDidFinish:(LSRouteSimulator *)simulator;
@end

@interface LSRouteSimulator : NSObject

@property (class, nonatomic, readonly) LSRouteSimulator *shared;

@property (nonatomic, weak, nullable) id<LSRouteSimulatorDelegate> delegate;
// Changes take effect on the next tick, so speed can be adjusted mid-route.
@property (nonatomic, copy) LSPlaybackOptions *options;
@property (nonatomic, readonly) LSTransportMode transportMode;
@property (nonatomic, readonly) double customSpeedKmh;
@property (nonatomic, readonly) BOOL isSimulating;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) BOOL isWaitingAtStop;
@property (nonatomic, readonly) NSTimeInterval waitRemaining;
@property (nonatomic, readonly) CLLocationCoordinate2D currentCoordinate;
@property (nonatomic, readonly) CLLocationDirection currentHeading;
// m/s at this moment, including acceleration, braking and waits.
@property (nonatomic, readonly) double currentSpeed;
// Read on main with the other playback state.
@property (nonatomic, readonly) double totalDistance;
@property (nonatomic, readonly) double distanceCovered;
@property (nonatomic, readonly, nullable) LSRoute *route;
@property (nonatomic, readonly) CLLocationCoordinate2D startCoordinate;
@property (nonatomic, readonly) CLLocationCoordinate2D destinationCoordinate;
@property (nonatomic, readonly) NSUInteger plannedStopsReached;

- (BOOL)startWithRoute:(LSRoute *)route;
- (void)pause;
- (void)resume;
- (void)stop;
// Seconds left at the current options, including waits. Cached for a few seconds.
- (NSTimeInterval)remainingTimeEstimate;

+ (double)speedMetersPerSecondForMode:(LSTransportMode)mode customSpeedKmh:(double)customSpeedKmh;
+ (double)horizontalAccuracyForMode:(LSTransportMode)mode;
+ (NSTimeInterval)estimatedDurationForRoute:(LSRoute *)route options:(LSPlaybackOptions *)options;
// The custom speed (km/h) that makes the trip take `seconds`, or NAN when 1–500 km/h cannot.
+ (double)speedKmhForRoute:(LSRoute *)route options:(LSPlaybackOptions *)options finishingIn:(NSTimeInterval)seconds;
// Plays the route offline from t = 0, calling block every `interval` seconds and at arrival.
+ (void)enumerateSamplesForRoute:(LSRoute *)route options:(LSPlaybackOptions *)options interval:(NSTimeInterval)interval
                           block:(void (^)(NSTimeInterval time, CLLocationCoordinate2D coordinate, double speed, double distance, CLLocationDirection heading))block;

@end

NS_ASSUME_NONNULL_END
