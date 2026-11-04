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

@interface LSRoute () {
    NSMutableData *_coordinateData;
    NSMutableData *_cumulativeData;
    NSMutableData *_timeData;
    NSMutableData *_pauseData;
}
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *stopDistances;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *stopDwells;
@property (nonatomic, readwrite, copy) NSArray<LSRouteWaypoint *> *waypoints;
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
    NSUInteger stride = count > kLSMaximumPoints ? (count + kLSMaximumPoints - 1) / kLSMaximumPoints : 1;
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
    _stopDistances = [distances copy];
    _stopDwells = [dwells copy];
    _waypoints = @[];
    _name = @"Route";
    _transportType = MKDirectionsTransportTypeAny;
    _polyline = [MKPolyline polylineWithCoordinates:(CLLocationCoordinate2D *)_coordinateData.bytes count:(NSUInteger)keptCount];
    return self;
}

+ (instancetype)routeWithLegs:(NSArray<MKRoute *> *)legs waypoints:(NSArray<LSRouteWaypoint *> *)waypoints {
    if (!legs.count || waypoints.count != legs.count + 1) return nil;
    NSMutableData *raw = [NSMutableData data];
    NSMutableArray<NSNumber *> *markers = [NSMutableArray array];
    NSTimeInterval eta = 0;
    for (NSUInteger legIndex = 0; legIndex < legs.count; legIndex++) {
        MKPolyline *polyline = legs[legIndex].polyline;
        NSUInteger count = polyline.pointCount;
        if (count < 2) return nil;
        CLLocationCoordinate2D *buffer = malloc(sizeof(CLLocationCoordinate2D) * count);
        if (!buffer) return nil;
        [polyline getCoordinates:buffer range:NSMakeRange(0, count)];
        [raw appendBytes:buffer length:sizeof(CLLocationCoordinate2D) * count];
        free(buffer);
        if (legIndex + 1 < legs.count) [markers addObject:@(raw.length / sizeof(CLLocationCoordinate2D) - 1)];
        if (isfinite(legs[legIndex].expectedTravelTime)) eta += legs[legIndex].expectedTravelTime;
    }
    LSRoute *route = [[self alloc] initWithRaw:raw.bytes times:NULL count:raw.length / sizeof(CLLocationCoordinate2D) stopMarkers:markers];
    if (!route) return nil;
    route.waypoints = waypoints;
    route.transportType = legs.firstObject.transportType;
    route.expectedTravelTime = eta;
    route.name = [NSString stringWithFormat:@"%@ to %@", waypoints.firstObject.name, waypoints.lastObject.name];
    return route;
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
            for (NSUInteger index = 1; index + 1 < count; index++) {
                if (fabs(cumulative[index] - meters) < 1e-6) { ((double *)route->_pauseData.mutableBytes)[index] = seconds; break; }
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
    return route;
}

@end
