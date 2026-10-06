#import "PersistenceManager.h"
#import <os/lock.h>

// Plaintext NSUserDefaults in the host sandbox; readable by the host process and device backups.
static NSString * const kSuiteName = @"com.locationspoofer.dylib";
static NSString * const kKeyEnabled = @"spoof_enabled";
static NSString * const kKeyLatitude = @"spoof_latitude";
static NSString * const kKeyLongitude = @"spoof_longitude";
static NSString * const kKeySimulationWasActive = @"LSSimulationWasActive";
static NSString * const kKeyAltitude = @"LSAltitude";
static NSString * const kKeyHeading = @"LSHeading";
static NSString * const kKeyFluctuationEnabled = @"LSFluctuationEnabled";
static NSString * const kKeyFluctuationRadius = @"LSFluctuationRadius";
static NSString * const kKeyKeepLastSpoof = @"LSKeepLastSpoof";
static NSString * const kKeyShowRealLocation = @"LSShowRealLocation";
static NSString * const kKeyFloatingButton = @"LSShowFloatingButton";
static NSString * const kKeyRecentLocations = @"LSRecentLocations";
static NSString * const kRecentLatitudeKey = @"LSRecentLat";
static NSString * const kRecentLongitudeKey = @"LSRecentLon";
static NSString * const kRecentNameKey = @"LSRecentName";
static NSString * const kRecentDateKey = @"LSRecentDate";
static const NSUInteger kLSMaxRecentLocations = 5;

@interface PersistenceManager () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, assign) BOOL cachedEnabled;
@property (nonatomic, assign) CLLocationCoordinate2D cachedCoordinate;
@property (nonatomic, assign) BOOL hasCachedCoordinate;
@property (nonatomic, assign) BOOL cachedSimulationWasActive;
@property (nonatomic, assign) double cachedAltitude;
@property (nonatomic, assign) CLLocationDirection cachedHeading;
@property (nonatomic, assign) BOOL cachedFluctuationEnabled;
@property (nonatomic, assign) double cachedFluctuationRadius;
@property (nonatomic, assign) BOOL cachedKeepLastSpoof;
@property (nonatomic, assign) BOOL cachedShowRealLocation;
@property (nonatomic, assign) BOOL cachedFloatingButton;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *cachedRecents;
@property (nonatomic, assign) BOOL recentsLoaded;
@end

@implementation PersistenceManager

@dynamic simulationWasActive, altitude, heading, fluctuationEnabled, fluctuationRadius, keepLastSpoof, showRealLocation, showFloatingButton;

+ (instancetype)shared {
    static PersistenceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PersistenceManager alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        _cachedEnabled = NO;
        _cachedCoordinate = kCLLocationCoordinate2DInvalid;
        _hasCachedCoordinate = NO;
        _cachedAltitude = 0.0;
        _cachedHeading = 0.0;
        _cachedFluctuationEnabled = NO;
        _cachedFluctuationRadius = 50.0;
        _cachedKeepLastSpoof = NO;
        _cachedShowRealLocation = NO;
        _cachedFloatingButton = YES;
        _cachedRecents = [NSMutableArray array];
    }
    return self;
}

+ (void)loadEarly {
    PersistenceManager *manager = [PersistenceManager shared];
    [manager reloadFromDefaults];
}

- (void)reloadRecentsLocked {
    if (self.recentsLoaded) return;
    id stored = [self.defaults objectForKey:kKeyRecentLocations];
    if ([stored isKindOfClass:NSArray.class]) {
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        for (id entry in stored) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            id lat = entry[kRecentLatitudeKey], lon = entry[kRecentLongitudeKey];
            id rawName = entry[kRecentNameKey], date = entry[kRecentDateKey];
            if (![lat isKindOfClass:NSNumber.class] || ![lon isKindOfClass:NSNumber.class] ||
                ![rawName isKindOfClass:NSString.class] || ![date isKindOfClass:NSString.class] ||
                ![self isValidLatitude:[lat doubleValue] longitude:[lon doubleValue]] ||
                [date length] > 64 || ![formatter dateFromString:date]) continue;
            NSString *name = [rawName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!name.length || name.length > 120) continue;
            BOOL duplicate = NO;
            for (NSDictionary *existing in self.cachedRecents) {
                if (fabs([existing[kRecentLatitudeKey] doubleValue] - [lat doubleValue]) < 0.000001 &&
                    fabs([existing[kRecentLongitudeKey] doubleValue] - [lon doubleValue]) < 0.000001) duplicate = YES;
            }
            if (duplicate) continue;
            [self.cachedRecents addObject:@{kRecentLatitudeKey:lat, kRecentLongitudeKey:lon, kRecentNameKey:name, kRecentDateKey:date}];
            if (self.cachedRecents.count == kLSMaxRecentLocations) break;
        }
    }
    self.recentsLoaded = YES;
}

