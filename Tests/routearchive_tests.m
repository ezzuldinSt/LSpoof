// Host tests for the versioned route format (resume after relaunch, saved routes, backup)
// and the saved-route store. Build with Tests/run.sh.
#import <Foundation/Foundation.h>
#import "../Source/LSRouteArchive.h"
#import "../Source/LSRouteStore.h"
#include <math.h>
#include <string.h>
#include <unistd.h>

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
#define NEAR(a, b, eps) (fabs((a) - (b)) <= (eps))

static NSData *Doubles(const double *values, NSUInteger count) {
    return [NSData dataWithBytes:values length:count * sizeof(double)];
}

// Little-endian float64s in base64, written independently of the code under test.
static NSString *Base64Doubles(const double *values, NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count * 8];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger index = 0; index < count; index++) {
        uint64_t bits;
        memcpy(&bits, &values[index], 8);
        for (int shift = 0; shift < 8; shift++) bytes[index * 8 + shift] = (uint8_t)(bits >> (8 * shift));
    }
    return [data base64EncodedStringWithOptions:0];
}

// Through real JSON text, as the file, the backup and the defaults round trip it.
static id ThroughJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] : nil;
}

static LSRouteArchive *SampleRoute(void) {
    LSRouteArchive *route = [[LSRouteArchive alloc] init];
    route.name = @"  Home to work  ";
    route.name = [LSRouteArchive validName:route.name];
    route.path = @"driving";
    route.places = @[ [LSArchivedPlace placeWithName:@"Home" latitude:52.52 longitude:13.405],
                      [LSArchivedPlace placeWithName:@"Bakery" latitude:52.5205 longitude:13.4062],
                      [LSArchivedPlace placeWithName:@"Work" latitude:52.5212 longitude:13.4075] ];
    // Values whose decimal forms don't round trip, to prove the path is stored bit for bit.
    double coordinates[] = { 52.52, 13.405, 52.5201234567890123, 13.4051 + 1e-12, 52.5205, 13.4062, 52.52091, -0.1 + 13.5075, 52.5212, 13.4075 };
    route.coordinates = Doubles(coordinates, 10);
    double times[] = { 0, 10.5, 31.25, 40, 61.125 };
    route.times = Doubles(times, 5);
    route.stops = @[ @[ @80.123456789, @-1 ], @[ @120.5, @20 ] ];
    route.expectedTravelTime = 302.5;
    route.recordedStartDate = [NSDate dateWithTimeIntervalSince1970:1762329600];
    LSRoutePlayback *playback = [[LSRoutePlayback alloc] init];
    playback.speedKmh = 37.5;
    playback.recordedPace = YES;
    playback.paceMultiplier = 1.5;
    playback.smooth = YES;
    playback.acceleration = 2;
    playback.stopDwell = 30;
    route.playback = playback;
    return route;
}

