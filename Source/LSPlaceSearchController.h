#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface LSPlaceSearchController : UIViewController
@property (nonatomic) MKCoordinateRegion searchRegion;
@property (nonatomic) CLLocationCoordinate2D initialCoordinate;
@property (nonatomic, copy, nullable) void (^didChoose)(CLLocationCoordinate2D coordinate, NSString *name);
@end
NS_ASSUME_NONNULL_END
