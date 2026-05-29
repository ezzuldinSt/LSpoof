#import "LocationSpoofer.h"
#import "PersistenceManager.h"
#import "RouteSimulator.h"
#import "LSHooking.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static _Thread_local BOOL ls_internalCreate = NO;
static BOOL ls_hooksBypassed = NO;
static NSHashTable *ls_swizzledDelegateClasses = nil;
static NSMutableSet *ls_observedDelegateClasses = nil;
static dispatch_once_t ls_delegateTablesOnceToken;
static dispatch_once_t ls_hookSelectorsOnceToken;
static os_log_t ls_log = NULL;

static SEL ls_hookDidUpdateLocationsSEL = NULL;
static SEL ls_hookDidUpdateToLocationSEL = NULL;

static void LSHookDidUpdateLocations(id self, SEL _cmd, CLLocationManager *manager, NSArray<CLLocation *> *locations);
static void LSHookDidUpdateToLocation(id self, SEL _cmd, CLLocationManager *manager, CLLocation *newLocation, CLLocation *oldLocation);

BOOL LSIsInternalLocationCreate(void) {
    return ls_internalCreate;
}

void LSSetHooksBypassed(BOOL bypassed) {
    @synchronized([LocationSpoofer class]) {
        ls_hooksBypassed = bypassed;
    }
}

static BOOL LSHooksBypassed(void) {
    @synchronized([LocationSpoofer class]) {
        return ls_hooksBypassed;
    }
}

static BOOL LSShouldSpoof(void) {
    return !ls_internalCreate &&
           !LSHooksBypassed() &&
           [[PersistenceManager shared] isSpoofingEnabled];
}

static CLLocation *LSBuildSpoofedLocation(CLLocationCoordinate2D coordinate,
                                          CLLocationDirection course,
                                          double altitude,
                                          double horizontalAccuracy,
                                          double speed) {
    ls_internalCreate = YES;
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:coordinate
                                                         altitude:altitude
                                               horizontalAccuracy:horizontalAccuracy
                                                 verticalAccuracy:6.0
                                                            course:course
                                                             speed:speed
                                                         timestamp:[NSDate date]];
    ls_internalCreate = NO;
    return location;
}

static CLLocationCoordinate2D LSApplyFluctuation(CLLocationCoordinate2D coordinate, double radiusMeters) {
    if (radiusMeters <= 0.0) {
        return coordinate;
    }

    double angle = (double)arc4random_uniform(UINT32_MAX) / (double)UINT32_MAX * 2.0 * M_PI;
    double distance = sqrt((double)arc4random_uniform(UINT32_MAX) / (double)UINT32_MAX) * radiusMeters;

    double latOffset = distance * cos(angle) / 111320.0;
    double cosLat = cos(coordinate.latitude * M_PI / 180.0);
    double lonOffset = 0.0;
    if (fabs(cosLat) > 1e-6) {
        lonOffset = distance * sin(angle) / (111320.0 * cosLat);
    }

    double newLat = coordinate.latitude + latOffset;
    double newLon = coordinate.longitude + lonOffset;

    if (newLat > 90.0) {
        newLat = 90.0;
    } else if (newLat < -90.0) {
        newLat = -90.0;
    }

    if (newLon > 180.0) {
        newLon -= 360.0;
    } else if (newLon < -180.0) {
        newLon += 360.0;
    }

    return CLLocationCoordinate2DMake(newLat, newLon);
}

