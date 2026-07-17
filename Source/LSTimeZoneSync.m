#import "LSTimeZoneSync.h"
#import "PersistenceManager.h"

#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>

static os_unfair_lock ls_timeZoneLock = OS_UNFAIR_LOCK_INIT;
static NSTimeZone *ls_activeTimeZone = nil;
static BOOL ls_hooksInstalled = NO;
static BOOL ls_defaultTimeZoneApplied = NO;
static NSUInteger ls_geocodeGeneration = 0;
static CLGeocoder *ls_geocoder = nil;
static os_log_t ls_timeZoneLog = NULL;

static void LSExchangeClassMethods(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getClassMethod(cls, originalSelector);
    Method swizzledMethod = class_getClassMethod(cls, swizzledSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

static NSTimeZone *LSResolveTimeZoneFromIdentifier(NSString *identifier) {
    if (identifier.length == 0) {
        return nil;
    }
    return [NSTimeZone timeZoneWithName:identifier];
}

static NSTimeZone *LSCopyActiveSpoofedTimeZoneIfServing(void) {
    PersistenceManager *store = [PersistenceManager shared];
    if (!store.timezoneSyncEnabled || ![store isSpoofingEnabled]) {
        return nil;
    }
    os_unfair_lock_lock(&ls_timeZoneLock);
    NSTimeZone *spoofed = ls_activeTimeZone;
    os_unfair_lock_unlock(&ls_timeZoneLock);
    return spoofed;
}

static void LSSetActiveTimeZoneLocked(NSTimeZone * _Nullable timeZone) {
    ls_activeTimeZone = timeZone;
}

static void LSApplyDefaultTimeZoneIfNeeded(NSTimeZone *timeZone) {
    if (!timeZone) {
        return;
    }
    [NSTimeZone setDefaultTimeZone:timeZone];
    ls_defaultTimeZoneApplied = YES;
}

static void LSResetDefaultTimeZoneIfNeeded(void) {
    if (!ls_defaultTimeZoneApplied) {
        return;
    }
    NSTimeZone *systemZone = [NSTimeZone systemTimeZone];
    if (systemZone) {
        [NSTimeZone setDefaultTimeZone:systemZone];
    }
    ls_defaultTimeZoneApplied = NO;
}

@interface NSTimeZone (LSHooks)
+ (NSTimeZone *)lsp_systemTimeZone;
+ (NSTimeZone *)lsp_localTimeZone;
+ (NSTimeZone *)lsp_defaultTimeZone;
@end

@implementation NSTimeZone (LSHooks)

+ (NSTimeZone *)lsp_systemTimeZone {
    NSTimeZone *spoofed = LSCopyActiveSpoofedTimeZoneIfServing();
    if (spoofed) {
        return spoofed;
    }
    return [self lsp_systemTimeZone];
}

+ (NSTimeZone *)lsp_localTimeZone {
    NSTimeZone *spoofed = LSCopyActiveSpoofedTimeZoneIfServing();
    if (spoofed) {
        return spoofed;
    }
    return [self lsp_localTimeZone];
}

+ (NSTimeZone *)lsp_defaultTimeZone {
    NSTimeZone *spoofed = LSCopyActiveSpoofedTimeZoneIfServing();
    if (spoofed) {
        return spoofed;
    }
    return [self lsp_defaultTimeZone];
}

@end

@implementation LSTimeZoneSync

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ls_timeZoneLog = os_log_create("com.locationspoofer.dylib", "timezone");
        LSExchangeClassMethods([NSTimeZone class], @selector(systemTimeZone), @selector(lsp_systemTimeZone));
        LSExchangeClassMethods([NSTimeZone class], @selector(localTimeZone), @selector(lsp_localTimeZone));
        LSExchangeClassMethods([NSTimeZone class], @selector(defaultTimeZone), @selector(lsp_defaultTimeZone));
        ls_hooksInstalled = YES;
        ls_geocoder = [[CLGeocoder alloc] init];
    });
}