static void TestRoundTrip(void) {
    LSRouteArchive *route = SampleRoute();
    CHECK(route.isValid, "sample route is valid");
    CHECK([route.name isEqualToString:@"Home to work"], "names are trimmed");
    CHECK(route.pointCount == 5 && route.plannedStopCount == 1, "five points, one planned stop");
    NSDictionary *dictionary = [route dictionaryRepresentation];
    CHECK([[dictionary objectForKey:@"v"] isEqual:@1], "written as version 1");
    CHECK([NSJSONSerialization isValidJSONObject:dictionary], "the dictionary is JSON-safe");
    NSString *error = nil;
    LSRouteArchive *back = [LSRouteArchive archiveFromDictionary:ThroughJSON(dictionary) error:&error];
    CHECK(back != nil, "decodes after JSON (%s)", error.UTF8String);
    if (!back) return;
    CHECK([back.identifier isEqualToString:route.identifier], "identifier kept");
    CHECK([back.name isEqualToString:@"Home to work"] && [back.path isEqualToString:@"driving"] && !back.fromTrack, "name and path kept");
    CHECK(NEAR(back.createdAt.timeIntervalSince1970, route.createdAt.timeIntervalSince1970, 1e-3), "creation date kept");
    CHECK(back.places.count == 3, "three places");
    if (back.places.count == 3) {
        LSArchivedPlace *stop = [back.places objectAtIndex:1];
        CHECK([stop.name isEqualToString:@"Bakery"] && NEAR(stop.latitude, 52.5205, 1e-12) && NEAR(stop.longitude, 13.4062, 1e-12), "stop place kept");
    }
    CHECK(back.coordinates.length == route.coordinates.length && memcmp(back.coordinates.bytes, route.coordinates.bytes, route.coordinates.length) == 0,
          "path stored bit for bit");
    CHECK(back.times.length == route.times.length && memcmp(back.times.bytes, route.times.bytes, route.times.length) == 0, "timing stored bit for bit");
    CHECK(back.stops.count == 2 && NEAR([[[back.stops objectAtIndex:0] objectAtIndex:0] doubleValue], 80.123456789, 1e-9) &&
          [[[back.stops objectAtIndex:0] objectAtIndex:1] doubleValue] == -1 && [[[back.stops objectAtIndex:1] objectAtIndex:1] doubleValue] == 20, "stops kept");
    CHECK(NEAR(back.expectedTravelTime, 302.5, 1e-9) && NEAR(back.recordedStartDate.timeIntervalSince1970, 1762329600, 1e-3), "eta and start kept");
    LSRoutePlayback *playback = back.playback;
    CHECK(playback && NEAR(playback.speedKmh, 37.5, 1e-9) && playback.recordedPace && NEAR(playback.paceMultiplier, 1.5, 1e-9) &&
          playback.smooth && playback.acceleration == 2 && NEAR(playback.stopDwell, 30, 1e-9), "playback kept");
    CHECK(NEAR(back.distance, route.distance, 1e-9) && back.distance > 100 && back.distance < 300, "distance %f", back.distance);
    LSRouteArchive *copy = [back copy];
    CHECK(copy != back && [copy.identifier isEqualToString:back.identifier] && [copy.coordinates isEqualToData:back.coordinates], "copies are equal");
}

static void TestByteOrder(void) {
    LSRouteArchive *route = [[LSRouteArchive alloc] init];
    route.places = @[ [LSArchivedPlace placeWithName:nil latitude:1 longitude:-2], [LSArchivedPlace placeWithName:@"" latitude:1.5 longitude:-2] ];
    double coordinates[] = { 1.0, -2.0, 1.5, -2.0 };
    route.coordinates = Doubles(coordinates, 4);
    NSString *coords = [[[route dictionaryRepresentation] objectForKey:@"geometry"] objectForKey:@"coords"];
    CHECK([coords hasPrefix:@"AAAAAAAA8D8AAAAAAAAAwA"], "little-endian float64 pairs: %s", coords.UTF8String);
    CHECK([[[route.places objectAtIndex:0] name] isEqualToString:@"Map point"] && [[[route.places objectAtIndex:1] name] isEqualToString:@"Map point"],
          "unnamed places are map points");
    CHECK(NEAR(route.distance, 55597.5, 5), "half a degree of latitude: %f", route.distance);
}

static NSMutableDictionary *Mutable(LSRouteArchive *route) {
    return ThroughJSON([route dictionaryRepresentation]);
}