CLLocation *LSCreateSpoofedLocation(void) {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    if (simulator.isSimulating) {
        LSTransportMode mode = simulator.transportMode;
        double speed = [LSRouteSimulator speedMetersPerSecondForMode:mode customSpeedKmh:simulator.customSpeedKmh];
        double accuracy = [LSRouteSimulator horizontalAccuracyForMode:mode];
        PersistenceManager *store = [PersistenceManager shared];
        return LSBuildSpoofedLocation(simulator.currentCoordinate,
                                      simulator.currentHeading,
                                      store.altitude,
                                      accuracy,
                                      speed);
    }

    PersistenceManager *store = [PersistenceManager shared];
    CLLocationCoordinate2D baseCoordinate = [store spoofCoordinate];
    if (store.fluctuationEnabled) {
        baseCoordinate = LSApplyFluctuation(baseCoordinate, store.fluctuationRadius);
    }
    return LSBuildSpoofedLocation(baseCoordinate,
                                store.heading,
                                store.altitude,
                                6.0,
                                0.0);
}

static BOOL LSIsSystemFrameworkBundle(NSBundle *bundle) {
    NSString *path = bundle.bundlePath;
    if (path.length == 0) {
        return YES;
    }
    if ([path hasPrefix:@"/System/"]) {
        return YES;
    }
    if ([path hasPrefix:@"/private/preboot/Cryptexes/"]) {
        return YES;
    }
    if ([path hasPrefix:@"/usr/"]) {
        return YES;
    }
    return NO;
}

static void LSInitializeDelegateTables(void) {
    dispatch_once(&ls_delegateTablesOnceToken, ^{
        ls_swizzledDelegateClasses = [NSHashTable weakObjectsHashTable];
        ls_observedDelegateClasses = [NSMutableSet set];
    });
}

static void LSInitializeDelegateHookSelectors(void) {
    dispatch_once(&ls_hookSelectorsOnceToken, ^{
        NSString *suffix = NSUUID.UUID.UUIDString;
        NSString *locationsName = [NSString stringWithFormat:@"lsp_locationManager_didUpdateLocations_%@:", suffix];
        NSString *legacyName = [NSString stringWithFormat:@"lsp_locationManager_didUpdateToLocation_fromLocation_%@:", suffix];
        ls_hookDidUpdateLocationsSEL = sel_registerName(locationsName.UTF8String);
        ls_hookDidUpdateToLocationSEL = sel_registerName(legacyName.UTF8String);
    });
}

static BOOL LSShouldSwizzleDelegateClass(Class delegateClass) {
    if (!delegateClass || delegateClass == [NSObject class]) {
        return NO;
    }

    NSString *className = NSStringFromClass(delegateClass);
    if (className.length == 0 || [className hasPrefix:@"_"]) {
        return NO;
    }

    if (LSIsSystemFrameworkBundle([NSBundle bundleForClass:delegateClass])) {
        return NO;
    }

    LSInitializeDelegateTables();
    @synchronized(ls_swizzledDelegateClasses) {
        return [ls_observedDelegateClasses containsObject:delegateClass];
    }
}

static void LSObserveDelegateClass(Class delegateClass) {
    if (!delegateClass || delegateClass == [NSObject class]) {
        return;
    }

    if (LSIsSystemFrameworkBundle([NSBundle bundleForClass:delegateClass])) {
        return;
    }

    LSInitializeDelegateTables();
    @synchronized(ls_swizzledDelegateClasses) {
        [ls_observedDelegateClasses addObject:delegateClass];
    }
}

static void LSSwizzleDelegateForClass(Class delegateClass) {
    if (!delegateClass || !LSShouldSwizzleDelegateClass(delegateClass)) {
        return;
    }

    LSInitializeDelegateHookSelectors();

    LSInitializeDelegateTables();
    @synchronized(ls_swizzledDelegateClasses) {
        Class locationsClass = LSClassDefiningInstanceMethod(delegateClass,
                                                             @selector(locationManager:didUpdateLocations:));
        if (locationsClass && ![ls_swizzledDelegateClasses containsObject:locationsClass]) {
            if (LSInstallInstanceHookWithIMP(locationsClass,
                                             @selector(locationManager:didUpdateLocations:),
                                             ls_hookDidUpdateLocationsSEL,
                                             (IMP)LSHookDidUpdateLocations)) {
                [ls_swizzledDelegateClasses addObject:locationsClass];
            }
        }

        Class legacyClass = LSClassDefiningInstanceMethod(delegateClass,
                                                          @selector(locationManager:didUpdateToLocation:fromLocation:));
        if (legacyClass && ![ls_swizzledDelegateClasses containsObject:legacyClass]) {
            if (LSInstallInstanceHookWithIMP(legacyClass,
                                             @selector(locationManager:didUpdateToLocation:fromLocation:),
                                             ls_hookDidUpdateToLocationSEL,
                                             (IMP)LSHookDidUpdateToLocation)) {
                [ls_swizzledDelegateClasses addObject:legacyClass];
            }
        }
    }
}

