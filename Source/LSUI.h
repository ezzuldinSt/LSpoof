#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT UIColor *LSAccentColor(void);
FOUNDATION_EXPORT UIColor *LSRouteColor(void);
FOUNDATION_EXPORT UIColor *LSErrorColor(void);
FOUNDATION_EXPORT UIColor *LSSuccessColor(void);
FOUNDATION_EXPORT UIColor *LSWarningColor(void);
FOUNDATION_EXPORT UIColor *LSCardColor(void);
// Takes an LSSessionMode value.
FOUNDATION_EXPORT UIColor *LSSessionColor(NSInteger mode);
FOUNDATION_EXPORT NSString *LSSessionSymbol(NSInteger mode);
FOUNDATION_EXPORT NSString *LSSessionTitle(NSInteger mode);

FOUNDATION_EXPORT UILabel *LSLabel(NSString *text, UIFontTextStyle style);
FOUNDATION_EXPORT UILabel *LSSectionLabel(NSString *text);
FOUNDATION_EXPORT UIFont *LSFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize);
FOUNDATION_EXPORT UIFont *LSMonospacedFont(UIFontTextStyle style);
FOUNDATION_EXPORT UIButton *LSButton(NSString *title, NSString * _Nullable symbol, BOOL prominent);
// Round 44 pt material button for floating map and header controls.
FOUNDATION_EXPORT UIButton *LSIconButton(NSString *symbol, NSString *accessibilityLabel);
// Compact capsule action, optionally selectable.
FOUNDATION_EXPORT UIButton *LSChipButton(NSString *title, NSString * _Nullable symbol);
FOUNDATION_EXPORT void LSSetChipSelected(UIButton *chip, BOOL selected);
// Rounded-square tinted symbol, like the icons in iOS Settings.
FOUNDATION_EXPORT UIView *LSIconBadge(NSString *symbol, UIColor *color, CGFloat size);
FOUNDATION_EXPORT UIView *LSSeparator(void);
FOUNDATION_EXPORT UITextField *LSNumberField(NSString *name);
FOUNDATION_EXPORT UIStackView *LSStack(NSArray<UIView *> *views, CGFloat spacing);
FOUNDATION_EXPORT UIStackView *LSRow(NSArray<UIView *> *views, CGFloat spacing);
FOUNDATION_EXPORT UIView *LSInsetPanel(UIView *content);
FOUNDATION_EXPORT UIView *LSFieldRow(NSString *title, UITextField *field, UILabel *error);
FOUNDATION_EXPORT void LSInstallNumberToolbar(UITextField *field, id target, SEL action);
FOUNDATION_EXPORT void LSAnchorAboveKeyboard(UIView *content, UIView *container);
FOUNDATION_EXPORT void LSSizeTableHeader(UITableView *table, UIView *header);
FOUNDATION_EXPORT void LSAnnounce(NSString *message);
// Transient capsule message near the top of a view; also announced to VoiceOver.
FOUNDATION_EXPORT void LSShowToast(UIView *host, NSString *message, NSString * _Nullable symbol);
FOUNDATION_EXPORT void LSHapticSelection(void);
FOUNDATION_EXPORT void LSHapticSuccess(void);
FOUNDATION_EXPORT void LSHapticWarning(void);
FOUNDATION_EXPORT BOOL LSMapAnimationsEnabled(void);
FOUNDATION_EXPORT NSNumber * _Nullable LSParseDecimal(NSString * _Nullable text, NSLocale *locale);
// Two decimal numbers separated by a comma, semicolon or whitespace, e.g. pasted "37.77, -122.42".
FOUNDATION_EXPORT BOOL LSParseCoordinatePair(NSString * _Nullable text, CLLocationCoordinate2D *coordinate);
FOUNDATION_EXPORT NSString *LSFormatDecimal(double value, NSUInteger fractionDigits);
FOUNDATION_EXPORT NSString *LSCoordinateText(CLLocationCoordinate2D coordinate);
FOUNDATION_EXPORT NSString *LSRelativeDate(NSDate *date);

// Colored dot and label describing the applied session.
@interface LSStatusChip : UIView
- (void)setTitle:(NSString *)title color:(UIColor *)color active:(BOOL)active;
@end
NS_ASSUME_NONNULL_END
