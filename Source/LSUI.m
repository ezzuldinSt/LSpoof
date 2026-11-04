#import "LSUI.h"
#import "SessionController.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

// MARK: - Palette

static UIColor *LSRGB(CGFloat red, CGFloat green, CGFloat blue) { return [UIColor colorWithRed:red green:green blue:blue alpha:1.0]; }
// Appearance x Increase Contrast. Each palette colour is built once; providers are immutable,
// and stable instances let LSStatusChip skip unchanged refreshes.
static UIColor *LSPalette(UIColor *light, UIColor *dark, UIColor *lightHigh, UIColor *darkHigh) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL high = traits.accessibilityContrast == UIAccessibilityContrastHigh;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) return high ? darkHigh : dark;
        return high ? lightHigh : light;
    }];
}
#define LS_PALETTE(...) static UIColor *color; static dispatch_once_t once; \
    dispatch_once(&once, ^{ color = LSPalette(__VA_ARGS__); }); return color

UIColor *LSAccentColor(void) {
    // Ocean ink. Mostly a fill under white text, so one value serves both appearances (5.7:1).
    LS_PALETTE(LSRGB(0.0, 0.388, 0.812), LSRGB(0.0, 0.388, 0.812), LSRGB(0.0, 0.31, 0.68), LSRGB(0.0, 0.31, 0.68));
}
UIColor *LSAccentTextColor(void) {
    LS_PALETTE(LSRGB(0.0, 0.388, 0.812), LSRGB(0.42, 0.69, 1.0), LSRGB(0.0, 0.31, 0.68), LSRGB(0.64, 0.82, 1.0));
}
UIColor *LSRouteColor(void) {
    // Contour teal.
    LS_PALETTE(LSRGB(0.0, 0.467, 0.427), LSRGB(0.392, 0.824, 0.784), LSRGB(0.0, 0.38, 0.345), LSRGB(0.56, 0.92, 0.88));
}
UIColor *LSErrorColor(void) {
    LS_PALETTE(LSRGB(0.706, 0.137, 0.094), LSRGB(1.0, 0.42, 0.38), LSRGB(0.58, 0.07, 0.05), LSRGB(1.0, 0.62, 0.58));
}
UIColor *LSSuccessColor(void) {
    // Park green.
    LS_PALETTE(LSRGB(0.10, 0.53, 0.25), LSRGB(0.30, 0.85, 0.45), LSRGB(0.04, 0.42, 0.18), LSRGB(0.55, 0.94, 0.64));
}
UIColor *LSWarningColor(void) {
    // Trail amber, deep enough in light mode for white text (4.9:1).
    LS_PALETTE(LSRGB(0.68, 0.36, 0.0), LSRGB(1.0, 0.70, 0.25), LSRGB(0.55, 0.28, 0.0), LSRGB(1.0, 0.83, 0.50));
}
UIColor *LSCardColor(void) { return UIColor.secondarySystemGroupedBackgroundColor; }
UIColor *LSFillColor(UIColor *color) {
    // The light variants are the deep ones, so resolving as light keeps white content legible.
    UITraitCollection *light = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithTraitsFromCollections:@[traits, light]]];
    }];
}
static UIColor *LSWash(UIColor *color, CGFloat alpha, CGFloat highContrastAlpha) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL high = traits.accessibilityContrast == UIAccessibilityContrastHigh;
        return [[color resolvedColorWithTraitCollection:traits] colorWithAlphaComponent:high ? highContrastAlpha : alpha];
    }];
}
UIColor *LSTintWash(UIColor *color) { return LSWash(color, 0.16, 0.28); }
// Rim of fallback glass: a light specular edge normally, a firm dark/light line when the
// material is opaque (Reduce Transparency) or Increase Contrast asks for clear boundaries.
static UIColor *LSGlassEdgeColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
            if (traits.accessibilityContrast == UIAccessibilityContrastHigh || UIAccessibilityIsReduceTransparencyEnabled()) {
                return [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:0.35];
            }
            return [UIColor colorWithWhite:1.0 alpha:dark ? 0.16 : 0.6];
        }];
    });
    return color;
}
// Hairline around unselected chips, only with Increase Contrast.
static UIColor *LSChipEdgeColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.accessibilityContrast == UIAccessibilityContrastHigh ? [UIColor.opaqueSeparatorColor resolvedColorWithTraitCollection:traits] : UIColor.clearColor;
        }];
    });
    return color;
}
UIColor *LSSessionColor(NSInteger mode) {
    switch ((LSSessionMode)mode) {
        case LSSessionModeStatic: return LSAccentTextColor();
        case LSSessionModeMoving: return LSSuccessColor();
        case LSSessionModePaused: return LSWarningColor();
        case LSSessionModeOff: break;
    }
    return UIColor.secondaryLabelColor;
}
NSString *LSSessionSymbol(NSInteger mode) {
    switch ((LSSessionMode)mode) {
        case LSSessionModeStatic: return @"mappin.and.ellipse";
        case LSSessionModeMoving: return @"location.north.line.fill";
        case LSSessionModePaused: return @"pause.fill";
        case LSSessionModeOff: break;
    }
    return @"location.slash";
}
NSString *LSSessionTitle(NSInteger mode) {
    switch ((LSSessionMode)mode) {
        case LSSessionModeStatic: return @"Holding location";
        case LSSessionModeMoving: return @"Moving along route";
        case LSSessionModePaused: return @"Route paused";
        case LSSessionModeOff: break;
    }
    return @"Off · real location";
}

// MARK: - Typography

// Fonts made with an explicit weight ignore Bold Text (preferredFont does not), so match it.
static UIFontWeight LSLegibleWeight(UIFontWeight weight) {
    if (!UIAccessibilityIsBoldTextEnabled()) return weight;
    if (weight < UIFontWeightMedium) return UIFontWeightSemibold;
    if (weight < UIFontWeightBold) return UIFontWeightBold;
    return weight < UIFontWeightHeavy ? UIFontWeightHeavy : UIFontWeightBlack;
}
static CGFloat LSStandardPointSize(UIFontTextStyle style) {
    UITraitCollection *standard = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    return [UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:standard].pointSize;
}
static UIFont *LSScaledFont(UIFontTextStyle style, UIFont *font, CGFloat maximumPointSize) {
    UIFontMetrics *metrics = [UIFontMetrics metricsForTextStyle:style];
    return maximumPointSize > 0 ? [metrics scaledFontForFont:font maximumPointSize:maximumPointSize] : [metrics scaledFontForFont:font];
}
static UIFont *LSRoundedSystemFont(CGFloat size, UIFontWeight weight, BOOL monospacedDigits) {
    UIFont *base = [UIFont systemFontOfSize:size weight:LSLegibleWeight(weight)];
    UIFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded] ?: base.fontDescriptor;
    if (monospacedDigits) {
        // kNumberSpacingType (6) / kMonospacedNumbersSelector (0) from CoreText's SFNTLayoutTypes.h.
        descriptor = [descriptor fontDescriptorByAddingAttributes:@{UIFontDescriptorFeatureSettingsAttribute: @[
            @{UIFontFeatureTypeIdentifierKey: @6, UIFontFeatureSelectorIdentifierKey: @0}]}];
    }
    return [UIFont fontWithDescriptor:descriptor size:size];
}
UIFont *LSFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize) {
    UIFont *font = [UIFont systemFontOfSize:LSStandardPointSize(style) weight:LSLegibleWeight(weight)];
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:font maximumPointSize:maximumPointSize];
}
UIFont *LSMonospacedFont(UIFontTextStyle style) {
    UIFont *font = [UIFont monospacedSystemFontOfSize:LSStandardPointSize(style) weight:LSLegibleWeight(UIFontWeightRegular)];
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:font];
}
UIFont *LSRoundedFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize) {
    return LSScaledFont(style, LSRoundedSystemFont(LSStandardPointSize(style), weight, NO), maximumPointSize);
}
UIFont *LSNumberFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize) {
    return LSScaledFont(style, LSRoundedSystemFont(LSStandardPointSize(style), weight, YES), maximumPointSize);
}
UIFont *LSHeroNumberFont(CGFloat pointSize, UIFontWeight weight) {
    return LSScaledFont(UIFontTextStyleLargeTitle, LSRoundedSystemFont(pointSize, weight, YES), pointSize * 1.6);
}
NSAttributedString *LSValueText(NSString *value, NSString *unit, UIFont *valueFont) {
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:value ?: @"" attributes:@{NSFontAttributeName: valueFont}];
    if (unit.length) {
        UIFont *unitFont = LSRoundedSystemFont(MAX(12.0, round(valueFont.pointSize * 0.45)), UIFontWeightSemibold, NO);
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:unit] attributes:@{
            NSFontAttributeName: unitFont, NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    }
    return text;
}
static UIConfigurationTextAttributesTransformer LSFontTransformer(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize) {
    return ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(style, weight, maximumPointSize);
        return result;
    };
}

UILabel *LSLabel(NSString *text, UIFontTextStyle style) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.labelColor;
    label.numberOfLines = 0;
    return label;
}
UILabel *LSSectionLabel(NSString *text) {
    // Sentence case, semibold: reads as a heading without shouting, and grows to 28 pt.
    UILabel *label = LSLabel(text, UIFontTextStyleSubheadline);
    label.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 28);
    label.textColor = UIColor.secondaryLabelColor;
    label.accessibilityTraits = UIAccessibilityTraitHeader;
    return label;
}

// MARK: - Controls

static void LSApplyMinimumSize(UIView *view, CGFloat height, CGFloat width) {
    NSLayoutConstraint *h = [view.heightAnchor constraintGreaterThanOrEqualToConstant:height];
    NSLayoutConstraint *w = [view.widthAnchor constraintGreaterThanOrEqualToConstant:width];
    // Hidden arranged subviews receive required zero-size constraints from UIStackView.
    h.priority = 999; w.priority = 999;
    [NSLayoutConstraint activateConstraints:@[h, w]];
}
static void LSInstallLargeContentViewer(UIView *view) {
    // Capped text and fixed-size controls show the large content viewer at accessibility sizes.
    view.showsLargeContentViewer = YES;
    view.scalesLargeContentImage = YES;
    [view addInteraction:[[UILargeContentViewerInteraction alloc] init]];
}
// iOS 26 adds glass button styles. This SDK predates them, so they are looked up at run time.
static UIButtonConfiguration *LSSystemGlassConfiguration(BOOL prominent) {
    SEL selector = NSSelectorFromString(prominent ? @"prominentGlassButtonConfiguration" : @"glassButtonConfiguration");
    if (![UIButtonConfiguration respondsToSelector:selector]) return nil;
    id configuration = ((id (*)(id, SEL))objc_msgSend)(UIButtonConfiguration.class, selector);
    return [configuration isKindOfClass:UIButtonConfiguration.class] ? configuration : nil;
}

