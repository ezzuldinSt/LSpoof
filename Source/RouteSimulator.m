#import "RouteSimulator.h"
#import "RouteGeometry.h"
#import "RouteMotion.h"
#import <os/lock.h>

static const double kLSPresetSpeeds[] = {5, 15, 50};

@implementation LSPlaybackOptions
- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = LSTransportModeWalking;
        _customSpeedKmh = 30.0;
        _accelerationProfile = LSAccelerationNormal;
        _paceMultiplier = 1.0;
    }
    return self;
}
+ (instancetype)optionsWithSpeedKmh:(double)kmh {
    LSPlaybackOptions *options = [[self alloc] init];
    options.mode = LSTransportModeCustom;
    for (NSInteger index = 0; index < 3; index++) {
        if (fabs(kmh - kLSPresetSpeeds[index]) < 0.01) options.mode = (LSTransportMode)index;
    }
    options.customSpeedKmh = options.mode == LSTransportModeCustom ? kmh : 30.0;
    return options;
}
- (id)copyWithZone:(NSZone *)zone {
    LSPlaybackOptions *copy = [[[self class] allocWithZone:zone] init];
    copy.mode = self.mode;
    copy.customSpeedKmh = self.customSpeedKmh;
    copy.smooth = self.smooth;
    copy.accelerationProfile = self.accelerationProfile;
    copy.stopDwell = self.stopDwell;
    copy.recordedPace = self.recordedPace;
    copy.paceMultiplier = self.paceMultiplier;
    return copy;
}
- (double)speedKmh {
    return self.mode == LSTransportModeCustom ? self.customSpeedKmh : kLSPresetSpeeds[MAX(0, MIN(2, self.mode))];
}
- (double)speedMetersPerSecond { return [LSRouteSimulator speedMetersPerSecondForMode:self.mode customSpeedKmh:self.customSpeedKmh]; }
- (BOOL)isValid {
    return self.mode >= LSTransportModeWalking && self.mode <= LSTransportModeCustom &&
        (self.mode != LSTransportModeCustom || (isfinite(self.customSpeedKmh) && self.customSpeedKmh >= 1.0 && self.customSpeedKmh <= 500.0)) &&
        self.accelerationProfile >= LSAccelerationGentle && self.accelerationProfile <= LSAccelerationSporty &&
        isfinite(self.stopDwell) && self.stopDwell >= 0 && self.stopDwell <= 3600 &&
        isfinite(self.paceMultiplier) && self.paceMultiplier >= 0.1 && self.paceMultiplier <= 20;
}
- (NSDictionary *)dictionaryRepresentation {
    return @{ @"mode": @(self.mode), @"customSpeedKmh": @(self.customSpeedKmh), @"smooth": @(self.smooth),
              @"acceleration": @(self.accelerationProfile), @"stopDwell": @(self.stopDwell),
              @"recordedPace": @(self.recordedPace), @"paceMultiplier": @(self.paceMultiplier) };
}
+ (instancetype)optionsFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *values = dictionary;
    for (NSString *key in @[ @"mode", @"customSpeedKmh", @"smooth", @"acceleration", @"stopDwell", @"recordedPace", @"paceMultiplier" ]) {
        if (![values[key] isKindOfClass:NSNumber.class]) return nil;
    }
    LSPlaybackOptions *options = [[self alloc] init];
    options.mode = (LSTransportMode)[values[@"mode"] integerValue];
    options.customSpeedKmh = [values[@"customSpeedKmh"] doubleValue];
    options.smooth = [values[@"smooth"] boolValue];
    options.accelerationProfile = (LSAccelerationProfile)[values[@"acceleration"] integerValue];
    options.stopDwell = [values[@"stopDwell"] doubleValue];
    options.recordedPace = [values[@"recordedPace"] boolValue];
    options.paceMultiplier = [values[@"paceMultiplier"] doubleValue];
    return options.isValid ? options : nil;
}
@end

