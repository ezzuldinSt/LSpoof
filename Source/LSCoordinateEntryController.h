#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
NS_ASSUME_NONNULL_BEGIN
@interface LSCoordinateEntryController : UIViewController
@property (nonatomic) CLLocationCoordinate2D initialCoordinate;
@property (nonatomic, copy, nullable) void (^didChoose)(CLLocationCoordinate2D coordinate);
// Optional alternative to didChoose that also passes the place name the preview showed
// (from a pasted map link or a reverse lookup), or nil. When set it is called instead.
@property (nonatomic, copy, nullable) void (^didChooseNamed)(CLLocationCoordinate2D coordinate, NSString * _Nullable name);
@end
NS_ASSUME_NONNULL_END