static CGFloat LSEdgeWidth(UITraitCollection *traits) {
    if (traits.accessibilityContrast == UIAccessibilityContrastHigh) return 1.0;
    return 1.0 / (traits.displayScale > 0 ? traits.displayScale : UIScreen.mainScreen.scale);
}

// Keeps a fixed-corner button a capsule at any single-line height, and a concentric rounded
// rectangle once Dynamic Type wraps the title (a tall capsule would crowd the text).
@interface LSPillButton : UIButton
@property (nonatomic) CGFloat lsMaximumCornerRadius;
@property (nonatomic) CGFloat lsAppliedRadius;  // The radius this class last wrote.
@property (nonatomic) BOOL lsCallerRadius;      // A caller set its own radius: keep it.
@property (nonatomic) BOOL lsGlass;
@property (nonatomic) float lsRestingShadowOpacity;
@property (nonatomic) float lsDefaultShadowOpacity;
@end
@implementation LSPillButton
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (size.height <= 0) return;
    UIButtonConfiguration *config = self.configuration;
    BOOL fixed = config.cornerStyle == UIButtonConfigurationCornerStyleFixed;
    CGFloat current = config.background.cornerRadius;
    // A radius this class did not write came from the caller, e.g. a concentric corner inside a
    // floating panel. From then on it is respected and no extra configuration pass runs.
    if (fixed && !self.lsCallerRadius && fabs(current - self.lsAppliedRadius) > 0.5) self.lsCallerRadius = YES;
    CGFloat radius = MIN(size.height / 2, self.lsMaximumCornerRadius);
    if (config.cornerStyle == UIButtonConfigurationCornerStyleCapsule) radius = size.height / 2;
    else if (fixed && self.lsCallerRadius) radius = MIN(current, size.height / 2);
    else if (fixed && fabs(current - radius) > 0.5) {
        UIBackgroundConfiguration *background = config.background;
        background.cornerRadius = radius;
        config.background = background;
        self.lsAppliedRadius = radius;
        self.configuration = config; // Converges: the next pass finds the radius already set.
    }
    // An explicit path keeps the glow cheap and shaped like the button.
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
}
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    // Filled buttons glow only while they can be pressed. Glass draws its own depth, and an
    // accent shadow under it would read as a smudge.
    float target = enabled && !self.lsGlass ? self.lsRestingShadowOpacity : 0;
    if (self.layer.shadowOpacity == target) return;
    if (self.window) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
        fade.fromValue = @(self.layer.shadowOpacity);
        fade.toValue = @(target);
        fade.duration = 0.2;
        [self.layer addAnimation:fade forKey:@"lsShadow"];
    }
    self.layer.shadowOpacity = target;
}
@end
void LSSetButtonEnabled(UIButton *button, BOOL enabled) { button.enabled = enabled; }
void LSSetButtonGlow(UIButton *button, BOOL glow) {
    if (![button isKindOfClass:LSPillButton.class]) return;
    LSPillButton *pill = (LSPillButton *)button;
    pill.lsRestingShadowOpacity = glow ? pill.lsDefaultShadowOpacity : 0;
    pill.layer.shadowOpacity = pill.enabled && !pill.lsGlass ? pill.lsRestingShadowOpacity : 0;
}

// Keeps the fallback rim legible when Increase Contrast is switched while the button is shown.
@interface LSIconControlButton : UIButton
@property (nonatomic) BOOL lsGlass;
@end
@implementation LSIconControlButton
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.lsGlass || previous.accessibilityContrast == self.traitCollection.accessibilityContrast) return;
    UIButtonConfiguration *config = self.configuration;
    UIBackgroundConfiguration *background = config.background;
    background.strokeWidth = LSEdgeWidth(self.traitCollection);
    config.background = background;
    self.configuration = config;
}
@end

UIButton *LSButton(NSString *title, NSString *symbol, BOOL prominent) {
    UIButtonConfiguration *glass = prominent ? LSSystemGlassConfiguration(YES) : nil;
    UIButtonConfiguration *config = glass ?: (prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration);
    config.title = title;
    config.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleMedium];
    config.imagePadding = 8;
    config.baseBackgroundColor = prominent ? LSAccentColor() : LSAccentTextColor();
    config.baseForegroundColor = prominent ? UIColor.whiteColor : LSAccentTextColor();
    // Capsules need a little more side room than rounded rectangles.
    config.contentInsets = prominent ? NSDirectionalEdgeInsetsMake(15, 20, 15, 20) : NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    config.titleLineBreakMode = NSLineBreakByWordWrapping;
    config.titleTextAttributesTransformer = LSFontTransformer(UIFontTextStyleHeadline, UIFontWeightSemibold, 26);
    config.subtitleTextAttributesTransformer = LSFontTransformer(UIFontTextStyleSubheadline, UIFontWeightRegular, 24);
    if (glass) {
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    } else {
        config.cornerStyle = UIButtonConfigurationCornerStyleFixed;
        UIBackgroundConfiguration *background = config.background;
        background.cornerRadius = prominent ? 26 : 22;
        config.background = background;
    }
    LSPillButton *button = [LSPillButton buttonWithType:UIButtonTypeSystem];
    button.lsMaximumCornerRadius = prominent ? 28 : 24;
    button.lsAppliedRadius = glass ? 0 : config.background.cornerRadius;
    button.lsGlass = glass != nil;
    button.lsDefaultShadowOpacity = prominent && !glass ? 0.25 : 0;
    button.lsRestingShadowOpacity = button.lsDefaultShadowOpacity;
    button.configuration = config;
    button.tintColor = LSAccentColor();
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    // No accessibilityLabel: UIButton speaks the configuration title, which callers update.
    // The glow follows the enabled state (see LSPillButton); callers never touch it.
    button.layer.shadowColor = LSAccentColor().CGColor;
    button.layer.shadowOpacity = button.lsRestingShadowOpacity;
    button.layer.shadowRadius = 12;
    button.layer.shadowOffset = CGSizeMake(0, 6);
    LSApplyMinimumSize(button, prominent ? 52 : 44, 44);
    if (!glass) LSAddPressFeedback(button); // Glass has its own interactive response.
    return button;
}
UIButton *LSIconButton(NSString *symbol, NSString *accessibilityLabel) {
    UIButtonConfiguration *glass = LSSystemGlassConfiguration(NO);
    UIButtonConfiguration *config = glass ?: UIButtonConfiguration.plainButtonConfiguration;
    config.image = [UIImage systemImageNamed:symbol];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    config.baseForegroundColor = LSAccentTextColor();
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    if (!glass) {
        UIBackgroundConfiguration *background = UIBackgroundConfiguration.clearConfiguration;
        background.visualEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial];
        background.cornerRadius = 22;
        background.strokeColor = LSGlassEdgeColor();
        // Traits are unknown until the button joins a window; LSIconControlButton follows changes.
        background.strokeWidth = LSIncreaseContrast() ? 1.0 : 1.0 / UIScreen.mainScreen.scale;
        config.background = background;
    }
    LSIconControlButton *button = [LSIconControlButton buttonWithType:UIButtonTypeSystem];
    button.lsGlass = glass != nil;
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = accessibilityLabel;
    button.largeContentTitle = accessibilityLabel;
    LSInstallLargeContentViewer(button);
    if (!glass) {
        button.layer.shadowColor = UIColor.blackColor.CGColor;
        button.layer.shadowOpacity = 0.14;
        button.layer.shadowRadius = 6;
        button.layer.shadowOffset = CGSizeMake(0, 2);
        // Without a path every frame of the live map below needs an offscreen shadow pass.
        button.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 44, 44)].CGPath;
        LSAddPressFeedback(button);
    }
    NSLayoutConstraint *width = [button.widthAnchor constraintEqualToConstant:44];
    NSLayoutConstraint *height = [button.heightAnchor constraintEqualToConstant:44];
    // Below required so a hidden button in a stack view can collapse without a conflict.
    width.priority = 999; height.priority = 999;
    [NSLayoutConstraint activateConstraints:@[width, height]];
    return button;
}

