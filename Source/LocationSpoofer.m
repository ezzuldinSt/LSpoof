#import "LocationSpoofer.h"
#import "SessionController.h"
#import "PersistenceManager.h"
#import "LSHooking.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import <UIKit/UIKit.h>

static _Thread_local BOOL ls_internalCreate;
static char ls_libraryManagerKey;
static char ls_historyKey;
static char ls_requestKey;
static char ls_oneShotKey;

// A swallowed kCLErrorLocationUnknown is replaced by a sample when none was delivered this recently.
static const NSTimeInterval kLSRecentSampleInterval = 10.0;
// CoreLocation reports a significant change after roughly 500 m of movement.
static const CLLocationDistance kLSSignificantChangeDistance = 500.0;

typedef struct {
    void *receiver;
    void *manager;
    SEL selector;
} LSDeliveryContext;
static _Thread_local LSDeliveryContext ls_deliveryContext;

@interface LSLocationHistory : NSObject
@property (nonatomic, strong) CLLocation *location;
@property (nonatomic, assign) uint64_t generation;
@end
@implementation LSLocationHistory
@end

BOOL LSIsInternalLocationCreate(void) {
    return ls_internalCreate;
}

void LSMarkLibraryLocationManager(CLLocationManager *manager) {
    objc_setAssociatedObject(manager, &ls_libraryManagerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL LSIsLibraryLocationManager(CLLocationManager *manager) {
    return [objc_getAssociatedObject(manager, &ls_libraryManagerKey) boolValue];
}

typedef struct {
    double north;
    double east;
} LSDriftOffset;

static double LSUniform(void) {
    return (double)arc4random() / 4294967296.0;
}

static double LSGaussian(void) {
    double u = fmax(LSUniform(), 1e-12);
    return sqrt(-2.0 * log(u)) * cos(2.0 * M_PI * LSUniform());
}

static LSDriftOffset LSClampOffset(LSDriftOffset offset, double limit) {
    double length = hypot(offset.north, offset.east);
    if (length <= limit || length <= 0.0) return offset;
    return (LSDriftOffset){offset.north * limit / length, offset.east * limit / length};
}

// The held point used to glide to a uniformly random spot every 6 seconds, on the same
// smoothstep curve each time, so the rhythm was easy to spot (#19). It now wanders in
// legs of random length and duration, mostly short hops with an occasional move
// across the circle, and a small quicker jitter rides on top.
typedef struct {
    LSDriftOffset from;
    LSDriftOffset to;
    NSTimeInterval start;
    NSTimeInterval duration;
    double ease;
} LSDriftLeg;

static LSDriftOffset LSWanderTarget(LSDriftOffset from, double radius) {
    LSDriftOffset target;
    if (LSUniform() < 0.65) {
        double step = radius * (0.12 + 0.48 * LSUniform());
        double angle = LSUniform() * 2.0 * M_PI;
        target = (LSDriftOffset){from.north + step * cos(angle), from.east + step * sin(angle)};
    } else {
        double sigma = radius * 0.45;
        target = (LSDriftOffset){LSGaussian() * sigma, LSGaussian() * sigma};
    }
    if (hypot(target.north, target.east) > radius) target = LSClampOffset(target, radius * (0.55 + 0.45 * LSUniform()));
    return target;
}

static LSDriftOffset LSJitterTarget(double amplitude) {
    return LSClampOffset((LSDriftOffset){LSGaussian() * amplitude * 0.5, LSGaussian() * amplitude * 0.5}, amplitude);
}

static void LSStartLeg(LSDriftLeg *leg, LSDriftOffset from, LSDriftOffset to, NSTimeInterval start, NSTimeInterval duration) {
    leg->from = from;
    leg->to = to;
    leg->start = start;
    leg->duration = duration;
    leg->ease = 1.2 + 1.6 * LSUniform();
}

static NSTimeInterval LSWanderDuration(void) {
    return fmin(18.0, 2.0 - log(1.0 - 0.999 * LSUniform()) * 4.5);
}

static NSTimeInterval LSJitterDuration(void) {
    return 0.6 + 1.8 * LSUniform();
}

static LSDriftOffset LSLegOffset(const LSDriftLeg *leg, NSTimeInterval now) {
    double t = fmax(0.0, fmin(1.0, (now - leg->start) / leg->duration));
    double a = pow(t, leg->ease), b = pow(1.0 - t, leg->ease);
    double eased = a + b > 0.0 ? a / (a + b) : t;
    return (LSDriftOffset){leg->from.north + (leg->to.north - leg->from.north) * eased,
                           leg->from.east + (leg->to.east - leg->from.east) * eased};
}

static os_unfair_lock ls_driftLock = OS_UNFAIR_LOCK_INIT;
static struct {
    BOOL valid;
    CLLocationCoordinate2D base;
    double radius;
    LSDriftLeg wander;
    LSDriftLeg jitter;
} ls_drift;

static LSDriftOffset LSCurrentDrift(CLLocationCoordinate2D base, double radius) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    double jitter = fmax(0.3, fmin(4.0, radius * 0.08));
    os_unfair_lock_lock(&ls_driftLock);
    if (!ls_drift.valid || ls_drift.radius != radius ||
        fabs(ls_drift.base.latitude - base.latitude) > 1e-9 || fabs(ls_drift.base.longitude - base.longitude) > 1e-9) {
        ls_drift.valid = YES;
        ls_drift.base = base;
        ls_drift.radius = radius;
        LSDriftOffset first = LSWanderTarget((LSDriftOffset){0, 0}, radius);
        LSStartLeg(&ls_drift.wander, first, LSWanderTarget(first, radius), now, LSWanderDuration());
        LSStartLeg(&ls_drift.jitter, (LSDriftOffset){0, 0}, LSJitterTarget(jitter), now, LSJitterDuration());
    }
    // After a long gap without reads the walk starts a fresh leg from where it was heading.
    if (now - ls_drift.wander.start > ls_drift.wander.duration + 30.0) {
        LSStartLeg(&ls_drift.wander, ls_drift.wander.to, LSWanderTarget(ls_drift.wander.to, radius), now, LSWanderDuration());
    }
    while (now - ls_drift.wander.start >= ls_drift.wander.duration) {
        LSDriftLeg *leg = &ls_drift.wander;
        LSStartLeg(leg, leg->to, LSWanderTarget(leg->to, radius), leg->start + leg->duration, LSWanderDuration());
    }
    if (now - ls_drift.jitter.start > ls_drift.jitter.duration + 10.0) {
        LSStartLeg(&ls_drift.jitter, ls_drift.jitter.to, LSJitterTarget(jitter), now, LSJitterDuration());
    }
    while (now - ls_drift.jitter.start >= ls_drift.jitter.duration) {
        LSDriftLeg *leg = &ls_drift.jitter;
        LSStartLeg(leg, leg->to, LSJitterTarget(jitter), leg->start + leg->duration, LSJitterDuration());
    }
    LSDriftOffset wander = LSLegOffset(&ls_drift.wander, now);
    LSDriftOffset shake = LSLegOffset(&ls_drift.jitter, now);
    os_unfair_lock_unlock(&ls_driftLock);
    return LSClampOffset((LSDriftOffset){wander.north + shake.north, wander.east + shake.east}, radius);
}

static CLLocationCoordinate2D LSApplyFluctuation(CLLocationCoordinate2D coordinate, double radius) {
    if (!isfinite(radius) || radius <= 0.0) return coordinate;
    LSDriftOffset offset = LSCurrentDrift(coordinate, radius);
    double latitude = fmax(-90.0, fmin(90.0, coordinate.latitude + offset.north / 111320.0));
    double cosLatitude = cos(coordinate.latitude * M_PI / 180.0);
    double longitude = coordinate.longitude;
    if (fabs(cosLatitude) > 1e-6) longitude += offset.east / (111320.0 * cosLatitude);
    longitude = fmod(longitude + 180.0, 360.0);
    if (longitude < 0.0) longitude += 360.0;
    return CLLocationCoordinate2DMake(latitude, longitude - 180.0);
}

// A heading derived from movement steadies with speed: about 18° walking, a few degrees driving.
static CLLocationDirectionAccuracy LSCourseAccuracy(CLLocationSpeed speed) {
    return fmin(45.0, fmax(3.0, 25.0 / fmax(speed, 0.5)));
}

static CLLocation *LSLocationForSnapshot(LSSessionSnapshot *snapshot) {
    CLLocation *sample = snapshot.location;
    if (snapshot.mode == LSSessionModeOff || !sample) return nil;
    CLLocationCoordinate2D coordinate = sample.coordinate;
    if (snapshot.fluctuationEnabled) coordinate = LSApplyFluctuation(coordinate, snapshot.fluctuationRadius);
    // The shorter initializer left courseAccuracy and speedAccuracy at -1, which marks course
    // and speed invalid to hosts that check them. SessionController puts the route's speed and
    // heading into a moving sample, speed 0 and the last heading into a paused one, and speed 0
    // with the Course setting into a held one.
    CLLocationSpeed speed = snapshot.mode == LSSessionModeMoving && sample.speed > 0 ? sample.speed : 0.0;
    CLLocationSpeedAccuracy speedAccuracy = 0.3 + 0.04 * fmax(0.0, sample.horizontalAccuracy);
    CLLocationDirection course = -1.0;
    CLLocationDirectionAccuracy courseAccuracy = -1.0;
    // A paused route is standing still, so its course is unknown, as on a real device.
    if (snapshot.mode != LSSessionModePaused && sample.course >= 0) {
        course = sample.course;
        courseAccuracy = LSCourseAccuracy(speed);
    }
    BOOL previous = ls_internalCreate;
    ls_internalCreate = YES;
    CLLocation *location;
    @try {
        location = [[CLLocation alloc] initWithCoordinate:coordinate altitude:sample.altitude
                                     horizontalAccuracy:sample.horizontalAccuracy verticalAccuracy:sample.verticalAccuracy
                                                 course:course courseAccuracy:courseAccuracy
                                                  speed:speed speedAccuracy:speedAccuracy timestamp:[NSDate date]];
    } @finally {
        ls_internalCreate = previous;
    }
    return location;
}

CLLocation *LSCreateSpoofedLocation(void) {
    if (ls_internalCreate) return nil;
    return LSLocationForSnapshot([LSSessionController shared].snapshot);
}

// All history is simulated. Never fall back to a host's real legacy oldLocation.
static CLLocation *LSRecordSample(CLLocationManager *manager, CLLocation *sample, uint64_t generation) {
    @synchronized(manager) {
        LSLocationHistory *history = objc_getAssociatedObject(manager, &ls_historyKey);
        CLLocation *previous = history.generation == generation ? history.location : nil;
        if (!sample) {
            objc_setAssociatedObject(manager, &ls_historyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return nil;
        }
        if (!history) history = [[LSLocationHistory alloc] init];
        history.location = sample;
        history.generation = generation;
        objc_setAssociatedObject(manager, &ls_historyKey, history, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return previous ?: sample;
    }
}

static void LSNoteLocationRequest(CLLocationManager *manager) {
    @synchronized(manager) {
        objc_setAssociatedObject(manager, &ls_requestKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// A failure is replaced by a sample when the host has none from this session yet, none since
// its last requestLocation (a one-shot request ends with exactly one update or failure), or
// none delivered recently.
static BOOL LSNeedsReplacementSample(CLLocationManager *manager, uint64_t generation) {
    @synchronized(manager) {
        LSLocationHistory *history = objc_getAssociatedObject(manager, &ls_historyKey);
        NSDate *delivered = history && history.generation == generation ? history.location.timestamp : nil;
        if (!delivered) return YES;
        NSDate *requested = objc_getAssociatedObject(manager, &ls_requestKey);
        if (requested && [delivered compare:requested] == NSOrderedAscending) return YES;
        return -delivered.timeIntervalSinceNow >= kLSRecentSampleInterval;
    }
}

static BOOL LSIsSystemClass(Class cls) {
    NSString *path = [NSBundle bundleForClass:cls].bundlePath;
    return path.length == 0 || [path hasPrefix:@"/System/"] ||
        [path hasPrefix:@"/private/preboot/Cryptexes/"] || [path hasPrefix:@"/usr/"];
}

static BOOL LSIsNestedDelivery(id receiver, CLLocationManager *manager, SEL selector) {
    return ls_deliveryContext.receiver == (__bridge void *)receiver &&
        ls_deliveryContext.manager == (__bridge void *)manager && ls_deliveryContext.selector == selector;
}

static void LSInstallDelegateHooks(id delegate) {
    for (Class cls = [delegate class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        if (LSIsSystemClass(cls)) continue;
        SEL modern = @selector(locationManager:didUpdateLocations:);
        LSInstallInstanceHook(cls, modern, ^IMP(IMP implementation) {
            void (*original)(id, SEL, CLLocationManager *, NSArray *) = (void *)implementation;
            return imp_implementationWithBlock(^(id receiver, CLLocationManager *manager, NSArray *locations) {
                NSArray *delivered = locations;
                if (!LSIsNestedDelivery(receiver, manager, modern) && !LSIsLibraryLocationManager(manager)) {
                    LSSessionSnapshot *snapshot = [LSSessionController shared].snapshot;
                    CLLocation *sample = LSLocationForSnapshot(snapshot);
                    if (sample) delivered = @[sample];
                    LSRecordSample(manager, sample, snapshot.generation);
                }
                LSDeliveryContext previous = ls_deliveryContext;
                ls_deliveryContext = (LSDeliveryContext){(__bridge void *)receiver, (__bridge void *)manager, modern};
                @try { original(receiver, modern, manager, delivered); }
                @finally { ls_deliveryContext = previous; }
            });
        });
        SEL legacy = @selector(locationManager:didUpdateToLocation:fromLocation:);
        LSInstallInstanceHook(cls, legacy, ^IMP(IMP implementation) {
            void (*original)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *) = (void *)implementation;
            return imp_implementationWithBlock(^(id receiver, CLLocationManager *manager, CLLocation *newLocation, CLLocation *oldLocation) {
                CLLocation *delivered = newLocation;
                CLLocation *previousSample = oldLocation;
                if (!LSIsNestedDelivery(receiver, manager, legacy) && !LSIsLibraryLocationManager(manager)) {
                    LSSessionSnapshot *snapshot = [LSSessionController shared].snapshot;
                    CLLocation *sample = LSLocationForSnapshot(snapshot);
                    CLLocation *history = LSRecordSample(manager, sample, snapshot.generation);
                    if (sample) { delivered = sample; previousSample = history; }
                }
                LSDeliveryContext previous = ls_deliveryContext;
                ls_deliveryContext = (LSDeliveryContext){(__bridge void *)receiver, (__bridge void *)manager, legacy};
                @try { original(receiver, legacy, manager, delivered, previousSample); }
                @finally { ls_deliveryContext = previous; }
            });
        });
        // Without a real fix (indoors, no signal) CoreLocation reports kCLErrorLocationUnknown
        // and keeps trying, so the host showed a location error while a spot was applied. Only
        // that error is swallowed; kCLErrorDenied and every other error always reach the host.
        SEL failure = @selector(locationManager:didFailWithError:);
        LSInstallInstanceHook(cls, failure, ^IMP(IMP implementation) {
            void (*original)(id, SEL, CLLocationManager *, NSError *) = (void *)implementation;
            return imp_implementationWithBlock(^(id receiver, CLLocationManager *manager, NSError *error) {
                if (!LSIsNestedDelivery(receiver, manager, failure) && !LSIsLibraryLocationManager(manager) &&
                    [error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorLocationUnknown) {
                    LSSessionSnapshot *snapshot = [LSSessionController shared].snapshot;
                    CLLocation *sample = LSLocationForSnapshot(snapshot);
                    if (sample) {
                        // Delivered on this thread, the manager's; the update hooks above
                        // substitute the current sample and record history.
                        if (!LSNeedsReplacementSample(manager, snapshot.generation)) return;
                        if ([receiver respondsToSelector:modern]) {
                            [receiver locationManager:manager didUpdateLocations:@[sample]];
                        } else if ([receiver respondsToSelector:legacy]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                            [receiver locationManager:manager didUpdateToLocation:sample fromLocation:sample];
#pragma clang diagnostic pop
                        }
                        return;
                    }
                }
                LSDeliveryContext previous = ls_deliveryContext;
                ls_deliveryContext = (LSDeliveryContext){(__bridge void *)receiver, (__bridge void *)manager, failure};
                @try { original(receiver, failure, manager, error); }
                @finally { ls_deliveryContext = previous; }
            });
        });
    }
}


// CoreLocation only calls a host delegate when the real device produces a fix that
// passes the host's distanceFilter. A phone lying still therefore delivered no route
// movement at all, and a newly applied location waited for the next real fix. The
// pusher delivers spoofed samples itself to managers the host is actively running.
static char ls_pushedKey;
static char ls_servicesKey;
static NSHashTable<CLLocationManager *> *ls_activeManagers;
static NSObject *ls_activeManagersLock;

typedef NS_OPTIONS(NSUInteger, LSManagerServices) {
    LSManagerServiceStandard = 1 << 0,     // startUpdatingLocation
    LSManagerServiceSignificant = 1 << 1,  // startMonitoringSignificantLocationChanges
};

// A manager stays pushed while either service runs, so stopping one keeps the other.
static void LSSetManagerService(CLLocationManager *manager, LSManagerServices service, BOOL active) {
    if (!manager || LSIsLibraryLocationManager(manager)) return;
    @synchronized(ls_activeManagersLock) {
        LSManagerServices services = [objc_getAssociatedObject(manager, &ls_servicesKey) unsignedIntegerValue];
        // Delegates are called on the thread that created the manager. Only main-thread
        // managers are pushed so delivery never happens on an unexpected thread.
        if (active && NSThread.isMainThread) services |= service;
        else if (active) services = 0;
        else services &= ~service;
        objc_setAssociatedObject(manager, &ls_servicesKey, services ? @(services) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (services) [ls_activeManagers addObject:manager];
        else [ls_activeManagers removeObject:manager];
    }
}

static LSManagerServices LSActiveServices(CLLocationManager *manager) {
    @synchronized(ls_activeManagersLock) {
        return [objc_getAssociatedObject(manager, &ls_servicesKey) unsignedIntegerValue];
    }
}

// The host delegate that may be handed a sample the library delivers itself, or nil.
// Authorization stays genuine: a manager without access is never answered.
static id<CLLocationManagerDelegate> LSPushableDelegate(CLLocationManager *manager) {
    if (LSIsLibraryLocationManager(manager)) return nil;
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if (!delegate || LSIsSystemClass([delegate class]) ||
        ![delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) return nil;
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status != kCLAuthorizationStatusAuthorizedAlways && status != kCLAuthorizationStatusAuthorizedWhenInUse) return nil;
    return delegate;
}

// requestLocation used to wait for a real fix, which indoors meant a long wait and then
// kCLErrorLocationUnknown. A main-thread manager is answered with one sample instead.
static void LSAnswerLocationRequest(CLLocationManager *manager, void (*original)(id, SEL), SEL selector) {
    // Repeated calls before the answer get one update, as in CoreLocation.
    if ([objc_getAssociatedObject(manager, &ls_oneShotKey) boolValue]) return;
    objc_setAssociatedObject(manager, &ls_oneShotKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak CLLocationManager *weakManager = manager;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *strongManager = weakManager;
        // stopUpdatingLocation cancels a pending request.
        if (!strongManager || ![objc_getAssociatedObject(strongManager, &ls_oneShotKey) boolValue]) return;
        objc_setAssociatedObject(strongManager, &ls_oneShotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id<CLLocationManagerDelegate> delegate = LSPushableDelegate(strongManager);
        CLLocation *sample = LSLocationForSnapshot([LSSessionController shared].snapshot);
        // Turned off (or access revoked) in the meantime: CoreLocation answers it after all.
        if (!delegate || !sample) {
            original(strongManager, selector);
            return;
        }
        // The installed delegate hook substitutes the current sample and records history.
        [delegate locationManager:strongManager didUpdateLocations:@[sample]];
    });
}

@interface LSLocationPusher : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) LSSessionMode lastMode;
@property (nonatomic) uint64_t lastGeneration;
@property (nonatomic) CLLocationCoordinate2D lastHeld;
@end

@implementation LSLocationPusher
+ (instancetype)shared {
    static LSLocationPusher *pusher;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pusher = [[self alloc] init]; });
    return pusher;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _lastMode = LSSessionModeOff;
        _lastHeld = kCLLocationCoordinate2DInvalid;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionChanged:)
                                                   name:LSSessionDidChangeNotification object:nil];
    }
    return self;
}
- (void)sessionChanged:(NSNotification *)note {
    (void)note;
    LSSessionSnapshot *snapshot = [LSSessionController shared].snapshot;
    LSSessionMode mode = snapshot.mode;
    BOOL modeChanged = mode != self.lastMode || snapshot.generation != self.lastGeneration;
    self.lastMode = mode;
    self.lastGeneration = snapshot.generation;
    if (mode == LSSessionModeMoving) {
        if (!self.timer) {
            self.timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
            [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        }
        if (modeChanged) [self pushSnapshot:snapshot force:YES];
        return;
    }
    [self.timer invalidate];
    self.timer = nil;
    if (mode != LSSessionModeStatic || !snapshot.location) {
        self.lastHeld = kCLLocationCoordinate2DInvalid;
        return;
    }
    CLLocationCoordinate2D held = snapshot.location.coordinate;
    BOOL moved = !CLLocationCoordinate2DIsValid(self.lastHeld) ||
        fabs(held.latitude - self.lastHeld.latitude) > 1e-7 || fabs(held.longitude - self.lastHeld.longitude) > 1e-7;
    self.lastHeld = held;
    if (moved || modeChanged) [self pushSnapshot:snapshot force:YES];
}
- (void)tick {
    LSSessionSnapshot *snapshot = [LSSessionController shared].snapshot;
    if (snapshot.mode != LSSessionModeMoving) { [self.timer invalidate]; self.timer = nil; return; }
    [self pushSnapshot:snapshot force:NO];
}
- (void)pushSnapshot:(LSSessionSnapshot *)snapshot force:(BOOL)force {
    // In the background a route only keeps moving when the user asked for it, and then
    // only services the OS keeps running there are pushed: standard updates the host set
    // up for the background, and significant changes with Always access.
    BOOL background = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    if (background && !PersistenceManager.shared.continueInBackground) return;
    NSArray<CLLocationManager *> *managers;
    @synchronized(ls_activeManagersLock) { managers = ls_activeManagers.allObjects; }
    for (CLLocationManager *manager in managers) {
        id<CLLocationManagerDelegate> delegate = LSPushableDelegate(manager);
        if (!delegate) continue;
        LSManagerServices services = LSActiveServices(manager);
        BOOL standard = (services & LSManagerServiceStandard) && (!background || manager.allowsBackgroundLocationUpdates);
        BOOL significant = (services & LSManagerServiceSignificant) &&
            (!background || manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways);
        if (!standard && !significant) continue;
        CLLocation *sample = LSLocationForSnapshot(snapshot);
        if (!sample) return;
        CLLocation *previous = objc_getAssociatedObject(manager, &ls_pushedKey);
        // Significant changes ignore distanceFilter and arrive only after about 500 m, even
        // when the held spot is replaced. Standard updates honour the host's filter, except
        // on a forced push (a new spot or a mode change).
        CLLocationDistance filter = standard ? manager.distanceFilter : kLSSignificantChangeDistance;
        BOOL filtered = previous && filter > 0 && [sample distanceFromLocation:previous] < filter;
        if (filtered && !(standard && force)) continue;
        objc_setAssociatedObject(manager, &ls_pushedKey, sample, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The installed delegate hook substitutes the current sample and records history.
        [delegate locationManager:manager didUpdateLocations:@[sample]];
    }
}
@end

@implementation LocationSpoofer

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ls_activeManagers = [NSHashTable weakObjectsHashTable];
        ls_activeManagersLock = [[NSObject alloc] init];
        Class managerClass = CLLocationManager.class;
        SEL setter = @selector(setDelegate:);
        LSInstallInstanceHook(managerClass, setter, ^IMP(IMP implementation) {
            void (*original)(id, SEL, id) = (void *)implementation;
            return imp_implementationWithBlock(^(CLLocationManager *manager, id delegate) {
                if (delegate && !LSIsLibraryLocationManager(manager)) LSInstallDelegateHooks(delegate);
                original(manager, setter, delegate);
            });
        });
        SEL getter = @selector(location);
        LSInstallInstanceHook(managerClass, getter, ^IMP(IMP implementation) {
            CLLocation *(*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^CLLocation *(CLLocationManager *manager) {
                if (!LSIsLibraryLocationManager(manager)) {
                    CLLocation *sample = LSCreateSpoofedLocation();
                    if (sample) return sample;
                }
                return original(manager, getter);
            });
        });
        SEL start = @selector(startUpdatingLocation);
        LSInstallInstanceHook(managerClass, start, ^IMP(IMP implementation) {
            void (*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^(CLLocationManager *manager) {
                LSSetManagerService(manager, LSManagerServiceStandard, YES);
                original(manager, start);
            });
        });
        SEL stop = @selector(stopUpdatingLocation);
        LSInstallInstanceHook(managerClass, stop, ^IMP(IMP implementation) {
            void (*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^(CLLocationManager *manager) {
                LSSetManagerService(manager, LSManagerServiceStandard, NO);
                // Stopping updates also cancels a pending requestLocation answer.
                if (NSThread.isMainThread) objc_setAssociatedObject(manager, &ls_oneShotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                original(manager, stop);
            });
        });
        SEL request = @selector(requestLocation);
        LSInstallInstanceHook(managerClass, request, ^IMP(IMP implementation) {
            void (*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^(CLLocationManager *manager) {
                if (LSIsLibraryLocationManager(manager) || [LSSessionController shared].snapshot.mode == LSSessionModeOff) {
                    original(manager, request);
                    return;
                }
                LSNoteLocationRequest(manager);
                // Only main-thread managers are answered directly, as the pusher does. Others
                // reach CoreLocation: a real fix is substituted by the delegate hook, and a
                // kCLErrorLocationUnknown failure is replaced by one sample.
                if (NSThread.isMainThread && LSPushableDelegate(manager)) LSAnswerLocationRequest(manager, original, request);
                else original(manager, request);
            });
        });
        SEL startSignificant = @selector(startMonitoringSignificantLocationChanges);
        LSInstallInstanceHook(managerClass, startSignificant, ^IMP(IMP implementation) {
            void (*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^(CLLocationManager *manager) {
                LSSetManagerService(manager, LSManagerServiceSignificant, YES);
                original(manager, startSignificant);
            });
        });
        SEL stopSignificant = @selector(stopMonitoringSignificantLocationChanges);
        LSInstallInstanceHook(managerClass, stopSignificant, ^IMP(IMP implementation) {
            void (*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^(CLLocationManager *manager) {
                LSSetManagerService(manager, LSManagerServiceSignificant, NO);
                original(manager, stopSignificant);
            });
        });
        dispatch_async(dispatch_get_main_queue(), ^{ (void)[LSLocationPusher shared]; });
        Class userLocationClass = NSClassFromString(@"MKUserLocation");
        LSInstallInstanceHook(userLocationClass, getter, ^IMP(IMP implementation) {
            CLLocation *(*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^CLLocation *(id receiver) {
                return LSCreateSpoofedLocation() ?: original(receiver, getter);
            });
        });
        // Authorization and service availability remain entirely owned by the OS.
    });
}

@end
