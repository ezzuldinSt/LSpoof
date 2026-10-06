#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface LSSettingsViewController : UIViewController
@property (nonatomic, copy, nullable) void (^didSave)(void);
@end
NS_ASSUME_NONNULL_END
