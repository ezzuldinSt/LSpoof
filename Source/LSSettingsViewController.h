#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface LSSettingsViewController : UIViewController
@property (nonatomic, copy, nullable) void (^didSave)(void);
// After a backup restore, with a message to show.
@property (nonatomic, copy, nullable) void (^didRestore)(NSString *message);
@end
NS_ASSUME_NONNULL_END
