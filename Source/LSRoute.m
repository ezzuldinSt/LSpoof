#import "LSRoute.h"
#import "RouteGeometry.h"

static const double kLSEarthRadius = 6371008.8;
// A timed track that stays within this many meters is standing still.
static const double kLSStationaryMeters = 2.0;
static const NSTimeInterval kLSPauseSeconds = 15.0;
static const NSUInteger kLSMaximumPoints = 50000;

static double LSHaversine(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    const double radians = M_PI / 180.0;
    double dLat = (b.latitude - a.latitude) * radians;
    double dLon = remainder(b.longitude - a.longitude, 360.0) * radians;
    double s = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * sin(dLon / 2) * sin(dLon / 2);
    return 2.0 * kLSEarthRadius * atan2(sqrt(s), sqrt(fmax(0.0, 1.0 - s)));
}

static BOOL LSCoordinateUsable(CLLocationCoordinate2D coordinate) {
    return isfinite(coordinate.latitude) && isfinite(coordinate.longitude) && CLLocationCoordinate2DIsValid(coordinate);
}

NSString *LSArchivePathForTransportType(MKDirectionsTransportType type) {
    if (type == MKDirectionsTransportTypeAutomobile) return @"driving";
    if (type == MKDirectionsTransportTypeTransit) return @"transit";
    return @"walking";
}

MKDirectionsTransportType LSTransportTypeForArchivePath(NSString *path, MKDirectionsTransportType fallback) {
    if ([path isEqual:@"driving"]) return MKDirectionsTransportTypeAutomobile;
    if ([path isEqual:@"walking"]) return MKDirectionsTransportTypeWalking;
    if ([path isEqual:@"transit"]) return MKDirectionsTransportTypeTransit;
    return fallback;
}

@implementation LSRouteWaypoint
+ (instancetype)waypointWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate {
    LSRouteWaypoint *waypoint = [[self alloc] init];
    NSString *trimmed = [name isKindOfClass:NSString.class] ? [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (trimmed.length > 120) trimmed = [trimmed substringToIndex:120];
    waypoint->_name = trimmed.length ? [trimmed copy] : @"Map point";
    waypoint->_coordinate = coordinate;
    return waypoint;
}
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
@end

// A km/h value a leg can play at, or NAN for the route speed.
static double LSLegSpeed(id value) {
    double kmh = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : NAN;
    return isfinite(kmh) && kmh >= 1.0 && kmh <= 500.0 ? kmh : NAN;
}

static BOOL LSTransportUsable(MKDirectionsTransportType type) {
    return type == MKDirectionsTransportTypeAutomobile || type == MKDirectionsTransportTypeWalking || type == MKDirectionsTransportTypeTransit;
}

@implementation LSRouteLegPath
+ (instancetype)pathWithRoute:(MKRoute *)route {
    if (![route isKindOfClass:MKRoute.class]) return nil;
    return [self pathWithPolyline:route.polyline expectedTravelTime:route.expectedTravelTime transportType:route.transportType];
}
+ (instancetype)pathWithPolyline:(MKPolyline *)polyline expectedTravelTime:(NSTimeInterval)time transportType:(MKDirectionsTransportType)transportType {
    if (![polyline isKindOfClass:MKPolyline.class] || polyline.pointCount < 2) return nil;
    LSRouteLegPath *path = [[self alloc] init];
    path->_polyline = polyline;
    path->_expectedTravelTime = isfinite(time) && time > 0 ? time : 0;
    path->_transportType = transportType;
    return path;
}
@end

@interface LSRouteLeg ()
+ (instancetype)legWithType:(MKDirectionsTransportType)type speed:(double)kmh start:(double)start end:(double)end eta:(NSTimeInterval)eta;
- (instancetype)legWithSpeed:(double)kmh;
@end

@implementation LSRouteLeg
+ (instancetype)legWithType:(MKDirectionsTransportType)type speed:(double)kmh start:(double)start end:(double)end eta:(NSTimeInterval)eta {
    LSRouteLeg *leg = [[self alloc] init];
    leg->_transportType = type;
    leg->_speedKmh = LSLegSpeed(@(kmh));
    leg->_startDistance = start;
    leg->_endDistance = MAX(start, end);
    leg->_expectedTravelTime = isfinite(eta) && eta > 0 ? eta : 0;
    return leg;
}
- (BOOL)hasOwnSpeed { return isfinite(self.speedKmh); }
- (instancetype)legWithSpeed:(double)kmh {
    return [LSRouteLeg legWithType:self.transportType speed:kmh start:self.startDistance end:self.endDistance eta:self.expectedTravelTime];
}
@end

@interface LSRoute () {
    NSMutableData *_coordinateData;
    NSMutableData *_cumulativeData;
    NSMutableData *_timeData;
    NSMutableData *_pauseData;
    // Distance along the path of each stop marker passed to initWithRaw, in order.
    NSArray<NSNumber *> *_markerDistances;
}
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *stopDistances;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *stopDwells;
@property (nonatomic, readwrite, copy) NSArray<LSRouteWaypoint *> *waypoints;
@property (nonatomic, readwrite, copy) NSArray<LSRouteLeg *> *legs;
@property (nonatomic, readwrite) MKDirectionsTransportType transportType;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) NSTimeInterval expectedTravelTime;
@property (nonatomic, readwrite, nullable) NSDate *recordedStartDate;
@property (nonatomic, readwrite) BOOL fromTrack;
@property (nonatomic, readwrite) MKPolyline *polyline;
@end

