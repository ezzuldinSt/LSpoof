#import "LSRouteArchive.h"
#include <math.h>
#include <string.h>

const NSInteger LSRouteArchiveVersion = 1;
// The same limits LSRoute applies to a path it builds.
const NSUInteger LSRouteArchiveMaximumPoints = 50000;
const NSUInteger LSRouteArchiveMaximumStops = 10;

static const double kLSArchiveEarthRadius = 6371008.8;

static BOOL LSArchiveCoordinateUsable(double latitude, double longitude) {
    return isfinite(latitude) && isfinite(longitude) && fabs(latitude) <= 90.0 && fabs(longitude) <= 180.0;
}

static id LSArchiveNumber(NSDictionary *dictionary, NSString *key) {
    id value = [dictionary objectForKey:key];
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? value : nil;
}

static NSString *LSArchiveUUID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 64) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    return uuid ? uuid.UUIDString : nil;
}

// Explicit little-endian float64s, so the bytes mean the same on every device.
static NSString *LSEncodeDoubles(NSData *data) {
    NSUInteger count = data.length / sizeof(double);
    const double *values = data.bytes;
    NSMutableData *packed = [NSMutableData dataWithLength:count * 8];
    uint8_t *bytes = packed.mutableBytes;
    for (NSUInteger index = 0; index < count; index++) {
        uint64_t bits;
        memcpy(&bits, &values[index], sizeof bits);
        for (NSUInteger shift = 0; shift < 8; shift++) bytes[index * 8 + shift] = (uint8_t)(bits >> (8 * shift));
    }
    return [packed base64EncodedStringWithOptions:0];
}

// nil unless the text decodes to whole doubles, all finite.
static NSData *LSDecodeDoubles(id text, NSUInteger maximum) {
    if (![text isKindOfClass:NSString.class] || [text length] > (maximum * 8 + 2) / 3 * 4 + 4) return nil;
    NSData *packed = [[NSData alloc] initWithBase64EncodedString:text options:0];
    if (!packed || packed.length % 8 || packed.length / 8 > maximum) return nil;
    NSUInteger count = packed.length / 8;
    NSMutableData *data = [NSMutableData dataWithLength:count * sizeof(double)];
    const uint8_t *bytes = packed.bytes;
    double *values = data.mutableBytes;
    for (NSUInteger index = 0; index < count; index++) {
        uint64_t bits = 0;
        for (NSUInteger shift = 0; shift < 8; shift++) bits |= (uint64_t)bytes[index * 8 + shift] << (8 * shift);
        memcpy(&values[index], &bits, sizeof bits);
        if (!isfinite(values[index])) return nil;
    }
    return data;
}

static double LSArchiveHaversine(double lat1, double lon1, double lat2, double lon2) {
    const double radians = M_PI / 180.0;
    double dLat = (lat2 - lat1) * radians;
    double dLon = remainder(lon2 - lon1, 360.0) * radians;
    double s = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2);
    return 2.0 * kLSArchiveEarthRadius * atan2(sqrt(s), sqrt(fmax(0.0, 1.0 - s)));
}

#pragma mark - Place

@interface LSArchivedLeg (LSArchiveCoding)
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)legFromDictionary:(id)dictionary;
@end

@interface LSArchivedPlace (LSArchiveCoding)
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)placeFromDictionary:(id)dictionary;
@end

@implementation LSArchivedPlace
+ (instancetype)placeWithName:(NSString *)name latitude:(double)latitude longitude:(double)longitude {
    if (!LSArchiveCoordinateUsable(latitude, longitude)) return nil;
    LSArchivedPlace *place = [[self alloc] init];
    NSString *trimmed = [name isKindOfClass:NSString.class] ? [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (trimmed.length > 120) trimmed = [trimmed substringToIndex:120];
    place->_name = [(trimmed.length ? trimmed : @"Map point") copy];
    place->_latitude = latitude;
    place->_longitude = longitude;
    return place;
}
- (NSString *)name { return _name; }
- (double)latitude { return _latitude; }
- (double)longitude { return _longitude; }
- (NSDictionary *)dictionaryRepresentation {
    return @{ @"name": _name, @"lat": @(_latitude), @"lon": @(_longitude) };
}
+ (instancetype)placeFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    id lat = LSArchiveNumber(dictionary, @"lat"), lon = LSArchiveNumber(dictionary, @"lon");
    if (!lat || !lon) return nil;
    return [self placeWithName:[dictionary objectForKey:@"name"] latitude:[lat doubleValue] longitude:[lon doubleValue]];
}
@end

#pragma mark - Leg