- (double)storedNumber:(NSString *)key fallback:(double)fallback {
    id value = [self.defaults objectForKey:key];
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? [value doubleValue] : fallback;
}

- (BOOL)storedBool:(NSString *)key fallback:(BOOL)fallback {
    id value = [self.defaults objectForKey:key];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}

- (void)reloadFromDefaults {
    os_unfair_lock_lock(&_lock);
    self.cachedEnabled = [self storedBool:kKeyEnabled fallback:NO];
    self.cachedSimulationWasActive = [self storedBool:kKeySimulationWasActive fallback:NO];
    self.cachedAltitude = [self storedNumber:kKeyAltitude fallback:0];
    self.cachedHeading = [self storedNumber:kKeyHeading fallback:0];
    self.cachedFluctuationEnabled = [self storedBool:kKeyFluctuationEnabled fallback:NO];
    self.cachedFluctuationRadius = [self storedNumber:kKeyFluctuationRadius fallback:50];
    self.cachedKeepLastSpoof = [self storedBool:kKeyKeepLastSpoof fallback:NO];
    self.cachedShowRealLocation = [self storedBool:kKeyShowRealLocation fallback:NO];
    self.cachedFloatingButton = [self storedBool:kKeyFloatingButton fallback:YES];
    if (self.cachedAltitude < -500 || self.cachedAltitude > 10000) self.cachedAltitude = 0;
    if (!isfinite(self.cachedAltitude)) self.cachedAltitude = 0.0;
    if (!isfinite(self.cachedHeading)) self.cachedHeading = 0.0;
    self.cachedHeading = fmod(fmod(self.cachedHeading, 360.0) + 360.0, 360.0);
    if (!isfinite(self.cachedFluctuationRadius) || self.cachedFluctuationRadius < 1.0 || self.cachedFluctuationRadius > 1000.0) {
        self.cachedFluctuationRadius = 50.0;
    }

    id storedLatitude = [self.defaults objectForKey:kKeyLatitude];
    id storedLongitude = [self.defaults objectForKey:kKeyLongitude];
    if ([storedLatitude isKindOfClass:NSNumber.class] && [storedLongitude isKindOfClass:NSNumber.class]) {
        CLLocationDegrees latitude = [storedLatitude doubleValue];
        CLLocationDegrees longitude = [storedLongitude doubleValue];
        if ([self isValidLatitude:latitude longitude:longitude]) {
            self.cachedCoordinate = CLLocationCoordinate2DMake(latitude, longitude);
            self.hasCachedCoordinate = YES;
        } else {
            self.cachedCoordinate = kCLLocationCoordinate2DInvalid;
            self.hasCachedCoordinate = NO;
        }
    } else {
        self.cachedCoordinate = kCLLocationCoordinate2DInvalid;
        self.hasCachedCoordinate = NO;
    }

    self.recentsLoaded = NO;
    [self.cachedRecents removeAllObjects];
    [self reloadRecentsLocked];
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)isValidLatitude:(CLLocationDegrees)latitude longitude:(CLLocationDegrees)longitude {
    return isfinite(latitude) && isfinite(longitude) && latitude >= -90.0 && latitude <= 90.0 &&
           longitude >= -180.0 && longitude <= 180.0;
}

- (BOOL)isSpoofingEnabled {
    os_unfair_lock_lock(&_lock);
    BOOL enabled = self.cachedEnabled && self.hasCachedCoordinate;
    os_unfair_lock_unlock(&_lock);
    return enabled;
}

- (CLLocationCoordinate2D)spoofCoordinate {
    os_unfair_lock_lock(&_lock);
    if (self.hasCachedCoordinate) {
        CLLocationCoordinate2D coord = self.cachedCoordinate;
        os_unfair_lock_unlock(&_lock);
        return coord;
    }
    os_unfair_lock_unlock(&_lock);
    return CLLocationCoordinate2DMake(37.7749, -122.4194);
}

- (BOOL)hasStoredCoordinate {
    os_unfair_lock_lock(&_lock);
    BOOL stored = self.hasCachedCoordinate;
    os_unfair_lock_unlock(&_lock);
    return stored;
}