@implementation LSRoute

- (NSUInteger)pointCount { return _coordinateData.length / sizeof(CLLocationCoordinate2D); }
- (const CLLocationCoordinate2D *)coordinates { return _coordinateData.bytes; }
- (const double *)cumulativeDistances { return _cumulativeData.bytes; }
- (const double *)timeOffsets { return _timeData.bytes; }
- (BOOL)hasTiming { return _timeData != nil; }
- (double)distance { return self.pointCount ? self.cumulativeDistances[self.pointCount - 1] : 0.0; }
- (NSUInteger)plannedStopCount { return self.waypoints.count > 2 ? self.waypoints.count - 2 : 0; }
- (BOOL)hasLegSettings {
    for (LSRouteLeg *leg in self.legs) if (leg.hasOwnSpeed || leg.transportType != self.transportType) return YES;
    return NO;
}
- (NSTimeInterval)recordedDuration {
    if (!_timeData || self.pointCount < 2) return 0.0;
    return self.timeOffsets[self.pointCount - 1] - self.timeOffsets[0];
}

// Builds the processed arrays: drops invalid and duplicate points, turns long
// stationary stretches of a timed track into pauses, and maps stop markers.
- (nullable instancetype)initWithRaw:(const CLLocationCoordinate2D *)raw times:(const double *)rawTimes count:(NSUInteger)count
                       stopMarkers:(NSArray<NSNumber *> *)markers {
    self = [super init];
    if (!self || !raw || count < 2) return nil;
    // Thinning keeps every stride-th point plus the last one and each stop marker; leave room
    // for those, or a long path kept a few points over the limit and could not be read back.
    NSUInteger budget = kLSMaximumPoints - 1 - MIN(markers.count, kLSMaximumPoints / 2);
    NSUInteger stride = count > kLSMaximumPoints ? (count + budget - 1) / budget : 1;
    BOOL timed = rawTimes != NULL;
    _coordinateData = [NSMutableData data];
    _cumulativeData = [NSMutableData data];
    NSMutableData *times = timed ? [NSMutableData data] : nil;
    NSMutableData *pauses = timed ? [NSMutableData data] : nil;
    NSMutableArray<NSNumber *> *keptForRaw = [NSMutableArray arrayWithCapacity:count];
    CLLocationCoordinate2D last = kCLLocationCoordinate2DInvalid;
    double cumulative = 0.0, lastTime = NAN, stillUntil = NAN;
    NSInteger keptCount = 0;
    NSSet<NSNumber *> *markerSet = [NSSet setWithArray:markers ?: @[]];
    for (NSUInteger index = 0; index < count; index++) {
        CLLocationCoordinate2D coordinate = raw[index];
        double time = timed ? rawTimes[index] : NAN;
        BOOL isMarker = [markerSet containsObject:@(index)];
        BOOL isLast = index + 1 == count;
        if (!LSCoordinateUsable(coordinate)) { [keptForRaw addObject:@(keptCount - 1)]; continue; }
        if (timed && (!isfinite(time) || (isfinite(lastTime) && time < lastTime - 1e-6))) { timed = NO; times = nil; pauses = nil; }
        if (keptCount > 0) {
            double step = LSHaversine(last, coordinate);
            double minimum = timed ? kLSStationaryMeters : 0.05;
            BOOL decimated = stride > 1 && index % stride != 0 && !isMarker && !isLast;
            if (step < minimum || decimated || !isfinite(step)) {
                if (timed && step < minimum) stillUntil = time;
                [keptForRaw addObject:@(keptCount - 1)];
                continue;
            }
            if (timed && isfinite(stillUntil)) {
                double pause = stillUntil - lastTime;
                double *pauseValues = pauses.mutableBytes;
                if (pause >= kLSPauseSeconds) {
                    if (keptCount == 1) ((double *)times.mutableBytes)[0] = stillUntil;
                    else pauseValues[keptCount - 1] = pause;
                }
            }
            stillUntil = NAN;
            cumulative += step;
        }
        [_coordinateData appendBytes:&coordinate length:sizeof(coordinate)];
        [_cumulativeData appendBytes:&cumulative length:sizeof(cumulative)];
        if (timed) {
            double zero = 0.0;
            [times appendBytes:&time length:sizeof(time)];
            [pauses appendBytes:&zero length:sizeof(zero)];
        }
        last = coordinate;
        lastTime = time;
        keptCount++;
        [keptForRaw addObject:@(keptCount - 1)];
    }
    if (keptCount < 2 || !(cumulative > 0.0) || !isfinite(cumulative)) return nil;
    // Offsets start at zero; the first entry may have moved to its departure.
    if (timed) {
        double *values = times.mutableBytes;
        double origin = values[0];
        for (NSInteger index = 0; index < keptCount; index++) values[index] -= origin;
        if (!(values[keptCount - 1] > 0.0)) { times = nil; pauses = nil; }
    }
    _timeData = times;
    _pauseData = pauses;
    NSMutableArray<NSNumber *> *distances = [NSMutableArray array], *dwells = [NSMutableArray array];
    const double *cumulativeValues = _cumulativeData.bytes;
    NSMutableDictionary<NSNumber *, NSNumber *> *stops = [NSMutableDictionary dictionary];
    for (NSNumber *marker in markers) {
        NSUInteger rawIndex = marker.unsignedIntegerValue;
        if (rawIndex >= keptForRaw.count) continue;
        NSInteger kept = keptForRaw[rawIndex].integerValue;
        if (kept <= 0 || kept >= keptCount - 1) continue;
        stops[@(kept)] = @(-1.0);
    }
    if (_pauseData) {
        const double *pauseValues = _pauseData.bytes;
        for (NSInteger index = 1; index < keptCount - 1; index++) {
            if (pauseValues[index] > 0.0 && !stops[@(index)]) stops[@(index)] = @(pauseValues[index]);
        }
    }
    for (NSNumber *kept in [stops.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [distances addObject:@(cumulativeValues[kept.integerValue])];
        [dwells addObject:stops[kept]];
    }
    // Where each leg ends, at the same point as its stop, so the two agree exactly.
    NSMutableArray<NSNumber *> *markerDistances = [NSMutableArray arrayWithCapacity:markers.count];
    for (NSNumber *marker in markers) {
        NSUInteger rawIndex = marker.unsignedIntegerValue;
        NSInteger kept = rawIndex < keptForRaw.count ? keptForRaw[rawIndex].integerValue : keptCount - 1;
        [markerDistances addObject:@(cumulativeValues[MAX(0, MIN(keptCount - 1, kept))])];
    }
    _markerDistances = [markerDistances copy];
    _stopDistances = [distances copy];
    _stopDwells = [dwells copy];
    _waypoints = @[];
    _legs = @[];
    _name = @"Route";
    _transportType = MKDirectionsTransportTypeAny;
    _polyline = [MKPolyline polylineWithCoordinates:(CLLocationCoordinate2D *)_coordinateData.bytes count:(NSUInteger)keptCount];
    return self;
}

+ (instancetype)routeWithLegs:(NSArray<MKRoute *> *)legs waypoints:(NSArray<LSRouteWaypoint *> *)waypoints {
    NSMutableArray<LSRouteLegPath *> *paths = [NSMutableArray arrayWithCapacity:legs.count];
    for (MKRoute *leg in legs) {
        LSRouteLegPath *path = [LSRouteLegPath pathWithRoute:leg];
        if (!path) return nil;
        [paths addObject:path];
    }
    return [self routeWithLegPaths:paths waypoints:waypoints transportType:legs.firstObject.transportType legSpeeds:nil];
}

+ (instancetype)routeWithLegPaths:(NSArray<LSRouteLegPath *> *)paths waypoints:(NSArray<LSRouteWaypoint *> *)waypoints
                    transportType:(MKDirectionsTransportType)transportType legSpeeds:(NSArray<NSNumber *> *)speeds {
    if (!paths.count || waypoints.count != paths.count + 1 || (speeds && speeds.count != paths.count)) return nil;
    NSMutableData *raw = [NSMutableData data];
    NSMutableArray<NSNumber *> *markers = [NSMutableArray array];
    NSTimeInterval eta = 0;
    for (NSUInteger legIndex = 0; legIndex < paths.count; legIndex++) {
        MKPolyline *polyline = paths[legIndex].polyline;
        NSUInteger count = polyline.pointCount;
        if (count < 2) return nil;
        CLLocationCoordinate2D *buffer = malloc(sizeof(CLLocationCoordinate2D) * count);
        if (!buffer) return nil;
        [polyline getCoordinates:buffer range:NSMakeRange(0, count)];
        [raw appendBytes:buffer length:sizeof(CLLocationCoordinate2D) * count];
        free(buffer);
        if (legIndex + 1 < paths.count) [markers addObject:@(raw.length / sizeof(CLLocationCoordinate2D) - 1)];
        eta += paths[legIndex].expectedTravelTime;
    }
    LSRoute *route = [[self alloc] initWithRaw:raw.bytes times:NULL count:raw.length / sizeof(CLLocationCoordinate2D) stopMarkers:markers];
    if (!route) return nil;
    route.waypoints = waypoints;
    route.transportType = transportType;
    route.expectedTravelTime = eta;
    route.name = [NSString stringWithFormat:@"%@ to %@", waypoints.firstObject.name, waypoints.lastObject.name];
    NSMutableArray<LSRouteLeg *> *legs = [NSMutableArray arrayWithCapacity:paths.count];
    double start = 0.0;
    for (NSUInteger legIndex = 0; legIndex < paths.count; legIndex++) {
        double end = legIndex + 1 < paths.count ? route->_markerDistances[legIndex].doubleValue : route.distance;
        [legs addObject:[LSRouteLeg legWithType:paths[legIndex].transportType speed:speeds ? LSLegSpeed(speeds[legIndex]) : NAN
                                          start:start end:end eta:paths[legIndex].expectedTravelTime]];
        start = MAX(start, end);
    }
    route.legs = legs;
    return route;
}

// Legs for a route stored before legs had their own settings, or a track: each follows the
// route, and ends at its planned stop (or, failing that, the point nearest its waypoint).
- (void)useDefaultLegs {
    NSUInteger count = self.waypoints.count >= 2 ? self.waypoints.count - 1 : 1;
    NSMutableArray<NSNumber *> *ends = [NSMutableArray array];
    for (NSUInteger index = 0; index < self.stopDistances.count; index++) {
        if (self.stopDwells[index].doubleValue < 0) [ends addObject:self.stopDistances[index]];
    }
    if (ends.count != count - 1) {
        [ends removeAllObjects];
        NSUInteger from = 0, pointCount = self.pointCount;
        for (NSUInteger stop = 1; stop < count; stop++) {
            CLLocationCoordinate2D target = self.waypoints[stop].coordinate;
            NSUInteger best = from;
            double bestMeters = INFINITY;
            for (NSUInteger index = from; index < pointCount; index++) {
                double meters = LSHaversine(self.coordinates[index], target);
                if (meters < bestMeters) { bestMeters = meters; best = index; }
            }
            [ends addObject:@(self.cumulativeDistances[best])];
            from = best;
        }
    }
    NSMutableArray<LSRouteLeg *> *legs = [NSMutableArray arrayWithCapacity:count];
    double start = 0.0, total = self.distance;
    for (NSUInteger index = 0; index < count; index++) {
        double end = index + 1 < count ? MAX(start, MIN(total, ends[index].doubleValue)) : total;
        double share = total > 0 ? (end - start) / total : 0;
        [legs addObject:[LSRouteLeg legWithType:self.transportType speed:NAN start:start end:end eta:self.expectedTravelTime * share]];
        start = end;
    }
    self.legs = legs;
}

+ (instancetype)routeWithCoordinates:(const CLLocationCoordinate2D *)coordinates times:(const double *)times count:(NSUInteger)count
                                name:(NSString *)name transportType:(MKDirectionsTransportType)transportType startDate:(NSDate *)startDate {
    LSRoute *route = [[self alloc] initWithRaw:coordinates times:times count:count stopMarkers:@[]];
    if (!route) return nil;
    NSString *title = [name isKindOfClass:NSString.class] && name.length ? name : @"Imported track";
    route.name = title.length > 120 ? [title substringToIndex:120] : title;
    route.transportType = transportType;
    route.recordedStartDate = route.hasTiming ? startDate : nil;
    route.fromTrack = YES;
    route.waypoints = @[[LSRouteWaypoint waypointWithName:@"Track start" coordinate:route.coordinates[0]],
                        [LSRouteWaypoint waypointWithName:@"Track end" coordinate:route.coordinates[route.pointCount - 1]]];
    [route useDefaultLegs];
    return route;
}

- (NSData *)recordedSegmentSpeeds {
    if (!_timeData || self.pointCount < 2) return nil;
    NSUInteger count = self.pointCount;
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(double) * count];
    double *speeds = data.mutableBytes;
    const double *times = self.timeOffsets, *cumulative = self.cumulativeDistances;
    const double *pauses = _pauseData.bytes;
    double sum = 0.0;
    NSUInteger known = 0;
    speeds[0] = NAN;
    for (NSUInteger index = 1; index < count; index++) {
        double departure = times[index - 1] + (pauses ? pauses[index - 1] : 0.0);
        double elapsed = times[index] - departure;
        double speed = elapsed > 0.05 ? (cumulative[index] - cumulative[index - 1]) / elapsed : NAN;
        if (isfinite(speed)) speed = fmax(0.2, fmin(140.0, speed));
        speeds[index] = speed;
        if (isfinite(speed)) { sum += speed; known++; }
    }
    double fallback = known ? sum / known : 1.4;
    for (NSUInteger index = 1; index < count; index++) if (!isfinite(speeds[index])) speeds[index] = fallback;
    return data;
}

