#import "LocationSpoofer.h"
#import "SessionController.h"
#import "LSHooking.h"
#import <objc/runtime.h>

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

static CLLocationCoordinate2D LSApplyFluctuation(CLLocationCoordinate2D coordinate, double radius) {
    if (!isfinite(radius) || radius <= 0.0) return coordinate;
    double angle = (double)arc4random_uniform(UINT32_MAX) / UINT32_MAX * 2.0 * M_PI;
    double distance = sqrt((double)arc4random_uniform(UINT32_MAX) / UINT32_MAX) * radius;
    double latitude = fmax(-90.0, fmin(90.0, coordinate.latitude + distance * cos(angle) / 111320.0));
    double cosLatitude = cos(coordinate.latitude * M_PI / 180.0);
    double longitude = coordinate.longitude;
    if (fabs(cosLatitude) > 1e-6) longitude += distance * sin(angle) / (111320.0 * cosLatitude);
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

@implementation LocationSpoofer

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