- (BOOL)simulationWasActive {
    os_unfair_lock_lock(&_lock);
    BOOL active = self.cachedSimulationWasActive;
    os_unfair_lock_unlock(&_lock);
    return active;
}

- (void)setSimulationWasActive:(BOOL)simulationWasActive {
    os_unfair_lock_lock(&_lock);
    self.cachedSimulationWasActive = simulationWasActive;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setBool:simulationWasActive forKey:kKeySimulationWasActive];
}

- (double)altitude {
    os_unfair_lock_lock(&_lock);
    double alt = self.cachedAltitude;
    os_unfair_lock_unlock(&_lock);
    return alt;
}

- (void)setAltitude:(double)altitude {
    if (!isfinite(altitude) || altitude < -500 || altitude > 10000) return;
    os_unfair_lock_lock(&_lock);
    self.cachedAltitude = altitude;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setDouble:altitude forKey:kKeyAltitude];
}

- (CLLocationDirection)heading {
    os_unfair_lock_lock(&_lock);
    CLLocationDirection hdg = self.cachedHeading;
    os_unfair_lock_unlock(&_lock);
    return hdg;
}

- (void)setHeading:(CLLocationDirection)heading {
    if (!isfinite(heading)) return;
    heading = fmod(fmod(heading, 360.0) + 360.0, 360.0);
    os_unfair_lock_lock(&_lock);
    self.cachedHeading = heading;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setDouble:heading forKey:kKeyHeading];
}

- (BOOL)fluctuationEnabled {
    os_unfair_lock_lock(&_lock);
    BOOL enabled = self.cachedFluctuationEnabled;
    os_unfair_lock_unlock(&_lock);
    return enabled;
}

- (void)setFluctuationEnabled:(BOOL)fluctuationEnabled {
    os_unfair_lock_lock(&_lock);
    self.cachedFluctuationEnabled = fluctuationEnabled;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setBool:fluctuationEnabled forKey:kKeyFluctuationEnabled];
}

- (double)fluctuationRadius {
    os_unfair_lock_lock(&_lock);
    double radius = self.cachedFluctuationRadius;
    os_unfair_lock_unlock(&_lock);
    return radius > 0.0 ? radius : 50.0;
}

- (void)setFluctuationRadius:(double)fluctuationRadius {
    if (!isfinite(fluctuationRadius) || fluctuationRadius < 1.0 || fluctuationRadius > 1000.0) return;
    os_unfair_lock_lock(&_lock);
    self.cachedFluctuationRadius = fluctuationRadius;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setDouble:fluctuationRadius forKey:kKeyFluctuationRadius];
}

- (BOOL)keepLastSpoof {
    os_unfair_lock_lock(&_lock);
    BOOL keep = self.cachedKeepLastSpoof;
    os_unfair_lock_unlock(&_lock);
    return keep;
}

- (void)setKeepLastSpoof:(BOOL)keepLastSpoof {
    os_unfair_lock_lock(&_lock);
    self.cachedKeepLastSpoof = keepLastSpoof;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setBool:keepLastSpoof forKey:kKeyKeepLastSpoof];
}

- (BOOL)showRealLocation {
    os_unfair_lock_lock(&_lock);
    BOOL show = self.cachedShowRealLocation;
    os_unfair_lock_unlock(&_lock);
    return show;
}

- (void)setShowRealLocation:(BOOL)showRealLocation {
    os_unfair_lock_lock(&_lock);
    self.cachedShowRealLocation = showRealLocation;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setBool:showRealLocation forKey:kKeyShowRealLocation];
}

- (NSArray<NSDictionary *> *)recentLocations {
    os_unfair_lock_lock(&_lock);
    [self reloadRecentsLocked];
    NSArray *recents = [self.cachedRecents copy];
    os_unfair_lock_unlock(&_lock);
    return recents;
}