- (CLLocationCoordinate2D)coordinateAtDistance:(double)distance heading:(CLLocationDirection *)heading {
    NSUInteger count = self.pointCount;
    if (count < 2) return count ? self.coordinates[0] : kCLLocationCoordinate2DInvalid;
    const double *cumulative = self.cumulativeDistances;
    distance = fmax(0.0, fmin(self.distance, isfinite(distance) ? distance : 0.0));
    NSUInteger low = 1, high = count - 1;
    while (low < high) {
        NSUInteger middle = (low + high) / 2;
        if (cumulative[middle] < distance) low = middle + 1; else high = middle;
    }
    CLLocationCoordinate2D a = self.coordinates[low - 1], b = self.coordinates[low];
    double length = cumulative[low] - cumulative[low - 1];
    double progress = length > 0 ? (distance - cumulative[low - 1]) / length : 0.0;
    LSRouteCoordinate start = {a.latitude, a.longitude}, end = {b.latitude, b.longitude};
    LSRouteCoordinate point = LSRouteInterpolate(start, end, progress);
    if (heading) *heading = LSRouteBearing(start, end);
    return CLLocationCoordinate2DMake(point.latitude, point.longitude);
}

- (NSUInteger)legIndexAtDistance:(double)distance {
    NSUInteger count = self.legs.count;
    if (count == 0) return 0;
    NSUInteger index = 0;
    while (index + 1 < count && self.legs[index].endDistance <= distance) index++;
    return index;
}

