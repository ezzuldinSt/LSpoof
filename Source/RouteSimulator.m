#import "RouteSimulator.h"
#import "RouteGeometry.h"
#import <os/lock.h>

@implementation LSRoutePoint
@end

@interface LSRouteSimulator () {
    os_unfair_lock _coordLock;
}
@property (nonatomic, strong) NSArray<LSRoutePoint *> *routePoints;
@property (nonatomic, assign) double totalDistance;
@property (nonatomic, assign) double distanceCovered;
@property (nonatomic, strong, nullable) NSTimer *tickTimer;
@property (nonatomic, assign) CLLocationCoordinate2D currentCoordinate;
@property (nonatomic, assign) CLLocationDirection currentHeading;
@property (nonatomic, assign) NSUInteger currentSegmentIndex;
@property (nonatomic, assign) BOOL isSimulating;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) NSTimeInterval lastTickTime;
@end

@implementation LSRouteSimulator

@synthesize currentCoordinate = _currentCoordinate;
@synthesize currentHeading = _currentHeading;

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
        _coordLock = OS_UNFAIR_LOCK_INIT;
        _transportMode = LSTransportModeWalking;
        _customSpeedKmh = 30.0;
        _currentCoordinate = kCLLocationCoordinate2DInvalid;
        _currentHeading = 0.0;
    }
    return self;
}

- (CLLocationCoordinate2D)currentCoordinate {
    os_unfair_lock_lock(&_coordLock);
    CLLocationCoordinate2D coord = _currentCoordinate;
    os_unfair_lock_unlock(&_coordLock);
    return coord;
}

- (void)setCurrentCoordinate:(CLLocationCoordinate2D)coordinate {
    os_unfair_lock_lock(&_coordLock);
    _currentCoordinate = coordinate;
    os_unfair_lock_unlock(&_coordLock);
}

- (CLLocationDirection)currentHeading {
    os_unfair_lock_lock(&_coordLock);
    CLLocationDirection heading = _currentHeading;
    os_unfair_lock_unlock(&_coordLock);
    return heading;
}

- (void)setCurrentHeading:(CLLocationDirection)heading {
    os_unfair_lock_lock(&_coordLock);
    _currentHeading = heading;
    os_unfair_lock_unlock(&_coordLock);
}

// Messaging nil returned {0, 0}, a valid coordinate in the Gulf of Guinea.
- (CLLocationCoordinate2D)startCoordinate {
    LSRoutePoint *point = self.routePoints.firstObject;
    return point ? point.coordinate : kCLLocationCoordinate2DInvalid;
}

- (CLLocationCoordinate2D)destinationCoordinate {
    LSRoutePoint *point = self.routePoints.lastObject;
    return point ? point.coordinate : kCLLocationCoordinate2DInvalid;
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

- (BOOL)startWithRoute:(MKRoute *)route {
    MKPolyline *polyline = route.polyline;
    NSUInteger pointCount = polyline.pointCount;
    if (!polyline || pointCount < 2) {
        return NO;
    }

    CLLocationCoordinate2D *rawCoordinates = malloc(sizeof(CLLocationCoordinate2D) * pointCount);
    if (!rawCoordinates) {
        return NO;
    }

    [polyline getCoordinates:rawCoordinates range:NSMakeRange(0, pointCount)];

    for (NSUInteger index = 0; index < pointCount; index++) {
        if (!CLLocationCoordinate2DIsValid(rawCoordinates[index])) {
            free(rawCoordinates);
            return NO;
        }
    }

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
        double distance = [current distanceFromLocation:previous];
        if (!isfinite(distance)) {
            free(rawCoordinates);
            return NO;
        }
        if (distance <= 0.0) continue;
        cumulative += distance;

        LSRoutePoint *point = [[LSRoutePoint alloc] init];
        point.coordinate = rawCoordinates[index];
        point.cumulativeDistance = cumulative;
        [points addObject:point];
    }

    if (points.count < 2 || !isfinite(cumulative) || cumulative <= 0.0) {
        free(rawCoordinates);
        return NO;
    }

    [self stop];
    self.routePoints = [points copy];
    self.totalDistance = cumulative;
    self.distanceCovered = 0.0;
    self.currentCoordinate = firstPoint.coordinate;
    self.currentSegmentIndex = 1;
    if (points.count >= 2) {
        self.currentHeading = [self headingFromCoordinate:((LSRoutePoint *)points[0]).coordinate
                                               toCoordinate:((LSRoutePoint *)points[1]).coordinate];
    }
    self.isSimulating = YES;
    self.isPaused = NO;

    free(rawCoordinates);

    [self scheduleTickTimer];
    return YES;
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
    self.currentSegmentIndex = 0;
    // Keep the validated definition for replay; session state controls activation.
}

