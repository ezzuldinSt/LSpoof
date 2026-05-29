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

- (NSArray<NSDictionary *> *)recentLocations;
- (void)recordRecentCoordinate:(CLLocationCoordinate2D)coordinate name:(nullable NSString *)name;

- (BOOL)setSpoofCoordinate:(CLLocationCoordinate2D)coordinate enabled:(BOOL)enabled;
- (void)clearSpoof;

@end

NS_ASSUME_NONNULL_END
