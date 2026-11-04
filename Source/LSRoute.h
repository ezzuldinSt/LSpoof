#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN

// A named point the route passes through: From, a stop, or To.
@interface LSRouteWaypoint : NSObject <NSCopying>
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
+ (instancetype)waypointWithName:(nullable NSString *)name coordinate:(CLLocationCoordinate2D)coordinate;
@end

// An immutable path to play back. Built from MapKit directions (one leg per pair of
// waypoints) or from a recorded track, which can carry its own timing.
@interface LSRoute : NSObject

@property (nonatomic, readonly) NSUInteger pointCount;
@property (nonatomic, readonly) const CLLocationCoordinate2D *coordinates;
@property (nonatomic, readonly) const double *cumulativeDistances;
// Departure time of each point in seconds from the start, or NULL without timing.
@property (nonatomic, readonly, nullable) const double *timeOffsets;
@property (nonatomic, readonly) double distance;
@property (nonatomic, readonly) BOOL hasTiming;
@property (nonatomic, readonly) NSTimeInterval recordedDuration;
// Planned stops (dwell -1) and pauses found in a recording (dwell in seconds), along the path.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *stopDistances;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *stopDwells;
@property (nonatomic, readonly) NSUInteger plannedStopCount;
// From, planned stops, To.
@property (nonatomic, readonly, copy) NSArray<LSRouteWaypoint *> *waypoints;
@property (nonatomic, readonly) MKDirectionsTransportType transportType;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSTimeInterval expectedTravelTime;
@property (nonatomic, readonly, nullable) NSDate *recordedStartDate;
// Read from a GPX, TCX or FIT file rather than built from directions.
@property (nonatomic, readonly) BOOL fromTrack;
@property (nonatomic, readonly) MKPolyline *polyline;

+ (nullable instancetype)routeWithLegs:(NSArray<MKRoute *> *)legs waypoints:(NSArray<LSRouteWaypoint *> *)waypoints;
// times may be NULL; NaN entries mean unknown. Stationary stretches longer than
// 15 seconds in a timed track become pauses.
+ (nullable instancetype)routeWithCoordinates:(const CLLocationCoordinate2D *)coordinates
                                        times:(nullable const double *)times
                                        count:(NSUInteger)count
                                         name:(nullable NSString *)name
                                transportType:(MKDirectionsTransportType)transportType
                                    startDate:(nullable NSDate *)startDate;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)routeFromDictionary:(id)dictionary;

// Recorded speed (m/s) of the segment ending at each point, or nil without timing.
- (nullable NSData *)recordedSegmentSpeeds;
- (CLLocationCoordinate2D)coordinateAtDistance:(double)distance heading:(nullable CLLocationDirection *)heading;
@end

NS_ASSUME_NONNULL_END
