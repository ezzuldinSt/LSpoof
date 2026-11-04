#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

// Sets a start time, an optional turn-off time and a daily repeat for the current
// location or route, and shows or cancels the existing schedule.
@interface LSScheduleViewController : UIViewController
// What would be scheduled, e.g. "Hold “Eiffel Tower”"; nil when there is nothing yet.
@property (nonatomic, copy, nullable) NSString *subject;
// Returns NO when the schedule could not be saved.
@property (nonatomic, copy, nullable) BOOL (^schedule)(NSDate *start, NSDate * _Nullable end, BOOL daily);
@property (nonatomic, copy, nullable) void (^didFinish)(NSString *message);
@end

NS_ASSUME_NONNULL_END
