#import "PersistenceManager.h"

// Plaintext NSUserDefaults in the host sandbox; readable by the host process and device backups.
static NSString * const kSuiteName = @"com.locationspoofer.dylib";
static NSString * const kKeyEnabled = @"spoof_enabled";
static NSString * const kKeyLatitude = @"spoof_latitude";
static NSString * const kKeyLongitude = @"spoof_longitude";
static NSString * const kKeySimulationWasActive = @"LSSimulationWasActive";
static NSString * const kKeyAltitude = @"LSAltitude";
static NSString * const kKeyHeading = @"LSHeading";
static NSString * const kKeyRecentLocations = @"LSRecentLocations";
static NSString * const kRecentLatitudeKey = @"LSRecentLat";
static NSString * const kRecentLongitudeKey = @"LSRecentLon";
static NSString * const kRecentNameKey = @"LSRecentName";
static NSString * const kRecentDateKey = @"LSRecentDate";
static const NSUInteger kLSMaxRecentLocations = 5;

@interface PersistenceManager ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, assign) BOOL cachedEnabled;
@property (nonatomic, assign) CLLocationCoordinate2D cachedCoordinate;
@property (nonatomic, assign) BOOL hasCachedCoordinate;
@property (nonatomic, assign) BOOL cachedSimulationWasActive;
@property (nonatomic, assign) double cachedAltitude;
@property (nonatomic, assign) CLLocationDirection cachedHeading;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *cachedRecents;
@property (nonatomic, assign) BOOL recentsLoaded;
@end

@implementation PersistenceManager

@dynamic simulationWasActive, altitude, heading;

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
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        _cachedEnabled = NO;
        _cachedCoordinate = kCLLocationCoordinate2DInvalid;
        _hasCachedCoordinate = NO;
        _cachedAltitude = 0.0;
        _cachedHeading = 0.0;
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
    @synchronized(self) {
        self.cachedEnabled = [self.defaults boolForKey:kKeyEnabled];
        self.cachedSimulationWasActive = [self.defaults boolForKey:kKeySimulationWasActive];
        self.cachedAltitude = [self.defaults doubleForKey:kKeyAltitude];
        self.cachedHeading = [self.defaults doubleForKey:kKeyHeading];

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
    }
}

- (BOOL)isValidLatitude:(CLLocationDegrees)latitude longitude:(CLLocationDegrees)longitude {
    return latitude >= -90.0 && latitude <= 90.0 &&
           longitude >= -180.0 && longitude <= 180.0;
}

- (BOOL)isSpoofingEnabled {
    @synchronized(self) {
        return self.cachedEnabled && self.hasCachedCoordinate;
    }
}

- (CLLocationCoordinate2D)spoofCoordinate {
    @synchronized(self) {
        if (self.hasCachedCoordinate) {
            return self.cachedCoordinate;
        }
    }
    return CLLocationCoordinate2DMake(37.7749, -122.4194);
}

- (BOOL)hasStoredCoordinate {
    @synchronized(self) {
        return self.hasCachedCoordinate;
    }
}

- (BOOL)simulationWasActive {
    @synchronized(self) {
        return self.cachedSimulationWasActive;
    }
}

- (void)setSimulationWasActive:(BOOL)simulationWasActive {
    @synchronized(self) {
        self.cachedSimulationWasActive = simulationWasActive;
        [self.defaults setBool:simulationWasActive forKey:kKeySimulationWasActive];
    }
}

- (double)altitude {
    @synchronized(self) {
        return self.cachedAltitude;
    }
}

- (void)setAltitude:(double)altitude {
    @synchronized(self) {
        self.cachedAltitude = altitude;
        [self.defaults setDouble:altitude forKey:kKeyAltitude];
    }
}

- (CLLocationDirection)heading {
    @synchronized(self) {
        return self.cachedHeading;
    }
}

- (void)setHeading:(CLLocationDirection)heading {
    @synchronized(self) {
        self.cachedHeading = heading;
        [self.defaults setDouble:heading forKey:kKeyHeading];
    }
}

- (NSArray<NSDictionary *> *)recentLocations {
    @synchronized(self) {
        [self reloadRecentsLocked];
        return [self.cachedRecents copy];
    }
}

- (void)recordRecentCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    @synchronized(self) {
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
    }
}

- (BOOL)setSpoofCoordinate:(CLLocationCoordinate2D)coordinate enabled:(BOOL)enabled {
    if (![self isValidLatitude:coordinate.latitude longitude:coordinate.longitude]) {
        return NO;
    }

    @synchronized(self) {
        self.cachedCoordinate = coordinate;
        self.hasCachedCoordinate = YES;
        self.cachedEnabled = enabled;

        [self.defaults setDouble:coordinate.latitude forKey:kKeyLatitude];
        [self.defaults setDouble:coordinate.longitude forKey:kKeyLongitude];
        [self.defaults setBool:enabled forKey:kKeyEnabled];
        [self.defaults setDouble:self.cachedAltitude forKey:kKeyAltitude];
        [self.defaults setDouble:self.cachedHeading forKey:kKeyHeading];
    }
    return YES;
}

- (void)clearSpoof {
    @synchronized(self) {
        self.cachedEnabled = NO;
        self.hasCachedCoordinate = NO;
        self.cachedCoordinate = kCLLocationCoordinate2DInvalid;
        self.cachedSimulationWasActive = NO;

        [self.defaults removeObjectForKey:kKeyEnabled];
        [self.defaults removeObjectForKey:kKeyLatitude];
        [self.defaults removeObjectForKey:kKeyLongitude];
        [self.defaults setBool:NO forKey:kKeySimulationWasActive];
    }
}

@end
