#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT CLLocation * _Nullable LSCreateSpoofedLocation(void);
FOUNDATION_EXPORT BOOL LSIsInternalLocationCreate(void);
FOUNDATION_EXPORT void LSMarkLibraryLocationManager(CLLocationManager *manager);

@interface LocationSpoofer : NSObject

+ (void)installHooks;

@end

NS_ASSUME_NONNULL_END