static void TestVersionsAndUnknownKeys(void) {
    NSMutableDictionary *dictionary = Mutable(SampleRoute());
    [dictionary setObject:@{ @"later": [NSNumber numberWithBool:YES] } forKey:@"future"];
    NSMutableDictionary *place = [[dictionary objectForKey:@"places"] objectAtIndex:1];
    [place setObject:@"cycling" forKey:@"leg"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] != nil, "unknown keys are ignored");
    [dictionary setObject:@"hovercraft" forKey:@"path"];
    CHECK([[[LSRouteArchive archiveFromDictionary:dictionary error:NULL] path] isEqualToString:@"hovercraft"], "an unknown path kind is kept");
    NSString *error = nil;
    [dictionary setObject:@2 forKey:@"v"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:&error] == nil && [error containsString:@"newer"], "a newer version is refused (%s)", error.UTF8String);
    [dictionary setObject:@1.5 forKey:@"v"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "a fractional version is refused");
    [dictionary removeObjectForKey:@"v"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "a missing version is refused");
    CHECK([LSRouteArchive archiveFromDictionary:@[] error:NULL] == nil && [LSRouteArchive archiveFromDictionary:nil error:NULL] == nil, "non-dictionaries are refused");
}

static void TestDamage(void) {
    NSMutableDictionary *dictionary = Mutable(SampleRoute());
    [[dictionary objectForKey:@"geometry"] setObject:@"not base64!" forKey:@"coords"];
    LSRouteArchive *planned = [LSRouteArchive archiveFromDictionary:dictionary error:NULL];
    CHECK(planned && planned.coordinates == nil && planned.times == nil && planned.stops.count == 0 && planned.places.count == 3,
          "a damaged path is dropped from a planned route, which keeps its places");
    CHECK(planned.isValid, "and it is still a valid route to look up again");
    [dictionary setObject:[NSNumber numberWithBool:YES] forKey:@"track"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "a track with a damaged path is refused");
    [[dictionary objectForKey:@"geometry"] removeObjectForKey:@"coords"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "a track with no path is refused");

    dictionary = Mutable(SampleRoute());
    double nan[] = { 52.5, NAN, 52.6, 13.4 };
    [[dictionary objectForKey:@"geometry"] setObject:Base64Doubles(nan, 4) forKey:@"coords"];
    CHECK([[LSRouteArchive archiveFromDictionary:dictionary error:NULL] coordinates] == nil, "non-finite coordinates drop the path");
    double far[] = { 95, 13, 52, 13 };
    [[dictionary objectForKey:@"geometry"] setObject:Base64Doubles(far, 4) forKey:@"coords"];
    CHECK([[LSRouteArchive archiveFromDictionary:dictionary error:NULL] coordinates] == nil, "latitudes past the pole drop the path");
    double odd[] = { 52.5, 13.4, 52.6 };
    [[dictionary objectForKey:@"geometry"] setObject:Base64Doubles(odd, 3) forKey:@"coords"];
    CHECK([[LSRouteArchive archiveFromDictionary:dictionary error:NULL] coordinates] == nil, "half a coordinate drops the path");

    dictionary = Mutable(SampleRoute());
    double shortTimes[] = { 0, 1 };
    [[dictionary objectForKey:@"geometry"] setObject:Base64Doubles(shortTimes, 2) forKey:@"times"];
    LSRouteArchive *untimed = [LSRouteArchive archiveFromDictionary:dictionary error:NULL];
    CHECK(untimed && untimed.pointCount == 5 && untimed.times == nil && untimed.recordedStartDate == nil, "timing of the wrong length is dropped, the path kept");
    double backwards[] = { 0, 10, 5, 20, 30 };
    [[dictionary objectForKey:@"geometry"] setObject:Base64Doubles(backwards, 5) forKey:@"times"];
    CHECK([[LSRouteArchive archiveFromDictionary:dictionary error:NULL] times] == nil, "timing that goes backwards is dropped");

    dictionary = Mutable(SampleRoute());
    [[dictionary objectForKey:@"geometry"] setObject:@[ @[ @-5, @-1 ], @[ @50, @-1 ], @[ @40, @-1 ], @"x", @[ @60, @(INFINITY) ], @[ @70, @99999 ], @[ @90, @-7 ] ] forKey:@"stops"];
    NSArray *stops = [[LSRouteArchive archiveFromDictionary:dictionary error:NULL] stops];
    CHECK(stops.count == 2 && [[[stops objectAtIndex:0] objectAtIndex:0] doubleValue] == 50 && [[[stops objectAtIndex:1] objectAtIndex:1] doubleValue] == -1,
          "only increasing, in-range stops are kept (%lu)", (unsigned long)stops.count);

    dictionary = Mutable(SampleRoute());
    [dictionary setObject:@{ @"speedKmh": @900 } forKey:@"playback"];
    LSRouteArchive *fast = [LSRouteArchive archiveFromDictionary:dictionary error:NULL];
    CHECK(fast && fast.playback == nil, "out-of-range playback is dropped, the route kept");
    [dictionary setObject:@{ @"speedKmh": @12 } forKey:@"playback"];
    LSRoutePlayback *minimal = [[LSRouteArchive archiveFromDictionary:dictionary error:NULL] playback];
    CHECK(minimal && minimal.speedKmh == 12 && minimal.paceMultiplier == 1 && minimal.acceleration == 1 && !minimal.smooth, "missing playback values take defaults");
    [dictionary setObject:@{ @"speedKmh": @12, @"acceleration": @1.5 } forKey:@"playback"];
    CHECK([[LSRouteArchive archiveFromDictionary:dictionary error:NULL] playback] == nil, "a fractional motion profile is refused");
}