static char ls_chipSelectedKey, ls_chipCheckKey, ls_chipOriginalImageKey, ls_chipIconColorKey, ls_chipShownIconKey;
void LSSetChipIconColor(UIButton *chip, UIColor *color) {
    objc_setAssociatedObject(chip, &ls_chipIconColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [chip setNeedsUpdateConfiguration];
}
static void LSStyleChipBackground(UIButtonConfiguration *config, BOOL selected) {
    UIBackgroundConfiguration *background = config.background;
    if (selected && (LSDifferentiateWithoutColor() || LSIncreaseContrast())) {
        // An outline ring marks selection by shape as well as by fill.
        background.strokeColor = UIColor.labelColor;
        background.strokeWidth = 1.5;
        background.strokeOutset = 2;
    } else {
        background.strokeColor = selected ? nil : LSChipEdgeColor();
        background.strokeWidth = selected ? 0 : 1;
        background.strokeOutset = 0;
    }
    config.background = background;
}
UIButton *LSChipButton(NSString *title, NSString *symbol) {
    UIButtonConfiguration *config = UIButtonConfiguration.grayButtonConfiguration;
    config.title = title;
    config.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleSmall];
    config.imagePadding = 6;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseForegroundColor = UIColor.labelColor;
    // Same fill as a deselected chip, so never-selected and deselected chips match.
    config.baseBackgroundColor = UIColor.tertiarySystemFillColor;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    config.titleLineBreakMode = NSLineBreakByWordWrapping;
    config.titleTextAttributesTransformer = LSFontTransformer(UIFontTextStyleSubheadline, UIFontWeightSemibold, 28);
    LSStyleChipBackground(config, NO);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    // Idle chips tint their symbol (accent, or LSSetChipIconColor), selected ones go white,
    // disabled ones use system dimming.
    button.configurationUpdateHandler = ^(UIButton *chip) {
        UIButtonConfiguration *updated = chip.configuration;
        // Follows title changes made by callers; a configuration title is not currentTitle.
        chip.largeContentTitle = updated.title;
        // A transformer the caller installed wins. Ours returns the exact colour object it last
        // installed, which a caller's transformer cannot.
        UIConfigurationColorTransformer current = updated.imageColorTransformer;
        UIColor *shown = objc_getAssociatedObject(chip, &ls_chipShownIconKey);
        if (current && !(shown && current(UIColor.clearColor) == shown)) return;
        BOOL selected = [objc_getAssociatedObject(chip, &ls_chipSelectedKey) boolValue];
        UIColor *idle = objc_getAssociatedObject(chip, &ls_chipIconColorKey) ?: LSAccentTextColor();
        UIColor *icon = !chip.enabled ? nil : (selected ? UIColor.whiteColor : idle);
        updated.imageColorTransformer = icon ? ^UIColor *(__unused UIColor *color) { return icon; } : nil;
        objc_setAssociatedObject(chip, &ls_chipShownIconKey, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        chip.configuration = updated;
    };
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    // No accessibilityLabel: UIButton speaks the configuration title, which callers update.
    LSInstallLargeContentViewer(button);
    LSApplyMinimumSize(button, 44, 44);
    LSAddPressFeedback(button);
    return button;
}
void LSSetChipSelected(UIButton *chip, BOOL selected) {
    NSNumber *previous = objc_getAssociatedObject(chip, &ls_chipSelectedKey);
    BOOL changed = previous && previous.boolValue != selected;
    objc_setAssociatedObject(chip, &ls_chipSelectedKey, @(selected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIButtonConfiguration *config = chip.configuration;
    config.baseBackgroundColor = selected ? LSAccentColor() : UIColor.tertiarySystemFillColor;
    config.baseForegroundColor = selected ? UIColor.whiteColor : UIColor.labelColor;
    config.titleTextAttributesTransformer = LSFontTransformer(UIFontTextStyleSubheadline, selected ? UIFontWeightBold : UIFontWeightSemibold, 28);
    // A checkmark stands in for a missing symbol (or for any symbol with Differentiate Without
    // Color). The caller's image is restored on deselection unless the caller replaced it.
    UIImage *check = objc_getAssociatedObject(chip, &ls_chipCheckKey);
    BOOL showsCheck = check && config.image == check;
    BOOL wantsCheck = selected && (showsCheck || !config.image || LSDifferentiateWithoutColor());
    if (wantsCheck && !showsCheck) {
        UIImage *mark = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithWeight:UIImageSymbolWeightBold]];
        objc_setAssociatedObject(chip, &ls_chipOriginalImageKey, config.image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(chip, &ls_chipCheckKey, mark, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        config.image = mark;
    } else if (!wantsCheck && check) {
        if (showsCheck) config.image = objc_getAssociatedObject(chip, &ls_chipOriginalImageKey);
        objc_setAssociatedObject(chip, &ls_chipOriginalImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(chip, &ls_chipCheckKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LSStyleChipBackground(config, selected);
    if (changed && chip.window) {
        // Cross-dissolve is not motion, so it also runs with Reduce Motion.
        [UIView transitionWithView:chip duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction animations:^{
            chip.configuration = config;
            [chip updateConfiguration];
        } completion:nil];
    } else {
        chip.configuration = config;
    }
    chip.selected = NO; // Selection is drawn by the configuration, not UIControl state.
    chip.accessibilityTraits = selected ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
}
UIButton *LSTextButton(NSString *title, NSString *symbol) {
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.title = title;
    config.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleMedium];
    config.imagePadding = 4;
    config.baseForegroundColor = LSAccentTextColor();
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
    config.titleTextAttributesTransformer = LSFontTransformer(UIFontTextStyleSubheadline, UIFontWeightSemibold, 30);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    LSApplyMinimumSize(button, 44, 44);
    return button;
}
UIView *LSIconBadge(NSString *symbol, UIColor *color, CGFloat size) {
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = LSFillColor(color);
    badge.layer.cornerRadius = size * 0.28;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.isAccessibilityElement = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    // Hierarchical white gives multi-layer symbols depth without a second colour.
    icon.preferredSymbolConfiguration = [[UIImageSymbolConfiguration configurationWithPointSize:size * 0.48 weight:UIImageSymbolWeightSemibold]
        configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithHierarchicalColor:UIColor.whiteColor]];
    [badge addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:size],
        [badge.heightAnchor constraintEqualToConstant:size],
        [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor]
    ]];
    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return badge;
}
UIView *LSSeparator(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = UIColor.separatorColor;
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return line;
}

// MARK: - Fields

// Owns its border: a focus ring while editing and an error ring while invalid. Callers mark
// errors with LSSetFieldInvalid (or an LSFieldRow error label), never with layer.border.
@interface LSNumberTextField : UITextField
@property (nonatomic) BOOL lsInvalid;     // From LSSetFieldInvalid.
@property (nonatomic) BOOL lsRowInvalid;  // Mirrored from the LSFieldRow error label.
@end
@implementation LSNumberTextField
- (void)ls_updateRing {
    UITraitCollection *traits = self.traitCollection;
    BOOL invalid = self.lsInvalid || self.lsRowInvalid;
    UIColor *ring = invalid ? LSErrorColor() : (self.isFirstResponder ? LSAccentTextColor() : nil);
    BOOL emphasized = ring != nil;
    if (!ring && traits.accessibilityContrast == UIAccessibilityContrastHigh) ring = UIColor.opaqueSeparatorColor;
    CGFloat width = ring ? (emphasized ? 2 : 1) : 0;
    CGColorRef color = [ring resolvedColorWithTraitCollection:traits].CGColor;
    if (self.layer.borderWidth == width && CGColorEqualToColor(self.layer.borderColor, color)) return;
    if (self.window) {
        // A quick cross-fade so the ring arrives rather than flashes.
        CABasicAnimation *fadeColor = [CABasicAnimation animationWithKeyPath:@"borderColor"];
        fadeColor.fromValue = (__bridge id)self.layer.borderColor;
        CABasicAnimation *fadeWidth = [CABasicAnimation animationWithKeyPath:@"borderWidth"];
        fadeWidth.fromValue = @(self.layer.borderWidth);
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[fadeColor, fadeWidth];
        group.duration = 0.15;
        [self.layer addAnimation:group forKey:@"lsRing"];
    }
    self.layer.borderWidth = width;
    self.layer.borderColor = color;
}
- (void)ls_invalidWas:(BOOL)wasInvalid {
    // Turning invalid while being typed into earns a warning tap and a small head-shake, the
    // way a wrong passcode does. Fields the person is not editing change quietly.
    if (!wasInvalid && (self.lsInvalid || self.lsRowInvalid) && self.isFirstResponder) {
        LSHapticWarning();
        if (LSMapAnimationsEnabled()) {
            CAKeyframeAnimation *nudge = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
            nudge.values = @[@0, @(-5), @5, @(-5), @0];
            nudge.additive = YES;
            nudge.duration = 0.3;
            nudge.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self.layer addAnimation:nudge forKey:@"lsNudge"];
        }
    }
    [self ls_updateRing];
}
- (void)setLsInvalid:(BOOL)invalid {
    BOOL was = _lsInvalid || _lsRowInvalid;
    _lsInvalid = invalid;
    [self ls_invalidWas:was];
}
- (void)setLsRowInvalid:(BOOL)invalid {
    BOOL was = _lsInvalid || _lsRowInvalid;
    _lsRowInvalid = invalid;
    [self ls_invalidWas:was];
}
- (BOOL)becomeFirstResponder {
    BOOL result = [super becomeFirstResponder];
    [self ls_updateRing];
    return result;
}
- (BOOL)resignFirstResponder {
    BOOL result = [super resignFirstResponder];
    [self ls_updateRing];
    return result;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self ls_updateRing];
}
@end
void LSSetFieldInvalid(UITextField *field, BOOL invalid) {
    if ([field isKindOfClass:LSNumberTextField.class]) ((LSNumberTextField *)field).lsInvalid = invalid;
}
static char ls_fieldBaseLabelKey;
void LSSetFieldError(UITextField *field, NSString *message) {
    if (!field) return;
    // The label as it was before any error, captured once ("" when there was none).
    NSString *base = objc_getAssociatedObject(field, &ls_fieldBaseLabelKey);
    if (!base) {
        base = field.accessibilityLabel ?: @"";
        objc_setAssociatedObject(field, &ls_fieldBaseLabelKey, base, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    BOOL invalid = message.length > 0;
    if (!invalid) field.accessibilityLabel = base.length ? base : nil;
    else field.accessibilityLabel = base.length ? [NSString stringWithFormat:@"%@, %@", base, message] : message;
    LSSetFieldInvalid(field, invalid);
}

UITextField *LSNumberField(NSString *name) {
    LSNumberTextField *field = [[LSNumberTextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = LSMonospacedFont(UIFontTextStyleBody);
    field.adjustsFontForContentSizeCategory = YES;
    field.backgroundColor = UIColor.tertiarySystemFillColor;
    field.layer.cornerRadius = LSRadiusS;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation; // Includes minus; hardware keyboards also work.
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.accessibilityLabel = name;
    field.placeholder = name;
    UIView *padding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 44)];
    field.leftView = padding;
    field.leftViewMode = UITextFieldViewModeAlways;
    NSLayoutConstraint *height = [field.heightAnchor constraintGreaterThanOrEqualToConstant:50];
    height.priority = 999; height.active = YES;
    return field;
}

// Mirrors its error label onto the field's ring. UIStackView lays out again whenever an
// arranged subview is shown or hidden, so callers keep toggling error.hidden as before.
@interface LSFieldRowView : UIStackView
@property (nonatomic, weak) UITextField *lsField;
@property (nonatomic, weak) UILabel *lsError;
@end
@implementation LSFieldRowView
- (void)layoutSubviews {
    [super layoutSubviews];
    LSNumberTextField *field = (LSNumberTextField *)self.lsField;
    UILabel *error = self.lsError;
    if (error && [field isKindOfClass:LSNumberTextField.class] && field.lsRowInvalid == error.hidden) field.lsRowInvalid = !error.hidden;
}
@end

UIStackView *LSStack(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = spacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}
UIStackView *LSRow(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *stack = LSStack(views, spacing);
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    return stack;
}

@interface LSAdaptiveStackView : UIStackView
@property (nonatomic) UIStackViewAlignment lsRowAlignment;
@property (nonatomic) BOOL lsStacked;
@end
@implementation LSAdaptiveStackView
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    BOOL stacked = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    if (stacked == self.lsStacked) return;
    self.lsStacked = stacked;
    if (stacked) {
        self.lsRowAlignment = self.alignment; // Whatever the caller chose for the row.
        self.axis = UILayoutConstraintAxisVertical;
        self.alignment = UIStackViewAlignmentLeading;
    } else {
        self.axis = UILayoutConstraintAxisHorizontal;
        self.alignment = self.lsRowAlignment;
    }
}
@end
UIStackView *LSAdaptiveRow(NSArray<UIView *> *views, CGFloat spacing) {
    LSAdaptiveStackView *row = [[LSAdaptiveStackView alloc] initWithArrangedSubviews:views];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = spacing;
    return row;
}
UIView *LSSectionHeader(NSString *title, UIView *accessory) {
    UILabel *label = LSSectionLabel(title);
    if (!accessory) return label;
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [accessory setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [accessory setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return LSAdaptiveRow(@[label, accessory], LSSpaceS);
}

// MARK: - Surfaces

@interface LSPanelView : UIView
@end
@implementation LSPanelView
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // Cards differ from the grouped background by about 1.1:1 in light mode; draw an edge
    // when Increase Contrast asks for clear boundaries.
    BOOL high = self.traitCollection.accessibilityContrast == UIAccessibilityContrastHigh;
    self.layer.borderWidth = high ? 1 : 0;
    self.layer.borderColor = high ? [UIColor.opaqueSeparatorColor resolvedColorWithTraitCollection:self.traitCollection].CGColor : nil;
}
@end
UIView *LSInsetPanel(UIView *content) {
    LSPanelView *panel = [[LSPanelView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = LSCardColor();
    panel.layer.cornerRadius = LSRadiusM;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:content];
    NSLayoutConstraint *bottom = [content.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-16];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:panel.topAnchor constant:16],
        [content.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        bottom
    ]];
    return panel;
}
UIView *LSFieldRow(NSString *title, UITextField *field, UILabel *error) {
    UILabel *label = LSLabel(title, UIFontTextStyleSubheadline);
    label.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightMedium, 28);
    label.textColor = UIColor.secondaryLabelColor;
    error.textColor = LSErrorColor();
    error.hidden = YES;
    LSFieldRowView *row = [[LSFieldRowView alloc] initWithArrangedSubviews:@[label, field, error]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 6;
    row.lsField = field;
    row.lsError = error;
    return row;
}
void LSInstallNumberToolbar(UITextField *field, id target, SEL action) {
    UIToolbar *toolbar = [[UIToolbar alloc] init];
    [toolbar sizeToFit];
    toolbar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
                      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:target action:action]];
    field.inputAccessoryView = toolbar;
}
void LSAnchorAboveKeyboard(UIView *content, UIView *container) {
    UIKeyboardLayoutGuide *guide = container.keyboardLayoutGuide;
    // Keep a bottom constraint active from the very first layout, including when
    // no keyboard has appeared. Edge-tracked constraints alone leave that layout
    // underdetermined on some iOS versions (a scroll view can have zero height).
    // Docked keyboards resize the viewport; a floating keyboard leaves it usable.
    guide.followsUndockedKeyboard = NO;
    [content.bottomAnchor constraintEqualToAnchor:guide.topAnchor].active = YES;
}
void LSSizeTableHeader(UITableView *table, UIView *header) {
    CGFloat width = table.bounds.size.width;
    if (width <= 0) return;
    // UITableView positions its header using a frame. Disabling autoresizing on
    // that outer view lets its labels' intrinsic width override the table width.
    // Its children still use Auto Layout, so constrain the width before measuring
    // the multiline height, and repeat whenever text or the table width changes.
    header.translatesAutoresizingMaskIntoConstraints = YES;
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    CGRect frame = header.frame;
    frame.size.width = width;
    header.frame = frame;
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                      withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = ceil(size.height);
    if (fabs(table.tableHeaderView.frame.size.height - height) > 0.5 || table.tableHeaderView != header) {
        header.frame = CGRectMake(0, 0, width, height);
        table.tableHeaderView = header;
    }
}