- (void)scheduleTickTimer {
    [self.tickTimer invalidate];
    self.lastTickTime = NSProcessInfo.processInfo.systemUptime;
    // Registered once, on the main run loop in common modes. The scheduled variant also
    // put it on the calling thread's run loop in the default mode.
    self.tickTimer = [NSTimer timerWithTimeInterval:0.1
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
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // A stalled main thread or an unannounced suspension must not teleport the
    // location far along the route; movement resumes at normal speed instead.
    NSTimeInterval elapsed = MIN(1.0, MAX(0.0, now - self.lastTickTime));
    self.lastTickTime = now;
    double advanced = LSRouteAdvanceDistance(self.distanceCovered, speed, elapsed, self.totalDistance);
    if (!isfinite(advanced)) return;
    self.distanceCovered = advanced;

    if (self.distanceCovered >= self.totalDistance) {
        LSRoutePoint *lastPoint = self.routePoints.lastObject;
        self.currentCoordinate = lastPoint.coordinate;
        NSUInteger lastIndex = self.routePoints.count - 1;
        if (lastIndex >= 1) {
            LSRoutePoint *previousPoint = self.routePoints[lastIndex - 1];
            self.currentHeading = [self headingFromCoordinate:previousPoint.coordinate
                                                 toCoordinate:lastPoint.coordinate];
        }
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        self.isSimulating = NO;
        self.isPaused = NO;
        id<LSRouteSimulatorDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(routeSimulatorDidFinish:)]) {
            [delegate routeSimulatorDidFinish:self];
        }
        return;
    }

    NSUInteger count = self.routePoints.count;
    while (self.currentSegmentIndex < count &&
           self.currentSegmentIndex + 1 < count &&
           self.distanceCovered >= self.routePoints[self.currentSegmentIndex].cumulativeDistance) {
        self.currentSegmentIndex++;
    }
    NSUInteger index = MIN(self.currentSegmentIndex, count - 1);
    LSRoutePoint *segmentEnd = self.routePoints[index];
    LSRoutePoint *segmentStart = index > 0 ? self.routePoints[index - 1] : segmentEnd;

    double segmentLength = segmentEnd.cumulativeDistance - segmentStart.cumulativeDistance;
    double segmentProgress = 0.0;
    if (segmentLength > 0.0) {
        segmentProgress = (self.distanceCovered - segmentStart.cumulativeDistance) / segmentLength;
    }

    LSRouteCoordinate interpolated = LSRouteInterpolate(
        (LSRouteCoordinate){segmentStart.coordinate.latitude, segmentStart.coordinate.longitude},
        (LSRouteCoordinate){segmentEnd.coordinate.latitude, segmentEnd.coordinate.longitude}, segmentProgress);
    self.currentCoordinate = CLLocationCoordinate2DMake(interpolated.latitude, interpolated.longitude);
    self.currentHeading = [self headingFromCoordinate:segmentStart.coordinate toCoordinate:segmentEnd.coordinate];
    [self notifyDelegateUpdate];
}

- (CLLocationDirection)headingFromCoordinate:(CLLocationCoordinate2D)from toCoordinate:(CLLocationCoordinate2D)to {
    return LSRouteBearing((LSRouteCoordinate){from.latitude, from.longitude},
                          (LSRouteCoordinate){to.latitude, to.longitude});
}

- (void)notifyDelegateUpdate {
    id<LSRouteSimulatorDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(routeSimulator:didUpdateCoordinate:heading:)]) {
        [delegate routeSimulator:self didUpdateCoordinate:self.currentCoordinate heading:self.currentHeading];
    }
}

@end
