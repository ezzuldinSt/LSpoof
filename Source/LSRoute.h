#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import "LSRouteArchive.h"

NS_ASSUME_NONNULL_BEGIN

// The route archive's path names: "driving", "walking", "transit". Unknown names use fallback.
FOUNDATION_EXPORT NSString *LSArchivePathForTransportType(MKDirectionsTransportType type);
FOUNDATION_EXPORT MKDirectionsTransportType LSTransportTypeForArchivePath(NSString * _Nullable path, MKDirectionsTransportType fallback);

// A named point the route passes through: From, a stop, or To.
@interface LSRouteWaypoint : NSObject <NSCopying>
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
+ (instancetype)waypointWithName:(nullable NSString *)name coordinate:(CLLocationCoordinate2D)coordinate;
@end

// One leg's directions: the path between two consecutive waypoints, Apple's time for it and
// the path type it follows. Made from an MKRoute, or kept from a route built earlier so the
// leg need not be looked up again.
@interface LSRouteLegPath : NSObject
@property (nonatomic, readonly) MKPolyline *polyline;
@property (nonatomic, readonly) NSTimeInterval expectedTravelTime;
@property (nonatomic, readonly) MKDirectionsTransportType transportType;
+ (nullable instancetype)pathWithRoute:(MKRoute *)route;
+ (nullable instancetype)pathWithPolyline:(MKPolyline *)polyline expectedTravelTime:(NSTimeInterval)time
                            transportType:(MKDirectionsTransportType)transportType;
@end

// One leg of a route: From to the first stop, stop to stop, or the last stop to To.
@interface LSRouteLeg : NSObject
// The path type the leg's directions follow. A leg whose type differs from the route's
// transportType was set on its own; the others follow the route.
@property (nonatomic, readonly) MKDirectionsTransportType transportType;
// Playback speed on this leg in km/h (1–500), or NAN to play it at the route's speed.
@property (nonatomic, readonly) double speedKmh;
@property (nonatomic, readonly) BOOL hasOwnSpeed;
// Meters along the route; a leg starts where the one before it ends.
@property (nonatomic, readonly) double startDistance;
@property (nonatomic, readonly) double endDistance;
@property (nonatomic, readonly) NSTimeInterval expectedTravelTime;
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
// One per pair of consecutive waypoints, in order. A recorded track is one leg.
@property (nonatomic, readonly, copy) NSArray<LSRouteLeg *> *legs;
// The route-wide path type, which every leg without its own follows.
@property (nonatomic, readonly) MKDirectionsTransportType transportType;
// Some leg follows another path type than the route or plays at its own speed.
@property (nonatomic, readonly) BOOL hasLegSettings;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSTimeInterval expectedTravelTime;
@property (nonatomic, readonly, nullable) NSDate *recordedStartDate;
// Read from a GPX, TCX or FIT file rather than built from directions.
@property (nonatomic, readonly) BOOL fromTrack;
@property (nonatomic, readonly) MKPolyline *polyline;

// Every leg follows the first leg's path type and plays at the route speed.
+ (nullable instancetype)routeWithLegs:(NSArray<MKRoute *> *)legs waypoints:(NSArray<LSRouteWaypoint *> *)waypoints;
// transportType is the route-wide path. speeds has a km/h value, or NAN for the route speed,
// per leg; nil plays every leg at the route speed.
+ (nullable instancetype)routeWithLegPaths:(NSArray<LSRouteLegPath *> *)paths
                                 waypoints:(NSArray<LSRouteWaypoint *> *)waypoints
                             transportType:(MKDirectionsTransportType)transportType
                                 legSpeeds:(nullable NSArray<NSNumber *> *)speeds;
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
// The versioned form used to resume after a relaunch, for saved routes and in backups, with
// each leg's path and speed. The archive gets a new identifier and no playback; set those as needed.
- (LSRouteArchive *)archive;
// nil when the archive has no usable path (a planned route can then be looked up again from its places).
+ (nullable instancetype)routeWithArchive:(LSRouteArchive *)archive;

// Recorded speed (m/s) of the segment ending at each point, or nil without timing.
- (nullable NSData *)recordedSegmentSpeeds;
- (CLLocationCoordinate2D)coordinateAtDistance:(double)distance heading:(nullable CLLocationDirection *)heading;

// The leg at a distance along the route; a leg's end already belongs to the next leg.
- (NSUInteger)legIndexAtDistance:(double)distance;
// The same path with other leg speeds (km/h, or NAN for the route speed), so a change can
// apply while the route plays. Shares this route's points and polyline.
- (nullable instancetype)routeWithLegSpeeds:(NSArray<NSNumber *> *)speeds;
// Same points and stops, so playback can carry over from one route to the other.
- (BOOL)hasSamePathAs:(nullable LSRoute *)route;
// A leg's part of the path, to build the route again without looking that leg up.
- (nullable LSRouteLegPath *)pathForLegAtIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