// MARK: - Announcements

static NSMutableArray<NSString *> *ls_pendingAnnouncements;
static void LSFlushAnnouncements(void) {
    NSArray<NSString *> *messages = ls_pendingAnnouncements;
    ls_pendingAnnouncements = nil;
    NSCharacterSet *terminators = [NSCharacterSet characterSetWithCharactersInString:@".!?…"];
    NSMutableArray<NSString *> *sentences = [NSMutableArray array];
    for (NSString *message in messages) {
        NSString *trimmed = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!trimmed.length) continue;
        BOOL terminated = [terminators characterIsMember:[trimmed characterAtIndex:trimmed.length - 1]];
        [sentences addObject:terminated ? trimmed : [trimmed stringByAppendingString:@"."]];
    }
    if (!sentences.count) return;
    NSAttributedString *speech = [[NSAttributedString alloc] initWithString:[sentences componentsJoinedByString:@" "]
                                                                 attributes:@{UIAccessibilitySpeechAttributeQueueAnnouncement: @YES}];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, speech);
}
void LSAnnounce(NSString *message) {
    if (!message.length) return;
    if (!NSThread.isMainThread) {
        NSString *copy = [message copy];
        dispatch_async(dispatch_get_main_queue(), ^{ LSAnnounce(copy); });
        return;
    }
    // A toast and its caller often announce the same words a moment apart.
    static NSString *lastMessage;
    static CFTimeInterval lastTime;
    CFTimeInterval now = CACurrentMediaTime();
    if ([message isEqualToString:lastMessage] && now - lastTime < 1.0) return;
    lastMessage = [message copy];
    lastTime = now;
    // Separate posts in one turn (status change, toast, route feedback) cut each other off;
    // speak them as one queued announcement instead.
    if (!ls_pendingAnnouncements) {
        ls_pendingAnnouncements = [NSMutableArray array];
        dispatch_async(dispatch_get_main_queue(), ^{ LSFlushAnnouncements(); });
    }
    [ls_pendingAnnouncements addObject:lastMessage];
}
BOOL LSMapAnimationsEnabled(void) { return !UIAccessibilityIsReduceMotionEnabled(); }

// MARK: - Haptics

// Shared, prepared generators: a fresh generator per call has to spin up the Taptic Engine,
// which delays the tap by a frame or two.
static UISelectionFeedbackGenerator *LSSelectionGenerator(void) {
    static UISelectionFeedbackGenerator *generator;
    if (!generator) generator = [[UISelectionFeedbackGenerator alloc] init];
    return generator;
}
static UINotificationFeedbackGenerator *LSNotificationGenerator(void) {
    static UINotificationFeedbackGenerator *generator;
    if (!generator) generator = [[UINotificationFeedbackGenerator alloc] init];
    return generator;
}
static UIImpactFeedbackGenerator *LSImpactGenerator(UIImpactFeedbackStyle style) {
    static UIImpactFeedbackGenerator *generators[5];
    NSInteger index = style >= UIImpactFeedbackStyleLight && style <= UIImpactFeedbackStyleRigid ? style : UIImpactFeedbackStyleMedium;
    if (!generators[index]) generators[index] = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyle)index];
    return generators[index];
}
static void LSNotify(UINotificationFeedbackType type) {
    UINotificationFeedbackGenerator *generator = LSNotificationGenerator();
    [generator notificationOccurred:type];
    [generator prepare];
}
void LSHapticSelection(void) {
    UISelectionFeedbackGenerator *generator = LSSelectionGenerator();
    [generator selectionChanged];
    [generator prepare]; // Ready for the next detent of a quick run.
}
void LSHapticSuccess(void) { LSNotify(UINotificationFeedbackTypeSuccess); }
void LSHapticWarning(void) { LSNotify(UINotificationFeedbackTypeWarning); }
void LSHapticError(void) { LSNotify(UINotificationFeedbackTypeError); }
void LSHapticImpact(UIImpactFeedbackStyle style) {
    UIImpactFeedbackGenerator *generator = LSImpactGenerator(style);
    [generator impactOccurred];
    [generator prepare];
}
void LSHapticPrepare(void) {
    [LSSelectionGenerator() prepare];
    [LSNotificationGenerator() prepare];
    [LSImpactGenerator(UIImpactFeedbackStyleLight) prepare];
}
void LSHapticPinDrop(void) {
    UIImpactFeedbackGenerator *generator = LSImpactGenerator(UIImpactFeedbackStyleRigid);
    [generator impactOccurredWithIntensity:0.8];
    [generator prepare];
}
void LSHapticApplied(void) { LSNotify(UINotificationFeedbackTypeSuccess); }

// MARK: - Design foundation
const CGFloat LSSpaceXS = 4, LSSpaceS = 8, LSSpaceM = 12, LSSpaceL = 16, LSSpaceXL = 24;
const CGFloat LSRadiusS = 12, LSRadiusM = 24, LSRadiusL = 32;

BOOL LSReduceTransparency(void) { return UIAccessibilityIsReduceTransparencyEnabled(); }
BOOL LSIncreaseContrast(void) { return UIAccessibilityDarkerSystemColorsEnabled(); }
BOOL LSDifferentiateWithoutColor(void) { return UIAccessibilityShouldDifferentiateWithoutColor(); }
BOOL LSLiquidGlassAvailable(void) { return NSClassFromString(@"UIGlassEffect") != Nil; }

// The regular material keeps text on floating panels legible over busy map imagery.
static UIBlurEffectStyle LSFallbackMaterial(BOOL highContrast) {
    return highContrast ? UIBlurEffectStyleSystemThickMaterial : UIBlurEffectStyleSystemMaterial;
}
// Both system glass and blur materials already turn opaque under Reduce Transparency; the
// fallback adds a rim so the edge stays visible over the map, firmer when the material is opaque.
@interface LSGlassEffectView : UIVisualEffectView
@property (nonatomic) BOOL lsDrawsEdge;
@end
@implementation LSGlassEffectView
- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    self = [super initWithEffect:effect];
    if (self) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ls_transparencyChanged:)
                                                   name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    }
    return self;
}
- (void)ls_transparencyChanged:(NSNotification *)note {
    (void)note;
    [self ls_updateEdge];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // The fallback material thickens with Increase Contrast, also when it changes on screen.
    UIAccessibilityContrast contrast = self.traitCollection.accessibilityContrast;
    if (self.lsDrawsEdge && previous.accessibilityContrast != contrast && contrast != UIAccessibilityContrastUnspecified) {
        self.effect = [UIBlurEffect effectWithStyle:LSFallbackMaterial(contrast == UIAccessibilityContrastHigh)];
    }
    [self ls_updateEdge];
}
- (void)ls_updateEdge {
    if (!self.lsDrawsEdge) {
        self.layer.borderWidth = 0;
        return;
    }
    UITraitCollection *traits = self.traitCollection;
    BOOL firm = traits.accessibilityContrast == UIAccessibilityContrastHigh || UIAccessibilityIsReduceTransparencyEnabled();
    CGFloat scale = traits.displayScale > 0 ? traits.displayScale : UIScreen.mainScreen.scale;
    self.layer.borderWidth = firm ? 1.0 : 1.0 / scale;
    self.layer.borderColor = [LSGlassEdgeColor() resolvedColorWithTraitCollection:traits].CGColor;
}
@end

