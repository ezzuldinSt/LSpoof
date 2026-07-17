#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSTimeZoneSync : NSObject

+ (void)install;
+ (void)applyFromPersistenceIfNeeded;
+ (void)notifySpoofCoordinateChanged:(CLLocationCoordinate2D)coordinate;
+ (void)clearApplied;
+ (nullable NSTimeZone *)activeSpoofedTimeZone;

@end

NS_ASSUME_NONNULL_END
