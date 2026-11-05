#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN
// Cartographic palette. Every colour adapts to dark mode and Increase Contrast. The light
// variants keep white text at 4.5:1 or better, so LSFillColor can use them as fills.
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
// Capsule button (a rounded rectangle once Dynamic Type wraps the title). Prominent uses
// Liquid Glass on iOS 26, a filled accent capsule before. Springs slightly when pressed.
// A fixed background cornerRadius set by the caller (e.g. concentric with its panel) is kept.
// The filled style's glow follows the enabled state by itself: never write layer.shadowOpacity.
FOUNDATION_EXPORT UIButton *LSButton(NSString *title, NSString * _Nullable symbol, BOOL prominent);
// Same as button.enabled = enabled; for an LSButton the glow fades with it (never under glass).
FOUNDATION_EXPORT void LSSetButtonEnabled(UIButton *button, BOOL enabled);
// Turns an LSButton's resting glow off (NO) or back to its default (YES); enabling it later
// never brings a disabled glow back. Use this instead of writing layer.shadowOpacity.
FOUNDATION_EXPORT void LSSetButtonGlow(UIButton *button, BOOL glow);
// Round 44 pt glass button for floating map and header controls.
FOUNDATION_EXPORT UIButton *LSIconButton(NSString *symbol, NSString *accessibilityLabel);
// Compact capsule action, optionally selectable.
FOUNDATION_EXPORT UIButton *LSChipButton(NSString *title, NSString * _Nullable symbol);
// Selected chips are filled and bold, and show a checkmark when they have no symbol (or when
// Differentiate Without Color is on) plus an outline ring with Differentiate Without Color or
// Increase Contrast, so selection never relies on colour alone.
// Chip titles stay on one line except at accessibility sizes. LSSetChipOneLine: never wraps
// and never shrinks below its title, for rows that scroll sideways. LSSetChipWraps: always may
// wrap, only for chips whose row sets their width (fill or fill-equally rows).
FOUNDATION_EXPORT void LSSetChipOneLine(UIButton *chip);
FOUNDATION_EXPORT void LSSetChipWraps(UIButton *chip);
FOUNDATION_EXPORT void LSSetChipSelected(UIButton *chip, BOOL selected);
// Symbol colour of an idle (unselected, enabled) chip; nil restores the accent. Selected chips
// show white symbols. An imageColorTransformer the caller sets on the configuration also wins.
FOUNDATION_EXPORT void LSSetChipIconColor(UIButton *chip, UIColor * _Nullable color);
// Rounded-square tinted symbol, like the icons in iOS Settings.
FOUNDATION_EXPORT UIView *LSIconBadge(NSString *symbol, UIColor *color, CGFloat size);
FOUNDATION_EXPORT UIView *LSSeparator(void);
// Owns its border: an accent ring while editing, an error ring while LSSetFieldInvalid(YES) or
// while its LSFieldRow error label is visible, a hairline with Increase Contrast. Callers must
// never write layer.borderWidth or layer.borderColor on an LSNumberField.
FOUNDATION_EXPORT UITextField *LSNumberField(NSString *name);
// Shows or clears the error ring of an LSNumberField. Does nothing for other text fields.
// Turning invalid while the field is being edited also plays a warning tap and a small shake.
FOUNDATION_EXPORT void LSSetFieldInvalid(UITextField *field, BOOL invalid);
// One call for an error: the ring, plus the message appended to the field's accessibility label
// ("Latitude, Enter a latitude from −90 to 90."). nil or empty clears both. The label as it was
// before the first call is kept as the base, so set any custom label before calling this.
FOUNDATION_EXPORT void LSSetFieldError(UITextField *field, NSString * _Nullable message);
FOUNDATION_EXPORT UIStackView *LSStack(NSArray<UIView *> *views, CGFloat spacing);
FOUNDATION_EXPORT UIStackView *LSRow(NSArray<UIView *> *views, CGFloat spacing);
FOUNDATION_EXPORT UIView *LSInsetPanel(UIView *content);
FOUNDATION_EXPORT UIView *LSFieldRow(NSString *title, UITextField *field, UILabel *error);
FOUNDATION_EXPORT void LSInstallNumberToolbar(UITextField *field, id target, SEL action);
FOUNDATION_EXPORT void LSAnchorAboveKeyboard(UIView *content, UIView *container);
FOUNDATION_EXPORT void LSSizeTableHeader(UITableView *table, UIView *header);
// Messages posted in the same run-loop turn are spoken together, queued after current speech.
FOUNDATION_EXPORT void LSAnnounce(NSString *message);
// Transient glass capsule near the top of a view; also announced to VoiceOver.
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
FOUNDATION_EXPORT const CGFloat LSRadiusM;  // 24, cards and inset panels
FOUNDATION_EXPORT const CGFloat LSRadiusL;  // 32, floating panels and sheets
// YES when the OS offers the system Liquid Glass material (iOS 26 and later).
FOUNDATION_EXPORT BOOL LSLiquidGlassAvailable(void);
// Floating material surface for controls and panels that sit over the map. Uses Liquid
// Glass when available, otherwise a system blur material with a hairline edge (stronger with
// Increase Contrast or Reduce Transparency, where the material turns opaque). Put content in
// contentView. It clips, so it cannot cast a shadow: use LSGlassPanel for depth.
FOUNDATION_EXPORT UIVisualEffectView *LSGlassView(CGFloat cornerRadius, BOOL interactive);
// Standard spring (about 0.4 s, no overshoot) and a livelier one for small confirmations.
// Both respect Reduce Motion by running a short cross-fade-length animation instead.
FOUNDATION_EXPORT void LSAnimate(dispatch_block_t animations, dispatch_block_t _Nullable completion);
FOUNDATION_EXPORT void LSAnimateBouncy(dispatch_block_t animations, dispatch_block_t _Nullable completion);
// Scales a control slightly while pressed and springs it back on release. Also warms the
// haptic engine so the action's feedback lands without delay. Built into LSButton,
// LSChipButton and LSIconButton; skipped for buttons that open a menu.
FOUNDATION_EXPORT void LSAddPressFeedback(UIControl *control);
FOUNDATION_EXPORT void LSHapticImpact(UIImpactFeedbackStyle style);
FOUNDATION_EXPORT void LSHapticError(void);
FOUNDATION_EXPORT BOOL LSReduceTransparency(void);
FOUNDATION_EXPORT BOOL LSIncreaseContrast(void);
FOUNDATION_EXPORT BOOL LSDifferentiateWithoutColor(void);
// Centered zero state: symbol in a soft halo, title, message and an optional action.
// Returns a vertical UIStackView.
FOUNDATION_EXPORT UIView *LSEmptyState(NSString *symbol, NSString *title, NSString *message, UIButton * _Nullable action);

