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
- (LSRoutePlayback *)playback {
    LSRoutePlayback *playback = [[LSRoutePlayback alloc] init];
    playback.speedKmh = self.speedKmh;
    playback.recordedPace = self.recordedPace;
    playback.paceMultiplier = self.paceMultiplier;
    playback.smooth = self.smooth;
    playback.acceleration = self.accelerationProfile;
    playback.stopDwell = self.stopDwell;
    return playback;
}
+ (instancetype)optionsWithPlayback:(LSRoutePlayback *)playback {
    if (![playback isKindOfClass:LSRoutePlayback.class] || !playback.isValid) return nil;
    LSPlaybackOptions *options = [self optionsWithSpeedKmh:playback.speedKmh];
    options.recordedPace = playback.recordedPace;
    options.paceMultiplier = playback.paceMultiplier;
    options.smooth = playback.smooth;
    options.accelerationProfile = (LSAccelerationProfile)playback.acceleration;
    options.stopDwell = playback.stopDwell;
    return options.isValid ? options : nil;
}
@end

// The kind of movement the route speed moves like; custom speeds like the nearest preset.
static LSMotionKind LSMotionKindForOptions(LSPlaybackOptions *options) {
    return options.mode == LSTransportModeCustom ? LSMotionKindForKmh(options.speedKmh) : (LSMotionKind)MAX(0, MIN(2, options.mode));
}

// The route in the arrays the motion model reads, plus turn radii and the legs, which
// depend on the playback options and are filled in by paramsForOptions:.
@interface LSMotionPlan : NSObject {
@public
    LSMotionRoute _motion;
}
@property (nonatomic, strong) LSRoute *route;
@property (nonatomic, strong) NSMutableData *radii;
@property (nonatomic, strong, nullable) NSData *speeds;
@property (nonatomic, strong) NSMutableData *stopDistances;
@property (nonatomic, strong) NSMutableData *stopDwells;
@property (nonatomic, strong) NSMutableData *legs;
- (LSMotionParams)paramsForOptions:(LSPlaybackOptions *)options;
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
    _legs = [NSMutableData dataWithLength:sizeof(LSMotionLeg) * route.legs.count];
    _motion = (LSMotionRoute){route.cumulativeDistances, _radii.bytes, _speeds.bytes, count,
                              _stopDistances.bytes, _stopDwells.bytes, route.stopDistances.count, NULL, 0};
    return self;
}
// The params for these options, with each leg's own speed and physics written into the
// legs the motion model reads. Every estimate and the live tick go through here, so they
// all play the legs the same way.
- (LSMotionParams)paramsForOptions:(LSPlaybackOptions *)options {
    LSMotionParams params = {0};
    params.cruiseSpeed = options.speedMetersPerSecond;
    params.paceMultiplier = options.paceMultiplier > 0 ? options.paceMultiplier : 1.0;
    params.useRecordedPace = options.recordedPace && self.route.hasTiming;
    // A recording already contains its own speeding up and slowing down.
    params.smooth = options.smooth && !params.useRecordedPace;
    params.defaultDwell = options.stopDwell;
    LSMotionKind routeKind = LSMotionKindForOptions(options);
    LSMotionApplyPhysics(&params, routeKind, (int)options.accelerationProfile);
    params.substep = 0.1;

    NSArray<LSRouteLeg *> *legs = self.route.legs;
    // A recording plays at its own pace, which no leg setting changes.
    if (params.useRecordedPace || legs.count < 2 || !self.route.hasLegSettings) {
        _motion.legs = NULL;
        _motion.legCount = 0;
        return params;
    }
    NSUInteger count = legs.count;
    NSMutableData *ends = [NSMutableData dataWithLength:sizeof(double) * count];
    NSMutableData *speeds = [NSMutableData dataWithLength:sizeof(double) * count];
    NSMutableData *paths = [NSMutableData dataWithLength:sizeof(unsigned long) * count];
    for (NSUInteger index = 0; index < count; index++) {
        ((double *)ends.mutableBytes)[index] = legs[index].endDistance;
        ((double *)speeds.mutableBytes)[index] = legs[index].speedKmh;
        ((unsigned long *)paths.mutableBytes)[index] = legs[index].transportType;
    }
    LSMotionLeg *motionLegs = self.legs.mutableBytes;
    LSMotionFillLegs(motionLegs, count, ends.bytes, speeds.bytes, paths.bytes, routeKind, (int)options.accelerationProfile);
    _motion.legs = motionLegs;
    _motion.legCount = count;
    return params;
}
@end

static LSMotionParams LSParamsForOptions(LSPlaybackOptions *options, LSMotionPlan *plan) {
    return [plan paramsForOptions:options];
}

