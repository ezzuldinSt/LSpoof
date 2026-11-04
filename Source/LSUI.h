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

// MARK: - Design foundation (shared by every screen)
// Spacing and corner scale. Nested corners should be concentric: inner = outer - inset.
FOUNDATION_EXPORT const CGFloat LSSpaceXS;  // 4
FOUNDATION_EXPORT const CGFloat LSSpaceS;   // 8
FOUNDATION_EXPORT const CGFloat LSSpaceM;   // 12
FOUNDATION_EXPORT const CGFloat LSSpaceL;   // 16
FOUNDATION_EXPORT const CGFloat LSSpaceXL;  // 24
FOUNDATION_EXPORT const CGFloat LSRadiusS;  // 12, fields and small controls
FOUNDATION_EXPORT const CGFloat LSRadiusM;  // 20, cards
FOUNDATION_EXPORT const CGFloat LSRadiusL;  // 28, floating panels and sheets
// YES when the OS offers the system Liquid Glass material (iOS 26 and later).
FOUNDATION_EXPORT BOOL LSLiquidGlassAvailable(void);
// Floating material surface for controls and panels that sit over the map. Uses Liquid
// Glass when available, otherwise a system blur material. Put content in contentView.
FOUNDATION_EXPORT UIVisualEffectView *LSGlassView(CGFloat cornerRadius, BOOL interactive);
// Standard spring (about 0.4 s, no overshoot) and a livelier one for small confirmations.
// Both respect Reduce Motion by running a short cross-fade-length animation instead.
FOUNDATION_EXPORT void LSAnimate(dispatch_block_t animations, dispatch_block_t _Nullable completion);
FOUNDATION_EXPORT void LSAnimateBouncy(dispatch_block_t animations, dispatch_block_t _Nullable completion);
// Scales a control slightly while pressed and springs it back on release.
FOUNDATION_EXPORT void LSAddPressFeedback(UIControl *control);
FOUNDATION_EXPORT void LSHapticImpact(UIImpactFeedbackStyle style);
FOUNDATION_EXPORT void LSHapticError(void);
FOUNDATION_EXPORT BOOL LSReduceTransparency(void);
FOUNDATION_EXPORT BOOL LSIncreaseContrast(void);
FOUNDATION_EXPORT BOOL LSDifferentiateWithoutColor(void);
// Centered zero state: large symbol, title, message and an optional action.
FOUNDATION_EXPORT UIView *LSEmptyState(NSString *symbol, NSString *title, NSString *message, UIButton * _Nullable action);

// Colored dot and label describing the applied session.
@interface LSStatusChip : UIView
- (void)setTitle:(NSString *)title color:(UIColor *)color active:(BOOL)active;
@end
NS_ASSUME_NONNULL_END