// MARK: - Colour helpers
// Accent for text and glyphs on plain, card or glass surfaces (brighter in dark mode).
FOUNDATION_EXPORT UIColor *LSAccentTextColor(void);
// Variant of any palette or system colour that keeps white symbols and text legible when the
// colour is used as a fill (badges, markers, swipe actions, filled buttons) in both appearances.
FOUNDATION_EXPORT UIColor *LSFillColor(UIColor *color);
// Translucent wash of a colour for tinted backgrounds; denser with Increase Contrast.
FOUNDATION_EXPORT UIColor *LSTintWash(UIColor *color);

// MARK: - Typography
// SF Rounded at a text style's size, scaled with Dynamic Type (maximumPointSize 0 = no cap).
FOUNDATION_EXPORT UIFont *LSRoundedFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize);
// SF Rounded with monospaced digits for values that tick (speed, ETA, distance, counts):
// digits keep their width, so the text never jitters while it updates.
FOUNDATION_EXPORT UIFont *LSNumberFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize);
// Display size for the one number that matters on a screen, e.g. LSHeroNumberFont(44, UIFontWeightBold).
// Scales like Large Title up to 1.6x.
FOUNDATION_EXPORT UIFont *LSHeroNumberFont(CGFloat pointSize, UIFontWeight weight);
// "42 km/h" with the unit smaller and secondary. Rebuild it when the value changes.
FOUNDATION_EXPORT NSAttributedString *LSValueText(NSString *value, NSString * _Nullable unit, UIFont *valueFont);