static void TestPlacesAndNames(void) {
    NSMutableDictionary *dictionary = Mutable(SampleRoute());
    // A copy: the Linux build has no ARC, and replacing the entry would free it.
    NSArray *places = [[dictionary objectForKey:@"places"] copy];
    [dictionary setObject:@[ [places objectAtIndex:0] ] forKey:@"places"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "one place is not a route");
    NSMutableArray *many = [NSMutableArray array];
    for (int index = 0; index < 13; index++) [many addObject:@{ @"name": @"P", @"lat": @(10 + index * 0.01), @"lon": @20 }];
    [dictionary setObject:many forKey:@"places"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "more than 10 stops is refused");
    [many removeLastObject];
    CHECK([[[LSRouteArchive archiveFromDictionary:dictionary error:NULL] places] count] == 12, "From, 10 stops and To are allowed");
    [dictionary setObject:@[ @{ @"lat": @10, @"lon": @20 }, @{ @"lat": @"ten", @"lon": @20 } ] forKey:@"places"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "an unreadable place is refused");
    [dictionary setObject:places forKey:@"places"];
    [dictionary setObject:@"   " forKey:@"name"];
    CHECK([LSRouteArchive archiveFromDictionary:dictionary error:NULL] == nil, "a blank name is refused");
    NSMutableString *longName = [NSMutableString string];
    for (int index = 0; index < 200; index++) [longName appendString:@"n"];
    [dictionary setObject:longName forKey:@"name"];
    CHECK([[[LSRouteArchive archiveFromDictionary:dictionary error:NULL] name] length] == 120, "long names are cut to 120");
    CHECK([LSRouteArchive validName:@" a "] && ![LSRouteArchive validName:@""] && ![LSRouteArchive validName:@3], "name validation");
    [dictionary setObject:@"not-a-uuid" forKey:@"id"];
    LSRouteArchive *fresh = [LSRouteArchive archiveFromDictionary:dictionary error:NULL];
    CHECK(fresh && [[NSUUID alloc] initWithUUIDString:fresh.identifier] != nil, "a bad identifier is replaced");
    CHECK([LSArchivedPlace placeWithName:@"x" latitude:NAN longitude:0] == nil && [LSArchivedPlace placeWithName:@"x" latitude:0 longitude:181] == nil, "unusable places");
}

