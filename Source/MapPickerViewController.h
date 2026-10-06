#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MapPickerViewController : UIViewController
// Presentation owner uses this to refresh the opener after a real dismissal.
@property (nonatomic, copy, nullable) void (^didDismiss)(void);

@end

NS_ASSUME_NONNULL_END