UIVisualEffectView *LSGlassView(CGFloat cornerRadius, BOOL interactive) {
    UIVisualEffect *effect = nil;
    // UIGlassEffect is newer than the SDK this builds with, so it is looked up at run time.
    Class glass = NSClassFromString(@"UIGlassEffect");
    if (glass && [glass isSubclassOfClass:UIVisualEffect.class]) {
        effect = [[glass alloc] init];
        if (interactive) {
            @try { [effect setValue:@YES forKey:@"interactive"]; } @catch (__unused NSException *e) {}
        }
    }
    BOOL systemGlass = effect != nil;
    if (!effect) effect = [UIBlurEffect effectWithStyle:LSFallbackMaterial(LSIncreaseContrast())];
    LSGlassEffectView *view = [[LSGlassEffectView alloc] initWithEffect:effect];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.layer.cornerRadius = cornerRadius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
    view.lsDrawsEdge = !systemGlass;
    [view ls_updateEdge];
    return view;
}

// Shadow host for a clipped glass view: the shadow lives outside the clip. A capsule keeps
// glass and shadow at half its height, so it stays round as Dynamic Type grows the content.
@interface LSFloatingPanelView : UIView
@property (nonatomic) CGFloat lsCornerRadius;
@property (nonatomic) BOOL lsCapsule;
@property (nonatomic, weak) UIView *lsGlass;
@end
@implementation LSFloatingPanelView
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat half = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
    CGFloat radius = self.lsCapsule ? half : MIN(self.lsCornerRadius, half);
    UIView *glass = self.lsGlass;
    if (self.lsCapsule && fabs(glass.layer.cornerRadius - radius) > 0.25) glass.layer.cornerRadius = radius;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
}
@end
static UIView *LSFloatingGlass(UIView *content, CGFloat cornerRadius, CGFloat inset, BOOL capsule) {
    LSFloatingPanelView *panel = [[LSFloatingPanelView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.lsCornerRadius = cornerRadius;
    panel.lsCapsule = capsule;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = LSLiquidGlassAvailable() ? 0.08 : 0.14; // Liquid Glass draws its own depth.
    panel.layer.shadowRadius = 18;
    panel.layer.shadowOffset = CGSizeMake(0, 8);
    UIVisualEffectView *glass = LSGlassView(cornerRadius, NO);
    panel.lsGlass = glass;
    [panel addSubview:glass];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [glass.contentView addSubview:content];
    NSLayoutConstraint *bottom = [content.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-inset];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [glass.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [glass.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [content.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:inset],
        [content.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:inset],
        [content.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-inset],
        bottom
    ]];
    return panel;
}
UIView *LSGlassPanel(UIView *content, CGFloat cornerRadius, CGFloat inset) { return LSFloatingGlass(content, cornerRadius, inset, NO); }
UIView *LSGlassCapsule(UIView *content, CGFloat inset) { return LSFloatingGlass(content, 0, inset, YES); }

@interface LSPillLabelView : UILabel
@end
@implementation LSPillLabelView
static const UIEdgeInsets kLSPillInsets = {3, 9, 3, 9};
- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)numberOfLines {
    CGRect text = [super textRectForBounds:UIEdgeInsetsInsetRect(bounds, kLSPillInsets) limitedToNumberOfLines:numberOfLines];
    return UIEdgeInsetsInsetRect(text, UIEdgeInsetsMake(-kLSPillInsets.top, -kLSPillInsets.left, -kLSPillInsets.bottom, -kLSPillInsets.right));
}
- (void)drawTextInRect:(CGRect)rect { [super drawTextInRect:UIEdgeInsetsInsetRect(rect, kLSPillInsets)]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
}
@end
UILabel *LSPillLabel(NSString *text, UIColor *color) {
    LSPillLabelView *pill = [[LSPillLabelView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.text = text;
    pill.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 24);
    pill.adjustsFontForContentSizeCategory = YES;
    pill.textColor = color;
    pill.backgroundColor = LSTintWash(color);
    pill.textAlignment = NSTextAlignmentCenter;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    [pill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [pill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return pill;
}

// MARK: - Motion

static void LSRunSpring(NSTimeInterval duration, CGFloat damping, CGFloat velocity, dispatch_block_t animations, dispatch_block_t completion) {
    if (!animations) return;
    BOOL motion = LSMapAnimationsEnabled();
    [UIView animateWithDuration:motion ? duration : 0.2 delay:0
         usingSpringWithDamping:motion ? damping : 1.0 initialSpringVelocity:motion ? velocity : 0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:animations
                     completion:^(__unused BOOL finished) { if (completion) completion(); }];
}
void LSAnimate(dispatch_block_t animations, dispatch_block_t completion) { LSRunSpring(0.42, 0.88, 0.2, animations, completion); }
void LSAnimateBouncy(dispatch_block_t animations, dispatch_block_t completion) { LSRunSpring(0.5, 0.68, 0.6, animations, completion); }

void LSBump(UIView *view) {
    if (!view.window || !LSMapAnimationsEnabled()) return;
    [UIView animateWithDuration:0.11 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ view.transform = CGAffineTransformMakeScale(1.08, 1.08); }
                     completion:^(__unused BOOL finished) { LSAnimateBouncy(^{ view.transform = CGAffineTransformIdentity; }, nil); }];
}

// Identifies the latest LSSetHidden call on a view, so an older completion cannot undo it.
@interface LSVisibilityChange : NSObject
@property (nonatomic) BOOL hidden;
@end
@implementation LSVisibilityChange
@end
static char ls_visibilityKey;
void LSSetHidden(UIView *view, BOOL hidden, BOOL animated) {
    if (!view) return;
    LSVisibilityChange *pending = objc_getAssociatedObject(view, &ls_visibilityKey);
    // Setting hidden to its current value on a stack view's arranged subview inside an
    // animation miscounts in UIKit and can leave it stuck, so only real changes go through.
    if ((pending ? pending.hidden : view.hidden) == hidden) return;
    UIStackView *stack = [view.superview isKindOfClass:UIStackView.class] ? (UIStackView *)view.superview : nil;
    BOOL arranged = [stack.arrangedSubviews containsObject:view];
    if (!animated || !view.window) {
        objc_setAssociatedObject(view, &ls_visibilityKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = hidden;
        if (!hidden && view.alpha < 0.01) view.alpha = 1;
        return;
    }
    LSVisibilityChange *change = [[LSVisibilityChange alloc] init];
    change.hidden = hidden;
    objc_setAssociatedObject(view, &ls_visibilityKey, change, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Lay out from the nearest scroll view (or the view controller's view) down: the stack and
    // every content-sized panel around it resize in one animation, while unrelated layout
    // elsewhere in the window is not swept into it. The stack alone left its panel jumping.
    UIView *root = stack ?: view;
    while (root.superview && ![root isKindOfClass:UIScrollView.class] && ![root.nextResponder isKindOfClass:UIViewController.class] &&
           ![root.superview isKindOfClass:UIWindow.class]) root = root.superview;
    dispatch_block_t finish = ^{
        if (objc_getAssociatedObject(view, &ls_visibilityKey) != change) return;
        objc_setAssociatedObject(view, &ls_visibilityKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (hidden) {
            view.hidden = YES;
            view.alpha = 1; // Hidden views keep alpha 1, so a plain hidden = NO later still shows them.
        }
    };
    if (hidden) {
        LSAnimate(^{
            view.alpha = 0;
            if (arranged) {
                view.hidden = YES;
                [root layoutIfNeeded];
            }
        }, finish);
    } else {
        if (view.hidden) view.alpha = 0;
        if (!arranged) view.hidden = NO;
        LSAnimate(^{
            if (arranged) {
                view.hidden = NO;
                [root layoutIfNeeded];
            }
            view.alpha = 1;
        }, finish);
    }
}

@interface LSPressFeedback : NSObject @end
@implementation LSPressFeedback
+ (void)down:(UIControl *)control {
    LSHapticPrepare();
    if (!LSMapAnimationsEnabled()) return;
    // A menu takes over the touch, and the release may never arrive to undo the scale.
    if ([control isKindOfClass:UIButton.class] && ((UIButton *)control).showsMenuAsPrimaryAction) return;
    // About 10 pt of travel: full-width buttons barely shrink, small ones up to 6%.
    CGSize size = control.bounds.size;
    CGFloat shrink = MIN(0.06, 10.0 / MAX(MAX(size.width, size.height), 1.0));
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                     animations:^{ control.transform = CGAffineTransformMakeScale(1 - shrink, 1 - shrink); } completion:nil];
}
+ (void)up:(UIControl *)control {
    if (CGAffineTransformIsIdentity(control.transform)) return;
    LSAnimateBouncy(^{ control.transform = CGAffineTransformIdentity; }, nil);
}
@end
void LSAddPressFeedback(UIControl *control) {
    [control addTarget:LSPressFeedback.class action:@selector(down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [control addTarget:LSPressFeedback.class action:@selector(up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
}

// MARK: - Toasts

static char ls_toastKey;
@interface LSToastView : UIView
@property (nonatomic, strong) UIVisualEffectView *lsGlass;
@property (nonatomic, copy, nullable) dispatch_block_t lsAction;
@property (nonatomic) BOOL lsFromBottom;
@property (nonatomic) BOOL lsDismissing;
@property (nonatomic, strong, nullable) CAShapeLayer *lsCountdown; // Action toasts: time left.
@property (nonatomic, strong, nullable) UIColor *lsTint;
@end
static void LSHideToast(LSToastView *toast, BOOL quick);
@implementation LSToastView
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    CGFloat radius = MIN(size.height / 2, 26);
    self.lsGlass.layer.cornerRadius = radius;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
    CAShapeLayer *countdown = self.lsCountdown;
    if (countdown) {
        // Along the straight run of the bottom edge, clear of the rounded ends.
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(radius, size.height - 1)];
        [line addLineToPoint:CGPointMake(MAX(radius, size.width - radius), size.height - 1)];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        countdown.frame = self.bounds;
        countdown.path = line.CGPath;
        [CATransaction commit];
    }
}
- (void)ls_updateCountdownColor {
    CAShapeLayer *countdown = self.lsCountdown;
    if (!countdown || !self.lsTint) return;
    UIColor *color = [self.lsTint resolvedColorWithTraitCollection:self.traitCollection];
    if (!LSIncreaseContrast()) color = [color colorWithAlphaComponent:0.55];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    countdown.strokeColor = color.CGColor;
    [CATransaction commit];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self ls_updateCountdownColor];
}
- (void)ls_swiped:(UISwipeGestureRecognizer *)gesture {
    (void)gesture;
    LSHideToast(self, NO);
}
- (void)ls_performAction {
    dispatch_block_t action = self.lsAction;
    self.lsAction = nil; // At most once, even if VoiceOver and a tap race.
    LSHideToast(self, NO);
    if (action) {
        LSHapticImpact(UIImpactFeedbackStyleLight);
        action();
    }
}
@end

static void LSHideToast(LSToastView *toast, BOOL quick) {
    if (!toast || toast.lsDismissing) return;
    toast.lsDismissing = YES;
    toast.lsAction = nil;
    toast.userInteractionEnabled = NO;
    UIView *host = toast.superview;
    if (host && objc_getAssociatedObject(host, &ls_toastKey) == toast) objc_setAssociatedObject(host, &ls_toastKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL accessible = !toast.accessibilityElementsHidden;
    BOOL motion = LSMapAnimationsEnabled();
    CGFloat drift = toast.lsFromBottom ? 12 : -12;
    __weak UIView *weakHost = host;
    [UIView animateWithDuration:quick ? 0.15 : 0.28 delay:0 options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState animations:^{
        toast.alpha = 0;
        if (motion) toast.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, drift), 0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        [toast removeFromSuperview];
        // VoiceOver may have been on the toast; let it settle on what is left, unless a newer
        // toast has just taken focus.
        UIView *strongHost = weakHost;
        if (accessible && !(strongHost && objc_getAssociatedObject(strongHost, &ls_toastKey))) {
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
        }
    }];
}
static UIColor *LSToastTint(NSString *symbol) {
    if ([symbol hasPrefix:@"exclamationmark"]) return LSWarningColor();
    if ([symbol hasPrefix:@"xmark.octagon"]) return LSErrorColor();
    if ([symbol hasPrefix:@"checkmark"]) return LSSuccessColor();
    return LSAccentTextColor();
}
static void LSPresentToast(UIView *host, BOOL bottom, UIView *aboveView, NSString *message, NSString *symbol, NSString *actionTitle, dispatch_block_t action) {
    BOOL hasAction = actionTitle.length > 0 && action != nil;
    if (!hasAction) LSAnnounce(message); // An action toast takes VoiceOver focus instead.
    if (!host || !message.length) return;
    LSHideToast(objc_getAssociatedObject(host, &ls_toastKey), YES);
    BOOL above = bottom && aboveView && aboveView != host && [aboveView isDescendantOfView:host];

    LSToastView *toast = [[LSToastView alloc] init];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.lsFromBottom = bottom;
    toast.lsAction = hasAction ? action : nil;
    toast.layer.shadowColor = UIColor.blackColor.CGColor;
    toast.layer.shadowOpacity = LSLiquidGlassAvailable() ? 0.10 : 0.18;
    toast.layer.shadowRadius = 16;
    toast.layer.shadowOffset = CGSizeMake(0, 6);
    UIVisualEffectView *glass = LSGlassView(22, NO);
    toast.lsGlass = glass;
    [toast addSubview:glass];

    NSString *name = symbol ?: @"info.circle.fill";
    UIColor *tint = LSToastTint(name);
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name]];
    icon.tintColor = tint;
    icon.preferredSymbolConfiguration = [[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleLarge]
        configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithHierarchicalColor:tint]];
    icon.isAccessibilityElement = NO;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [icon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *label = LSLabel(message, UIFontTextStyleSubheadline);
    label.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 28);
    UIStackView *messageRow = LSRow(@[icon, label], 10);
    [messageRow setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    NSMutableArray<UIView *> *parts = [NSMutableArray arrayWithObject:messageRow];
    if (hasAction) {
        UIButton *button = LSTextButton(actionTitle, nil);
        [button addTarget:toast action:@selector(ls_performAction) forControlEvents:UIControlEventTouchUpInside];
        [parts addObject:button];
    }
    UIStackView *content = LSAdaptiveRow(parts, LSSpaceS);
    [glass.contentView addSubview:content];
    [host addSubview:toast];
    CGFloat vertical = hasAction ? 6 : 11;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [glass.topAnchor constraintEqualToAnchor:toast.topAnchor],
        [glass.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor],
        [content.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:vertical],
        [content.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-vertical],
        [content.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:hasAction ? -8 : -18],
        [toast.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor constant:-32],
        [toast.widthAnchor constraintLessThanOrEqualToConstant:560]
    ]];
    if (above) [constraints addObject:[toast.bottomAnchor constraintEqualToAnchor:aboveView.topAnchor constant:-12]];
    else if (bottom) [constraints addObject:[toast.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-12]];
    else [constraints addObject:[toast.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:8]];
    [NSLayoutConstraint activateConstraints:constraints];
    objc_setAssociatedObject(host, &ls_toastKey, toast, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak LSToastView *weakToast = toast;
    if (hasAction) {
        // A hairline that runs out with the time left to act; it stays full under Reduce Motion.
        CAShapeLayer *countdown = [CAShapeLayer layer];
        countdown.lineWidth = 2;
        countdown.lineCap = kCALineCapRound;
        countdown.fillColor = nil;
        [glass.contentView.layer addSublayer:countdown];
        toast.lsCountdown = countdown;
        toast.lsTint = tint;
        [toast ls_updateCountdownColor];
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:toast action:@selector(ls_swiped:)];
        swipe.direction = UISwipeGestureRecognizerDirectionUp | UISwipeGestureRecognizerDirectionDown;
        [toast addGestureRecognizer:swipe];
        label.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc] initWithName:actionTitle actionHandler:^BOOL(__unused UIAccessibilityCustomAction *customAction) {
            [weakToast ls_performAction];
            return YES;
        }]];
        __weak UILabel *weakLabel = label;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakLabel) UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, weakLabel);
        });
    } else {
        // Passes touches through to the controls underneath, and was already announced.
        toast.userInteractionEnabled = NO;
        toast.accessibilityElementsHidden = YES;
    }

    BOOL motion = LSMapAnimationsEnabled();
    toast.alpha = 0;
    if (motion) toast.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, bottom ? 20 : -20), 0.9, 0.9);
    [UIView animateWithDuration:motion ? 0.5 : 0.2 delay:0 usingSpringWithDamping:motion ? 0.72 : 1.0 initialSpringVelocity:motion ? 0.5 : 0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        toast.alpha = 1;
        toast.transform = CGAffineTransformIdentity;
    } completion:nil];

    NSTimeInterval visible = MIN(6.0, 2.2 + message.length / 40.0);
    if (hasAction) visible = UIAccessibilityIsVoiceOverRunning() ? 12.0 : MAX(visible, 5.0);
    CAShapeLayer *countdown = toast.lsCountdown;
    if (countdown && motion) {
        CABasicAnimation *drain = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        drain.fromValue = @1;
        drain.toValue = @0;
        drain.duration = visible;
        drain.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        drain.removedOnCompletion = NO; // Survives a trip to the background.
        drain.fillMode = kCAFillModeForwards;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        countdown.strokeEnd = 0;
        [CATransaction commit];
        [countdown addAnimation:drain forKey:@"lsCountdown"];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(visible * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ LSHideToast(weakToast, NO); });
}
void LSShowToast(UIView *host, NSString *message, NSString *symbol) { LSPresentToast(host, NO, nil, message, symbol, nil, nil); }
void LSShowToastAbove(UIView *host, UIView *aboveView, NSString *message, NSString *symbol) {
    LSPresentToast(host, YES, aboveView, message, symbol, nil, nil);
}
void LSShowActionToast(UIView *host, UIView *aboveView, NSString *message, NSString *symbol, NSString *actionTitle, dispatch_block_t action) {
    LSPresentToast(host, YES, aboveView, message, symbol, actionTitle, action);
}
void LSDismissToast(UIView *host) {
    if (host) LSHideToast(objc_getAssociatedObject(host, &ls_toastKey), NO);
}

