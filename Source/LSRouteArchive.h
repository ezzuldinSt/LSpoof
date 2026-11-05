#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The versioned, JSON-safe form of a route: the route a relaunch resumes, each saved route,
// and the routes in a backup. Foundation only, so it can be tested on Linux, which is also why
// the instance variables are declared here (GNUstep's runtime needs it).
//
// Version 1:
//   { "v": 1, "id": UUID, "name": text, "created": unix seconds, "path": "walking" | "driving",
//     "track": true (a recorded GPX, TCX or FIT track; optional),
//     "places": [ { "name", "lat", "lon" } ],          From, up to 10 stops, To
//     "geometry": {                                      optional for planned routes
//         "coords": base64 of little-endian float64 latitude, longitude pairs,
//         "times": base64 of little-endian float64 seconds from the start (optional),
//         "stops": [ [meters along, seconds] ],          -1 seconds: a planned stop
//         "eta": seconds, "start": unix seconds (optional) },
//     "legs": [ { "path", "speedKmh" (optional), "end" (optional), "eta" } ],   optional, one per
//         pair of places: how each leg is travelled. "end" is meters along the stored path.
//     "playback": { "speedKmh", "recordedPace", "paceMultiplier", "smooth", "acceleration", "stopDwell" } }
// Readers ignore keys they don't know, so later versions can add fields without breaking v1.
FOUNDATION_EXPORT const NSInteger LSRouteArchiveVersion;
FOUNDATION_EXPORT const NSUInteger LSRouteArchiveMaximumPoints;
FOUNDATION_EXPORT const NSUInteger LSRouteArchiveMaximumStops;

// From, a stop, or To.
@interface LSArchivedPlace : NSObject {
@private
    NSString *_name;
    double _latitude;
    double _longitude;
}
// nil for an unusable coordinate. A missing or empty name becomes "Map point".
+ (nullable instancetype)placeWithName:(nullable NSString *)name latitude:(double)latitude longitude:(double)longitude;
- (NSString *)name;
- (double)latitude;
- (double)longitude;
@end

// One leg (From to the first stop, stop to stop, the last stop to To): its own path type and,
// optionally, its own speed.
@interface LSArchivedLeg : NSObject {
@private
    NSString *_path;
    double _speedKmh;
    double _end;
    double _expectedTravelTime;
}
// "walking", "driving" or "transit"; another value from a later version is kept as it is.
+ (nullable instancetype)legWithPath:(NSString *)path speedKmh:(double)speedKmh end:(double)end expectedTravelTime:(double)eta;
- (NSString *)path;
// 1 to 500 km/h, or NAN to play the leg at the route speed.
- (double)speedKmh;
// Meters along the stored path where the leg ends, or NAN when unknown (no path).
- (double)end;
- (double)expectedTravelTime;
@end

// How the route plays: the same values as LSPlaybackOptions, kept apart from UIKit and MapKit.
@interface LSRoutePlayback : NSObject <NSCopying> {
@private
    double _speedKmh;
    BOOL _recordedPace;
    double _paceMultiplier;
    BOOL _smooth;
    NSInteger _acceleration;
    double _stopDwell;
}
@property (nonatomic) double speedKmh;          // 1 to 500
@property (nonatomic) BOOL recordedPace;
@property (nonatomic) double paceMultiplier;    // 0.1 to 20
@property (nonatomic) BOOL smooth;
@property (nonatomic) NSInteger acceleration;   // 0 gentle, 1 normal, 2 sporty
@property (nonatomic) double stopDwell;         // seconds at each planned stop, 0 to 3600
- (BOOL)isValid;
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)playbackFromDictionary:(nullable id)dictionary;
@end

@interface LSRouteArchive : NSObject <NSCopying> {
@private
    NSString *_identifier;
    NSString *_name;
    NSDate *_createdAt;
    NSArray<LSArchivedPlace *> *_places;
    NSString *_path;
    BOOL _fromTrack;
    NSData *_coordinates;
    NSData *_times;
    NSArray<NSArray<NSNumber *> *> *_stops;
    double _expectedTravelTime;
    NSDate *_recordedStartDate;
    LSRoutePlayback *_playback;
    NSArray<LSArchivedLeg *> *_legs;
    double _cachedDistance;
}
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, copy) NSArray<LSArchivedPlace *> *places;
// "walking" or "driving": the kind of streets the route follows.
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL fromTrack;
// Latitude, longitude pairs of host doubles (the CLLocationCoordinate2D layout), or nil.
@property (nonatomic, copy, nullable) NSData *coordinates;
// Seconds from the start for each point (host doubles), or nil.
@property (nonatomic, copy, nullable) NSData *times;
// [meters along the path, seconds]: -1 for a planned stop, else a pause from a recording.
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *stops;
@property (nonatomic) double expectedTravelTime;
@property (nonatomic, strong, nullable) NSDate *recordedStartDate;
@property (nonatomic, copy, nullable) LSRoutePlayback *playback;
// Empty, or exactly one per pair of places.
@property (nonatomic, copy) NSArray<LSArchivedLeg *> *legs;

// A new route with a fresh identifier and today's date.
- (instancetype)init;
- (NSUInteger)pointCount;
// Meters along the stored path, or 0 without one.
- (double)distance;
- (NSUInteger)plannedStopCount;
// Two to twelve places, a name, and for a track its path.
- (BOOL)isValid;
- (NSDictionary *)dictionaryRepresentation;
// Unknown keys are ignored. A damaged path is dropped from a planned route (it can be
// looked up again from its places); a track without a usable path is rejected.
+ (nullable instancetype)archiveFromDictionary:(nullable id)dictionary error:(NSString * _Nullable * _Nullable)error;
// A trimmed name of 1 to 120 characters, or nil.
+ (nullable NSString *)validName:(nullable id)name;
@end

// Where a playing route had got to, written every few seconds so a relaunch can resume it.
//   { "v": 1, "route": UUID of the archive, "covered": meters, "total": meters, "stop": next stop index,
//     "wait": seconds still to wait at the stop it is at, "at": unix seconds, "playback": { ... } }
@interface LSRouteCheckpoint : NSObject <NSCopying> {
@private
    NSString *_routeID;
    double _covered;
    double _total;
    NSUInteger _nextStop;
    double _waitRemaining;
    NSDate *_savedAt;
    LSRoutePlayback *_playback;
}
@property (nonatomic, copy) NSString *routeID;
@property (nonatomic) double covered;
@property (nonatomic) double total;
@property (nonatomic) NSUInteger nextStop;
@property (nonatomic) double waitRemaining;
@property (nonatomic, strong) NSDate *savedAt;
@property (nonatomic, copy) LSRoutePlayback *playback;
// Has distance left to go.
- (BOOL)isUnfinished;
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)checkpointFromDictionary:(nullable id)dictionary;
@end

NS_ASSUME_NONNULL_END