+ (nullable NSTimeZone *)activeSpoofedTimeZone {
    return LSCopyActiveSpoofedTimeZoneIfServing();
}

+ (void)applyCachedIdentifier:(NSString *)identifier {
    NSTimeZone *zone = LSResolveTimeZoneFromIdentifier(identifier);
    if (!zone) {
        if (ls_timeZoneLog) {
            os_log_error(ls_timeZoneLog, "Invalid time zone identifier: %{public}@", identifier ?: @"(nil)");
        }
        return;
    }

    os_unfair_lock_lock(&ls_timeZoneLock);
    LSSetActiveTimeZoneLocked(zone);
    os_unfair_lock_unlock(&ls_timeZoneLock);

    LSApplyDefaultTimeZoneIfNeeded(zone);
}

+ (void)applyFromPersistenceIfNeeded {
    PersistenceManager *store = [PersistenceManager shared];
    if (!store.timezoneSyncEnabled || ![store isSpoofingEnabled]) {
        [self clearApplied];
        return;
    }

    NSString *identifier = store.timeZoneIdentifier;
    if (identifier.length == 0) {
        if ([store hasStoredCoordinate]) {
            [self notifySpoofCoordinateChanged:[store spoofCoordinate]];
        }
        return;
    }

    [self applyCachedIdentifier:identifier];
}

+ (void)clearApplied {
    os_unfair_lock_lock(&ls_timeZoneLock);
    ls_geocodeGeneration += 1;
    LSSetActiveTimeZoneLocked(nil);
    os_unfair_lock_unlock(&ls_timeZoneLock);

    if (ls_geocoder.isGeocoding) {
        [ls_geocoder cancelGeocode];
    }
    LSResetDefaultTimeZoneIfNeeded();
}

+ (void)notifySpoofCoordinateChanged:(CLLocationCoordinate2D)coordinate {
    PersistenceManager *store = [PersistenceManager shared];
    if (!store.timezoneSyncEnabled || ![store isSpoofingEnabled]) {
        [self clearApplied];
        return;
    }

    if (!CLLocationCoordinate2DIsValid(coordinate) ||
        coordinate.latitude < -90.0 || coordinate.latitude > 90.0 ||
        coordinate.longitude < -180.0 || coordinate.longitude > 180.0) {
        return;
    }

    NSString *cachedIdentifier = store.timeZoneIdentifier;
    if (cachedIdentifier.length > 0) {
        [self applyCachedIdentifier:cachedIdentifier];
    }

    NSUInteger generation = 0;
    os_unfair_lock_lock(&ls_timeZoneLock);
    ls_geocodeGeneration += 1;
    generation = ls_geocodeGeneration;
    os_unfair_lock_unlock(&ls_timeZoneLock);

    if (ls_geocoder.isGeocoding) {
        [ls_geocoder cancelGeocode];
    }

    CLLocation *location = [[CLLocation alloc] initWithLatitude:coordinate.latitude
                                                      longitude:coordinate.longitude];
    [ls_geocoder reverseGeocodeLocation:location completionHandler:^(NSArray<CLPlacemark *> * _Nullable placemarks, NSError * _Nullable error) {
        os_unfair_lock_lock(&ls_timeZoneLock);
        BOOL outdated = generation != ls_geocodeGeneration;
        os_unfair_lock_unlock(&ls_timeZoneLock);
        if (outdated) {
            return;
        }

        PersistenceManager *latestStore = [PersistenceManager shared];
        if (!latestStore.timezoneSyncEnabled || ![latestStore isSpoofingEnabled]) {
            return;
        }

        NSTimeZone *resolved = placemarks.firstObject.timeZone;
        if (error || !resolved) {
            if (ls_timeZoneLog) {
                os_log_error(ls_timeZoneLog, "Time zone geocode failed: %{public}@", error.localizedDescription ?: @"no timezone");
            }
            return;
        }

        NSString *identifier = resolved.name;
        if (identifier.length == 0) {
            return;
        }

        latestStore.timeZoneIdentifier = identifier;
        [self applyCachedIdentifier:identifier];
    }];
}

@end