- (instancetype)routeWithLegSpeeds:(NSArray<NSNumber *> *)speeds {
    if (speeds.count != self.legs.count) return nil;
    LSRoute *route = [[LSRoute alloc] init];
    route->_coordinateData = _coordinateData;
    route->_cumulativeData = _cumulativeData;
    route->_timeData = _timeData;
    route->_pauseData = _pauseData;
    route->_markerDistances = _markerDistances;
    route.stopDistances = self.stopDistances;
    route.stopDwells = self.stopDwells;
    route.waypoints = self.waypoints;
    route.transportType = self.transportType;
    route.name = self.name;
    route.expectedTravelTime = self.expectedTravelTime;
    route.recordedStartDate = self.recordedStartDate;
    route.fromTrack = self.fromTrack;
    // The same polyline object, so the map keeps its overlay and the travelled part.
    route.polyline = self.polyline;
    NSMutableArray<LSRouteLeg *> *legs = [NSMutableArray arrayWithCapacity:speeds.count];
    for (NSUInteger index = 0; index < speeds.count; index++) [legs addObject:[self.legs[index] legWithSpeed:LSLegSpeed(speeds[index])]];
    route.legs = legs;
    return route;
}

- (BOOL)hasSamePathAs:(LSRoute *)route {
    if (![route isKindOfClass:LSRoute.class]) return NO;
    if (route == self) return YES;
    BOOL points = route->_coordinateData == _coordinateData || [route->_coordinateData isEqualToData:_coordinateData];
    return points && [route.stopDistances isEqualToArray:self.stopDistances] && [route.stopDwells isEqualToArray:self.stopDwells];
}