// The route in the arrays the motion model reads, plus turn radii.
@interface LSMotionPlan : NSObject {
@public
    LSMotionRoute _motion;
}
@property (nonatomic, strong) LSRoute *route;
@property (nonatomic, strong) NSMutableData *radii;
@property (nonatomic, strong, nullable) NSData *speeds;
@property (nonatomic, strong) NSMutableData *stopDistances;
@property (nonatomic, strong) NSMutableData *stopDwells;
@end
@implementation LSMotionPlan
- (instancetype)initWithRoute:(LSRoute *)route {
    self = [super init];
    if (!self) return nil;
    NSUInteger count = route.pointCount;
    _route = route;
    NSMutableData *latitudes = [NSMutableData dataWithLength:sizeof(double) * count];
    NSMutableData *longitudes = [NSMutableData dataWithLength:sizeof(double) * count];
    double *lat = latitudes.mutableBytes, *lon = longitudes.mutableBytes;
    for (NSUInteger index = 0; index < count; index++) { lat[index] = route.coordinates[index].latitude; lon[index] = route.coordinates[index].longitude; }
    _radii = [NSMutableData dataWithLength:sizeof(double) * count];
    LSRouteCornerRadii(lat, lon, route.cumulativeDistances, count, 15.0, _radii.mutableBytes);
    _speeds = route.recordedSegmentSpeeds;
    _stopDistances = [NSMutableData dataWithLength:sizeof(double) * route.stopDistances.count];
    _stopDwells = [NSMutableData dataWithLength:sizeof(double) * route.stopDistances.count];
    for (NSUInteger index = 0; index < route.stopDistances.count; index++) {
        ((double *)_stopDistances.mutableBytes)[index] = route.stopDistances[index].doubleValue;
        ((double *)_stopDwells.mutableBytes)[index] = route.stopDwells[index].doubleValue;
    }
    _motion = (LSMotionRoute){route.cumulativeDistances, _radii.bytes, _speeds.bytes, count,
                              _stopDistances.bytes, _stopDwells.bytes, route.stopDistances.count};
    return self;
}
@end

static LSMotionParams LSParamsForOptions(LSPlaybackOptions *options, LSRoute *route) {
    LSMotionParams params = {0};
    params.cruiseSpeed = options.speedMetersPerSecond;
    params.paceMultiplier = options.paceMultiplier > 0 ? options.paceMultiplier : 1.0;
    params.useRecordedPace = options.recordedPace && route.hasTiming;
    // A recording already contains its own speeding up and slowing down.
    params.smooth = options.smooth && !params.useRecordedPace;
    params.defaultDwell = options.stopDwell;
    double kmh = options.speedKmh;
    LSTransportMode physics = options.mode;
    if (physics == LSTransportModeCustom) physics = kmh <= 7 ? LSTransportModeWalking : (kmh <= 25 ? LSTransportModeCycling : LSTransportModeDriving);
    switch (physics) {
        case LSTransportModeWalking: params.acceleration = 0.6; params.deceleration = 1.0; params.lateralAcceleration = 1.5; params.minimumCornerSpeed = 0.8; break;
        case LSTransportModeCycling: params.acceleration = 0.9; params.deceleration = 2.0; params.lateralAcceleration = 2.0; params.minimumCornerSpeed = 2.0; break;
        default: params.acceleration = 2.2; params.deceleration = 3.0; params.lateralAcceleration = 2.8; params.minimumCornerSpeed = 3.0; break;
    }
    double scale = options.accelerationProfile == LSAccelerationGentle ? 0.6 : (options.accelerationProfile == LSAccelerationSporty ? 1.6 : 1.0);
    double lateral = options.accelerationProfile == LSAccelerationGentle ? 0.85 : (options.accelerationProfile == LSAccelerationSporty ? 1.2 : 1.0);
    params.acceleration *= scale;
    params.deceleration *= scale;
    params.lateralAcceleration *= lateral;
    params.substep = 0.1;
    return params;
}

@interface LSRouteSimulator () {
    os_unfair_lock _coordLock;
    LSMotionState _state;
}
@property (nonatomic, strong, nullable) LSRoute *route;
@property (nonatomic, strong, nullable) LSMotionPlan *plan;
@property (nonatomic, strong, nullable) NSTimer *tickTimer;
@property (nonatomic, assign) CLLocationCoordinate2D currentCoordinate;
@property (nonatomic, assign) CLLocationDirection currentHeading;
@property (nonatomic, assign) BOOL isSimulating;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) NSTimeInterval lastTickTime;
@property (nonatomic, assign) double cachedRemaining;
@property (nonatomic, assign) NSTimeInterval cachedRemainingAt;
@property (nonatomic, assign) BOOL remainingDirty;
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
        _options = [[LSPlaybackOptions alloc] init];
        _currentCoordinate = kCLLocationCoordinate2DInvalid;
        _currentHeading = 0.0;
        LSMotionReset(&_state);
    }
    return self;
}

