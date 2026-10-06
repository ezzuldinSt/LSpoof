#import "LocationSpoofer.h"
#import "SessionController.h"
#import "LSHooking.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import <UIKit/UIKit.h>

static _Thread_local BOOL ls_internalCreate;
static char ls_libraryManagerKey;
static char ls_historyKey;

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

static LSDriftOffset LSRandomOffset(double radius) {
    double angle = (double)arc4random_uniform(UINT32_MAX) / UINT32_MAX * 2.0 * M_PI;
    double distance = sqrt((double)arc4random_uniform(UINT32_MAX) / UINT32_MAX) * radius;
    return (LSDriftOffset){distance * cos(angle), distance * sin(angle)};
}

// A fresh random point on every read made the held location jump across the whole
// radius many times per second (MapKit reads .location per frame). The offset now
// drifts smoothly between random targets, like a real GPS fix wandering.
static const NSTimeInterval kLSDriftInterval = 6.0;
static os_unfair_lock ls_driftLock = OS_UNFAIR_LOCK_INIT;
static struct {
    BOOL valid;
    CLLocationCoordinate2D base;
    double radius;
    LSDriftOffset from;
    LSDriftOffset to;
    NSTimeInterval start;
} ls_drift;

static LSDriftOffset LSCurrentDrift(CLLocationCoordinate2D base, double radius) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    os_unfair_lock_lock(&ls_driftLock);
    if (!ls_drift.valid || ls_drift.radius != radius ||
        fabs(ls_drift.base.latitude - base.latitude) > 1e-9 || fabs(ls_drift.base.longitude - base.longitude) > 1e-9) {
        ls_drift.valid = YES;
        ls_drift.base = base;
        ls_drift.radius = radius;
        ls_drift.from = LSRandomOffset(radius);
        ls_drift.to = LSRandomOffset(radius);
        ls_drift.start = now;
    } else if (now - ls_drift.start >= kLSDriftInterval) {
        BOOL stale = now - ls_drift.start >= 2.0 * kLSDriftInterval;
        ls_drift.from = stale ? LSRandomOffset(radius) : ls_drift.to;
        ls_drift.to = LSRandomOffset(radius);
        ls_drift.start = now;
    }
    double t = fmax(0.0, fmin(1.0, (now - ls_drift.start) / kLSDriftInterval));
    t = t * t * (3.0 - 2.0 * t);
    LSDriftOffset offset = {
        ls_drift.from.north + (ls_drift.to.north - ls_drift.from.north) * t,
        ls_drift.from.east + (ls_drift.to.east - ls_drift.from.east) * t
    };
    os_unfair_lock_unlock(&ls_driftLock);
    return offset;
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

static CLLocation *LSLocationForSnapshot(LSSessionSnapshot *snapshot) {
    CLLocation *sample = snapshot.location;
    if (snapshot.mode == LSSessionModeOff || !sample) return nil;
    CLLocationCoordinate2D coordinate = sample.coordinate;
    if (snapshot.fluctuationEnabled) coordinate = LSApplyFluctuation(coordinate, snapshot.fluctuationRadius);
    BOOL previous = ls_internalCreate;
    ls_internalCreate = YES;
    CLLocation *location;
    @try {
        location = [[CLLocation alloc] initWithCoordinate:coordinate altitude:sample.altitude
                                     horizontalAccuracy:sample.horizontalAccuracy verticalAccuracy:sample.verticalAccuracy
                                                 course:sample.course speed:sample.speed timestamp:[NSDate date]];
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
    }
}


// CoreLocation only calls a host delegate when the real device produces a fix that
// passes the host's distanceFilter. A phone lying still therefore delivered no route
// movement at all, and a newly applied location waited for the next real fix. The
// pusher delivers spoofed samples itself to managers the host is actively running.
static char ls_pushedKey;
static NSHashTable<CLLocationManager *> *ls_activeManagers;
static NSObject *ls_activeManagersLock;

static void LSSetManagerActive(CLLocationManager *manager, BOOL active) {
    if (!manager || LSIsLibraryLocationManager(manager)) return;
    @synchronized(ls_activeManagersLock) {
        // Delegates are called on the thread that created the manager. Only main-thread
        // managers are pushed so delivery never happens on an unexpected thread.
        if (active && NSThread.isMainThread) [ls_activeManagers addObject:manager];
        else [ls_activeManagers removeObject:manager];
    }
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
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    NSArray<CLLocationManager *> *managers;
    @synchronized(ls_activeManagersLock) { managers = ls_activeManagers.allObjects; }
    SEL selector = @selector(locationManager:didUpdateLocations:);
    for (CLLocationManager *manager in managers) {
        if (LSIsLibraryLocationManager(manager)) continue;
        id<CLLocationManagerDelegate> delegate = manager.delegate;
        if (!delegate || LSIsSystemClass([delegate class]) || ![delegate respondsToSelector:selector]) continue;
        CLAuthorizationStatus status = manager.authorizationStatus;
        if (status != kCLAuthorizationStatusAuthorizedAlways && status != kCLAuthorizationStatusAuthorizedWhenInUse) continue;
        CLLocation *sample = LSLocationForSnapshot(snapshot);
        if (!sample) return;
        CLLocation *previous = objc_getAssociatedObject(manager, &ls_pushedKey);
        CLLocationDistance filter = manager.distanceFilter;
        if (!force && previous && filter > 0 && [sample distanceFromLocation:previous] < filter) continue;
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
                LSSetManagerActive(manager, YES);
                original(manager, start);
            });
        });
        SEL stop = @selector(stopUpdatingLocation);
        LSInstallInstanceHook(managerClass, stop, ^IMP(IMP implementation) {
            void (*original)(id, SEL) = (void *)implementation;
            return imp_implementationWithBlock(^(CLLocationManager *manager) {
                LSSetManagerActive(manager, NO);
                original(manager, stop);
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
