#import "LSUI.h"
#import "SessionController.h"
#import <objc/runtime.h>

static UIColor *LSDynamicColor(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}
UIColor *LSAccentColor(void) {
    // White button titles retain contrast in both appearances.
    return [UIColor colorWithRed:0.0 green:0.388 blue:0.812 alpha:1.0];
}
// Accent used for text and glyphs on tinted or plain surfaces.
static UIColor *LSAccentTextColor(void) {
    return LSDynamicColor(LSAccentColor(), [UIColor colorWithRed:0.42 green:0.69 blue:1.0 alpha:1.0]);
}
UIColor *LSRouteColor(void) {
    return LSDynamicColor([UIColor colorWithRed:0.0 green:0.467 blue:0.427 alpha:1.0],
                          [UIColor colorWithRed:0.392 green:0.824 blue:0.784 alpha:1.0]);
}
UIColor *LSErrorColor(void) {
    return LSDynamicColor([UIColor colorWithRed:0.706 green:0.137 blue:0.094 alpha:1.0],
                          [UIColor colorWithRed:1.0 green:0.412 blue:0.38 alpha:1.0]);
}
UIColor *LSSuccessColor(void) {
    return LSDynamicColor([UIColor colorWithRed:0.10 green:0.53 blue:0.25 alpha:1.0],
                          [UIColor colorWithRed:0.30 green:0.85 blue:0.45 alpha:1.0]);
}
UIColor *LSWarningColor(void) {
    return LSDynamicColor([UIColor colorWithRed:0.74 green:0.40 blue:0.0 alpha:1.0],
                          [UIColor colorWithRed:1.0 green:0.70 blue:0.25 alpha:1.0]);
}
UIColor *LSCardColor(void) { return UIColor.secondarySystemGroupedBackgroundColor; }
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

UIFont *LSFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximumPointSize) {
    UITraitCollection *standard = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    CGFloat size = [UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:standard].pointSize;
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight] maximumPointSize:maximumPointSize];
}
UIFont *LSMonospacedFont(UIFontTextStyle style) {
    UITraitCollection *standard = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    CGFloat size = [UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:standard].pointSize;
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular]];
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
    UILabel *label = LSLabel(text.uppercaseString, UIFontTextStyleFootnote);
    label.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
    label.textColor = UIColor.secondaryLabelColor;
    label.accessibilityLabel = text;
    label.accessibilityTraits = UIAccessibilityTraitHeader;
    return label;
}
static void LSApplyMinimumSize(UIView *view, CGFloat height, CGFloat width) {
    NSLayoutConstraint *h = [view.heightAnchor constraintGreaterThanOrEqualToConstant:height];
    NSLayoutConstraint *w = [view.widthAnchor constraintGreaterThanOrEqualToConstant:width];
    // Hidden arranged subviews receive required zero-size constraints from UIStackView.
    h.priority = 999; w.priority = 999;
    [NSLayoutConstraint activateConstraints:@[h, w]];
}
UIButton *LSButton(NSString *title, NSString *symbol, BOOL prominent) {
    UIButtonConfiguration *config = prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    config.title = title;
    config.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleMedium];
    config.imagePadding = 8;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.baseBackgroundColor = prominent ? LSAccentColor() : LSAccentTextColor();
    config.baseForegroundColor = prominent ? UIColor.whiteColor : LSAccentTextColor();
    config.contentInsets = prominent ? NSDirectionalEdgeInsetsMake(15, 16, 15, 16) : NSDirectionalEdgeInsetsMake(12, 14, 12, 14);
    config.titleLineBreakMode = NSLineBreakByWordWrapping;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 26);
        return result;
    };
    config.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleSubheadline, UIFontWeightRegular, 24);
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    button.accessibilityLabel = title;
    if (prominent) {
        button.layer.shadowColor = LSAccentColor().CGColor;
        button.layer.shadowOpacity = 0.25;
        button.layer.shadowRadius = 10;
        button.layer.shadowOffset = CGSizeMake(0, 4);
    }
    LSApplyMinimumSize(button, prominent ? 52 : 44, 44);
    return button;
}
UIButton *LSIconButton(NSString *symbol, NSString *accessibilityLabel) {
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.image = [UIImage systemImageNamed:symbol];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    config.baseForegroundColor = LSAccentTextColor();
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
    UIBackgroundConfiguration *background = UIBackgroundConfiguration.clearConfiguration;
    background.visualEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial];
    background.cornerRadius = 22;
    config.background = background;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = accessibilityLabel;
    button.largeContentTitle = accessibilityLabel;
    button.showsLargeContentViewer = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.14;
    button.layer.shadowRadius = 6;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    [NSLayoutConstraint activateConstraints:@[[button.widthAnchor constraintEqualToConstant:44],
                                              [button.heightAnchor constraintEqualToConstant:44]]];
    return button;
}
UIButton *LSChipButton(NSString *title, NSString *symbol) {
    UIButtonConfiguration *config = UIButtonConfiguration.grayButtonConfiguration;
    config.title = title;
    config.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleSmall];
    config.imagePadding = 6;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseForegroundColor = UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    config.titleLineBreakMode = NSLineBreakByWordWrapping;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 22);
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.accessibilityLabel = title;
    LSApplyMinimumSize(button, 44, 44);
    return button;
}
void LSSetChipSelected(UIButton *chip, BOOL selected) {
    UIButtonConfiguration *config = chip.configuration;
    config.baseBackgroundColor = selected ? LSAccentColor() : UIColor.tertiarySystemFillColor;
    config.baseForegroundColor = selected ? UIColor.whiteColor : UIColor.labelColor;
    chip.configuration = config;
    chip.selected = NO; // Selection is drawn by the configuration, not UIControl state.
    chip.accessibilityTraits = selected ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
}
UIView *LSIconBadge(NSString *symbol, UIColor *color, CGFloat size) {
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = color;
    badge.layer.cornerRadius = size * 0.28;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.isAccessibilityElement = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:size * 0.48 weight:UIImageSymbolWeightSemibold];
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
UITextField *LSNumberField(NSString *name) {
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = LSMonospacedFont(UIFontTextStyleBody);
    field.adjustsFontForContentSizeCategory = YES;
    field.backgroundColor = UIColor.tertiarySystemFillColor;
    field.layer.cornerRadius = 12;
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
UIView *LSInsetPanel(UIView *content) {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = LSCardColor();
    panel.layer.cornerRadius = 20;
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
    label.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightMedium, 24);
    label.textColor = UIColor.secondaryLabelColor;
    error.textColor = LSErrorColor();
    error.hidden = YES;
    return LSStack(@[label, field, error], 6);
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
void LSAnnounce(NSString *message) { if (message.length) UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message); }
BOOL LSMapAnimationsEnabled(void) { return !UIAccessibilityIsReduceMotionEnabled(); }

