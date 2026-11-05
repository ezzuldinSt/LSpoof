#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PersistenceManager : NSObject

+ (instancetype)shared;

+ (void)loadEarly;

- (BOOL)isSpoofingEnabled;
- (CLLocationCoordinate2D)spoofCoordinate;
- (BOOL)hasStoredCoordinate;

@property (nonatomic, assign) BOOL simulationWasActive;
@property (nonatomic, assign) double altitude;
@property (nonatomic, assign) CLLocationDirection heading;
@property (nonatomic, assign) BOOL fluctuationEnabled;
@property (nonatomic, assign) double fluctuationRadius;
@property (nonatomic, assign) BOOL keepLastSpoof;
@property (nonatomic, assign) BOOL showRealLocation;
@property (nonatomic, assign) BOOL showFloatingButton;
// Route playback preferences.
@property (nonatomic, assign) BOOL smoothMotion;
@property (nonatomic, assign) NSInteger accelerationProfile;
@property (nonatomic, assign) double stopDwell;
@property (nonatomic, assign) BOOL continueInBackground;
// Wander radius for the held location when it came from a saved place with its own
// radius: NAN uses the global setting, 0 turns wandering off, otherwise meters.
@property (nonatomic, assign) double activeRadiusOverride;

- (NSArray<NSDictionary *> *)recentLocations;
- (void)recordRecentCoordinate:(CLLocationCoordinate2D)coordinate name:(nullable NSString *)name;
- (void)clearRecentLocations;
// Replaces the list with entries in the stored format (used by backup restore).
- (void)replaceRecentLocations:(NSArray<NSDictionary *> *)entries;

// The playing route, kept so a relaunch can offer to resume it (#20). Its path (an
// LSRouteArchive dictionary) is written once per route to a file in Application Support, off the
// main thread; the small checkpoint (an LSRouteCheckpoint dictionary) goes to the defaults every
// few seconds. nil removes either.
@property (nonatomic, copy, nullable) NSDictionary *routeCheckpoint;
- (void)storeActiveRoute:(nullable NSDictionary *)archive;
// Waits for pending writes, then reads the file. It can be large, so not on the main thread.
- (nullable NSDictionary *)loadActiveRoute;
- (void)clearActiveRoute;

- (BOOL)setSpoofCoordinate:(CLLocationCoordinate2D)coordinate enabled:(BOOL)enabled;
- (void)clearSpoof;
- (void)clearLastSpoof;

@end

NS_ASSUME_NONNULL_END
