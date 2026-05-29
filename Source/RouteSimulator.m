#import "RouteSimulator.h"

@interface LSRoutePoint : NSObject
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;
@property (nonatomic, assign) double cumulativeDistance;
@end

@implementation LSRoutePoint
@end

@interface LSRouteSimulator ()
@property (nonatomic, strong) NSArray<LSRoutePoint *> *routePoints;
@property (nonatomic, assign) double totalDistance;
@property (nonatomic, assign) double distanceCovered;
@property (nonatomic, strong, nullable) NSTimer *tickTimer;
@property (nonatomic, assign) CLLocationCoordinate2D currentCoordinate;
@property (nonatomic, assign) CLLocationDirection currentHeading;
@property (nonatomic, assign) BOOL isSimulating;
@property (nonatomic, assign) BOOL isPaused;
@end

@implementation LSRouteSimulator

+ (instancetype)shared {
    static LSRouteSimulator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LSRouteSimulator alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _transportMode = LSTransportModeWalking;
        _customSpeedKmh = 30.0;
        _currentCoordinate = kCLLocationCoordinate2DInvalid;
        _currentHeading = 0.0;
    }
    return self;
}

+ (double)speedMetersPerSecondForMode:(LSTransportMode)mode customSpeedKmh:(double)customSpeedKmh {
    switch (mode) {
        case LSTransportModeWalking:
            return 1.389;
        case LSTransportModeCycling:
            return 4.167;
        case LSTransportModeDriving:
            return 13.889;
        case LSTransportModeCustom:
            return customSpeedKmh / 3.6;
    }
    return 1.389;
}

+ (double)horizontalAccuracyForMode:(LSTransportMode)mode {
    switch (mode) {
        case LSTransportModeWalking:
            return 10.0;
        case LSTransportModeCycling:
            return 8.0;
        case LSTransportModeDriving:
            return 5.0;
        case LSTransportModeCustom:
            return 6.0;
    }
    return 6.0;
}

- (void)startWithRoute:(MKRoute *)route {
    [self stop];

    MKPolyline *polyline = route.polyline;
    if (!polyline || polyline.pointCount < 2) {
        return;
    }

    NSUInteger pointCount = polyline.pointCount;
    CLLocationCoordinate2D *rawCoordinates = malloc(sizeof(CLLocationCoordinate2D) * pointCount);
    if (!rawCoordinates) {
        return;
    }

    [polyline getCoordinates:rawCoordinates range:NSMakeRange(0, pointCount)];

    NSMutableArray<LSRoutePoint *> *points = [NSMutableArray arrayWithCapacity:pointCount];
    double cumulative = 0.0;

    LSRoutePoint *firstPoint = [[LSRoutePoint alloc] init];
    firstPoint.coordinate = rawCoordinates[0];
    firstPoint.cumulativeDistance = 0.0;
    [points addObject:firstPoint];

    for (NSUInteger index = 1; index < pointCount; index++) {
        CLLocation *previous = [[CLLocation alloc] initWithLatitude:rawCoordinates[index - 1].latitude
                                                          longitude:rawCoordinates[index - 1].longitude];
        CLLocation *current = [[CLLocation alloc] initWithLatitude:rawCoordinates[index].latitude
                                                       longitude:rawCoordinates[index].longitude];
        cumulative += [current distanceFromLocation:previous];

        LSRoutePoint *point = [[LSRoutePoint alloc] init];
        point.coordinate = rawCoordinates[index];
        point.cumulativeDistance = cumulative;
        [points addObject:point];
    }

    if (points.count < 2 || cumulative <= 0.0) {
        free(rawCoordinates);
        return;
    }

    self.routePoints = points;
    self.totalDistance = cumulative;
    self.distanceCovered = 0.0;
    self.currentCoordinate = firstPoint.coordinate;
    if (points.count >= 2) {
        self.currentHeading = [self headingFromCoordinate:((LSRoutePoint *)points[0]).coordinate
                                               toCoordinate:((LSRoutePoint *)points[1]).coordinate];
    }
    self.isSimulating = YES;
    self.isPaused = NO;

    free(rawCoordinates);

    [self scheduleTickTimer];
    [self notifyDelegateUpdate];
}

