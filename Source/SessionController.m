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

@interface LSResumeOffer ()
@property (nonatomic, strong) LSRoute *route;
@property (nonatomic, strong) LSPlaybackOptions *options;
@property (nonatomic) double covered;
@property (nonatomic) double remainingDistance;
@property (nonatomic) NSTimeInterval remainingTime;
@end
@implementation LSResumeOffer
// Any thread: the estimate replays the rest of the route, which can take a moment.
+ (nullable instancetype)offerWithRoute:(LSRoute *)route checkpoint:(LSRouteCheckpoint *)checkpoint fallback:(LSPlaybackOptions *)fallback {
    if (!route || !checkpoint.isUnfinished || checkpoint.covered >= route.distance - 0.5) return nil;
    LSResumeOffer *offer = [[self alloc] init];
    offer.route = route;
    offer.options = [LSPlaybackOptions optionsWithPlayback:checkpoint.playback] ?: [fallback copy];
    offer.covered = checkpoint.covered;
    offer.remainingDistance = MAX(0, route.distance - checkpoint.covered);
    offer.remainingTime = [LSRouteSimulator remainingTimeForRoute:route options:offer.options covered:checkpoint.covered waitRemaining:checkpoint.waitRemaining];
    return offer;
}
@end

@interface LSSessionController () <LSRouteSimulatorDelegate> {
    os_unfair_lock _snapshotLock;
    LSSessionSnapshot *_snapshot;
    uint64_t _generation;
    BOOL _pausedForBackground;
    NSTimeInterval _lastCheckpoint;
    // The persisted copy of the retained route (#20): its identifier on disk, where it got to,
    // and the offer to go on from there. Main thread.
    NSString *_activeRouteID;
    LSRouteCheckpoint *_checkpoint;
    LSResumeOffer *_cachedOffer;
    // Bumped by every start, held location and turn-off, so a slow restore can tell it is stale.
    uint64_t _routeRevision;
    BOOL _restoreStarted;
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
    return [self applyStaticCoordinate:coordinate radiusOverride:radius keepRoute:NO];
}

- (BOOL)applyStaticCoordinate:(CLLocationCoordinate2D)coordinate radiusOverride:(double)radius keepRoute:(BOOL)keepRoute {
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
        self->_routeRevision++;
        if (!keepRoute) [self forgetPersistedRoute];
        if (wasOff) self->_generation++;
        [self publishMode:LSSessionModeStatic coordinate:coordinate heading:store.heading];
    }];
    return applied;
}

- (BOOL)startRoute:(LSRoute *)route options:(LSPlaybackOptions *)options {
    if (![options isKindOfClass:LSPlaybackOptions.class] || !options.isValid || ![route isKindOfClass:LSRoute.class]) return NO;
    __block BOOL started = NO;
    [self onMain:^{ started = [self beginRoute:route options:options covered:0 wait:0 routeID:nil]; }];
    return started;
}