// MARK: - Parsing and formatting

// Building a number formatter is costly and these run several times per playback tick, so
// configured formatters are cached (they are safe to use from any thread once configured).
// A locale change in Settings empties the cache.
static os_unfair_lock ls_formatterLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<id, NSNumberFormatter *> *ls_formatters;
static NSNumberFormatter *LSCachedFormatter(id key, NSNumberFormatter *(^make)(void)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ls_formatters = [NSMutableDictionary dictionary];
        [NSNotificationCenter.defaultCenter addObserverForName:NSCurrentLocaleDidChangeNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            os_unfair_lock_lock(&ls_formatterLock);
            [ls_formatters removeAllObjects];
            os_unfair_lock_unlock(&ls_formatterLock);
        }];
    });
    os_unfair_lock_lock(&ls_formatterLock);
    NSNumberFormatter *formatter = ls_formatters[key];
    os_unfair_lock_unlock(&ls_formatterLock);
    if (formatter) return formatter;
    formatter = make(); // Outside the lock: formatter set-up can take a while.
    os_unfair_lock_lock(&ls_formatterLock);
    ls_formatters[key] = formatter;
    os_unfair_lock_unlock(&ls_formatterLock);
    return formatter;
}

NSNumber *LSParseDecimal(NSString *text, NSLocale *locale) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *directionMarks = [NSCharacterSet characterSetWithCharactersInString:@"؜‎‏⁦⁧⁨⁩"];
    trimmed = [[trimmed componentsSeparatedByCharactersInSet:directionMarks] componentsJoinedByString:@""];
    if (trimmed.length == 0 || trimmed.length > 64) return nil;
    // Decimal comma, decimal point, Arabic decimal separator, and native digits are accepted.
    // Grouping, exponents, incomplete signs, and trailing text are deliberately rejected.
    static NSRegularExpression *grammar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        grammar = [NSRegularExpression regularExpressionWithPattern:@"^[+−-]?(?:\\p{Nd}+(?:[.,٫]\\p{Nd}*)?|[.,٫]\\p{Nd}+)$" options:0 error:nil];
    });
    if ([grammar numberOfMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)] != 1) return nil;
    NSString *key = [NSString stringWithFormat:@"parse:%@|%@", locale.localeIdentifier, [locale objectForKey:NSLocaleDecimalSeparator] ?: @""];
    NSNumberFormatter *formatter = LSCachedFormatter(key, ^NSNumberFormatter *{
        NSNumberFormatter *made = [[NSNumberFormatter alloc] init];
        made.locale = locale;
        made.numberStyle = NSNumberFormatterDecimalStyle;
        made.usesGroupingSeparator = NO;
        made.lenient = NO;
        return made;
    });
    NSString *normalized = [[trimmed stringByReplacingOccurrencesOfString:@"−" withString:@"-"] stringByReplacingOccurrencesOfString:@"," withString:@"."];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"٫" withString:@"."];
    if ([normalized hasPrefix:@"+"]) normalized = [normalized substringFromIndex:1];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"." withString:formatter.decimalSeparator];
    id value = nil;
    NSRange parsedRange = NSMakeRange(0, normalized.length);
    BOOL success = [formatter getObjectValue:&value forString:normalized range:&parsedRange error:nil];
    return success && parsedRange.location == 0 && parsedRange.length == normalized.length &&
        [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? value : nil;
}
static NSString *LSMatchGroup(NSString *text, NSTextCheckingResult *match, NSUInteger index) {
    NSRange range = [match rangeAtIndex:index];
    return range.location == NSNotFound ? nil : [text substringWithRange:range];
}
static unichar LSHemisphere(NSString *letter) { return letter.length ? [letter.uppercaseString characterAtIndex:0] : 0; }
// Degrees with optional minutes and seconds. Only the last part given may have a fraction
// (point or comma), minutes and seconds stay below 60, and a minus sign (- or −) never
// combines with a hemisphere letter.
static BOOL LSAngleValue(NSString *degrees, NSString *minutes, NSString *seconds, NSString *sign, unichar hemisphere, double *value) {
    degrees = [degrees stringByReplacingOccurrencesOfString:@"," withString:@"."];
    minutes = [minutes stringByReplacingOccurrencesOfString:@"," withString:@"."];
    seconds = [seconds stringByReplacingOccurrencesOfString:@"," withString:@"."];
    if ((minutes && [degrees containsString:@"."]) || (seconds && [minutes containsString:@"."])) return NO;
    double m = minutes.doubleValue, s = seconds.doubleValue;
    if (m >= 60 || s >= 60) return NO;
    BOOL minus = sign && ![sign isEqualToString:@"+"];
    if (minus && hemisphere) return NO;
    double angle = degrees.doubleValue + m / 60.0 + s / 3600.0;
    *value = minus || hemisphere == 'S' || hemisphere == 'W' ? -angle : angle;
    return isfinite(*value);
}
// 48°51'29.6"N 2°17'40.2"E, N 48° 51.493' E 2° 17.67', 48.8584° N, 2.2945° E, 48°51,5' N.
// Primes, smart quotes and '' all mark minutes and seconds; letters may lead or trail each
// value and put longitude first. Every number ends in its unit mark, so a decimal comma can
// never be read as the separator. ASCII digits only, like the decimal forms.
static BOOL LSParseAnglePair(NSString *text, CLLocationCoordinate2D *coordinate) {
    static NSRegularExpression *pair;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Degrees never directly follow a degree or minute mark: in 48°51'29,2°17' the 29 is
        // seconds missing their mark, not the start of the second value.
        NSString *part = @"([NSEW])?\\s*([+−-])?\\s*(?<![°º˚'′’])([0-9]{1,3}(?:[.,][0-9]+)?)\\s*[°º˚]\\s*"
                         @"(?:([0-9]{1,2}(?:[.,][0-9]+)?)\\s*['′’]\\s*(?:([0-9]{1,2}(?:[.,][0-9]+)?)\\s*(?:\"|″|”|''|′′))?)?\\s*([NSEW])?";
        NSString *pattern = [NSString stringWithFormat:@"^\\s*%@\\s*(?:[,;/]\\s*)?%@\\s*$", part, part];
        pair = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSTextCheckingResult *match = [pair firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 13) return NO;
    unichar lead1 = LSHemisphere(LSMatchGroup(text, match, 1)), trail1 = LSHemisphere(LSMatchGroup(text, match, 6));
    unichar lead2 = LSHemisphere(LSMatchGroup(text, match, 7)), trail2 = LSHemisphere(LSMatchGroup(text, match, 12));
    // "N 48° 51' E 2° 17'": the greedy first value took the letter that leads the second.
    if (lead1 && trail1 && !lead2) { lead2 = trail1; trail1 = 0; }
    if ((lead1 && trail1) || (lead2 && trail2)) return NO;
    unichar first = lead1 ?: trail1, second = lead2 ?: trail2;
    double a, b;
    if (!LSAngleValue(LSMatchGroup(text, match, 3), LSMatchGroup(text, match, 4), LSMatchGroup(text, match, 5), LSMatchGroup(text, match, 2), first, &a) ||
        !LSAngleValue(LSMatchGroup(text, match, 9), LSMatchGroup(text, match, 10), LSMatchGroup(text, match, 11), LSMatchGroup(text, match, 8), second, &b)) return NO;
    BOOL firstLat = first == 'N' || first == 'S', firstLon = first == 'E' || first == 'W';
    BOOL secondLat = second == 'N' || second == 'S', secondLon = second == 'E' || second == 'W';
    if ((firstLat && secondLat) || (firstLon && secondLon)) return NO;
    BOOL swapped = firstLon || secondLat;
    double latitude = swapped ? b : a, longitude = swapped ? a : b;
    if (fabs(latitude) > 90 || fabs(longitude) > 180) return NO;
    if (coordinate) *coordinate = CLLocationCoordinate2DMake(latitude, longitude);
    return YES;
}
BOOL LSParseCoordinatePair(NSString *text, CLLocationCoordinate2D *coordinate) {
    if (!text.length || text.length > 128) return NO;
    static NSRegularExpression *spaced, *compact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Point decimals and a comma followed by a space, so "48,85" typed in a comma
        // locale is never mistaken for a pair. ASCII digits only: \d also matched native
        // digits, which doubleValue read as 0, so the pair silently became 0, 0.
        spaced = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\(?\\s*([+−-]?[0-9]{1,3}(?:\\.[0-9]+)?)\\s*°?\\s*(?:;\\s*|,\\s+|\\s+)([+−-]?[0-9]{1,3}(?:\\.[0-9]+)?)\\s*°?\\s*\\)?\\s*$" options:0 error:nil];
        // Many apps copy "48.8584,2.2945" with no space. With a point decimal on both
        // sides the comma can only be the separator.
        compact = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\(?\\s*([+−-]?[0-9]{1,3}\\.[0-9]+)\\s*°?\\s*,\\s*([+−-]?[0-9]{1,3}\\.[0-9]+)\\s*°?\\s*\\)?\\s*$" options:0 error:nil];
    });
    NSRange whole = NSMakeRange(0, text.length);
    NSTextCheckingResult *match = [spaced firstMatchInString:text options:0 range:whole] ?: [compact firstMatchInString:text options:0 range:whole];
    if (!match) return LSParseAnglePair(text, coordinate);
    NSString *(^clean)(NSRange) = ^NSString *(NSRange range) {
        return [[text substringWithRange:range] stringByReplacingOccurrencesOfString:@"−" withString:@"-"];
    };
    double latitude = clean([match rangeAtIndex:1]).doubleValue;
    double longitude = clean([match rangeAtIndex:2]).doubleValue;
    if (!isfinite(latitude) || !isfinite(longitude) || fabs(latitude) > 90 || fabs(longitude) > 180) return NO;
    if (coordinate) *coordinate = CLLocationCoordinate2DMake(latitude, longitude);
    return YES;
}
NSString *LSFormatDecimal(double value, NSUInteger fractionDigits) {
    NSNumberFormatter *formatter = LSCachedFormatter(@(fractionDigits), ^NSNumberFormatter *{
        NSNumberFormatter *made = [[NSNumberFormatter alloc] init];
        made.locale = NSLocale.currentLocale;
        made.numberStyle = NSNumberFormatterDecimalStyle;
        made.usesGroupingSeparator = NO;
        made.maximumFractionDigits = fractionDigits;
        return made;
    });
    return [formatter stringFromNumber:@(value)] ?: @"";
}
NSString *LSCoordinateText(CLLocationCoordinate2D coordinate) {
    // Always point decimals: in comma locales "48,856600, 2,352200" was ambiguous and
    // could not be pasted back into the coordinate fields or other apps.
    return [NSString stringWithFormat:@"%.6f, %.6f", coordinate.latitude, coordinate.longitude];
}
NSString *LSRelativeDate(NSDate *date) {
    if (!date) return @"";
    if (fabs(date.timeIntervalSinceNow) < 60) return @"Just now";
    NSRelativeDateTimeFormatter *formatter = [[NSRelativeDateTimeFormatter alloc] init];
    formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    return [formatter localizedStringForDate:date relativeToDate:NSDate.date];
}

