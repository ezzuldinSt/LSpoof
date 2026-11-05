#import "SessionController.h"
#import "PersistenceManager.h"
#import "LSSettings.h"
#import <UIKit/UIKit.h>
#import <os/lock.h>

NSNotificationName const LSSessionDidChangeNotification = @"LSSessionDidChange";

@interface LSSessionSnapshot ()
@property (nonatomic, assign) LSSessionMode mode;
@property (nonatomic, strong, nullable) CLLocation *location;
@property (nonatomic, assign) uint64_t generation;
@property (nonatomic, assign) BOOL fluctuationEnabled;
@property (nonatomic, assign) double fluctuationRadius;
@end
@implementation LSSessionSnapshot
@end

@interface LSSessionController () <LSRouteSimulatorDelegate> {
    os_unfair_lock _snapshotLock;
    LSSessionSnapshot *_snapshot;
    uint64_t _generation;
    BOOL _pausedForBackground;
    NSTimeInterval _lastCheckpoint;
}
@property (nonatomic, strong, nullable) LSRoute *retainedRoute;
@end

@implementation LSSessionController

+ (instancetype)shared {
    static LSSessionController *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _snapshotLock = OS_UNFAIR_LOCK_INIT;
        _generation = 1;
        PersistenceManager *store = [PersistenceManager shared];
        // A terminated route restores its last checkpoint as a held location.
        store.simulationWasActive = NO;
        [LSRouteSimulator shared].delegate = self;
        [self publishMode:store.isSpoofingEnabled ? LSSessionModeStatic : LSSessionModeOff
              coordinate:store.spoofCoordinate heading:store.heading];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationDidEnterBackground:)
                                                   name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationWillEnterForeground:)
                                                   name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (LSSessionSnapshot *)snapshot {
    os_unfair_lock_lock(&_snapshotLock);
    LSSessionSnapshot *snapshot = _snapshot;
    os_unfair_lock_unlock(&_snapshotLock);
    return snapshot;
}

- (void)onMain:(dispatch_block_t)command {
    if (NSThread.isMainThread) command();
    else dispatch_sync(dispatch_get_main_queue(), command);
}

- (void)publishMode:(LSSessionMode)mode coordinate:(CLLocationCoordinate2D)coordinate heading:(CLLocationDirection)heading {
    PersistenceManager *store = [PersistenceManager shared];
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    LSSessionSnapshot *snapshot = [[LSSessionSnapshot alloc] init];
    snapshot.mode = mode;
    snapshot.generation = _generation;
    // A saved place can carry its own radius, or turn wandering off for itself.
    double placeRadius = store.activeRadiusOverride;
    BOOL wander = isfinite(placeRadius) ? placeRadius > 0 : store.fluctuationEnabled;
    snapshot.fluctuationEnabled = mode == LSSessionModeStatic && wander;
    snapshot.fluctuationRadius = isfinite(placeRadius) && placeRadius > 0 ? placeRadius : store.fluctuationRadius;
    if (mode != LSSessionModeOff && CLLocationCoordinate2DIsValid(coordinate)) {
        double speed = mode == LSSessionModeMoving ? simulator.currentSpeed : 0.0;
        double accuracy = mode == LSSessionModeMoving || mode == LSSessionModePaused
            ? [LSRouteSimulator horizontalAccuracyForMode:simulator.transportMode] : 6.0;
        snapshot.location = [[CLLocation alloc] initWithCoordinate:coordinate altitude:store.altitude
                                              horizontalAccuracy:accuracy verticalAccuracy:6.0
                                                          course:heading speed:speed timestamp:[NSDate date]];
    } else {
        snapshot.mode = LSSessionModeOff;
    }
    os_unfair_lock_lock(&_snapshotLock);
    _snapshot = snapshot;
    os_unfair_lock_unlock(&_snapshotLock);
    // UI subscribers observe completed commands, not intermediate persistence writes.
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:LSSessionDidChangeNotification object:self];
    });
}

- (BOOL)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate {
    return [self applyStaticCoordinate:coordinate radiusOverride:NAN];
}