@implementation LSArchivedLeg
+ (instancetype)legWithPath:(NSString *)path speedKmh:(double)speedKmh end:(double)end expectedTravelTime:(double)eta {
    if (![path isKindOfClass:NSString.class] || ![path length] || [path length] > 32) return nil;
    LSArchivedLeg *leg = [[self alloc] init];
    leg->_path = [path copy];
    leg->_speedKmh = isfinite(speedKmh) && speedKmh >= 1 && speedKmh <= 500 ? speedKmh : NAN;
    leg->_end = isfinite(end) && end >= 0 ? end : NAN;
    leg->_expectedTravelTime = isfinite(eta) && eta > 0 ? eta : 0;
    return leg;
}
- (NSString *)path { return _path; }
- (double)speedKmh { return _speedKmh; }
- (double)end { return _end; }
- (double)expectedTravelTime { return _expectedTravelTime; }
- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setObject:_path forKey:@"path"];
    if (isfinite(_speedKmh)) [dictionary setObject:@(_speedKmh) forKey:@"speedKmh"];
    if (isfinite(_end)) [dictionary setObject:@(_end) forKey:@"end"];
    [dictionary setObject:@(_expectedTravelTime) forKey:@"eta"];
    return dictionary;
}
+ (instancetype)legFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    id speed = LSArchiveNumber(dictionary, @"speedKmh"), end = LSArchiveNumber(dictionary, @"end"), eta = LSArchiveNumber(dictionary, @"eta");
    return [self legWithPath:[dictionary objectForKey:@"path"] speedKmh:speed ? [speed doubleValue] : NAN
                         end:end ? [end doubleValue] : NAN expectedTravelTime:eta ? [eta doubleValue] : 0];
}
@end

#pragma mark - Playback

@implementation LSRoutePlayback
@synthesize speedKmh = _speedKmh, recordedPace = _recordedPace, paceMultiplier = _paceMultiplier, smooth = _smooth,
    acceleration = _acceleration, stopDwell = _stopDwell;
- (instancetype)init {
    self = [super init];
    if (self) {
        _speedKmh = 5;
        _paceMultiplier = 1;
        _acceleration = 1;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    LSRoutePlayback *copy = [[[self class] allocWithZone:zone] init];
    copy.speedKmh = _speedKmh;
    copy.recordedPace = _recordedPace;
    copy.paceMultiplier = _paceMultiplier;
    copy.smooth = _smooth;
    copy.acceleration = _acceleration;
    copy.stopDwell = _stopDwell;
    return copy;
}
- (BOOL)isValid {
    return isfinite(_speedKmh) && _speedKmh >= 1 && _speedKmh <= 500 &&
        isfinite(_paceMultiplier) && _paceMultiplier >= 0.1 && _paceMultiplier <= 20 &&
        _acceleration >= 0 && _acceleration <= 2 && isfinite(_stopDwell) && _stopDwell >= 0 && _stopDwell <= 3600;
}
- (NSDictionary *)dictionaryRepresentation {
    return @{ @"speedKmh": @(_speedKmh), @"recordedPace": @(_recordedPace), @"paceMultiplier": @(_paceMultiplier),
              @"smooth": @(_smooth), @"acceleration": @(_acceleration), @"stopDwell": @(_stopDwell) };
}
+ (instancetype)playbackFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    LSRoutePlayback *playback = [[self alloc] init];
    id speed = LSArchiveNumber(dictionary, @"speedKmh");
    if (!speed) return nil;
    playback.speedKmh = [speed doubleValue];
    // Optional values keep their defaults when missing.
    id value;
    if ((value = LSArchiveNumber(dictionary, @"recordedPace"))) playback.recordedPace = [value boolValue];
    if ((value = LSArchiveNumber(dictionary, @"paceMultiplier"))) playback.paceMultiplier = [value doubleValue];
    if ((value = LSArchiveNumber(dictionary, @"smooth"))) playback.smooth = [value boolValue];
    if ((value = LSArchiveNumber(dictionary, @"acceleration"))) {
        double level = [value doubleValue];
        if (level != floor(level)) return nil;
        playback.acceleration = (NSInteger)level;
    }
    if ((value = LSArchiveNumber(dictionary, @"stopDwell"))) playback.stopDwell = [value doubleValue];
    return playback.isValid ? playback : nil;
}
@end

#pragma mark - Route

@implementation LSRouteArchive
@synthesize identifier = _identifier, name = _name, createdAt = _createdAt, places = _places, path = _path, fromTrack = _fromTrack,
    coordinates = _coordinates, times = _times, stops = _stops, expectedTravelTime = _expectedTravelTime,
    recordedStartDate = _recordedStartDate, playback = _playback, legs = _legs;