- (LSRouteLegPath *)pathForLegAtIndex:(NSUInteger)index {
    if (index >= self.legs.count || self.fromTrack) return nil;
    LSRouteLeg *leg = self.legs[index];
    NSUInteger count = self.pointCount;
    const double *cumulative = self.cumulativeDistances;
    // The points at the leg's start and end; they are exact cumulative values.
    NSUInteger (^nearest)(double) = ^NSUInteger(double meters) {
        NSUInteger low = 0, high = count - 1;
        while (low < high) {
            NSUInteger middle = (low + high) / 2;
            if (cumulative[middle] < meters) low = middle + 1; else high = middle;
        }
        if (low > 0 && fabs(cumulative[low - 1] - meters) <= fabs(cumulative[low] - meters)) low--;
        return low;
    };
    NSUInteger first = nearest(leg.startDistance), last = nearest(leg.endDistance);
    if (last <= first) return nil;
    MKPolyline *polyline = [MKPolyline polylineWithCoordinates:(CLLocationCoordinate2D *)self.coordinates + first count:last - first + 1];
    return [LSRouteLegPath pathWithPolyline:polyline expectedTravelTime:leg.expectedTravelTime transportType:leg.transportType];
}

#pragma mark - Persistence

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *waypoints = [NSMutableArray array];
    for (LSRouteWaypoint *waypoint in self.waypoints) {
        [waypoints addObject:@{@"name":waypoint.name, @"lat":@(waypoint.coordinate.latitude), @"lon":@(waypoint.coordinate.longitude)}];
    }
    NSMutableArray *stops = [NSMutableArray array];
    for (NSUInteger index = 0; index < self.stopDistances.count; index++) [stops addObject:@[self.stopDistances[index], self.stopDwells[index]]];
    NSMutableDictionary *dictionary = [@{@"v":@1, @"name":self.name, @"transport":@(self.transportType), @"eta":@(self.expectedTravelTime),
                                         @"coords":[_coordinateData copy], @"stops":stops, @"waypoints":waypoints} mutableCopy];
    if (_timeData) dictionary[@"times"] = [_timeData copy];
    NSMutableArray *legs = [NSMutableArray arrayWithCapacity:self.legs.count];
    for (LSRouteLeg *leg in self.legs) {
        NSMutableDictionary *entry = [@{@"t":@(leg.transportType), @"e":@(leg.endDistance), @"eta":@(leg.expectedTravelTime)} mutableCopy];
        if (leg.hasOwnSpeed) entry[@"s"] = @(leg.speedKmh);
        [legs addObject:entry];
    }
    if (legs.count) dictionary[@"legs"] = legs;
    if (self.recordedStartDate) dictionary[@"start"] = @(self.recordedStartDate.timeIntervalSince1970);
    if (self.fromTrack) dictionary[@"track"] = @YES;
    return dictionary;
}

