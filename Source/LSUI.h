#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT UIColor *LSAccentColor(void);
FOUNDATION_EXPORT UIColor *LSRouteColor(void);
FOUNDATION_EXPORT UIColor *LSErrorColor(void);
FOUNDATION_EXPORT UILabel *LSLabel(NSString *text, UIFontTextStyle style);
FOUNDATION_EXPORT UIButton *LSButton(NSString *title, NSString * _Nullable symbol, BOOL prominent);
FOUNDATION_EXPORT UITextField *LSNumberField(NSString *name);
FOUNDATION_EXPORT UIStackView *LSStack(NSArray<UIView *> *views, CGFloat spacing);
FOUNDATION_EXPORT UIView *LSInsetPanel(UIView *content);
FOUNDATION_EXPORT UIView *LSFieldRow(NSString *title, UITextField *field, UILabel *error);
FOUNDATION_EXPORT void LSInstallNumberToolbar(UITextField *field, id target, SEL action);
FOUNDATION_EXPORT void LSAnchorAboveKeyboard(UIView *content, UIView *container);
FOUNDATION_EXPORT void LSSizeTableHeader(UITableView *table, UIView *header);
FOUNDATION_EXPORT void LSAnnounce(NSString *message);
FOUNDATION_EXPORT BOOL LSMapAnimationsEnabled(void);
FOUNDATION_EXPORT NSNumber * _Nullable LSParseDecimal(NSString * _Nullable text, NSLocale *locale);
FOUNDATION_EXPORT NSString *LSFormatDecimal(double value, NSUInteger fractionDigits);
FOUNDATION_EXPORT NSString *LSCoordinateText(CLLocationCoordinate2D coordinate);
NS_ASSUME_NONNULL_END