// Places the state `covered` meters along. With wait > 0 it is back at the stop it was
// waiting at, for the rest of that wait (never longer than the stop's own wait now).
static void LSSeekState(LSMotionPlan *plan, LSMotionParams params, LSMotionState *state, double covered, double wait) {
    const LSMotionRoute *route = &plan->_motion;
    LSMotionSeek(route, state, covered);
    if (!(wait > 0) || !isfinite(wait) || state->finished) return;
    for (size_t index = state->nextStop; index > 0; index--) {
        if (covered - route->stopDistance[index - 1] > 0.5) break;
        double dwell = LSMotionDwellForStop(route, &params, index - 1);
        if (dwell <= 0) continue;
        state->nextStop = index - 1;
        state->dwelling = true;
        state->dwellRemaining = fmin(wait, dwell);
        state->speed = 0;
        return;
    }
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
// Where a leg has its own speed, the location moves (and reports accuracy) like that mode.
- (LSTransportMode)transportMode {
    LSRouteLeg *leg = [self currentLeg];
    if (!leg.hasOwnSpeed || (self.options.recordedPace && self.route.hasTiming)) return self.options.mode;
    return [LSPlaybackOptions optionsWithSpeedKmh:leg.speedKmh].mode;
}
- (nullable LSRouteLeg *)currentLeg {
    NSArray<LSRouteLeg *> *legs = self.route.legs;
    return legs.count ? legs[[self currentLegIndex]] : nil;
}
- (NSUInteger)currentLegIndex {
    LSRoute *route = self.route;
    return route ? MIN(route.legs.count ? route.legs.count - 1 : 0, [route legIndexAtDistance:_state.covered]) : 0;
}
- (BOOL)currentLegHasOwnSpeed {
    return [self currentLeg].hasOwnSpeed && !(self.options.recordedPace && self.route.hasTiming);
}
- (double)setSpeedKmh { return self.currentLegHasOwnSpeed ? [self currentLeg].speedKmh : self.options.speedKmh; }
- (double)customSpeedKmh { return self.options.customSpeedKmh; }
- (double)totalDistance { return self.route.distance; }
- (double)distanceCovered { return self.route ? _state.covered : 0.0; }
- (double)currentSpeed { return self.isSimulating && !self.isPaused ? _state.speed : 0.0; }
- (BOOL)isWaitingAtStop { return self.isSimulating && _state.dwelling; }
- (NSTimeInterval)waitRemaining { return _state.dwelling ? _state.dwellRemaining : 0.0; }
- (NSUInteger)nextStopIndex { return self.route ? _state.nextStop : 0; }
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

- (BOOL)replaceRouteKeepingProgress:(LSRoute *)route {
    if (!self.isSimulating || ![route hasSamePathAs:self.route] || route.legs.count != self.route.legs.count) return NO;
    LSMotionPlan *plan = [[LSMotionPlan alloc] initWithRoute:route];
    if (!plan) return NO;
    // Same points and stops, so the motion state carries over as it is.
    self.route = route;
    self.plan = plan;
    self.remainingDirty = YES;
    return YES;
}

- (BOOL)startWithRoute:(LSRoute *)route covered:(double)covered waitRemaining:(NSTimeInterval)wait {
    if (![route isKindOfClass:LSRoute.class] || !isfinite(covered) || covered < 0 || !(covered < route.distance - 0.5)) return NO;
    if (![self startWithRoute:route]) return NO;
    LSSeekState(self.plan, LSParamsForOptions(self.options, self.plan), &_state, covered, wait);
    CLLocationDirection heading = self.currentHeading;
    CLLocationCoordinate2D coordinate = [route coordinateAtDistance:_state.covered heading:&heading];
    if (CLLocationCoordinate2DIsValid(coordinate)) self.currentCoordinate = coordinate;
    if (isfinite(heading)) self.currentHeading = heading;
    self.remainingDirty = YES;
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
    LSMotionParams params = LSParamsForOptions(self.options, self.plan);
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
    // Legs at their own speeds are timed leg by leg; steady playback ends each step at a leg's end.
    if (params.smooth || params.useRecordedPace || route->legCount) return YES;
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
    LSMotionParams params = LSParamsForOptions(self.options, self.plan);
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
    LSMotionParams params = LSParamsForOptions(options, plan);
    return LSRemainingFrom(&plan->_motion, params, state);
}

+ (NSTimeInterval)remainingTimeForRoute:(LSRoute *)route options:(LSPlaybackOptions *)options
                                covered:(double)covered waitRemaining:(NSTimeInterval)wait {
    if (![route isKindOfClass:LSRoute.class] || !options.isValid || !isfinite(covered)) return NAN;
    LSMotionPlan *plan = [[LSMotionPlan alloc] initWithRoute:route];
    LSMotionParams params = LSParamsForOptions(options, plan);
    LSMotionState state;
    LSSeekState(plan, params, &state, covered, wait);
    return LSRemainingFrom(&plan->_motion, params, state);
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
        LSMotionParams params = LSParamsForOptions(trial, plan);
        return LSRemainingFrom(&plan->_motion, params, start);
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
    LSMotionParams params = LSParamsForOptions(options, plan);
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