+ (instancetype)routeFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class] || ![dictionary[@"v"] isEqual:@1]) return nil;
    NSData *coordinates = dictionary[@"coords"];
    if (![coordinates isKindOfClass:NSData.class] || coordinates.length % sizeof(CLLocationCoordinate2D) || coordinates.length < 2 * sizeof(CLLocationCoordinate2D)) return nil;
    NSUInteger count = coordinates.length / sizeof(CLLocationCoordinate2D);
    if (count > kLSMaximumPoints) return nil;
    NSData *times = dictionary[@"times"];
    if (times && (![times isKindOfClass:NSData.class] || times.length != count * sizeof(double))) times = nil;
    // Pauses are restored from the stop list instead of being detected again.
    LSRoute *route = [[self alloc] initWithRaw:coordinates.bytes times:NULL count:count stopMarkers:@[]];
    if (!route || route.pointCount != count) return nil;
    if (times) {
        route->_timeData = [times mutableCopy];
        route->_pauseData = [NSMutableData dataWithLength:sizeof(double) * count];
    }
    NSMutableArray *distances = [NSMutableArray array], *dwells = [NSMutableArray array];
    id stops = dictionary[@"stops"];
    for (id stop in [stops isKindOfClass:NSArray.class] ? stops : @[]) {
        if (![stop isKindOfClass:NSArray.class] || [stop count] != 2) continue;
        id distance = stop[0], dwell = stop[1];
        if (![distance isKindOfClass:NSNumber.class] || ![dwell isKindOfClass:NSNumber.class]) continue;
        double meters = [distance doubleValue], seconds = [dwell doubleValue];
        if (!isfinite(meters) || meters <= 0 || meters >= route.distance || !isfinite(seconds) || seconds > 86400) continue;
        if (distances.count && meters <= [distances.lastObject doubleValue]) continue;
        [distances addObject:@(meters)];
        [dwells addObject:@(seconds < 0 ? -1.0 : seconds)];
        if (route->_pauseData && seconds >= 0) {
            const double *cumulative = route.cumulativeDistances;
            // Kept points are at least 5 cm apart, so a millimeter finds the right one even
            // after the distance went through JSON text.
            for (NSUInteger index = 1; index + 1 < count; index++) {
                if (fabs(cumulative[index] - meters) < 1e-3) { ((double *)route->_pauseData.mutableBytes)[index] = seconds; break; }
            }
        }
    }
    route.stopDistances = distances;
    route.stopDwells = dwells;
    NSMutableArray *waypoints = [NSMutableArray array];
    id storedWaypoints = dictionary[@"waypoints"];
    for (id entry in [storedWaypoints isKindOfClass:NSArray.class] ? storedWaypoints : @[]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        id lat = entry[@"lat"], lon = entry[@"lon"];
        if (![lat isKindOfClass:NSNumber.class] || ![lon isKindOfClass:NSNumber.class]) continue;
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]);
        if (LSCoordinateUsable(coordinate)) [waypoints addObject:[LSRouteWaypoint waypointWithName:entry[@"name"] coordinate:coordinate]];
    }
    if (waypoints.count < 2) {
        waypoints = [@[[LSRouteWaypoint waypointWithName:@"Start" coordinate:route.coordinates[0]],
                       [LSRouteWaypoint waypointWithName:@"End" coordinate:route.coordinates[count - 1]]] mutableCopy];
    }
    route.waypoints = waypoints;
    id name = dictionary[@"name"];
    route.name = [name isKindOfClass:NSString.class] && [name length] ? name : @"Route";
    id transport = dictionary[@"transport"];
    route.transportType = [transport isKindOfClass:NSNumber.class] ? [transport unsignedIntegerValue] : MKDirectionsTransportTypeAny;
    id eta = dictionary[@"eta"];
    route.expectedTravelTime = [eta isKindOfClass:NSNumber.class] && isfinite([eta doubleValue]) ? [eta doubleValue] : 0;
    id start = dictionary[@"start"];
    if ([start isKindOfClass:NSNumber.class] && route.hasTiming) route.recordedStartDate = [NSDate dateWithTimeIntervalSince1970:[start doubleValue]];
    route.fromTrack = [dictionary[@"track"] isEqual:@YES];
    [route restoreLegs:dictionary[@"legs"]];
    return route;
}