- (BOOL)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate radiusOverride:(double)radius {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return NO;
    __block BOOL applied = NO;
    [self onMain:^{
        [PersistenceManager shared].activeRadiusOverride = radius;
        BOOL wasOff = self.snapshot.mode == LSSessionModeOff;
        self->_pausedForBackground = NO;
        [[LSRouteSimulator shared] stop];
        PersistenceManager *store = [PersistenceManager shared];
        applied = [store setSpoofCoordinate:coordinate enabled:YES];
        if (!applied) return;
        store.simulationWasActive = NO;
        self.retainedRoute = nil;
        if (wasOff) self->_generation++;
        [self publishMode:LSSessionModeStatic coordinate:coordinate heading:store.heading];
    }];
    return applied;
}

- (BOOL)startRoute:(LSRoute *)route options:(LSPlaybackOptions *)options {
    if (![options isKindOfClass:LSPlaybackOptions.class] || !options.isValid || ![route isKindOfClass:LSRoute.class]) return NO;
    __block BOOL started = NO;
    [self onMain:^{
        BOOL wasOff = self.snapshot.mode == LSSessionModeOff;
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        LSPlaybackOptions *previous = simulator.options;
        simulator.options = options;
        // The engine validates the complete replacement before stopping the old route.
        started = [simulator startWithRoute:route];
        if (!started) {
            simulator.options = previous;
            return;
        }
        self.retainedRoute = route;
        self->_pausedForBackground = NO;
        self->_lastCheckpoint = NSProcessInfo.processInfo.systemUptime;
        PersistenceManager *store = [PersistenceManager shared];
        store.activeRadiusOverride = NAN;
        [store setSpoofCoordinate:simulator.startCoordinate enabled:YES];
        store.simulationWasActive = YES;
        if (wasOff) self->_generation++;
        [self publishMode:LSSessionModeMoving coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
    }];
    return started;
}

- (BOOL)updatePlaybackOptions:(LSPlaybackOptions *)options {
    if (![options isKindOfClass:LSPlaybackOptions.class] || !options.isValid) return NO;
    [self onMain:^{
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        simulator.options = options;
        if (simulator.isSimulating) {
            [self publishMode:simulator.isPaused ? LSSessionModePaused : LSSessionModeMoving
                  coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
        }
    }];
    return YES;
}

// Small steps at walking pace, bigger ones at driving speeds.
static double LSNextSpeed(double kmh, NSInteger direction) {
    static const double steps[] = {1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100,
                                   110, 120, 130, 150, 175, 200, 250, 300, 400, 500};
    size_t count = sizeof(steps) / sizeof(steps[0]);
    if (direction > 0) { for (size_t i = 0; i < count; i++) if (steps[i] > kmh + 0.01) return steps[i]; return 500; }
    for (size_t i = count; i > 0; i--) if (steps[i - 1] < kmh - 0.01) return steps[i - 1];
    return 1;
}

static double LSNextMultiplier(double multiplier, NSInteger direction) {
    static const double steps[] = {0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 10};
    size_t count = sizeof(steps) / sizeof(steps[0]);
    if (direction > 0) { for (size_t i = 0; i < count; i++) if (steps[i] > multiplier + 0.001) return steps[i]; return 10; }
    for (size_t i = count; i > 0; i--) if (steps[i - 1] < multiplier - 0.001) return steps[i - 1];
    return 0.25;
}

- (BOOL)updatePlayingRoute:(LSRoute *)route {
    if (![route isKindOfClass:LSRoute.class]) return NO;
    __block BOOL updated = NO;
    [self onMain:^{
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        if (self.retainedRoute != simulator.route) return;
        updated = [simulator replaceRouteKeepingProgress:route];
        if (!updated) return;
        self.retainedRoute = route;
        [self publishMode:simulator.isPaused ? LSSessionModePaused : LSSessionModeMoving
              coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
    }];
    return updated;
}

- (BOOL)nudgeSpeed:(NSInteger)direction {
    __block BOOL changed = NO;
    [self onMain:^{
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        if (!simulator.isSimulating || direction == 0) return;
        LSPlaybackOptions *options = [simulator.options copy];
        if (simulator.currentLegHasOwnSpeed) {
            // The leg being played changes, so the location speeds up or slows down now.
            LSRoute *route = simulator.route;
            NSUInteger leg = simulator.currentLegIndex;
            double current = route.legs[leg].speedKmh, next = LSNextSpeed(current, direction);
            if (fabs(next - current) <= 0.01) return;
            NSMutableArray<NSNumber *> *speeds = [NSMutableArray arrayWithCapacity:route.legs.count];
            for (LSRouteLeg *each in route.legs) [speeds addObject:@(each.speedKmh)];
            speeds[leg] = @(next);
            LSRoute *updated = [route routeWithLegSpeeds:speeds];
            changed = updated && [self updatePlayingRoute:updated];
            return;
        }
        if (options.recordedPace && simulator.route.hasTiming) {
            double next = LSNextMultiplier(options.paceMultiplier, direction);
            changed = fabs(next - options.paceMultiplier) > 0.001;
            options.paceMultiplier = next;
        } else {
            double current = options.speedKmh;
            LSPlaybackOptions *next = [LSPlaybackOptions optionsWithSpeedKmh:LSNextSpeed(current, direction)];
            changed = fabs(next.speedKmh - current) > 0.01;
            options.mode = next.mode;
            options.customSpeedKmh = next.customSpeedKmh;
            options.recordedPace = NO;
        }
        if (changed) [self updatePlaybackOptions:options];
    }];
    return changed;
}

- (void)checkpointSimulator {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    PersistenceManager *store = [PersistenceManager shared];
    store.heading = simulator.currentHeading;
    [store setSpoofCoordinate:simulator.currentCoordinate enabled:YES];
    _lastCheckpoint = NSProcessInfo.processInfo.systemUptime;
}

- (BOOL)saveSettings:(LSSettings *)settings {
    LSSettings *validated = [settings copy];
    if (!validated.isValid) return NO;
    [self onMain:^{
        LSSessionSnapshot *current = self.snapshot;
        [validated writeToStore];
        CLLocationDirection course = current.mode == LSSessionModeStatic ? validated.course : current.location.course;
        [self publishMode:current.mode coordinate:current.location ? current.location.coordinate : kCLLocationCoordinate2DInvalid heading:course];
    }];
    return YES;
}

- (void)pause {
    [self onMain:^{
        self->_pausedForBackground = NO;
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        if (!simulator.isSimulating || simulator.isPaused) return;
        [simulator pause];
        [self checkpointSimulator];
        [self publishMode:LSSessionModePaused coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
    }];
}

- (void)resume {
    [self onMain:^{
        self->_pausedForBackground = NO;
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        if (!simulator.isSimulating || !simulator.isPaused) return;
        [simulator resume];
        [self publishMode:LSSessionModeMoving coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
    }];
}

- (void)stopAndHold {
    [self onMain:^{
        CLLocation *location = self.snapshot.location;
        if (!location) return;
        LSRoute *route = self.retainedRoute;
        [PersistenceManager shared].heading = location.course;
        [self applyStaticCoordinate:location.coordinate];
        self.retainedRoute = route;
    }];
}

- (void)disable {
    [self onMain:^{
        self->_pausedForBackground = NO;
        [[LSRouteSimulator shared] stop];
        [PersistenceManager shared].activeRadiusOverride = NAN;
        [[PersistenceManager shared] clearSpoof];
        self.retainedRoute = nil;
        self->_generation++;
        [self publishMode:LSSessionModeOff coordinate:kCLLocationCoordinate2DInvalid heading:0.0];
    }];
}

- (void)routeSimulator:(LSRouteSimulator *)simulator didUpdateCoordinate:(CLLocationCoordinate2D)coordinate heading:(CLLocationDirection)heading {
    // Previously the stored point only changed on pause or finish, so a crash or a
    // force quit mid-route restored the route's start. Checkpoint every few seconds.
    if (NSProcessInfo.processInfo.systemUptime - _lastCheckpoint >= 5.0) [self checkpointSimulator];
    [self publishMode:simulator.isPaused ? LSSessionModePaused : LSSessionModeMoving coordinate:coordinate heading:heading];
}

- (void)routeSimulatorDidFinish:(LSRouteSimulator *)simulator {
    [self checkpointSimulator];
    [PersistenceManager shared].simulationWasActive = NO;
    [self publishMode:LSSessionModeStatic coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self onMain:^{
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        if (!simulator.isSimulating || simulator.isPaused) return;
        // Only useful while iOS keeps the host running, e.g. a host with background location.
        if ([PersistenceManager shared].continueInBackground) return;
        [self pause];
        // Remember that the pause was automatic so the route continues on return.
        self->_pausedForBackground = YES;
    }];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    (void)notification;
    [self onMain:^{
        if (!self->_pausedForBackground) return;
        [self resume];
    }];
}

@end