// MARK: - Empty states and tips

@interface LSCircleView : UIView
@end
@implementation LSCircleView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
}
@end

// Lets the halo settle in with a small spring the first time the empty state appears.
@interface LSEmptyStateView : UIStackView
@property (nonatomic, weak) UIView *lsHalo;
@property (nonatomic) BOOL lsRevealed;
@end
@implementation LSEmptyStateView
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window || self.lsRevealed) return;
    self.lsRevealed = YES;
    UIView *halo = self.lsHalo;
    if (!halo || !LSMapAnimationsEnabled()) return;
    halo.alpha = 0;
    halo.transform = CGAffineTransformMakeScale(0.7, 0.7);
    LSAnimateBouncy(^{
        halo.alpha = 1;
        halo.transform = CGAffineTransformIdentity;
    }, nil);
}
@end

UIView *LSEmptyState(NSString *symbol, NSString *title, NSString *message, UIButton *action) {
    UIColor *tint = LSAccentTextColor();
    LSCircleView *halo = [[LSCircleView alloc] init];
    halo.translatesAutoresizingMaskIntoConstraints = NO;
    halo.backgroundColor = LSTintWash(tint);
    halo.isAccessibilityElement = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = tint;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleLargeTitle scale:UIImageSymbolScaleMedium]
        configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithHierarchicalColor:tint]];
    icon.isAccessibilityElement = NO;
    [halo addSubview:icon];
    // Smallest circle that clears the symbol by 18 pt, at least 84 pt; it grows with Dynamic Type.
    NSLayoutConstraint *preferred = [halo.widthAnchor constraintEqualToConstant:84];
    preferred.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [halo.heightAnchor constraintEqualToAnchor:halo.widthAnchor],
        [halo.widthAnchor constraintGreaterThanOrEqualToConstant:84],
        [halo.widthAnchor constraintGreaterThanOrEqualToAnchor:icon.widthAnchor constant:36],
        [halo.heightAnchor constraintGreaterThanOrEqualToAnchor:icon.heightAnchor constant:36],
        [icon.centerXAnchor constraintEqualToAnchor:halo.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:halo.centerYAnchor],
        preferred
    ]];
    UILabel *titleLabel = LSLabel(title, UIFontTextStyleTitle3);
    titleLabel.font = LSRoundedFont(UIFontTextStyleTitle3, UIFontWeightBold, 34);
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    UILabel *messageLabel = LSLabel(message, UIFontTextStyleSubheadline);
    messageLabel.textColor = UIColor.secondaryLabelColor;
    messageLabel.textAlignment = NSTextAlignmentCenter;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObjects:halo, titleLabel, messageLabel, nil];
    if (action) [views addObject:action];
    LSEmptyStateView *stack = [[LSEmptyStateView alloc] initWithArrangedSubviews:views];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.lsHalo = halo;
    [stack setCustomSpacing:LSSpaceL afterView:halo];
    if (action) [stack setCustomSpacing:LSSpaceXL - 4 afterView:messageLabel];
    stack.layoutMargins = UIEdgeInsetsMake(LSSpaceXL, LSSpaceXL, LSSpaceXL, LSSpaceXL);
    stack.layoutMarginsRelativeArrangement = YES;
    return stack;
}