static void TestCheckpoint(void) {
    LSRouteCheckpoint *checkpoint = [[LSRouteCheckpoint alloc] init];
    checkpoint.routeID = NSUUID.UUID.UUIDString;
    checkpoint.covered = 1234.56789;
    checkpoint.total = 5000.25;
    checkpoint.nextStop = 2;
    checkpoint.waitRemaining = 12.5;
    checkpoint.savedAt = [NSDate dateWithTimeIntervalSince1970:1762330000];
    checkpoint.playback = SampleRoute().playback;
    CHECK(checkpoint.isUnfinished, "part-way is unfinished");
    LSRouteCheckpoint *back = [LSRouteCheckpoint checkpointFromDictionary:ThroughJSON([checkpoint dictionaryRepresentation])];
    CHECK(back && [back.routeID isEqualToString:checkpoint.routeID] && NEAR(back.covered, 1234.56789, 1e-6) && NEAR(back.total, 5000.25, 1e-6) &&
          back.nextStop == 2 && NEAR(back.waitRemaining, 12.5, 1e-9) && NEAR(back.savedAt.timeIntervalSince1970, 1762330000, 1e-3), "checkpoint round trip");
    CHECK(back.playback && back.playback.smooth && NEAR(back.playback.speedKmh, 37.5, 1e-9), "checkpoint playback kept");
    NSMutableDictionary *dictionary = ThroughJSON([checkpoint dictionaryRepresentation]);
    [dictionary setObject:@5002 forKey:@"covered"];
    CHECK([LSRouteCheckpoint checkpointFromDictionary:dictionary] == nil, "past the end is refused");
    [dictionary setObject:@5000.5 forKey:@"covered"];
    LSRouteCheckpoint *end = [LSRouteCheckpoint checkpointFromDictionary:dictionary];
    CHECK(end && end.covered == 5000.25 && !end.isUnfinished, "rounding past the end clamps and is finished");
    [dictionary setObject:@0 forKey:@"total"];
    CHECK([LSRouteCheckpoint checkpointFromDictionary:dictionary] == nil, "no length is refused");
    dictionary = ThroughJSON([checkpoint dictionaryRepresentation]);
    [dictionary setObject:@"route" forKey:@"route"];
    CHECK([LSRouteCheckpoint checkpointFromDictionary:dictionary] == nil, "a bad route identifier is refused");
    dictionary = ThroughJSON([checkpoint dictionaryRepresentation]);
    [dictionary setObject:@2 forKey:@"v"];
    CHECK([LSRouteCheckpoint checkpointFromDictionary:dictionary] == nil, "another version is refused");
    dictionary = ThroughJSON([checkpoint dictionaryRepresentation]);
    [dictionary removeObjectForKey:@"playback"];
    CHECK([LSRouteCheckpoint checkpointFromDictionary:dictionary] == nil, "a checkpoint needs its playback");
    dictionary = ThroughJSON([checkpoint dictionaryRepresentation]);
    [dictionary setObject:@-4 forKey:@"wait"];
    [dictionary setObject:@1.5 forKey:@"stop"];
    back = [LSRouteCheckpoint checkpointFromDictionary:dictionary];
    CHECK(back && back.waitRemaining == 0 && back.nextStop == 0, "odd wait and stop values fall back to zero");
}

static NSURL *TemporaryFile(NSString *name) {
    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"lspoof-routes-%d", (int)getpid()]];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [folder stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    return [NSURL fileURLWithPath:path];
}

static LSRouteArchive *Named(NSString *name) {
    LSRouteArchive *route = SampleRoute();
    route.identifier = NSUUID.UUID.UUIDString;
    route.name = name;
    return route;
}