static char ls_toastKey;
void LSShowToast(UIView *host, NSString *message, NSString *symbol) {
    LSAnnounce(message);
    if (!host || !message.length) return;
    UIView *previous = objc_getAssociatedObject(host, &ls_toastKey);
    [previous removeFromSuperview];
    UIVisualEffectView *toast = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.layer.cornerRadius = 22;
    toast.layer.cornerCurve = kCACornerCurveContinuous;
    toast.clipsToBounds = YES;
    toast.userInteractionEnabled = NO;
    toast.accessibilityElementsHidden = YES; // Already announced.
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol ?: @"info.circle.fill"]];
    icon.tintColor = LSAccentTextColor();
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleLarge];
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *label = LSLabel(message, UIFontTextStyleSubheadline);
    label.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 22);
    label.numberOfLines = 3;
    UIStackView *row = LSRow(@[icon, label], 10);
    [toast.contentView addSubview:row];
    [host addSubview:toast];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:toast.contentView.topAnchor constant:11],
        [row.bottomAnchor constraintEqualToAnchor:toast.contentView.bottomAnchor constant:-11],
        [row.leadingAnchor constraintEqualToAnchor:toast.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:toast.contentView.trailingAnchor constant:-18],
        [toast.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:8],
        [toast.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor constant:-32]
    ]];
    objc_setAssociatedObject(host, &ls_toastKey, toast, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL animate = LSMapAnimationsEnabled();
    toast.alpha = 0;
    toast.transform = animate ? CGAffineTransformMakeTranslation(0, -16) : CGAffineTransformIdentity;
    [UIView animateWithDuration:animate ? 0.35 : 0.15 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        toast.alpha = 1;
        toast.transform = CGAffineTransformIdentity;
    } completion:nil];
    __weak UIView *weakHost = host;
    __weak UIVisualEffectView *weakToast = toast;
    NSTimeInterval visible = MIN(6.0, 2.2 + message.length / 40.0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(visible * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIVisualEffectView *current = weakToast;
        if (!current) return;
        [UIView animateWithDuration:0.25 animations:^{ current.alpha = 0; } completion:^(__unused BOOL finished) {
            [current removeFromSuperview];
            UIView *strongHost = weakHost;
            if (strongHost && objc_getAssociatedObject(strongHost, &ls_toastKey) == current) {
                objc_setAssociatedObject(strongHost, &ls_toastKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }];
    });
}
void LSHapticSelection(void) { [[[UISelectionFeedbackGenerator alloc] init] selectionChanged]; }
void LSHapticSuccess(void) { [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess]; }
void LSHapticWarning(void) { [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeWarning]; }

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
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = locale;
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.lenient = NO;
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
    if (!match) return NO;
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
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = NSLocale.currentLocale;
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.maximumFractionDigits = fractionDigits;
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

@interface LSStatusChip ()
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *label;
@end
@implementation LSStatusChip
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
        _label = LSLabel(@"", UIFontTextStyleFootnote);
        _label.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 20);
        _label.numberOfLines = 1;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.8;
        UIStackView *row = LSRow(@[_dot, _label], 6);
        [self addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [_dot.widthAnchor constraintEqualToConstant:8],
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
    self.layer.cornerRadius = self.bounds.size.height / 2;
}
- (void)setTitle:(NSString *)title color:(UIColor *)color active:(BOOL)active {
    // Called on every playback refresh; restarting the pulse each time made it stutter.
    BOOL unchanged = [title isEqualToString:self.label.text] && active == (self.dot.layer.animationKeys.count > 0);
    if (unchanged) return;
    self.label.text = title;
    self.label.textColor = color;
    self.dot.backgroundColor = color;
    self.backgroundColor = [color colorWithAlphaComponent:0.14];
    self.accessibilityLabel = [NSString stringWithFormat:@"Status: %@", title];
    [self.dot.layer removeAnimationForKey:@"pulse"];
    if (active && LSMapAnimationsEnabled()) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @1.0;
        pulse.toValue = @0.25;
        pulse.duration = 0.8;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.dot.layer addAnimation:pulse forKey:@"pulse"];
    }
}
@end