- (void)recordRecentCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (![self isValidLatitude:coordinate.latitude longitude:coordinate.longitude]) return;
    NSString *validName = [name isKindOfClass:NSString.class] ? [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    if (!validName.length) validName = @"Selected location";
    if (validName.length > 120) validName = [validName substringToIndex:120];
    os_unfair_lock_lock(&_lock);
    [self reloadRecentsLocked];
    NSIndexSet *duplicates = [self.cachedRecents indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, __unused NSUInteger index, __unused BOOL *stop) {
        return fabs([entry[kRecentLatitudeKey] doubleValue] - coordinate.latitude) < 0.000001 &&
            fabs([entry[kRecentLongitudeKey] doubleValue] - coordinate.longitude) < 0.000001;
    }];
    [self.cachedRecents removeObjectsAtIndexes:duplicates];
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSDictionary *entry = @{kRecentLatitudeKey:@(coordinate.latitude), kRecentLongitudeKey:@(coordinate.longitude),
                            kRecentNameKey:validName, kRecentDateKey:[formatter stringFromDate:NSDate.date]};
    [self.cachedRecents insertObject:entry atIndex:0];
    while (self.cachedRecents.count > kLSMaxRecentLocations) [self.cachedRecents removeLastObject];
    NSArray *payload = [self.cachedRecents copy];
    os_unfair_lock_unlock(&_lock);
    [self.defaults setObject:payload forKey:kKeyRecentLocations];
}

- (void)clearRecentLocations {
    os_unfair_lock_lock(&_lock);
    [self.cachedRecents removeAllObjects];
    self.recentsLoaded = YES;
    os_unfair_lock_unlock(&_lock);
    [self.defaults removeObjectForKey:kKeyRecentLocations];
}

- (BOOL)showFloatingButton {
    os_unfair_lock_lock(&_lock);
    BOOL show = self.cachedFloatingButton;
    os_unfair_lock_unlock(&_lock);
    return show;
}
- (void)setShowFloatingButton:(BOOL)show {
    os_unfair_lock_lock(&_lock);
    self.cachedFloatingButton = show;
    os_unfair_lock_unlock(&_lock);
    [self.defaults setBool:show forKey:kKeyFloatingButton];
}

- (BOOL)setSpoofCoordinate:(CLLocationCoordinate2D)coordinate enabled:(BOOL)enabled {
    if (![self isValidLatitude:coordinate.latitude longitude:coordinate.longitude]) {
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    self.cachedCoordinate = coordinate;
    self.hasCachedCoordinate = YES;
    self.cachedEnabled = enabled;
    double altitude = self.cachedAltitude, heading = self.cachedHeading, radius = self.cachedFluctuationRadius;
    BOOL fluctuation = self.cachedFluctuationEnabled;
    os_unfair_lock_unlock(&_lock);

    // NSUserDefaults can post change notifications synchronously; never write while
    // holding the non-recursive cache lock.
    [self.defaults setDouble:coordinate.latitude forKey:kKeyLatitude];
    [self.defaults setDouble:coordinate.longitude forKey:kKeyLongitude];
    [self.defaults setBool:enabled forKey:kKeyEnabled];
    [self.defaults setDouble:altitude forKey:kKeyAltitude];
    [self.defaults setDouble:heading forKey:kKeyHeading];
    [self.defaults setBool:fluctuation forKey:kKeyFluctuationEnabled];
    [self.defaults setDouble:radius forKey:kKeyFluctuationRadius];
    return YES;
}

- (void)clearSpoof {
    os_unfair_lock_lock(&_lock);
    BOOL preserve = self.cachedKeepLastSpoof && self.hasCachedCoordinate;
    self.cachedEnabled = NO;
    if (!preserve) {
        self.hasCachedCoordinate = NO;
        self.cachedCoordinate = kCLLocationCoordinate2DInvalid;
    }
    self.cachedSimulationWasActive = NO;
    os_unfair_lock_unlock(&_lock);

    if (!preserve) {
        [self.defaults removeObjectForKey:kKeyLatitude];
        [self.defaults removeObjectForKey:kKeyLongitude];
    }
    [self.defaults removeObjectForKey:kKeyEnabled];
    [self.defaults setBool:NO forKey:kKeySimulationWasActive];
}

- (void)clearLastSpoof {
    os_unfair_lock_lock(&_lock);
    self.cachedEnabled = NO;
    self.hasCachedCoordinate = NO;
    self.cachedCoordinate = kCLLocationCoordinate2DInvalid;
    self.cachedSimulationWasActive = NO;
    self.cachedKeepLastSpoof = NO;
    os_unfair_lock_unlock(&_lock);

    [self.defaults removeObjectForKey:kKeyEnabled];
    [self.defaults removeObjectForKey:kKeyLatitude];
    [self.defaults removeObjectForKey:kKeyLongitude];
    [self.defaults setBool:NO forKey:kKeySimulationWasActive];
    [self.defaults setBool:NO forKey:kKeyKeepLastSpoof];
}

@end
