#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface LSOverlayManager : NSObject
+ (void)install;
+ (void)presentMapPicker;
+ (void)presentMapPickerInWindow:(UIWindow *)window;
+ (void)refreshOpeners;
@end
NS_ASSUME_NONNULL_END
