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
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *cachedRecents;
@property (nonatomic, assign) BOOL recentsLoaded;
@end

@implementation PersistenceManager

@dynamic simulationWasActive, altitude, heading, fluctuationEnabled, fluctuationRadius;

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
        _cachedRecents = [NSMutableArray array];
    }
    return self;
}

+ (void)loadEarly {
    PersistenceManager *manager = [PersistenceManager shared];
    [manager reloadFromDefaults];
}

- (void)reloadRecentsLocked {
    if (self.recentsLoaded) {
        return;
    }
    NSArray *stored = [self.defaults arrayForKey:kKeyRecentLocations];
    if ([stored isKindOfClass:[NSArray class]]) {
        for (id entry in stored) {
            if ([entry isKindOfClass:[NSDictionary class]]) {
                [self.cachedRecents addObject:entry];
            }
        }
    }
    self.recentsLoaded = YES;
}

- (void)reloadFromDefaults {
    os_unfair_lock_lock(&_lock);
    self.cachedEnabled = [self.defaults boolForKey:kKeyEnabled];
    self.cachedSimulationWasActive = [self.defaults boolForKey:kKeySimulationWasActive];
    self.cachedAltitude = [self.defaults doubleForKey:kKeyAltitude];
    self.cachedHeading = [self.defaults doubleForKey:kKeyHeading];
    self.cachedFluctuationEnabled = [self.defaults boolForKey:kKeyFluctuationEnabled];
    self.cachedFluctuationRadius = [self.defaults doubleForKey:kKeyFluctuationRadius];
    if (self.cachedFluctuationRadius <= 0.0) {
        self.cachedFluctuationRadius = 50.0;
    }

    if ([self.defaults objectForKey:kKeyLatitude] != nil &&
        [self.defaults objectForKey:kKeyLongitude] != nil) {
        CLLocationDegrees latitude = [self.defaults doubleForKey:kKeyLatitude];
        CLLocationDegrees longitude = [self.defaults doubleForKey:kKeyLongitude];
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
    return latitude >= -90.0 && latitude <= 90.0 &&
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
    [self.defaults setBool:simulationWasActive forKey:kKeySimulationWasActive];
    os_unfair_lock_unlock(&_lock);
}

- (double)altitude {
    os_unfair_lock_lock(&_lock);
    double alt = self.cachedAltitude;
    os_unfair_lock_unlock(&_lock);
    return alt;
}

- (void)setAltitude:(double)altitude {
    os_unfair_lock_lock(&_lock);
    self.cachedAltitude = altitude;
    [self.defaults setDouble:altitude forKey:kKeyAltitude];
    os_unfair_lock_unlock(&_lock);
}

- (CLLocationDirection)heading {
    os_unfair_lock_lock(&_lock);
    CLLocationDirection hdg = self.cachedHeading;
    os_unfair_lock_unlock(&_lock);
    return hdg;
}

- (void)setHeading:(CLLocationDirection)heading {
    os_unfair_lock_lock(&_lock);
    self.cachedHeading = heading;
    [self.defaults setDouble:heading forKey:kKeyHeading];
    os_unfair_lock_unlock(&_lock);
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
    [self.defaults setBool:fluctuationEnabled forKey:kKeyFluctuationEnabled];
    os_unfair_lock_unlock(&_lock);
}

- (double)fluctuationRadius {
    os_unfair_lock_lock(&_lock);
    double radius = self.cachedFluctuationRadius;
    os_unfair_lock_unlock(&_lock);
    return radius > 0.0 ? radius : 50.0;
}

- (void)setFluctuationRadius:(double)fluctuationRadius {
    os_unfair_lock_lock(&_lock);
    self.cachedFluctuationRadius = fluctuationRadius > 0.0 ? fluctuationRadius : 50.0;
    [self.defaults setDouble:self.cachedFluctuationRadius forKey:kKeyFluctuationRadius];
    os_unfair_lock_unlock(&_lock);
}

- (NSArray<NSDictionary *> *)recentLocations {
    os_unfair_lock_lock(&_lock);
    [self reloadRecentsLocked];
    NSArray *recents = [self.cachedRecents copy];
    os_unfair_lock_unlock(&_lock);
    return recents;
}

- (void)recordRecentCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    os_unfair_lock_lock(&_lock);
    [self reloadRecentsLocked];

        static NSISO8601DateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSISO8601DateFormatter alloc] init];
        });

        NSDictionary *entry = @{
            kRecentLatitudeKey: @(coordinate.latitude),
            kRecentLongitudeKey: @(coordinate.longitude),
            kRecentNameKey: name.length > 0 ? name : @"Location",
            kRecentDateKey: [formatter stringFromDate:[NSDate date]]
        };

        [self.cachedRecents insertObject:entry atIndex:0];
        while (self.cachedRecents.count > kLSMaxRecentLocations) {
            [self.cachedRecents removeLastObject];
        }
        [self.defaults setObject:[self.cachedRecents copy] forKey:kKeyRecentLocations];
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)setSpoofCoordinate:(CLLocationCoordinate2D)coordinate enabled:(BOOL)enabled {
    if (![self isValidLatitude:coordinate.latitude longitude:coordinate.longitude]) {
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    self.cachedCoordinate = coordinate;
    self.hasCachedCoordinate = YES;
    self.cachedEnabled = enabled;

    [self.defaults setDouble:coordinate.latitude forKey:kKeyLatitude];
    [self.defaults setDouble:coordinate.longitude forKey:kKeyLongitude];
    [self.defaults setBool:enabled forKey:kKeyEnabled];
    [self.defaults setDouble:self.cachedAltitude forKey:kKeyAltitude];
    [self.defaults setDouble:self.cachedHeading forKey:kKeyHeading];
    [self.defaults setBool:self.cachedFluctuationEnabled forKey:kKeyFluctuationEnabled];
    [self.defaults setDouble:self.cachedFluctuationRadius forKey:kKeyFluctuationRadius];
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (void)clearSpoof {
    os_unfair_lock_lock(&_lock);
    self.cachedEnabled = NO;
    self.hasCachedCoordinate = NO;
    self.cachedCoordinate = kCLLocationCoordinate2DInvalid;
    self.cachedSimulationWasActive = NO;

    [self.defaults removeObjectForKey:kKeyEnabled];
    [self.defaults removeObjectForKey:kKeyLatitude];
    [self.defaults removeObjectForKey:kKeyLongitude];
    [self.defaults setBool:NO forKey:kKeySimulationWasActive];
    os_unfair_lock_unlock(&_lock);
}

@end