// Stored legs when they fit this route's waypoints and path, else legs that follow the route.
- (void)restoreLegs:(id)stored {
    NSArray *entries = [stored isKindOfClass:NSArray.class] ? stored : nil;
    NSUInteger count = self.waypoints.count - 1;
    if (entries.count != count) { [self useDefaultLegs]; return; }
    NSMutableArray<LSRouteLeg *> *legs = [NSMutableArray arrayWithCapacity:count];
    double start = 0.0, total = self.distance;
    for (NSUInteger index = 0; index < count; index++) {
        NSDictionary *entry = [entries[index] isKindOfClass:NSDictionary.class] ? entries[index] : nil;
        id type = entry[@"t"], end = entry[@"e"], eta = entry[@"eta"];
        if (![type isKindOfClass:NSNumber.class] || ![end isKindOfClass:NSNumber.class] || !LSTransportUsable([type unsignedIntegerValue])) { [self useDefaultLegs]; return; }
        double meters = index + 1 < count ? [end doubleValue] : total;
        if (!isfinite(meters) || meters < start - 1e-6 || meters > total + 1e-6) { [self useDefaultLegs]; return; }
        meters = MAX(start, MIN(total, meters));
        [legs addObject:[LSRouteLeg legWithType:[type unsignedIntegerValue] speed:LSLegSpeed(entry[@"s"]) start:start end:meters
                                            eta:[eta isKindOfClass:NSNumber.class] ? [eta doubleValue] : 0]];
        start = meters;
    }
    self.legs = legs;
}

#pragma mark - Archive

