#import "LSUI.h"

UIColor *LSAccentColor(void) {
    // White button titles retain contrast in both appearances.
    return [UIColor colorWithRed:0.0 green:0.388 blue:0.812 alpha:1.0];
}
UIColor *LSRouteColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.392 green:0.824 blue:0.784 alpha:1.0]
            : [UIColor colorWithRed:0.0 green:0.467 blue:0.427 alpha:1.0];
    }];
}
UIColor *LSErrorColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:1.0 green:0.412 blue:0.38 alpha:1.0]
            : [UIColor colorWithRed:0.706 green:0.137 blue:0.094 alpha:1.0];
    }];
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
UIButton *LSButton(NSString *title, NSString *symbol, BOOL prominent) {
    UIButtonConfiguration *config = prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    config.title = title;
    config.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    config.imagePadding = 8;
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    config.baseBackgroundColor = LSAccentColor();
    config.baseForegroundColor = prominent ? UIColor.whiteColor : UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsMake(12, 12, 12, 12);
    config.titleLineBreakMode = NSLineBreakByWordWrapping;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold] maximumPointSize:26];
        return result;
    };
    config.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15] maximumPointSize:24];
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    button.accessibilityLabel = title;
    NSLayoutConstraint *height = [button.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    NSLayoutConstraint *width = [button.widthAnchor constraintGreaterThanOrEqualToConstant:44];
    // Hidden arranged subviews receive required zero-size constraints from UIStackView.
    height.priority = 999; width.priority = 999;
    [NSLayoutConstraint activateConstraints:@[height, width]];
    return button;
}
UITextField *LSNumberField(NSString *name) {
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    field.backgroundColor = UIColor.tertiarySystemFillColor;
    field.layer.cornerRadius = 10;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation; // Includes minus; hardware keyboards also work.
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.accessibilityLabel = name;
    field.placeholder = name;
    UIView *padding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
    field.leftView = padding;
    field.leftViewMode = UITextFieldViewModeAlways;
    NSLayoutConstraint *height = [field.heightAnchor constraintGreaterThanOrEqualToConstant:48];
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
UIView *LSInsetPanel(UIView *content) {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    panel.layer.cornerRadius = 16;
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
void LSAnnounce(NSString *message) { UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message); }
BOOL LSMapAnimationsEnabled(void) { return !UIAccessibilityIsReduceMotionEnabled(); }

NSNumber *LSParseDecimal(NSString *text, NSLocale *locale) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *directionMarks = [NSCharacterSet characterSetWithCharactersInString:@"\u061c\u200e\u200f\u2066\u2067\u2068\u2069"];
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
NSString *LSFormatDecimal(double value, NSUInteger fractionDigits) {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = NSLocale.currentLocale;
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.maximumFractionDigits = fractionDigits;
    return [formatter stringFromNumber:@(value)] ?: @"";
}
NSString *LSCoordinateText(CLLocationCoordinate2D coordinate) {
    return [NSString stringWithFormat:@"%@, %@", LSFormatDecimal(coordinate.latitude, 6), LSFormatDecimal(coordinate.longitude, 6)];
}