UIView *LSTipView(NSString *symbol, NSString *title, NSString *message, dispatch_block_t dismissed) {
    UIColor *tint = LSAccentTextColor();
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = tint;
    icon.preferredSymbolConfiguration = [[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2 scale:UIImageSymbolScaleMedium]
        configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithHierarchicalColor:tint]];
    icon.isAccessibilityElement = NO;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [icon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *titleLabel = LSLabel(title, UIFontTextStyleHeadline);
    titleLabel.font = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 30);
    UILabel *messageLabel = LSLabel(message, UIFontTextStyleSubheadline);
    messageLabel.textColor = UIColor.secondaryLabelColor;
    UIStackView *text = LSStack(@[titleLabel, messageLabel], 2);
    text.isAccessibilityElement = YES;
    text.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, message];
    // The top margin lines the title up with the close glyph, whose 44 pt target starts higher.
    UIStackView *body = LSRow(@[icon, text], LSSpaceM);
    body.alignment = UIStackViewAlignmentTop;
    body.layoutMargins = UIEdgeInsetsMake(10, 0, 0, 0);
    body.layoutMarginsRelativeArrangement = YES;
    [body setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [body setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIButtonConfiguration *closeStyle = UIButtonConfiguration.plainButtonConfiguration;
    closeStyle.image = [UIImage systemImageNamed:@"xmark"];
    closeStyle.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    closeStyle.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.configuration = closeStyle;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    close.accessibilityLabel = @"Dismiss tip";
    close.largeContentTitle = @"Dismiss tip";
    LSInstallLargeContentViewer(close);
    NSLayoutConstraint *closeWidth = [close.widthAnchor constraintEqualToConstant:44];
    NSLayoutConstraint *closeHeight = [close.heightAnchor constraintEqualToConstant:44];
    closeWidth.priority = 999; closeHeight.priority = 999;
    UIStackView *row = LSRow(@[body, close], LSSpaceXS);
    row.alignment = UIStackViewAlignmentTop;
    LSPanelView *panel = [[LSPanelView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = LSCardColor();
    panel.layer.cornerRadius = LSRadiusM;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    [panel addSubview:row];
    // Tight on the trailing side so the close glyph sits near the corner; its target stays 44 pt.
    NSLayoutConstraint *bottom = [row.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-14];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        closeWidth, closeHeight,
        [row.topAnchor constraintEqualToAnchor:panel.topAnchor constant:4],
        [row.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-4],
        bottom
    ]];
    __weak UIView *weakPanel = panel;
    dispatch_block_t done = [dismissed copy];
    [close addAction:[UIAction actionWithHandler:^(__unused UIAction *closeAction) {
        UIView *tip = weakPanel;
        if (!tip || tip.hidden) return;
        LSHapticSelection();
        LSSetHidden(tip, YES, YES);
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
        if (done) done();
    }] forControlEvents:UIControlEventTouchUpInside];
    return panel;
}

// MARK: - Status chip

@interface LSStatusChip ()
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *lsSymbolView;
@property (nonatomic, strong, nullable) UIColor *lsColor;
@property (nonatomic, copy, nullable) NSString *lsSymbol;
@property (nonatomic) BOOL lsActive;
@property (nonatomic) BOOL lsPulsing;
@property (nonatomic) BOOL lsConfigured;
@end
@implementation LSStatusChip
static NSString *LSSymbolForSessionTitle(NSString *title) {
    for (NSInteger mode = LSSessionModeOff; mode <= LSSessionModePaused; mode++) {
        if ([title isEqualToString:LSSessionTitle(mode)]) return LSSessionSymbol(mode);
    }
    return nil;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitStaticText;
        _dot = [[UIView alloc] init];
        _dot.translatesAutoresizingMaskIntoConstraints = NO;
        _dot.layer.cornerRadius = 4;
        _lsSymbolView = [[UIImageView alloc] init];
        _lsSymbolView.contentMode = UIViewContentModeScaleAspectFit;
        _lsSymbolView.hidden = YES;
        [_lsSymbolView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_lsSymbolView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        _label = LSLabel(@"", UIFontTextStyleFootnote);
        _label.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
        _label.numberOfLines = 1;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.8;
        [self ls_updateSymbolSize];
        LSInstallLargeContentViewer(self);
        UIStackView *row = LSRow(@[_dot, _lsSymbolView, _label], 5);
        [self addSubview:row];
        // Width below required: the stack view collapses the dot to zero while a symbol shows.
        NSLayoutConstraint *dotWidth = [_dot.widthAnchor constraintEqualToConstant:8];
        dotWidth.priority = 999;
        [NSLayoutConstraint activateConstraints:@[
            dotWidth,
            [_dot.heightAnchor constraintEqualToConstant:8],
            [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:9],
            [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10]
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // A capsule on one line; a rounded rectangle once the title wraps.
    CGFloat height = self.bounds.size.height;
    self.layer.cornerRadius = self.label.numberOfLines == 1 ? height / 2 : MIN(height / 2, 14);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // At accessibility sizes the title wraps to two lines rather than shrinking out of reach.
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.label.numberOfLines = large ? 2 : 1;
    self.label.adjustsFontSizeToFitWidth = !large;
    [self ls_updateSymbolSize];
    [self ls_updateEdge];
    [self setNeedsLayout];
}
- (void)ls_updateSymbolSize {
    // Sized from the capped label font, so the symbol never outgrows the text.
    self.lsSymbolView.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithFont:LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22) scale:UIImageSymbolScaleSmall];
}
- (void)ls_updateEdge {
    UITraitCollection *traits = self.traitCollection;
    BOOL high = traits.accessibilityContrast == UIAccessibilityContrastHigh && self.lsColor;
    self.layer.borderWidth = high ? 1 : 0;
    self.layer.borderColor = high ? [[self.lsColor resolvedColorWithTraitCollection:traits] colorWithAlphaComponent:0.7].CGColor : nil;
}
- (void)setTitle:(NSString *)title color:(UIColor *)color active:(BOOL)active {
    [self setTitle:title symbol:LSSymbolForSessionTitle(title) color:color active:active];
}
- (void)setSessionMode:(NSInteger)mode {
    [self setTitle:LSSessionTitle(mode) symbol:LSSessionSymbol(mode) color:LSSessionColor(mode) active:mode == LSSessionModeMoving];
}
- (void)setTitle:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color active:(BOOL)active {
    // Called on every playback refresh. Pulse state is tracked explicitly: with Reduce Motion an
    // active chip has no animation, which made every tick look like a change.
    UIView *indicator = symbol ? self.lsSymbolView : self.dot;
    BOOL motion = LSMapAnimationsEnabled();
    BOOL wantsLoop = self.pulsesContinuously && active && motion;
    // The system drops a looping pulse when the app is backgrounded; a refresh puts it back.
    BOOL loopLost = wantsLoop && ![indicator.layer animationForKey:@"pulse"];
    BOOL sameTitle = [title isEqualToString:self.label.text];
    BOOL sameSymbol = symbol == self.lsSymbol || [symbol isEqualToString:self.lsSymbol];
    BOOL sameColor = color == self.lsColor || [color isEqual:self.lsColor];
    if (self.lsConfigured && sameTitle && sameSymbol && sameColor && active == self.lsActive && wantsLoop == self.lsPulsing && !loopLost) return;
    BOOL titleChanged = self.lsConfigured && !sameTitle;
    BOOL stateChanged = !self.lsConfigured || !sameTitle || !sameSymbol || active != self.lsActive;
    self.lsConfigured = YES;
    self.lsSymbol = symbol;
    self.lsColor = color;
    self.lsActive = active;
    self.lsPulsing = wantsLoop;
    // Label-coloured text stays at full contrast; the colour tints the symbol and wash.
    self.label.text = title;
    self.label.textColor = UIColor.labelColor;
    self.dot.backgroundColor = color;
    self.dot.hidden = symbol != nil;
    self.lsSymbolView.hidden = symbol == nil;
    if (symbol) {
        self.lsSymbolView.image = [UIImage systemImageNamed:symbol];
        self.lsSymbolView.tintColor = color;
    }
    // Denser than other washes: the chip is the "what is happening now" signal.
    self.backgroundColor = LSWash(color, 0.22, 0.32);
    self.accessibilityLabel = [NSString stringWithFormat:@"Status: %@", title];
    self.largeContentTitle = title;
    self.largeContentImage = symbol ? [UIImage systemImageNamed:symbol] : nil;
    [self ls_updateEdge];
    // By default the indicator pulses twice when the state changes and then rests, so this chip,
    // other chips and the map's own live markers never throb together through a playback.
    BOOL pulseOnce = !self.pulsesContinuously && active && motion && stateChanged;
    if (wantsLoop || pulseOnce || !active || stateChanged) {
        [self.dot.layer removeAnimationForKey:@"pulse"];
        [self.lsSymbolView.layer removeAnimationForKey:@"pulse"];
    }
    if (wantsLoop || pulseOnce) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @1.0;
        pulse.toValue = @0.3;
        pulse.duration = wantsLoop ? 0.9 : 0.45; // Two brisk beats, or the slower steady loop.
        pulse.autoreverses = YES;
        pulse.repeatCount = wantsLoop ? HUGE_VALF : 2;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [indicator.layer addAnimation:pulse forKey:@"pulse"];
    }
    if (titleChanged && self.window) {
        CATransition *fade = [CATransition animation];
        fade.type = kCATransitionFade;
        fade.duration = 0.2;
        [self.label.layer addAnimation:fade forKey:@"fade"];
        LSBump(self);
    }
}
@end