- (void)setOptions:(LSPlaybackOptions *)options {
    if (!options.isValid) return;
    _options = [options copy];
    self.remainingDirty = YES;
}
- (LSTransportMode)transportMode { return self.options.mode; }
- (double)customSpeedKmh { return self.options.customSpeedKmh; }
- (double)totalDistance { return self.route.distance; }
- (double)distanceCovered { return self.route ? _state.covered : 0.0; }
- (double)currentSpeed { return self.isSimulating && !self.isPaused ? _state.speed : 0.0; }
- (BOOL)isWaitingAtStop { return self.isSimulating && _state.dwelling; }
- (NSTimeInterval)waitRemaining { return _state.dwelling ? _state.dwellRemaining : 0.0; }
- (NSUInteger)plannedStopsReached {
    NSUInteger reached = 0;
    for (NSUInteger index = 0; index < self.route.stopDistances.count; index++) {
        if (self.route.stopDwells[index].doubleValue < 0 && self.route.stopDistances[index].doubleValue <= _state.covered + 1e-6) reached++;
    }
    return reached;
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
    return self.route.pointCount ? self.route.coordinates[0] : kCLLocationCoordinate2DInvalid;
}

- (CLLocationCoordinate2D)destinationCoordinate {
    return self.route.pointCount ? self.route.coordinates[self.route.pointCount - 1] : kCLLocationCoordinate2DInvalid;
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

- (BOOL)startWithRoute:(LSRoute *)route {
    if (![route isKindOfClass:LSRoute.class] || route.pointCount < 2 || !(route.distance > 0) || !isfinite(route.distance)) return NO;
    LSMotionPlan *plan = [[LSMotionPlan alloc] initWithRoute:route];
    if (!plan) return NO;
    [self stop];
    self.route = route;
    self.plan = plan;
    LSMotionReset(&_state);
    CLLocationDirection heading = 0;
    self.currentCoordinate = [route coordinateAtDistance:0 heading:&heading];
    if (isfinite(heading)) self.currentHeading = heading;
    self.isSimulating = YES;
    self.isPaused = NO;
    self.remainingDirty = YES;
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
    // Playback was standing still; it starts moving again from rest.
    _state.speed = 0.0;
    self.remainingDirty = YES;
    [self scheduleTickTimer];
}

- (void)stop {
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    self.isSimulating = NO;
    self.isPaused = NO;
    LSMotionReset(&_state);
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
    if (!self.isSimulating || self.isPaused || !self.plan) {
        return;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // A stalled main thread or an unannounced suspension must not teleport the
    // location far along the route; movement resumes at normal speed instead.
    NSTimeInterval elapsed = MIN(1.0, MAX(0.0, now - self.lastTickTime));
    self.lastTickTime = now;
    LSMotionParams params = LSParamsForOptions(self.options, self.route);
    LSMotionStep(&self.plan->_motion, &params, &_state, elapsed);

    CLLocationDirection heading = self.currentHeading;
    CLLocationCoordinate2D coordinate = [self.route coordinateAtDistance:_state.covered heading:&heading];
    if (CLLocationCoordinate2DIsValid(coordinate)) self.currentCoordinate = coordinate;
    if (isfinite(heading) && !_state.dwelling) self.currentHeading = heading;

    if (_state.finished) {
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
    [self notifyDelegateUpdate];
}

- (void)notifyDelegateUpdate {
    id<LSRouteSimulatorDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(routeSimulator:didUpdateCoordinate:heading:)]) {
        [delegate routeSimulator:self didUpdateCoordinate:self.currentCoordinate heading:self.currentHeading];
    }
}

#pragma mark - Estimates

static BOOL LSNeedsPlayback(LSMotionParams params, const LSMotionRoute *route) {
    if (params.smooth || params.useRecordedPace) return YES;
    for (size_t index = 0; index < route->stopCount; index++) if (route->stopDwell[index] < 0 && params.defaultDwell > 0) return YES;
    return NO;
}

static double LSRemainingFrom(const LSMotionRoute *route, LSMotionParams params, LSMotionState state) {
    if (state.finished) return 0.0;
    if (!LSNeedsPlayback(params, route)) return (LSMotionTotal(route) - state.covered) / LSMotionCruise(route, &params, &state);
    params.substep = 0.5;
    double elapsed = 0.0;
    double dt = 1.0;
    unsigned steps = 0;
    while (!state.finished) {
        double used = LSMotionStep(route, &params, &state, dt);
        elapsed += used;
        // Very long trips fall back to coarser steps rather than stalling the caller.
        if (++steps == 20000) { dt = 10.0; params.substep = 2.0; }
        if (used <= 0.0 || elapsed > 30.0 * 86400.0) return NAN;
    }
    return elapsed;
}

- (NSTimeInterval)remainingTimeEstimate {
    if (!self.isSimulating || !self.plan) return 0.0;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!self.remainingDirty && now - self.cachedRemainingAt < 3.0) {
        double passed = self.isPaused ? 0.0 : now - self.cachedRemainingAt;
        return MAX(0.0, self.cachedRemaining - passed);
    }
    LSMotionParams params = LSParamsForOptions(self.options, self.route);
    double remaining = LSRemainingFrom(&self.plan->_motion, params, _state);
    self.cachedRemaining = remaining;
    self.cachedRemainingAt = now;
    self.remainingDirty = NO;
    return remaining;
}