static void TestStore(void) {
    NSURL *file = TemporaryFile(@"SavedRoutes.json");
    LSRouteStore *store = [[LSRouteStore alloc] initWithFileURL:file];
    CHECK(store.allRoutes.count == 0, "a new store is empty");
    LSRouteArchive *first = Named(@"First"), *second = Named(@"Second");
    CHECK([store addRoute:first] && [store addRoute:second], "routes are added");
    CHECK(![store addRoute:first], "the same route is not added twice");
    CHECK([[[store.allRoutes objectAtIndex:0] name] isEqualToString:@"Second"], "newest first");
    CHECK([store renameRouteWithID:first.identifier name:@"  Renamed  "] && [[[store routeWithID:first.identifier] name] isEqualToString:@"Renamed"], "rename");
    CHECK(![store renameRouteWithID:first.identifier name:@" "] && ![store renameRouteWithID:@"missing" name:@"x"], "bad renames are refused");
    LSRouteArchive *invalid = Named(@"Invalid");
    invalid.places = @[];
    CHECK(![store addRoute:invalid], "an invalid route is refused");

    LSRouteStore *reloaded = [[LSRouteStore alloc] initWithFileURL:file];
    NSArray<LSRouteArchive *> *routes = reloaded.allRoutes;
    CHECK(routes.count == 2 && [[[routes objectAtIndex:1] name] isEqualToString:@"Renamed"], "routes survive a reload, in order");
    CHECK(routes.count == 2 && [[[routes objectAtIndex:1] coordinates] isEqualToData:first.coordinates], "their paths survive too");

    CHECK([store removeRouteWithID:second.identifier] && ![store removeRouteWithID:second.identifier], "remove once");
    CHECK([store insertRoute:second atIndex:0] && [[[store.allRoutes objectAtIndex:0] identifier] isEqualToString:second.identifier], "undo puts it back in place");

    // Capacity.
    for (NSUInteger index = store.allRoutes.count; index < LSRouteStore.capacity; index++) [store addRoute:Named([NSString stringWithFormat:@"Route %lu", (unsigned long)index])];
    CHECK(store.allRoutes.count == LSRouteStore.capacity, "fills to the capacity");
    CHECK(![store addRoute:Named(@"One too many")], "refuses past the capacity");
    CHECK([store importRoutes:@[ Named(@"Merged") ] replace:NO] == 0, "a merge never goes past the capacity");

    // Restore.
    LSRouteArchive *kept = Named(@"Kept");
    NSUInteger added = [store importRoutes:@[ kept, kept, Named(@"Other") ] replace:YES];
    CHECK(added == 2 && store.allRoutes.count == 2, "replace swaps the list and skips duplicates (%lu)", (unsigned long)added);
    added = [store importRoutes:@[ kept, Named(@"New") ] replace:NO];
    CHECK(added == 1 && store.allRoutes.count == 3, "merge skips a route already saved");
    CHECK([[[store.allRoutes lastObject] name] isEqualToString:@"New"], "merged routes go after the saved ones");

    // A damaged entry in the file is skipped, the rest load.
    NSMutableArray *entries = [NSMutableArray arrayWithObject:@{ @"v": @1, @"name": @"Broken" }];
    [entries addObject:[Named(@"Fine") dictionaryRepresentation]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"format": @"lspoof-routes", @"version": @1, @"routes": entries } options:0 error:NULL];
    NSURL *damaged = TemporaryFile(@"Damaged.json");
    [data writeToURL:damaged atomically:YES];
    NSArray *loaded = [[LSRouteStore alloc] initWithFileURL:damaged].allRoutes;
    CHECK(loaded.count == 1 && [[[loaded objectAtIndex:0] name] isEqualToString:@"Fine"], "damaged entries are skipped");
    [@"not json" writeToURL:damaged atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    CHECK([[LSRouteStore alloc] initWithFileURL:damaged].allRoutes.count == 0, "an unreadable file is an empty store");
    [NSFileManager.defaultManager removeItemAtURL:[file URLByDeletingLastPathComponent] error:NULL];
}

int main(void) {
    @autoreleasepool {
        TestRoundTrip();
        TestByteOrder();
        TestVersionsAndUnknownKeys();
        TestDamage();
        TestPlacesAndNames();
        TestCheckpoint();
        TestStore();
        printf("routearchive_tests: %d checks, %d failures\n", checks, failures);
    }
    return failures ? 1 : 0;
}