- (instancetype)init {
    self = [super init];
    if (self) {
        self.identifier = NSUUID.UUID.UUIDString;
        self.name = @"Route";
        self.createdAt = [NSDate date];
        self.places = @[];
        self.path = @"walking";
        self.stops = @[];
        self.legs = @[];
        _cachedDistance = NAN;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    LSRouteArchive *copy = [[[self class] allocWithZone:zone] init];
    copy.identifier = _identifier;
    copy.name = _name;
    copy.createdAt = _createdAt;
    copy.places = _places;
    copy.path = _path;
    copy.fromTrack = _fromTrack;
    copy.coordinates = _coordinates;
    copy.times = _times;
    copy.stops = _stops;
    copy.expectedTravelTime = _expectedTravelTime;
    copy.recordedStartDate = _recordedStartDate;
    copy.playback = _playback;
    copy.legs = _legs;
    copy->_cachedDistance = _cachedDistance;
    return copy;
}

- (void)setCoordinates:(NSData *)coordinates {
    _coordinates = [coordinates copy];
    _cachedDistance = NAN;
}

- (NSUInteger)pointCount { return _coordinates.length / (2 * sizeof(double)); }

- (double)distance {
    if (isfinite(_cachedDistance)) return _cachedDistance;
    NSUInteger count = self.pointCount;
    const double *values = _coordinates.bytes;
    double total = 0;
    for (NSUInteger index = 1; index < count; index++) {
        total += LSArchiveHaversine(values[2 * index - 2], values[2 * index - 1], values[2 * index], values[2 * index + 1]);
    }
    _cachedDistance = isfinite(total) ? total : 0;
    return _cachedDistance;
}

- (NSUInteger)plannedStopCount { return _places.count > 2 ? _places.count - 2 : 0; }

+ (NSString *)validName:(id)name {
    if (![name isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length && trimmed.length <= 120 ? trimmed : nil;
}

- (BOOL)isValid {
    if (![LSRouteArchive validName:_name] || !LSArchiveUUID(_identifier) || !_createdAt) return NO;
    if (_places.count < 2 || _places.count > LSRouteArchiveMaximumStops + 2) return NO;
    if (_fromTrack && self.pointCount < 2) return NO;
    if (_coordinates && (_coordinates.length % (2 * sizeof(double)) || self.pointCount < 2 || self.pointCount > LSRouteArchiveMaximumPoints)) return NO;
    if (_times && (!_coordinates || _times.length != self.pointCount * sizeof(double))) return NO;
    return YES;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *places = [NSMutableArray array];
    for (LSArchivedPlace *place in _places) [places addObject:[place dictionaryRepresentation]];
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setObject:@(LSRouteArchiveVersion) forKey:@"v"];
    [dictionary setObject:_identifier forKey:@"id"];
    [dictionary setObject:_name forKey:@"name"];
    [dictionary setObject:@(_createdAt.timeIntervalSince1970) forKey:@"created"];
    [dictionary setObject:_path forKey:@"path"];
    if (_fromTrack) [dictionary setObject:[NSNumber numberWithBool:YES] forKey:@"track"];
    [dictionary setObject:places forKey:@"places"];
    if (self.pointCount >= 2) {
        NSMutableDictionary *geometry = [NSMutableDictionary dictionary];
        [geometry setObject:LSEncodeDoubles(_coordinates) forKey:@"coords"];
        if (_times) [geometry setObject:LSEncodeDoubles(_times) forKey:@"times"];
        [geometry setObject:_stops ?: @[] forKey:@"stops"];
        [geometry setObject:@(isfinite(_expectedTravelTime) ? _expectedTravelTime : 0) forKey:@"eta"];
        if (_recordedStartDate) [geometry setObject:@(_recordedStartDate.timeIntervalSince1970) forKey:@"start"];
        [dictionary setObject:geometry forKey:@"geometry"];
    }
    if (_playback.isValid) [dictionary setObject:[_playback dictionaryRepresentation] forKey:@"playback"];
    if (_legs.count && _legs.count + 1 == _places.count) {
        NSMutableArray *legs = [NSMutableArray arrayWithCapacity:_legs.count];
        for (LSArchivedLeg *leg in _legs) [legs addObject:[leg dictionaryRepresentation]];
        [dictionary setObject:legs forKey:@"legs"];
    }
    return dictionary;
}

// Reads the path. Returns NO when it is present but unusable.
- (BOOL)readGeometry:(id)geometry {
    if (!geometry) return YES;
    if (![geometry isKindOfClass:NSDictionary.class]) return NO;
    NSData *coordinates = LSDecodeDoubles([geometry objectForKey:@"coords"], 2 * LSRouteArchiveMaximumPoints);
    NSUInteger count = coordinates.length / (2 * sizeof(double));
    if (!coordinates || coordinates.length % (2 * sizeof(double)) || count < 2) return NO;
    const double *values = coordinates.bytes;
    for (NSUInteger index = 0; index < count; index++) {
        if (!LSArchiveCoordinateUsable(values[2 * index], values[2 * index + 1])) return NO;
    }
    self.coordinates = coordinates;
    // Unusable timing only loses the recorded pace.
    NSData *times = LSDecodeDoubles([geometry objectForKey:@"times"], LSRouteArchiveMaximumPoints);
    if (times && times.length == count * sizeof(double)) {
        const double *offsets = times.bytes;
        BOOL ordered = YES;
        for (NSUInteger index = 1; index < count && ordered; index++) ordered = offsets[index] >= offsets[index - 1];
        if (ordered && offsets[count - 1] > offsets[0]) self.times = times;
    }
    NSMutableArray *stops = [NSMutableArray array];
    id entries = [geometry objectForKey:@"stops"];
    for (id stop in [entries isKindOfClass:NSArray.class] ? entries : @[]) {
        if (![stop isKindOfClass:NSArray.class] || [stop count] != 2) continue;
        id meters = [stop objectAtIndex:0], seconds = [stop objectAtIndex:1];
        if (![meters isKindOfClass:NSNumber.class] || ![seconds isKindOfClass:NSNumber.class]) continue;
        double distance = [meters doubleValue], dwell = [seconds doubleValue];
        if (!isfinite(distance) || distance <= 0 || !isfinite(dwell) || dwell > 86400) continue;
        if (stops.count && distance <= [[stops.lastObject objectAtIndex:0] doubleValue]) continue;
        [stops addObject:@[ @(distance), @(dwell < 0 ? -1.0 : dwell) ]];
        if (stops.count >= 10000) break;
    }
    self.stops = stops;
    id eta = LSArchiveNumber(geometry, @"eta");
    self.expectedTravelTime = eta && [eta doubleValue] >= 0 ? [eta doubleValue] : 0;
    id start = LSArchiveNumber(geometry, @"start");
    if (start && self.times) self.recordedStartDate = [NSDate dateWithTimeIntervalSince1970:[start doubleValue]];
    return YES;
}

+ (instancetype)archiveFromDictionary:(id)dictionary error:(NSString **)error {
    if (![dictionary isKindOfClass:NSDictionary.class]) { if (error) *error = @"The route is not readable."; return nil; }
    id version = LSArchiveNumber(dictionary, @"v");
    if (!version || [version doubleValue] < 1 || [version doubleValue] != floor([version doubleValue])) {
        if (error) *error = @"The route has no version.";
        return nil;
    }
    if ([version integerValue] > LSRouteArchiveVersion) { if (error) *error = @"The route was saved by a newer LSpoof."; return nil; }
    LSRouteArchive *archive = [[self alloc] init];
    NSString *identifier = LSArchiveUUID([dictionary objectForKey:@"id"]);
    if (identifier) archive.identifier = identifier;
    id rawName = [dictionary objectForKey:@"name"];
    NSString *name = [rawName isKindOfClass:NSString.class] ? [rawName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    if (name.length > 120) name = [name substringToIndex:120];
    if (!name.length) { if (error) *error = @"The route has no name."; return nil; }
    archive.name = name;
    id created = LSArchiveNumber(dictionary, @"created");
    if (created) archive.createdAt = [NSDate dateWithTimeIntervalSince1970:[created doubleValue]];
    id path = [dictionary objectForKey:@"path"];
    // A path kind this version doesn't know (say, from a later LSpoof) is kept as it is.
    if ([path isKindOfClass:NSString.class] && [path length] && [path length] <= 32) archive.path = path;
    archive.fromTrack = [[dictionary objectForKey:@"track"] isEqual:[NSNumber numberWithBool:YES]];
    NSMutableArray *places = [NSMutableArray array];
    id entries = [dictionary objectForKey:@"places"];
    for (id entry in [entries isKindOfClass:NSArray.class] ? entries : @[]) {
        LSArchivedPlace *place = [LSArchivedPlace placeFromDictionary:entry];
        if (!place) { if (error) *error = @"A place in the route is not readable."; return nil; }
        [places addObject:place];
    }
    if (places.count < 2 || places.count > LSRouteArchiveMaximumStops + 2) {
        if (error) *error = @"The route needs From, To and at most 10 stops.";
        return nil;
    }
    archive.places = places;
    if (![archive readGeometry:[dictionary objectForKey:@"geometry"]]) {
        archive.coordinates = nil;
        archive.times = nil;
        archive.stops = @[];
        archive.recordedStartDate = nil;
        if (archive.fromTrack) { if (error) *error = @"The recorded track in the route is damaged."; return nil; }
    }
    if (archive.fromTrack && archive.pointCount < 2) { if (error) *error = @"The recorded track in the route is missing."; return nil; }
    archive.playback = [LSRoutePlayback playbackFromDictionary:[dictionary objectForKey:@"playback"]];
    // Legs only count as a whole: one per pair of places, each readable. Their ends refer to the
    // stored path, so without one they are dropped.
    id legEntries = [dictionary objectForKey:@"legs"];
    NSMutableArray<LSArchivedLeg *> *legs = [NSMutableArray array];
    for (id entry in [legEntries isKindOfClass:NSArray.class] ? legEntries : @[]) {
        LSArchivedLeg *leg = [LSArchivedLeg legFromDictionary:entry];
        if (!leg) { [legs removeAllObjects]; break; }
        if (archive.pointCount < 2) leg = [LSArchivedLeg legWithPath:leg.path speedKmh:leg.speedKmh end:NAN expectedTravelTime:leg.expectedTravelTime];
        [legs addObject:leg];
    }
    archive.legs = legs.count + 1 == places.count ? legs : @[];
    return archive;
}
@end

#pragma mark - Checkpoint

@implementation LSRouteCheckpoint
@synthesize routeID = _routeID, covered = _covered, total = _total, nextStop = _nextStop, waitRemaining = _waitRemaining,
    savedAt = _savedAt, playback = _playback;
- (instancetype)init {
    self = [super init];
    if (self) {
        self.routeID = @"";
        self.savedAt = [NSDate date];
        self.playback = [[LSRoutePlayback alloc] init];
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    LSRouteCheckpoint *copy = [[[self class] allocWithZone:zone] init];
    copy.routeID = _routeID;
    copy.covered = _covered;
    copy.total = _total;
    copy.nextStop = _nextStop;
    copy.waitRemaining = _waitRemaining;
    copy.savedAt = _savedAt;
    copy.playback = _playback;
    return copy;
}
- (BOOL)isUnfinished { return _total > 0 && _covered < _total - 0.5; }
- (NSDictionary *)dictionaryRepresentation {
    return @{ @"v": @(LSRouteArchiveVersion), @"route": _routeID, @"covered": @(_covered), @"total": @(_total),
              @"stop": @(_nextStop), @"wait": @(_waitRemaining), @"at": @(_savedAt.timeIntervalSince1970),
              @"playback": [_playback dictionaryRepresentation] };
}
+ (instancetype)checkpointFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    id version = LSArchiveNumber(dictionary, @"v");
    if (!version || [version integerValue] != LSRouteArchiveVersion) return nil;
    NSString *route = LSArchiveUUID([dictionary objectForKey:@"route"]);
    id covered = LSArchiveNumber(dictionary, @"covered"), total = LSArchiveNumber(dictionary, @"total");
    id stop = LSArchiveNumber(dictionary, @"stop"), wait = LSArchiveNumber(dictionary, @"wait"), at = LSArchiveNumber(dictionary, @"at");
    LSRoutePlayback *playback = [LSRoutePlayback playbackFromDictionary:[dictionary objectForKey:@"playback"]];
    if (!route || !covered || !total || !playback) return nil;
    double meters = [covered doubleValue], length = [total doubleValue];
    if (meters < 0 || !(length > 0) || meters > length + 1) return nil;
    LSRouteCheckpoint *checkpoint = [[self alloc] init];
    checkpoint.routeID = route;
    checkpoint.covered = MIN(meters, length);
    checkpoint.total = length;
    double next = stop ? [stop doubleValue] : 0;
    checkpoint.nextStop = next >= 0 && next <= 100000 && next == floor(next) ? (NSUInteger)next : 0;
    double seconds = wait ? [wait doubleValue] : 0;
    checkpoint.waitRemaining = seconds > 0 && seconds <= 86400 ? seconds : 0;
    if (at) checkpoint.savedAt = [NSDate dateWithTimeIntervalSince1970:[at doubleValue]];
    checkpoint.playback = playback;
    return checkpoint;
}
@end