+ (NSTimeInterval)estimatedDurationForRoute:(LSRoute *)route options:(LSPlaybackOptions *)options {
    if (!route || !options.isValid) return NAN;
    LSMotionPlan *plan = [[LSMotionPlan alloc] initWithRoute:route];
    LSMotionState state;
    LSMotionReset(&state);
    return LSRemainingFrom(&plan->_motion, LSParamsForOptions(options, route), state);
}

+ (double)speedKmhForRoute:(LSRoute *)route options:(LSPlaybackOptions *)options finishingIn:(NSTimeInterval)seconds {
    if (!route || !isfinite(seconds) || seconds <= 0) return NAN;
    LSMotionPlan *plan = [[LSMotionPlan alloc] initWithRoute:route];
    LSPlaybackOptions *trial = [options copy];
    trial.mode = LSTransportModeCustom;
    trial.recordedPace = NO;
    LSMotionState start;
    LSMotionReset(&start);
    double (^durationAt)(double) = ^double(double kmh) {
        trial.customSpeedKmh = kmh;
        return LSRemainingFrom(&plan->_motion, LSParamsForOptions(trial, route), start);
    };
    double fastest = durationAt(500.0);
    if (!isfinite(fastest) || fastest > seconds * 1.01) return NAN;
    double slowest = durationAt(1.0);
    if (isfinite(slowest) && slowest < seconds * 0.99) return NAN;
    double low = 1.0, high = 500.0;
    for (int iteration = 0; iteration < 22; iteration++) {
        double middle = sqrt(low * high);
        double duration = durationAt(middle);
        if (!isfinite(duration) || duration > seconds) low = middle; else high = middle;
    }
    return round(sqrt(low * high) * 10.0) / 10.0;
}

+ (void)enumerateSamplesForRoute:(LSRoute *)route options:(LSPlaybackOptions *)options interval:(NSTimeInterval)interval
                           block:(void (^)(NSTimeInterval, CLLocationCoordinate2D, double, double, CLLocationDirection))block {
    if (!route || !block || !options.isValid) return;
    LSMotionPlan *plan = [[LSMotionPlan alloc] initWithRoute:route];
    LSMotionParams params = LSParamsForOptions(options, route);
    if (!(interval > 0) || !isfinite(interval)) interval = 1.0;
    NSTimeInterval estimate = LSRemainingFrom(&plan->_motion, params, (LSMotionState){.segment = 1});
    // Long trips are sampled less often so the files stay a reasonable size.
    if (isfinite(estimate) && estimate / interval > 100000) interval = ceil(estimate / 100000);
    LSMotionState state;
    LSMotionReset(&state);
    NSTimeInterval time = 0;
    CLLocationDirection heading = 0;
    CLLocationCoordinate2D coordinate = [route coordinateAtDistance:0 heading:&heading];
    block(0, coordinate, 0, 0, isfinite(heading) ? heading : 0);
    unsigned guard = 0;
    while (!state.finished && guard++ < 2000000) {
        double used = LSMotionStep(&plan->_motion, &params, &state, interval);
        if (used <= 0) break;
        time += used;
        CLLocationDirection next = heading;
        coordinate = [route coordinateAtDistance:state.covered heading:&next];
        if (isfinite(next) && !state.dwelling) heading = next;
        double speed = state.finished ? 0.0 : state.speed;
        block(time, coordinate, speed, state.covered, heading);
    }
}

@end