static void LSSwizzleDelegateIfNeeded(id delegate) {
    if (!delegate) {
        return;
    }

    Class delegateClass = [delegate class];
    LSObserveDelegateClass(delegateClass);
    LSSwizzleDelegateForClass(delegateClass);
}

static void LSHookDidUpdateLocations(id self, SEL _cmd, CLLocationManager *manager, NSArray<CLLocation *> *locations) {
    (void)_cmd;
    NSArray<CLLocation *> *deliveredLocations = locations;
    if (LSShouldSpoof()) {
        deliveredLocations = @[LSCreateSpoofedLocation()];
    }

    void (*originalIMP)(id, SEL, CLLocationManager *, NSArray<CLLocation *> *) =
        (void (*)(id, SEL, CLLocationManager *, NSArray<CLLocation *> *))objc_msgSend;
    originalIMP(self, ls_hookDidUpdateLocationsSEL, manager, deliveredLocations);
}

static void LSHookDidUpdateToLocation(id self, SEL _cmd, CLLocationManager *manager, CLLocation *newLocation, CLLocation *oldLocation) {
    (void)_cmd;
    CLLocation *deliveredLocation = newLocation;
    if (LSShouldSpoof()) {
        deliveredLocation = LSCreateSpoofedLocation();
    }

    void (*originalIMP)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *) =
        (void (*)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *))objc_msgSend;
    originalIMP(self, ls_hookDidUpdateToLocationSEL, manager, deliveredLocation, oldLocation);
}

@interface CLLocationManager (LSHooks)
- (void)lsp_setDelegate:(id<CLLocationManagerDelegate>)delegate;
- (CLLocation *)lsp_location;
@end

@implementation CLLocationManager (LSHooks)

- (void)lsp_setDelegate:(id<CLLocationManagerDelegate>)delegate {
    [self lsp_setDelegate:delegate];
    if (delegate) {
        LSSwizzleDelegateIfNeeded(delegate);
    }
}

- (CLLocation *)lsp_location {
    if (LSShouldSpoof()) {
        return LSCreateSpoofedLocation();
    }
    return [self lsp_location];
}

@end

static void LSExchangeInstanceMethods(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

static void LSInstallCLLocationManagerHooks(void) {
    Class managerClass = NSClassFromString(@"CLLocationManager");
    if (!managerClass) {
        if (ls_log) {
            os_log_error(ls_log, "CLLocationManager class missing at hook install");
        }
        return;
    }

    if (!class_getInstanceMethod(managerClass, @selector(setDelegate:))) {
        if (ls_log) {
            os_log_error(ls_log, "CLLocationManager setDelegate: missing at hook install");
        }
        return;
    }

    LSExchangeInstanceMethods(managerClass, @selector(setDelegate:), @selector(lsp_setDelegate:));

    if (class_getInstanceMethod(managerClass, @selector(location))) {
        LSExchangeInstanceMethods(managerClass, @selector(location), @selector(lsp_location));
    }
}

@implementation LocationSpoofer

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ls_log = os_log_create("com.locationspoofer.dylib", "hooks");
        LSInitializeDelegateHookSelectors();
        LSInstallCLLocationManagerHooks();
    });
}

@end
