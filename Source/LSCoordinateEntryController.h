#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
NS_ASSUME_NONNULL_BEGIN
@interface LSCoordinateEntryController : UIViewController
@property (nonatomic) CLLocationCoordinate2D initialCoordinate;
@property (nonatomic, copy, nullable) void (^didChoose)(CLLocationCoordinate2D coordinate);
@end
NS_ASSUME_NONNULL_END