// Main thread. routeID nil is a new run, written to disk; otherwise it continues that one.
- (BOOL)beginRoute:(LSRoute *)route options:(LSPlaybackOptions *)options covered:(double)covered wait:(double)wait routeID:(nullable NSString *)routeID {
    BOOL wasOff = self.snapshot.mode == LSSessionModeOff;
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    LSPlaybackOptions *previous = simulator.options;
    simulator.options = options;
    // The engine validates the complete replacement before stopping the old route.
    BOOL started = covered > 0 || wait > 0 ? [simulator startWithRoute:route covered:covered waitRemaining:wait] : [simulator startWithRoute:route];
    if (!started) {
        simulator.options = previous;
        return NO;
    }
    self.retainedRoute = route;
    _pausedForBackground = NO;
    _lastCheckpoint = NSProcessInfo.processInfo.systemUptime;
    _routeRevision++;
    PersistenceManager *store = [PersistenceManager shared];
    store.activeRadiusOverride = NAN;
    [store setSpoofCoordinate:simulator.currentCoordinate enabled:YES];
    store.simulationWasActive = YES;
    if (!routeID) {
        routeID = NSUUID.UUID.UUIDString;
        LSRouteArchive *archive = route.archive;
        archive.identifier = routeID;
        [store storeActiveRoute:archive.dictionaryRepresentation];
    }
    _activeRouteID = routeID;
    [self saveCheckpoint:[self currentCheckpoint]];
    if (wasOff) _generation++;
    [self publishMode:LSSessionModeMoving coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
    return YES;
}

#pragma mark - Resume (#20)

// Where the simulator is on the retained route right now.
- (nullable LSRouteCheckpoint *)currentCheckpoint {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    LSRoute *route = self.retainedRoute;
    if (!route || simulator.route != route || !_activeRouteID) return nil;
    // After stop the engine is back at zero; only a playing or arrived route knows where it is.
    if (!simulator.isSimulating && simulator.distanceCovered < route.distance - 0.5) return nil;
    LSRouteCheckpoint *checkpoint = [[LSRouteCheckpoint alloc] init];
    checkpoint.routeID = _activeRouteID;
    checkpoint.total = route.distance;
    checkpoint.covered = MIN(route.distance, MAX(0, simulator.distanceCovered));
    checkpoint.nextStop = simulator.nextStopIndex;
    checkpoint.waitRemaining = simulator.isWaitingAtStop ? simulator.waitRemaining : 0;
    checkpoint.playback = simulator.options.playback;
    return checkpoint;
}

- (void)saveCheckpoint:(nullable LSRouteCheckpoint *)checkpoint {
    if (!checkpoint) return;
    _checkpoint = checkpoint;
    _cachedOffer = nil;
    [PersistenceManager shared].routeCheckpoint = checkpoint.dictionaryRepresentation;
}

- (void)forgetPersistedRoute {
    PersistenceManager *store = [PersistenceManager shared];
    BOOL stored = _activeRouteID || _checkpoint || store.routeCheckpoint;
    _activeRouteID = nil;
    _checkpoint = nil;
    _cachedOffer = nil;
    if (stored) [store clearActiveRoute];
}

- (LSResumeOffer *)resumeOffer {
    if (!NSThread.isMainThread) return nil;
    LSRoute *route = self.retainedRoute;
    LSRouteCheckpoint *checkpoint = _checkpoint;
    if (!route || !checkpoint || ![checkpoint.routeID isEqualToString:_activeRouteID] || !checkpoint.isUnfinished ||
        LSRouteSimulator.shared.isSimulating || self.snapshot.mode != LSSessionModeStatic) return nil;
    if (_cachedOffer.route != route) _cachedOffer = [LSResumeOffer offerWithRoute:route checkpoint:checkpoint fallback:LSRouteSimulator.shared.options];
    return _cachedOffer;
}

- (BOOL)resumeRoute {
    __block BOOL started = NO;
    [self onMain:^{
        LSResumeOffer *offer = [self resumeOffer];
        LSRouteCheckpoint *checkpoint = self->_checkpoint;
        if (!offer || !checkpoint) return;
        started = [self beginRoute:offer.route options:offer.options covered:checkpoint.covered wait:checkpoint.waitRemaining routeID:self->_activeRouteID];
    }];
    return started;
}

- (void)restorePersistedRoute {
    if (!NSThread.isMainThread || _restoreStarted) return;
    _restoreStarted = YES;
    PersistenceManager *store = [PersistenceManager shared];
    // Something already replaced it (a scheduled start, say), and that keeps its own copy.
    if (self.retainedRoute || LSRouteSimulator.shared.isSimulating) return;
    LSRouteCheckpoint *checkpoint = [LSRouteCheckpoint checkpointFromDictionary:store.routeCheckpoint];
    // A route only makes sense while its last point is the held location. One that arrived
    // has nothing to resume, and a relaunch then starts as it always did.
    if (!checkpoint || !checkpoint.isUnfinished || self.snapshot.mode != LSSessionModeStatic) {
        [store clearActiveRoute];
        return;
    }
    uint64_t revision = _routeRevision;
    LSPlaybackOptions *fallback = [LSRouteSimulator.shared.options copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        LSRouteArchive *archive = [LSRouteArchive archiveFromDictionary:[store loadActiveRoute] error:NULL];
        LSRoute *route = [archive.identifier isEqualToString:checkpoint.routeID] ? [LSRoute routeWithArchive:archive] : nil;
        // The same path to within a meter, or the checkpoint's distance would land elsewhere.
        if (route && fabs(route.distance - checkpoint.total) > 1.0) route = nil;
        LSResumeOffer *offer = route ? [LSResumeOffer offerWithRoute:route checkpoint:checkpoint fallback:fallback] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            // The session changed meanwhile; whatever changed it kept or cleared the stored route.
            if (revision != self->_routeRevision || self.retainedRoute) return;
            if (!route || !offer || self.snapshot.mode != LSSessionModeStatic) {
                // Unreadable: fall back quietly to the held location.
                [store clearActiveRoute];
                return;
            }
            self.retainedRoute = route;
            self->_activeRouteID = checkpoint.routeID;
            self->_checkpoint = checkpoint;
            self->_cachedOffer = offer;
            // The planner shows, and Replay uses, the speed and motion the route had.
            if (offer.options && !LSRouteSimulator.shared.isSimulating) LSRouteSimulator.shared.options = offer.options;
            // The floating button and an open picker pick up the offer.
            [NSNotificationCenter.defaultCenter postNotificationName:LSSessionDidChangeNotification object:self];
        });
    });
}

- (BOOL)updatePlaybackOptions:(LSPlaybackOptions *)options {
    if (![options isKindOfClass:LSPlaybackOptions.class] || !options.isValid) return NO;
    [self onMain:^{
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        simulator.options = options;
        if (simulator.isSimulating) {
            // A resume continues at the speed and motion it last had.
            [self saveCheckpoint:[self currentCheckpoint]];
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
    [self saveCheckpoint:[self currentCheckpoint]];
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
        // Taken before the engine stops: the held spot is where Resume route goes on from.
        LSRouteCheckpoint *checkpoint = [self currentCheckpoint] ?: self->_checkpoint;
        NSString *routeID = self->_activeRouteID;
        [PersistenceManager shared].heading = location.course;
        [self applyStaticCoordinate:location.coordinate radiusOverride:NAN keepRoute:YES];
        self.retainedRoute = route;
        if (route && routeID && [checkpoint.routeID isEqualToString:routeID]) {
            self->_activeRouteID = routeID;
            [self saveCheckpoint:checkpoint];
        } else {
            [self forgetPersistedRoute];
        }
    }];
}

- (void)disable {
    [self onMain:^{
        self->_pausedForBackground = NO;
        [[LSRouteSimulator shared] stop];
        [PersistenceManager shared].activeRadiusOverride = NAN;
        [[PersistenceManager shared] clearSpoof];
        self.retainedRoute = nil;
        self->_routeRevision++;
        [self forgetPersistedRoute];
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