- (LSRouteArchive *)archive {
    LSRouteArchive *archive = [[LSRouteArchive alloc] init];
    NSString *name = [self.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    archive.name = name.length ? (name.length > 120 ? [name substringToIndex:120] : name) : @"Route";
    NSMutableArray<LSArchivedPlace *> *places = [NSMutableArray array];
    for (LSRouteWaypoint *waypoint in self.waypoints) {
        LSArchivedPlace *place = [LSArchivedPlace placeWithName:waypoint.name latitude:waypoint.coordinate.latitude longitude:waypoint.coordinate.longitude];
        if (place) [places addObject:place];
    }
    // The planner allows 10 stops; anything past that keeps From, the first stops and To.
    NSUInteger limit = LSRouteArchiveMaximumStops + 2;
    if (places.count > limit) {
        LSArchivedPlace *last = places.lastObject;
        [places removeObjectsInRange:NSMakeRange(limit - 1, places.count - (limit - 1))];
        [places addObject:last];
    }
    if (places.count < 2 && self.pointCount >= 2) {
        CLLocationCoordinate2D start = self.coordinates[0], end = self.coordinates[self.pointCount - 1];
        places = [@[[LSArchivedPlace placeWithName:@"Start" latitude:start.latitude longitude:start.longitude],
                    [LSArchivedPlace placeWithName:@"End" latitude:end.latitude longitude:end.longitude]] mutableCopy];
    }
    archive.places = places;
    archive.path = LSArchivePathForTransportType(self.transportType);
    // Each leg's own path and speed (#28), when the legs still line up with the places.
    if (self.legs.count && self.legs.count + 1 == places.count && self.legs.count + 1 == self.waypoints.count) {
        NSMutableArray<LSArchivedLeg *> *legs = [NSMutableArray arrayWithCapacity:self.legs.count];
        for (LSRouteLeg *leg in self.legs) {
            LSArchivedLeg *saved = [LSArchivedLeg legWithPath:LSArchivePathForTransportType(leg.transportType) speedKmh:leg.speedKmh
                                                          end:leg.endDistance expectedTravelTime:leg.expectedTravelTime];
            if (saved) [legs addObject:saved];
        }
        archive.legs = legs.count == self.legs.count ? legs : @[];
    }
    archive.fromTrack = self.fromTrack;
    archive.coordinates = [_coordinateData copy];
    archive.times = [_timeData copy];
    NSMutableArray *stops = [NSMutableArray array];
    for (NSUInteger index = 0; index < self.stopDistances.count; index++) [stops addObject:@[self.stopDistances[index], self.stopDwells[index]]];
    archive.stops = stops;
    archive.expectedTravelTime = isfinite(self.expectedTravelTime) ? self.expectedTravelTime : 0;
    archive.recordedStartDate = self.recordedStartDate;
    return archive;
}

+ (instancetype)routeWithArchive:(LSRouteArchive *)archive {
    if (![archive isKindOfClass:LSRouteArchive.class] || archive.pointCount < 2) return nil;
    NSMutableArray *waypoints = [NSMutableArray array];
    for (LSArchivedPlace *place in archive.places) [waypoints addObject:@{@"name":place.name, @"lat":@(place.latitude), @"lon":@(place.longitude)}];
    MKDirectionsTransportType transport = LSTransportTypeForArchivePath(archive.path, MKDirectionsTransportTypeWalking);
    if (transport == MKDirectionsTransportTypeTransit) transport = MKDirectionsTransportTypeWalking;
    NSMutableDictionary *dictionary = [@{@"v":@1, @"name":archive.name, @"transport":@(transport), @"eta":@(archive.expectedTravelTime),
                                         @"coords":archive.coordinates, @"stops":archive.stops ?: @[], @"waypoints":waypoints} mutableCopy];
    if (archive.times) dictionary[@"times"] = archive.times;
    if (archive.recordedStartDate) dictionary[@"start"] = @(archive.recordedStartDate.timeIntervalSince1970);
    if (archive.fromTrack) dictionary[@"track"] = @YES;
    // Legs in routeFromDictionary's form. It checks them against the path, and falls back to
    // legs that follow the route.
    NSArray<LSArchivedLeg *> *saved = archive.legs.count + 1 == archive.places.count ? archive.legs : @[];
    NSMutableArray *legs = [NSMutableArray arrayWithCapacity:saved.count];
    NSMutableArray<NSNumber *> *speeds = [NSMutableArray arrayWithCapacity:saved.count];
    BOOL ends = saved.count > 0;
    for (NSUInteger index = 0; index < saved.count; index++) {
        LSArchivedLeg *leg = saved[index];
        BOOL last = index + 1 == saved.count;
        if (!last && !isfinite(leg.end)) ends = NO;
        NSMutableDictionary *entry = [@{@"t":@(LSTransportTypeForArchivePath(leg.path, transport)), @"e":@(isfinite(leg.end) ? leg.end : 0),
                                        @"eta":@(leg.expectedTravelTime)} mutableCopy];
        if (isfinite(leg.speedKmh)) entry[@"s"] = @(leg.speedKmh);
        [legs addObject:entry];
        [speeds addObject:@(leg.speedKmh)];
    }
    if (ends) dictionary[@"legs"] = legs;
    LSRoute *route = [self routeFromDictionary:dictionary];
    // Without leg ends the legs follow the route; their speeds still apply.
    if (route && !ends && speeds.count && speeds.count == route.legs.count) route = [route routeWithLegSpeeds:speeds] ?: route;
    return route;
}

@end
