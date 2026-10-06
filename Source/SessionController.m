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
}
@property (nonatomic, strong, nullable) MKRoute *retainedRoute;
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
    snapshot.fluctuationEnabled = mode == LSSessionModeStatic && store.fluctuationEnabled;
    snapshot.fluctuationRadius = store.fluctuationRadius;
    if (mode != LSSessionModeOff && CLLocationCoordinate2DIsValid(coordinate)) {
        double speed = mode == LSSessionModeMoving
            ? [LSRouteSimulator speedMetersPerSecondForMode:simulator.transportMode customSpeedKmh:simulator.customSpeedKmh] : 0.0;
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
    if (!CLLocationCoordinate2DIsValid(coordinate)) return NO;
    __block BOOL applied = NO;
    [self onMain:^{
        BOOL wasOff = self.snapshot.mode == LSSessionModeOff;
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

- (BOOL)validTransportMode:(LSTransportMode)mode speed:(double)speed {
    return mode >= LSTransportModeWalking && mode <= LSTransportModeCustom &&
        (mode != LSTransportModeCustom || (isfinite(speed) && speed >= 1.0 && speed <= 500.0));
}

- (BOOL)startRoute:(MKRoute *)route transportMode:(LSTransportMode)mode customSpeedKmh:(double)speed {
    if (![self validTransportMode:mode speed:speed]) return NO;
    __block BOOL started = NO;
    [self onMain:^{
        BOOL wasOff = self.snapshot.mode == LSSessionModeOff;
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        LSTransportMode previousMode = simulator.transportMode;
        double previousSpeed = simulator.customSpeedKmh;
        simulator.transportMode = mode;
        simulator.customSpeedKmh = mode == LSTransportModeCustom ? speed : 30.0;
        // The engine validates the complete replacement before stopping the old route.
        started = [simulator startWithRoute:route];
        if (!started) {
            simulator.transportMode = previousMode;
            simulator.customSpeedKmh = previousSpeed;
            return;
        }
        self.retainedRoute = route;
        PersistenceManager *store = [PersistenceManager shared];
        [store setSpoofCoordinate:simulator.startCoordinate enabled:YES];
        store.simulationWasActive = YES;
        if (wasOff) self->_generation++;
        [self publishMode:LSSessionModeMoving coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
    }];
    return started;
}

- (BOOL)updateTransportMode:(LSTransportMode)mode customSpeedKmh:(double)speed {
    if (![self validTransportMode:mode speed:speed]) return NO;
    [self onMain:^{
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        simulator.transportMode = mode;
        simulator.customSpeedKmh = mode == LSTransportModeCustom ? speed : 30.0;
        if (simulator.isSimulating) {
            [self publishMode:simulator.isPaused ? LSSessionModePaused : LSSessionModeMoving
                  coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
        }
    }];
    return YES;
}

- (void)checkpointSimulator {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    PersistenceManager *store = [PersistenceManager shared];
    store.heading = simulator.currentHeading;
    [store setSpoofCoordinate:simulator.currentCoordinate enabled:YES];
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
        LSRouteSimulator *simulator = [LSRouteSimulator shared];
        if (!simulator.isSimulating || simulator.isPaused) return;
        [simulator pause];
        [self checkpointSimulator];
        [self publishMode:LSSessionModePaused coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
    }];
}

- (void)resume {
    [self onMain:^{
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
        MKRoute *route = self.retainedRoute;
        [PersistenceManager shared].heading = location.course;
        [self applyStaticCoordinate:location.coordinate];
        self.retainedRoute = route;
    }];
}

- (void)disable {
    [self onMain:^{
        [[LSRouteSimulator shared] stop];
        [[PersistenceManager shared] clearSpoof];
        self.retainedRoute = nil;
        self->_generation++;
        [self publishMode:LSSessionModeOff coordinate:kCLLocationCoordinate2DInvalid heading:0.0];
    }];
}

- (void)routeSimulator:(LSRouteSimulator *)simulator didUpdateCoordinate:(CLLocationCoordinate2D)coordinate heading:(CLLocationDirection)heading {
    [self publishMode:simulator.isPaused ? LSSessionModePaused : LSSessionModeMoving coordinate:coordinate heading:heading];
}

- (void)routeSimulatorDidFinish:(LSRouteSimulator *)simulator {
    [self checkpointSimulator];
    [PersistenceManager shared].simulationWasActive = NO;
    [self publishMode:LSSessionModeStatic coordinate:simulator.currentCoordinate heading:simulator.currentHeading];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self pause];
}

@end