- (void)pause {
    if (!self.isSimulating || self.isPaused) {
        return;
    }
    self.isPaused = YES;
    [self.tickTimer invalidate];
    self.tickTimer = nil;
}

- (void)resume {
    if (!self.isSimulating || !self.isPaused) {
        return;
    }
    self.isPaused = NO;
    [self scheduleTickTimer];
}

- (void)stop {
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    self.isSimulating = NO;
    self.isPaused = NO;
    self.distanceCovered = 0.0;
    self.routePoints = nil;
    self.totalDistance = 0.0;
}

- (void)scheduleTickTimer {
    [self.tickTimer invalidate];
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                      target:self
                                                    selector:@selector(handleTick)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.tickTimer forMode:NSRunLoopCommonModes];
}

- (void)handleTick {
    if (!self.isSimulating || self.isPaused || self.routePoints.count < 2) {
        return;
    }

    double speed = [LSRouteSimulator speedMetersPerSecondForMode:self.transportMode
                                                  customSpeedKmh:self.customSpeedKmh];
    self.distanceCovered += speed * 0.1;

    if (self.distanceCovered >= self.totalDistance) {
        LSRoutePoint *lastPoint = self.routePoints.lastObject;
        self.currentCoordinate = lastPoint.coordinate;
        NSUInteger lastIndex = self.routePoints.count - 1;
        if (lastIndex >= 1) {
            LSRoutePoint *previousPoint = self.routePoints[lastIndex - 1];
            self.currentHeading = [self headingFromCoordinate:previousPoint.coordinate
                                                 toCoordinate:lastPoint.coordinate];
        }
        [self notifyDelegateUpdate];
        id<LSRouteSimulatorDelegate> delegate = self.delegate;
        [self stop];
        if ([delegate respondsToSelector:@selector(routeSimulatorDidFinish:)]) {
            [delegate routeSimulatorDidFinish:self];
        }
        return;
    }

    NSUInteger low = 0;
    NSUInteger high = self.routePoints.count - 1;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (self.routePoints[mid].cumulativeDistance < self.distanceCovered) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    NSUInteger index = low;
    LSRoutePoint *segmentEnd = self.routePoints[index];
    LSRoutePoint *segmentStart = index > 0 ? self.routePoints[index - 1] : segmentEnd;

    double segmentLength = segmentEnd.cumulativeDistance - segmentStart.cumulativeDistance;
    double segmentProgress = 0.0;
    if (segmentLength > 0.0) {
        segmentProgress = (self.distanceCovered - segmentStart.cumulativeDistance) / segmentLength;
    }

    CLLocationDegrees latitude = segmentStart.coordinate.latitude +
        (segmentEnd.coordinate.latitude - segmentStart.coordinate.latitude) * segmentProgress;
    CLLocationDegrees longitude = segmentStart.coordinate.longitude +
        (segmentEnd.coordinate.longitude - segmentStart.coordinate.longitude) * segmentProgress;

    self.currentCoordinate = CLLocationCoordinate2DMake(latitude, longitude);
    self.currentHeading = [self headingFromCoordinate:segmentStart.coordinate toCoordinate:segmentEnd.coordinate];
    [self notifyDelegateUpdate];
}

- (CLLocationDirection)headingFromCoordinate:(CLLocationCoordinate2D)from toCoordinate:(CLLocationCoordinate2D)to {
    double deltaX = to.longitude - from.longitude;
    double deltaY = to.latitude - from.latitude;
    double radians = atan2(deltaX, deltaY);
    double degrees = radians * 180.0 / M_PI;
    if (degrees < 0.0) {
        degrees += 360.0;
    }
    return degrees;
}

- (void)notifyDelegateUpdate {
    id<LSRouteSimulatorDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(routeSimulator:didUpdateCoordinate:heading:)]) {
        [delegate routeSimulator:self didUpdateCoordinate:self.currentCoordinate heading:self.currentHeading];
    }
}

@end