// MARK: - Components
// Plain accent text button with a 44 pt target, e.g. "Undo", "See all", "Clear".
FOUNDATION_EXPORT UIButton *LSTextButton(NSString *title, NSString * _Nullable symbol);
// Section heading with an optional trailing accessory (usually an LSTextButton); the accessory
// moves under the title at accessibility text sizes.
FOUNDATION_EXPORT UIView *LSSectionHeader(NSString *title, UIView * _Nullable accessory);
// Horizontal row that stacks vertically, leading aligned, at accessibility text sizes.
FOUNDATION_EXPORT UIStackView *LSAdaptiveRow(NSArray<UIView *> *views, CGFloat spacing);
// Small capsule label for counts and states ("3 stops", "Live"). Set text as usual.
FOUNDATION_EXPORT UILabel *LSPillLabel(NSString *text, UIColor *color);
// Floating glass panel over the map: soft shadow, LSGlassView inside, content inset on all sides.
FOUNDATION_EXPORT UIView *LSGlassPanel(UIView *content, CGFloat cornerRadius, CGFloat inset);
// Same, as a capsule: glass corners and shadow stay at half the height through layout and
// Dynamic Type, so no custom capsule subclass is needed. Content is inset on all sides.
FOUNDATION_EXPORT UIView *LSGlassCapsule(UIView *content, CGFloat inset);
// Inline first-use hint: tinted symbol, title, message and a close button. Closing collapses
// it (animated) and then calls dismissed, where the caller remembers not to show it again.
FOUNDATION_EXPORT UIView *LSTipView(NSString *symbol, NSString *title, NSString *message, dispatch_block_t _Nullable dismissed);

// MARK: - Toasts
// The glass toast is tinted by its symbol: exclamationmark.* warning, xmark.octagon* error,
// checkmark* success, anything else accent. A new toast replaces the previous one in host.
// Like LSShowToast, but near the bottom so it never covers the header: just above aboveView
// (e.g. the picker footer) when it is given and inside host, else above host's bottom safe area.
FOUNDATION_EXPORT void LSShowToastAbove(UIView *host, UIView * _Nullable aboveView, NSString *message, NSString * _Nullable symbol);
// Bottom toast (placed like LSShowToastAbove) with one action, e.g. Undo. The action has a 44 pt target, is a VoiceOver custom
// action on the message, and VoiceOver moves to the toast. Visible about 5 s, 12 s while
// VoiceOver runs; swipe up or down to dismiss. action runs at most once, on the main thread.
FOUNDATION_EXPORT void LSShowActionToast(UIView *host, UIView * _Nullable aboveView, NSString *message, NSString * _Nullable symbol,
                                         NSString *actionTitle, dispatch_block_t action);
FOUNDATION_EXPORT void LSDismissToast(UIView *host);

// MARK: - Motion
// Shows or hides a view with a fade; arranged subviews of a stack view also collapse smoothly.
// Safe to call repeatedly with the same value. A shown view ends at alpha 1.
FOUNDATION_EXPORT void LSSetHidden(UIView *view, BOOL hidden, BOOL animated);
// Quick spring "pop" that confirms a change on a view (a saved chip, a new value). Skipped with
// Reduce Motion. Overwrites the view's transform.
FOUNDATION_EXPORT void LSBump(UIView *view);

// MARK: - Haptics
// Generators are shared and kept prepared. Call LSHapticPrepare when a gesture begins (pan,
// long press) so the following feedback lands on time; press feedback does this for controls.
FOUNDATION_EXPORT void LSHapticPrepare(void);
// Crisp tap when a pin lands or a marker snaps into place.
FOUNDATION_EXPORT void LSHapticPinDrop(void);
// The confirmation when a spot or route goes live.
FOUNDATION_EXPORT void LSHapticApplied(void);

// Status capsule for the applied session: a symbol (or dot), the title and a soft tint.
// Session titles from LSSessionTitle get their LSSessionSymbol automatically. The text uses
// the label colour; the colour tints the symbol and background. Cheap to call at 4 Hz.
// When it becomes active (or its state changes while active) the symbol pulses twice and then
// rests, so several live indicators never loop together. Wraps to two lines at accessibility
// sizes and offers the Large Content Viewer.
@interface LSStatusChip : UIView
// Pulse for as long as the chip is active instead (a single, primary live indicator). NO by default.
@property (nonatomic) BOOL pulsesContinuously;
- (void)setTitle:(NSString *)title color:(UIColor *)color active:(BOOL)active;
- (void)setTitle:(NSString *)title symbol:(nullable NSString *)symbol color:(UIColor *)color active:(BOOL)active;
// Title, symbol, colour and live pulse for an LSSessionMode value.
- (void)setSessionMode:(NSInteger)mode;
@end
NS_ASSUME_NONNULL_END
