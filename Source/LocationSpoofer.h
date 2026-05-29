#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT CLLocation *LSCreateSpoofedLocation(void);
FOUNDATION_EXPORT BOOL LSIsInternalLocationCreate(void);
FOUNDATION_EXPORT void LSSetHooksBypassed(BOOL bypassed);

@interface LocationSpoofer : NSObject

+ (void)installHooks;

@end

NS_ASSUME_NONNULL_END
