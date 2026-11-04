#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"
#import "LSMapLinks.h"
#import "LSTrackIO.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static const NSUInteger kLSMaximumStops = 10;
static const double kLSLongestTripMinutes = 30 * 24 * 60;
// The ends of the engine's speed steps (LSSessionController nudgeSpeed:), so the
// slower and faster buttons can say when they cannot go further.
static const double kLSSlowestKmh = 1, kLSFastestKmh = 500, kLSSlowestPace = 0.25, kLSFastestPace = 10;

typedef NS_ENUM(NSInteger, LSRouteTone) { LSRouteToneInfo, LSRouteToneBusy, LSRouteToneSuccess, LSRouteToneError };

// The "path versus speed" tip is shown until the first route is built in this host launch.
static BOOL ls_routeExplained = NO;

#pragma mark - Formatting (reused: playback refreshes up to four times a second)

static MKDistanceFormatter *LSDistanceFormatter(BOOL spoken) {
    static MKDistanceFormatter *brief, *full;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        brief = [[MKDistanceFormatter alloc] init];
        brief.unitStyle = MKDistanceFormatterUnitStyleAbbreviated;
        full = [[MKDistanceFormatter alloc] init];
        full.unitStyle = MKDistanceFormatterUnitStyleFull;
    });
    return spoken ? full : brief;
}
static NSString *LSDistance(double meters) {
    return [LSDistanceFormatter(NO) stringFromDistance:isfinite(meters) ? MAX(0, meters) : 0];
}
static NSString *LSSpokenDistance(double meters) {
    return [LSDistanceFormatter(YES) stringFromDistance:isfinite(meters) ? MAX(0, meters) : 0];
}
static NSDateComponentsFormatter *LSDurationFormatter(NSDateComponentsFormatterUnitsStyle style) {
    static NSMutableDictionary<NSNumber *, NSDateComponentsFormatter *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSDateComponentsFormatter *formatter = cache[@(style)];
    if (!formatter) {
        formatter = [[NSDateComponentsFormatter alloc] init];
        formatter.unitsStyle = style;
        cache[@(style)] = formatter;
    }
    return formatter;
}
static NSString *LSDuration(double seconds) {
    if (!isfinite(seconds)) return @"—";
    if (seconds < 60) return @"under 1 min";
    NSDateComponentsFormatter *formatter = LSDurationFormatter(NSDateComponentsFormatterUnitsStyleAbbreviated);
    formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
    return [formatter stringFromTimeInterval:seconds] ?: @"—";
}
// Rounded up, so a countdown never reads "0 min" while the location still moves.
static NSString *LSTimeText(double seconds, BOOL spoken) {
    if (!isfinite(seconds)) return @"—";
    seconds = MAX(0, seconds);
    NSDateComponentsFormatter *formatter = LSDurationFormatter(spoken ? NSDateComponentsFormatterUnitsStyleFull : NSDateComponentsFormatterUnitsStyleShort);
    if (seconds < 60) {
        formatter.allowedUnits = NSCalendarUnitSecond;
        return [formatter stringFromTimeInterval:ceil(seconds)] ?: @"—";
    }
    formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
    return [formatter stringFromTimeInterval:ceil(seconds / 60) * 60] ?: @"—";
}
static NSString *LSClockTime(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterNoStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
    });
    return [formatter stringFromDate:date];
}
static NSString *LSPercentText(double fraction) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterPercentStyle;
        formatter.maximumFractionDigits = 0;
        formatter.roundingMode = NSNumberFormatterRoundFloor;
    });
    return [formatter stringFromNumber:@(MIN(1, MAX(0, fraction)))] ?: @"";
}
static NSString *LSWaitText(double seconds) {
    if (!isfinite(seconds) || seconds <= 0) return @"No wait";
    if (seconds < 60) return [NSString stringWithFormat:@"%.0f s", seconds];
    NSInteger minutes = (NSInteger)(seconds / 60), rest = (NSInteger)fmod(seconds, 60);
    return rest ? [NSString stringWithFormat:@"%ld min %ld s", (long)minutes, (long)rest] : [NSString stringWithFormat:@"%ld min", (long)minutes];
}
static NSString *LSClock(double seconds) {
    NSInteger total = (NSInteger)ceil(MAX(0, seconds));
    return total >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(total / 3600), (long)(total / 60 % 60), (long)(total % 60)]
                         : [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}
static NSString *LSSpeedText(double kmh) {
    return [NSString stringWithFormat:@"%@ km/h", LSFormatDecimal(kmh, kmh < 10 ? 1 : 0)];
}
static NSString *LSSpokenSpeed(double kmh) {
    return [NSString stringWithFormat:@"%@ kilometers per hour", LSFormatDecimal(kmh, kmh < 10 ? 1 : 0)];
}

// Preset speeds match the engine's walking, cycling and driving modes, so those routes
// report each mode's realistic accuracy instead of always using the custom profile.
static const double kLSPresetSpeeds[] = {5, 15, 50};
static LSTransportMode LSModeForSpeed(double kmh) {
    if (fabs(kmh - kLSPresetSpeeds[0]) < 0.01) return LSTransportModeWalking;
    if (fabs(kmh - kLSPresetSpeeds[1]) < 0.01) return LSTransportModeCycling;
    if (fabs(kmh - kLSPresetSpeeds[2]) < 0.01) return LSTransportModeDriving;
    return LSTransportModeCustom;
}
static NSString *LSActivityForKmh(double kmh) {
    return kmh < 8 ? @"walking" : (kmh < 30 ? @"cycling" : @"driving");
}

#pragma mark - Colours and type

static UIColor *LSRouteDynamic(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}
// Travelled part of a playing route: quiet, like the road already driven in Maps.
static UIColor *LSRouteTraveledColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = LSRouteDynamic([UIColor colorWithRed:0.56 green:0.60 blue:0.63 alpha:1], [UIColor colorWithRed:0.44 green:0.49 blue:0.52 alpha:1]); });
    return color;
}
// Outline under the route so it reads on busy streets and satellite imagery.
static UIColor *LSRouteCasingColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = LSRouteDynamic(UIColor.whiteColor, [UIColor colorWithRed:0.02 green:0.08 blue:0.08 alpha:0.9]); });
    return color;
}
// Cached once so the 4 Hz refresh can compare colours by identity.
static UIColor *LSCachedRouteColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = LSRouteColor(); });
    return color;
}
static UIColor *LSCachedWarningColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = LSWarningColor(); });
    return color;
}
static CGFloat LSRouteLineWidth(void) { return LSIncreaseContrast() ? 7 : 6; }

static UILabel *LSRouteLabel(UIFontTextStyle style, UIFontWeight weight, CGFloat maximum, UIColor *color) {
    UILabel *label = LSLabel(@"", style);
    label.font = LSNumberFont(style, weight, maximum);
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    return label;
}
// UILabel redraws and relayouts on every text assignment; the 4 Hz refresh skips repeats.
static void LSSetText(UILabel *label, NSString *text) {
    if (label.text == text || [label.text isEqualToString:text]) return;
    label.text = text;
}

// Digits (and the separators between them) in the value font, everything else (units) smaller
// and secondary, so "4.2 km", "12 min" and "1 hr, 5 min" read like an instrument.
static NSAttributedString *LSRouteNumberText(NSString *text, UIFont *valueFont, UIFont *unitFont, UIColor *color) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName: unitFont, NSForegroundColorAttributeName: UIColor.secondaryLabelColor}];
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSUInteger length = text.length;
    BOOL any = NO;
    for (NSUInteger index = 0; index < length; index++) {
        unichar character = [text characterAtIndex:index];
        BOOL digit = [digits characterIsMember:character];
        BOOL joiner = !digit && index > 0 && index + 1 < length && (character == '.' || character == ',' || character == ':' || character == 0x066B) &&
            [digits characterIsMember:[text characterAtIndex:index - 1]] && [digits characterIsMember:[text characterAtIndex:index + 1]];
        if (!digit && !joiner) continue;
        any = YES;
        [result addAttributes:@{NSFontAttributeName: valueFont, NSForegroundColorAttributeName: color} range:NSMakeRange(index, 1)];
    }
    if (!any) [result setAttributes:@{NSFontAttributeName: valueFont, NSForegroundColorAttributeName: color} range:NSMakeRange(0, length)];
    return result;
}

// Wraps content that a stack view may hide. The trailing and bottom edges give way (999) to
// the stack's zero-size hiding constraint instead of conflicting with the content's own sizes.
static UIView *LSRouteCollapsible(UIView *content) {
    UIView *wrap = [[UIView alloc] init];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:content];
    NSLayoutConstraint *trailing = [content.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor];
    NSLayoutConstraint *bottom = [content.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor];
    trailing.priority = 999;
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[[content.topAnchor constraintEqualToAnchor:wrap.topAnchor],
                                              [content.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor], trailing, bottom]];
    return wrap;
}

#pragma mark - Views

// A row that stacks its items once text reaches a size, and reports text-size and appearance
// changes so layer colours and attributed text can be rebuilt.
@interface LSTraitStack : UIStackView
@property (nonatomic, copy, nullable) UIContentSizeCategory stackFrom;
@property (nonatomic) UIStackViewAlignment rowAlignment;
@property (nonatomic, copy, nullable) dispatch_block_t traitsChanged;
// When the row is one VoiceOver element, what a double tap does.
@property (nonatomic, copy, nullable) dispatch_block_t activated;
@end
@implementation LSTraitStack
- (BOOL)accessibilityActivate {
    if (!self.activated) return [super accessibilityActivate];
    self.activated();
    return YES;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyAxis];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyAxis];
    BOOL size = ![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory];
    if (self.traitsChanged && (size || [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous])) self.traitsChanged();
}
- (void)applyAxis {
    if (!self.stackFrom) return;
    BOOL stacked = UIContentSizeCategoryCompareToCategory(self.traitCollection.preferredContentSizeCategory, self.stackFrom) != NSOrderedAscending;
    UILayoutConstraintAxis axis = stacked ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    if (self.axis == axis) return;
    self.axis = axis;
    self.alignment = stacked ? UIStackViewAlignmentFill : self.rowAlignment;
}
@end
static LSTraitStack *LSRouteRow(NSArray<UIView *> *views, CGFloat spacing, UIStackViewAlignment alignment, UIContentSizeCategory stackFrom) {
    LSTraitStack *row = [[LSTraitStack alloc] initWithArrangedSubviews:views];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = spacing;
    row.alignment = alignment;
    row.rowAlignment = alignment;
    row.stackFrom = stackFrom;
    return row;
}

// A big rounded figure with a caption under it ("12 min / left").
@interface LSRouteStatView : UIView
@property (nonatomic, readonly) UILabel *valueLabel;
@property (nonatomic, readonly) UILabel *captionLabel;
@property (nonatomic, strong) UIColor *valueColor;
- (instancetype)initHero:(BOOL)hero trailing:(BOOL)trailing;
- (void)setValue:(NSString *)value caption:(NSString *)caption spoken:(nullable NSString *)spoken;
@end
@implementation LSRouteStatView {
    BOOL _hero, _trailing;
    NSString *_value;
}
- (instancetype)initHero:(BOOL)hero trailing:(BOOL)trailing {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _hero = hero;
    _trailing = trailing;
    _valueColor = UIColor.labelColor;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.isAccessibilityElement = YES;
    _valueLabel = [[UILabel alloc] init];
    _valueLabel.numberOfLines = 0;
    _captionLabel = LSLabel(@"", UIFontTextStyleFootnote);
    _captionLabel.font = LSFont(UIFontTextStyleFootnote, UIFontWeightMedium, 22);
    _captionLabel.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = LSStack(@[_valueLabel, _captionLabel], 0);
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]
    ]];
    [self applyAlignment];
    return self;
}
- (UIView *)viewForFirstBaselineLayout { return self.valueLabel; }
- (UIView *)viewForLastBaselineLayout { return self.captionLabel; }
- (void)applyAlignment {
    BOOL stacked = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    NSTextAlignment alignment = NSTextAlignmentNatural;
    if (_trailing && !stacked) {
        BOOL rtl = [UIView userInterfaceLayoutDirectionForSemanticContentAttribute:self.semanticContentAttribute] == UIUserInterfaceLayoutDirectionRightToLeft;
        alignment = rtl ? NSTextAlignmentLeft : NSTextAlignmentRight;
    }
    self.valueLabel.textAlignment = alignment;
    self.captionLabel.textAlignment = alignment;
}
- (void)setValue:(NSString *)value caption:(NSString *)caption spoken:(NSString *)spoken {
    if (![_value isEqualToString:value]) {
        _value = [value copy];
        [self render];
    }
    LSSetText(self.captionLabel, caption);
    self.accessibilityLabel = caption;
    self.accessibilityValue = spoken ?: value;
}
- (void)setValueColor:(UIColor *)color {
    if (_valueColor == color) return;
    _valueColor = color;
    [self render];
}
- (void)render {
    UIFont *value = _hero ? LSHeroNumberFont(48, UIFontWeightBold) : LSNumberFont(UIFontTextStyleTitle1, UIFontWeightBold, 44);
    UIFont *unit = _hero ? LSNumberFont(UIFontTextStyleTitle3, UIFontWeightSemibold, 30) : LSNumberFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 24);
    self.valueLabel.attributedText = LSRouteNumberText(_value ?: @"", value, unit, _valueColor);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) return;
    [self applyAlignment];
    [self render];
}
@end

// Capsule progress with the planned stops as dots and a knob at the current point. Layers
// animate between the throttled refreshes, so the fill glides instead of stepping.
@interface LSRouteProgressBar : UIView
@property (nonatomic, readonly) double progress;
@property (nonatomic, copy) NSArray<NSNumber *> *stopFractions;
@property (nonatomic) NSUInteger stopsPassed;
@property (nonatomic, strong) UIColor *fillColor;
- (void)setProgress:(double)progress animated:(BOOL)animated;
@end
@implementation LSRouteProgressBar {
    CALayer *_track, *_fill, *_knob;
    NSMutableArray<CALayer *> *_stops;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.userInteractionEnabled = NO;
    _track = [CALayer layer];
    _fill = [CALayer layer];
    _knob = [CALayer layer];
    _knob.borderWidth = 3;
    _knob.shadowColor = UIColor.blackColor.CGColor;
    _knob.shadowOpacity = 0.22;
    _knob.shadowRadius = 2;
    _knob.shadowOffset = CGSizeMake(0, 1);
    [self.layer addSublayer:_track];
    [self.layer addSublayer:_fill];
    [self.layer addSublayer:_knob];
    _stops = [NSMutableArray array];
    _stopFractions = @[];
    _fillColor = LSCachedRouteColor();
    [self setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self updateColors];
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 22); }
- (void)setStopFractions:(NSArray<NSNumber *> *)fractions {
    _stopFractions = [fractions copy] ?: @[];
    for (CALayer *layer in _stops) [layer removeFromSuperlayer];
    [_stops removeAllObjects];
    for (NSUInteger index = 0; index < _stopFractions.count; index++) {
        CALayer *dot = [CALayer layer];
        dot.borderWidth = 2;
        [self.layer insertSublayer:dot below:_knob];
        [_stops addObject:dot];
    }
    [self updateColors];
    [self setNeedsLayout];
}
- (void)setStopsPassed:(NSUInteger)passed {
    if (_stopsPassed == passed) return;
    _stopsPassed = passed;
    [self updateColors];
}
- (void)setFillColor:(UIColor *)color {
    if (_fillColor == color) return;
    _fillColor = color;
    [self updateColors];
}
- (void)updateColors {
    UITraitCollection *traits = self.traitCollection;
    UIColor *fill = [_fillColor resolvedColorWithTraitCollection:traits];
    UIColor *track = [UIColor.tertiarySystemFillColor resolvedColorWithTraitCollection:traits];
    UIColor *card = [LSCardColor() resolvedColorWithTraitCollection:traits];
    UIColor *upcoming = [LSWarningColor() resolvedColorWithTraitCollection:traits];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.backgroundColor = track.CGColor;
    _fill.backgroundColor = fill.CGColor;
    _knob.backgroundColor = UIColor.whiteColor.CGColor;
    _knob.borderColor = fill.CGColor;
    for (NSUInteger index = 0; index < _stops.count; index++) {
        _stops[index].backgroundColor = index < _stopsPassed ? fill.CGColor : upcoming.CGColor;
        _stops[index].borderColor = card.CGColor;
    }
    [CATransaction commit];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self layoutBar];
    // An explicit shadow path spares Core Animation an offscreen pass for the knob's shadow.
    _knob.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_knob.bounds].CGPath;
    [CATransaction commit];
}
- (void)layoutBar {
    CGRect bounds = self.bounds;
    CGFloat width = bounds.size.width, height = 8, y = round((bounds.size.height - height) / 2);
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat (^place)(CGFloat, CGFloat) = ^CGFloat(CGFloat origin, CGFloat length) { return rtl ? width - origin - length : origin; };
    _track.frame = CGRectMake(0, y, width, height);
    _track.cornerRadius = height / 2;
    CGFloat end = width * MIN(1, MAX(0, _progress));
    CGFloat fillWidth = MIN(width, MAX(height, end));
    _fill.frame = CGRectMake(place(0, fillWidth), y, fillWidth, height);
    _fill.cornerRadius = height / 2;
    CGFloat dot = 10;
    for (NSUInteger index = 0; index < _stops.count; index++) {
        CGFloat center = width * MIN(1, MAX(0, _stopFractions[index].doubleValue));
        CGFloat origin = MIN(MAX(0, width - dot), MAX(0, center - dot / 2));
        _stops[index].frame = CGRectMake(place(origin, dot), round((bounds.size.height - dot) / 2), dot, dot);
        _stops[index].cornerRadius = dot / 2;
    }
    CGFloat knob = 16;
    CGFloat knobOrigin = MIN(MAX(0, width - knob), MAX(0, end - knob / 2));
    _knob.frame = CGRectMake(place(knobOrigin, knob), round((bounds.size.height - knob) / 2), knob, knob);
    _knob.cornerRadius = knob / 2;
}
- (void)setProgress:(double)progress animated:(BOOL)animated {
    if (!isfinite(progress)) progress = 0;
    progress = MIN(1, MAX(0, progress));
    if (fabs(progress - _progress) < 0.0002) return;
    _progress = progress;
    [CATransaction begin];
    [CATransaction setDisableActions:!animated || !LSMapAnimationsEnabled() || !self.window];
    // About one refresh interval, so consecutive updates join into continuous movement.
    [CATransaction setAnimationDuration:0.3];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    [self layoutBar];
    [CATransaction commit];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) [self updateColors];
}
@end

// The marker column of the planner: a symbol per row joined by a dotted line, with a soft
// halo on the row that the next map tap sets.
@interface LSRouteRailView : UIView
@property (nonatomic) BOOL lineAbove, lineBelow, active;
- (instancetype)initWithSymbol:(NSString *)symbol color:(UIColor *)color;
- (void)setSymbol:(NSString *)symbol color:(UIColor *)color;
@end
@implementation LSRouteRailView {
    UIImageView *_icon;
    UIView *_halo;
    CAShapeLayer *_line;
    NSString *_symbol;
    UIColor *_color;
    NSLayoutConstraint *_width, *_haloWidth, *_haloHeight;
}
- (instancetype)initWithSymbol:(NSString *)symbol color:(UIColor *)color {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.isAccessibilityElement = NO;
    self.userInteractionEnabled = NO;
    _line = [CAShapeLayer layer];
    _line.lineWidth = 3;
    _line.lineCap = kCALineCapRound;
    _line.lineDashPattern = @[@0, @6];
    _line.fillColor = nil;
    [self.layer addSublayer:_line];
    _halo = [[UIView alloc] init];
    _halo.translatesAutoresizingMaskIntoConstraints = NO;
    _halo.alpha = 0;
    _halo.transform = CGAffineTransformMakeScale(0.6, 0.6);
    _icon = [[UIImageView alloc] init];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.contentMode = UIViewContentModeCenter;
    [self addSubview:_halo];
    [self addSubview:_icon];
    _width = [self.widthAnchor constraintEqualToConstant:36];
    _haloWidth = [_halo.widthAnchor constraintEqualToConstant:36];
    _haloHeight = [_halo.heightAnchor constraintEqualToConstant:36];
    [NSLayoutConstraint activateConstraints:@[
        _width, _haloWidth, _haloHeight,
        [_icon.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_halo.centerXAnchor constraintEqualToAnchor:_icon.centerXAnchor],
        [_halo.centerYAnchor constraintEqualToAnchor:_icon.centerYAnchor]
    ]];
    [self setSymbol:symbol color:color];
    [self updateLineColor];
    return self;
}
- (void)setSymbol:(NSString *)symbol color:(UIColor *)color {
    _symbol = [symbol copy];
    _color = color;
    [self renderIcon];
}
// The marker grows with the text beside it, up to about one and a half times.
- (void)renderIcon {
    CGFloat point = MIN(34, [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledValueForValue:22 compatibleWithTraitCollection:self.traitCollection]);
    CGFloat halo = round(point + 14);
    _width.constant = MAX(36, halo);
    _haloWidth.constant = halo;
    _haloHeight.constant = halo;
    _halo.layer.cornerRadius = halo / 2;
    UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:point weight:UIImageSymbolWeightSemibold];
    UIImageSymbolConfiguration *palette = [UIImageSymbolConfiguration configurationWithPaletteColors:@[UIColor.whiteColor, LSFillColor(_color)]];
    _icon.image = [UIImage systemImageNamed:_symbol withConfiguration:[size configurationByApplyingConfiguration:palette]];
    _halo.backgroundColor = LSTintWash(_color);
}
- (void)setLineAbove:(BOOL)above { _lineAbove = above; [self setNeedsLayout]; }
- (void)setLineBelow:(BOOL)below { _lineBelow = below; [self setNeedsLayout]; }
- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    UIView *halo = _halo;
    void (^apply)(void) = ^{
        halo.alpha = active ? 1 : 0;
        halo.transform = active ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.6, 0.6);
    };
    if (self.window) LSAnimateBouncy(apply, nil); else apply();
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds, icon = _icon.frame;
    CGFloat mid = CGRectGetMidX(bounds), gap = 6;
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (_lineAbove && CGRectGetMinY(icon) - gap > 0) {
        [path moveToPoint:CGPointMake(mid, 0)];
        [path addLineToPoint:CGPointMake(mid, CGRectGetMinY(icon) - gap)];
    }
    if (_lineBelow && CGRectGetMaxY(icon) + gap < bounds.size.height) {
        [path moveToPoint:CGPointMake(mid, CGRectGetMaxY(icon) + gap)];
        [path addLineToPoint:CGPointMake(mid, bounds.size.height)];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _line.frame = bounds;
    _line.path = path.CGPath;
    [CATransaction commit];
}
- (void)updateLineColor {
    UIColor *color = [UIColor.tertiaryLabelColor resolvedColorWithTraitCollection:self.traitCollection];
    _line.strokeColor = color.CGColor;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) [self updateLineColor];
    if (![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self renderIcon];
        [self setNeedsLayout];
    }
}
@end

// Forwards a map gesture's start to the draw-in, without the recognizer pointing at the picker.
@interface LSRouteGestureRelay : NSObject
@property (nonatomic, copy, nullable) dispatch_block_t moved;
- (void)fire:(UIGestureRecognizer *)gesture;
@end
@implementation LSRouteGestureRelay
// Pans, pinches and rotations move the map as they begin; a double-tap or two-finger tap zoom once it ends.
- (void)fire:(UIGestureRecognizer *)gesture {
    BOOL tap = [gesture isKindOfClass:UITapGestureRecognizer.class];
    if (gesture.state == (tap ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateBegan) && self.moved) self.moved();
}
@end
static char ls_routeRelayKey;

// VoiceOver swipes up or down on the speed line to step the speed.
@interface LSAdjustableLabel : UILabel
@property (nonatomic, copy, nullable) dispatch_block_t increment, decrement;
@end
@implementation LSAdjustableLabel
- (UIAccessibilityTraits)accessibilityTraits { return [super accessibilityTraits] | UIAccessibilityTraitAdjustable; }
- (void)accessibilityIncrement { if (self.increment) self.increment(); }
- (void)accessibilityDecrement { if (self.decrement) self.decrement(); }
@end

static UIButton *LSTransportButton(NSString *symbol, NSString *label, CGFloat diameter, BOOL prominent) {
    UIButtonConfiguration *config = prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.grayButtonConfiguration;
    config.image = [UIImage systemImageNamed:symbol];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:prominent ? 26 : 20 weight:UIImageSymbolWeightBold];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseBackgroundColor = prominent ? LSFillColor(LSRouteColor()) : UIColor.tertiarySystemFillColor;
    config.baseForegroundColor = prominent ? UIColor.whiteColor : UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = label;
    button.largeContentTitle = label;
    button.showsLargeContentViewer = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    [NSLayoutConstraint activateConstraints:@[[button.widthAnchor constraintEqualToConstant:diameter],
                                              [button.heightAnchor constraintEqualToConstant:diameter]]];
    LSAddPressFeedback(button);
    return button;
}

// Live playback: state, the time left as the one big number, speed now, progress with stops,
// distance done and to go, and the transport controls. The readout is one VoiceOver element.
@interface LSRouteInstrumentView : UIView
@property (nonatomic, readonly) UIView *readout;
@property (nonatomic, readonly) LSStatusChip *stateChip;
@property (nonatomic, readonly) UILabel *etaLabel;
@property (nonatomic, readonly) UILabel *headingLabel;
@property (nonatomic, readonly) LSRouteStatView *timeLeft;
@property (nonatomic, readonly) LSRouteStatView *speedNow;
@property (nonatomic, readonly) LSRouteProgressBar *bar;
@property (nonatomic, readonly) UILabel *percentLabel;
@property (nonatomic, readonly) UILabel *doneLabel;
@property (nonatomic, readonly) UILabel *leftLabel;
@property (nonatomic, readonly) UILabel *detailLabel;
@property (nonatomic, readonly) UIView *transport;
@property (nonatomic, readonly) UIStackView *transportRow;
@property (nonatomic, readonly) UIButton *slowerButton, *playButton, *fasterButton;
@property (nonatomic, readonly) LSAdjustableLabel *speedLabel;
@property (nonatomic, weak, nullable) LSRoute *boundRoute;
- (void)setPaused:(BOOL)paused;
@end
@implementation LSRouteInstrumentView {
    BOOL _paused, _hasPlayState;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    UIContentSizeCategory large = UIContentSizeCategoryAccessibilityMedium;
    _stateChip = [[LSStatusChip alloc] init];
    [_stateChip setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _etaLabel = LSRouteLabel(UIFontTextStyleSubheadline, UIFontWeightSemibold, 26, UIColor.secondaryLabelColor);
    _etaLabel.textAlignment = NSTextAlignmentRight;
    LSTraitStack *top = LSRouteRow(@[_stateChip, _etaLabel], 8, UIStackViewAlignmentCenter, large);
    _headingLabel = LSLabel(@"", UIFontTextStyleHeadline);
    _headingLabel.font = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 28);
    _timeLeft = [[LSRouteStatView alloc] initHero:YES trailing:NO];
    _speedNow = [[LSRouteStatView alloc] initHero:NO trailing:YES];
    [_timeLeft setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_speedNow setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_speedNow setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    LSTraitStack *figures = LSRouteRow(@[_timeLeft, _speedNow], 12, UIStackViewAlignmentLastBaseline, large);
    _bar = [[LSRouteProgressBar alloc] init];
    _percentLabel = LSRouteLabel(UIFontTextStyleFootnote, UIFontWeightSemibold, 22, UIColor.secondaryLabelColor);
    [_percentLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_percentLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *barRow = LSRow(@[_bar, _percentLabel], 10);
    _doneLabel = LSRouteLabel(UIFontTextStyleFootnote, UIFontWeightMedium, 22, UIColor.secondaryLabelColor);
    _leftLabel = LSRouteLabel(UIFontTextStyleFootnote, UIFontWeightMedium, 22, UIColor.secondaryLabelColor);
    _leftLabel.textAlignment = NSTextAlignmentRight;
    [_doneLabel setContentHuggingPriority:UILayoutPriorityDefaultLow + 1 forAxis:UILayoutConstraintAxisHorizontal];
    LSTraitStack *distances = LSRouteRow(@[_doneLabel, _leftLabel], 8, UIStackViewAlignmentFirstBaseline, large);
    _detailLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.hidden = YES;
    UIStackView *readout = LSStack(@[top, _headingLabel, figures, barRow, distances, _detailLabel], 10);
    [readout setCustomSpacing:4 afterView:_headingLabel];
    [readout setCustomSpacing:14 afterView:figures];
    [readout setCustomSpacing:4 afterView:barRow];
    readout.isAccessibilityElement = YES;
    readout.accessibilityLabel = @"Applied route";
    readout.accessibilityTraits = UIAccessibilityTraitUpdatesFrequently;
    _readout = readout;

    _slowerButton = LSTransportButton(@"tortoise.fill", @"Slower", 52, NO);
    _slowerButton.accessibilityHint = @"Slows the route down one step.";
    _playButton = LSTransportButton(@"pause.fill", @"Pause route", 64, YES);
    _fasterButton = LSTransportButton(@"hare.fill", @"Faster", 52, NO);
    _fasterButton.accessibilityHint = @"Speeds the route up one step.";
    _transportRow = LSRow(@[_slowerButton, _playButton, _fasterButton], 28);
    UIStackView *centered = LSStack(@[_transportRow], 0);
    centered.alignment = UIStackViewAlignmentCenter;
    _transport = LSRouteCollapsible(centered);
    _speedLabel = [[LSAdjustableLabel alloc] init];
    _speedLabel.font = LSNumberFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
    _speedLabel.adjustsFontForContentSizeCategory = YES;
    _speedLabel.numberOfLines = 0;
    _speedLabel.textAlignment = NSTextAlignmentCenter;
    _speedLabel.textColor = UIColor.secondaryLabelColor;
    _speedLabel.accessibilityHint = @"Swipe up or down to change the speed.";
    UIStackView *content = LSStack(@[readout, _transport, _speedLabel], 14);
    [content setCustomSpacing:18 afterView:readout];
    [content setCustomSpacing:8 afterView:_transport];
    [self addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:self.topAnchor], [content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]
    ]];
    return self;
}
- (void)setPaused:(BOOL)paused {
    if (_hasPlayState && _paused == paused) return;
    _paused = paused;
    _hasPlayState = YES;
    UIButton *button = self.playButton;
    UIButtonConfiguration *config = button.configuration;
    config.image = [UIImage systemImageNamed:paused ? @"play.fill" : @"pause.fill"];
    NSString *label = paused ? @"Resume route" : @"Pause route";
    button.accessibilityLabel = label;
    button.largeContentTitle = label;
    BOOL animate = LSMapAnimationsEnabled() && self.window;
    [UIView transitionWithView:button duration:animate ? 0.2 : 0 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ button.configuration = config; } completion:nil];
}
@end

// Route line: one gradient overlay so the travelled part can be dimmed with a single redraw.
@interface LSRouteLineRenderer : MKGradientPolylineRenderer
@property (nonatomic) CGFloat traveled;
- (void)applyTraveled:(CGFloat)location traits:(UITraitCollection *)traits;
@end
@implementation LSRouteLineRenderer {
    BOOL _configured;
}
- (void)applyTraveled:(CGFloat)location traits:(UITraitCollection *)traits {
    _configured = YES;
    _traveled = location;
    UIColor *route = [LSRouteColor() resolvedColorWithTraitCollection:traits];
    UIColor *done = [LSRouteTraveledColor() resolvedColorWithTraitCollection:traits];
    // Drawn off the main thread, so the colours are resolved here rather than left dynamic.
    if (location <= 0) [self setColors:@[route, route] atLocations:@[@0, @1]];
    else if (location >= 1) [self setColors:@[done, done] atLocations:@[@0, @1]];
    else [self setColors:@[done, done, route, route] atLocations:@[@0, @(location), @(location), @1]];
    [super setStrokeColor:route];
}
// The picker re-tints every polyline when the appearance changes; take that as the cue to
// resolve this route's own colours again.
- (void)setStrokeColor:(UIColor *)color {
    [super setStrokeColor:color];
    if (_configured) [self applyTraveled:_traveled traits:UITraitCollection.currentTraitCollection];
}
@end

// Outline drawn under the route line; keeps its own colour through appearance changes.
@interface LSRouteCasingRenderer : MKPolylineRenderer
- (void)applyTraits:(UITraitCollection *)traits;
@end
@implementation LSRouteCasingRenderer
- (void)applyTraits:(UITraitCollection *)traits {
    [super setStrokeColor:[LSRouteCasingColor() resolvedColorWithTraitCollection:traits]];
}
- (void)setStrokeColor:(UIColor *)color {
    (void)color;
    [self applyTraits:UITraitCollection.currentTraitCollection];
}
@end

#pragma mark - Controls

static UIButton *LSEndpointButton(NSString *caption) {
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.title = caption;
    config.titlePadding = 2;
    config.baseForegroundColor = UIColor.labelColor;
    config.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
    config.titleLineBreakMode = NSLineBreakByWordWrapping;
    config.subtitleLineBreakMode = NSLineBreakByWordWrapping;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 0, 10, 4);
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
        result[NSForegroundColorAttributeName] = UIColor.secondaryLabelColor;
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.numberOfLines = 0;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    return button;
}
// The place under a row's caption; placeholders are quieter than chosen places.
static void LSSetEndpointText(UIButton *button, NSString *text, BOOL placeholder) {
    UIButtonConfiguration *config = button.configuration;
    config.subtitle = text;
    UIColor *color = placeholder ? UIColor.secondaryLabelColor : UIColor.labelColor;
    UIFontWeight weight = placeholder ? UIFontWeightRegular : UIFontWeightMedium;
    config.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleBody, weight, 30);
        result[NSForegroundColorAttributeName] = color;
        return result;
    };
    button.configuration = config;
}
static UIButton *LSAddStopButton(void) {
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.title = @"Add stop";
    config.titlePadding = 2;
    config.baseForegroundColor = LSAccentTextColor();
    config.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
    config.subtitleLineBreakMode = NSLineBreakByWordWrapping;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 0, 10, 4);
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleBody, UIFontWeightSemibold, 30);
        return result;
    };
    config.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleFootnote, UIFontWeightRegular, 22);
        result[NSForegroundColorAttributeName] = UIColor.secondaryLabelColor;
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return button;
}
static UIButton *LSRowIconButton(NSString *symbol, NSString *label) {
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.image = [UIImage systemImageNamed:symbol];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    config.baseForegroundColor = UIColor.secondaryLabelColor;
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = label;
    button.largeContentTitle = label;
    button.showsLargeContentViewer = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    [NSLayoutConstraint activateConstraints:@[[button.widthAnchor constraintEqualToConstant:44], [button.heightAnchor constraintEqualToConstant:44]]];
    return button;
}
// One planner row: rail, the row's button, an optional trailing control and a hairline under it.
static UIView *LSPlannerRow(LSRouteRailView *rail, UIButton *button, UIView *accessory, BOOL separator) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:rail];
    [row addSubview:button];
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [rail.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [rail.topAnchor constraintEqualToAnchor:row.topAnchor],
        [rail.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [button.leadingAnchor constraintEqualToAnchor:rail.trailingAnchor constant:8],
        [button.topAnchor constraintEqualToAnchor:row.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
    ]];
    if (accessory) {
        [row addSubview:accessory];
        [constraints addObjectsFromArray:@[[accessory.leadingAnchor constraintEqualToAnchor:button.trailingAnchor constant:4],
                                           [accessory.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                                           [accessory.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]]];
    } else {
        [constraints addObject:[button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]];
    }
    if (separator) {
        UIView *line = LSSeparator();
        [row addSubview:line];
        [constraints addObjectsFromArray:@[[line.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
                                           [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                                           [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return row;
}

static UIButton *LSMenuChip(NSString *title, NSString *symbol) {
    UIButton *chip = LSChipButton(title, symbol);
    chip.showsMenuAsPrimaryAction = YES;
    return chip;
}
static void LSSetChipTitle(UIButton *chip, NSString *title) {
    UIButtonConfiguration *config = chip.configuration;
    config.title = title;
    chip.configuration = config;
    chip.accessibilityLabel = title;
}
// Speed choice with its value spelled out under the name ("Drive / 50 km/h").
static UIButton *LSSpeedChip(NSString *title, NSString *symbol, NSString *value, BOOL stacked) {
    UIButton *chip = LSChipButton(title, symbol);
    UIButtonConfiguration *config = chip.configuration;
    config.subtitle = value;
    config.imagePlacement = stacked ? NSDirectionalRectEdgeTop : NSDirectionalRectEdgeLeading;
    config.imagePadding = stacked ? 4 : 8;
    config.titlePadding = 1;
    config.titleAlignment = stacked ? UIButtonConfigurationTitleAlignmentCenter : UIButtonConfigurationTitleAlignmentLeading;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 8, 10, 8);
    config.titleLineBreakMode = NSLineBreakByWordWrapping;
    config.subtitleLineBreakMode = NSLineBreakByWordWrapping;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 22);
        return result;
    };
    config.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSNumberFont(UIFontTextStyleCaption1, UIFontWeightMedium, 20);
        return result;
    };
    chip.configuration = config;
    return chip;
}
// A menu built when it opens, so menus that show current values cost nothing between taps.
static UIMenu *LSLiveMenu(NSString *title, UIMenuOptions options, UIMenu * _Nullable (^build)(void)) {
    UIDeferredMenuElement *element = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(build().children ?: @[]);
    }];
    return [UIMenu menuWithTitle:title image:nil identifier:nil options:options children:@[element]];
}
static void LSSetChipSubtitle(UIButton *chip, NSString *subtitle) {
    UIButtonConfiguration *config = chip.configuration;
    if ([config.subtitle isEqualToString:subtitle]) return;
    config.subtitle = subtitle;
    chip.configuration = config;
}

// What a map tap sets, coloured like the markers it places. Selected chips are filled with the
// marker colour; the shared chip styling adds the ring and, with Differentiate Without Color,
// the checkmark.
static NSString *const kLSTargetSymbols[] = {@"circle.circle.fill", @"plus.circle.fill", @"mappin.circle.fill"};
static UIColor *LSTargetColor(NSInteger target) {
    return target == LSEndpointFrom ? LSSuccessColor() : (target == LSEndpointStop ? LSWarningColor() : LSErrorColor());
}
static UIButton *LSTargetChip(NSString *title, NSInteger target) {
    UIButton *chip = LSChipButton(title, kLSTargetSymbols[MAX(0, MIN(2, target))]);
    chip.tag = target;
    UIButtonConfiguration *config = chip.configuration;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleMedium];
    chip.configuration = config;
    // Idle, the symbol keeps its marker colour (through taps too); selected, it turns white.
    LSSetChipIconColor(chip, LSFillColor(LSTargetColor(target)));
    return chip;
}
static void LSSetTargetChip(UIButton *chip, BOOL selected) {
    LSSetChipSelected(chip, selected);
    UIButtonConfiguration *config = chip.configuration;
    config.baseBackgroundColor = selected ? LSFillColor(LSTargetColor(chip.tag)) : UIColor.tertiarySystemFillColor;
    chip.configuration = config;
    [chip setNeedsUpdateConfiguration];
}

#pragma mark - Map drawing

// The route converted to screen points for the draw-in, thinned to points at least 2 pt apart.
static UIBezierPath *LSTracePath(MKMapView *map, MKPolyline *polyline, CGFloat *length) {
    NSUInteger count = polyline.pointCount;
    if (count < 2) return nil;
    MKMapPoint *points = polyline.points;
    NSUInteger stride = MAX((NSUInteger)1, count / 3000);
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGPoint last = CGPointZero;
    CGFloat total = 0;
    for (NSUInteger index = 0; ; index = MIN(index + stride, count - 1)) {
        CGPoint point = [map convertCoordinate:MKCoordinateForMapPoint(points[index]) toPointToView:map];
        if (!isfinite(point.x) || !isfinite(point.y)) return nil;
        if (index == 0) {
            [path moveToPoint:point];
            last = point;
        } else {
            CGFloat step = hypot(point.x - last.x, point.y - last.y);
            if (step >= 2 || index == count - 1) {
                [path addLineToPoint:point];
                total += step;
                last = point;
            }
        }
        if (index == count - 1) break;
    }
    if (length) *length = total;
    return total >= 12 ? path : nil;
}
static CAShapeLayer *LSTraceLayer(UIBezierPath *path, UIColor *color, CGFloat width) {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.path = path.CGPath;
    layer.strokeColor = color.CGColor;
    layer.fillColor = nil;
    layer.lineWidth = width;
    layer.lineCap = kCALineCapRound;
    layer.lineJoin = kCALineJoinRound;
    return layer;
}

#pragma mark - Background work

static NSURL *LSExportRoute(LSRoute *route, LSPlaybackOptions *options, NSString *format, double altitude) {
    double duration = [LSRouteSimulator estimatedDurationForRoute:route options:options];
    NSTimeInterval interval = isfinite(duration) && duration > 20000 ? duration / 20000 : 1.0;
    NSDate *start = options.recordedPace && route.recordedStartDate ? route.recordedStartDate : NSDate.date;
    double begin = floor(start.timeIntervalSince1970);
    NSMutableData *points = [NSMutableData data];
    [LSRouteSimulator enumerateSamplesForRoute:route options:options interval:interval block:^(NSTimeInterval time, CLLocationCoordinate2D coordinate, double speed, double distance, __unused CLLocationDirection heading) {
        LSTrackPoint point = { begin + time, coordinate.latitude, coordinate.longitude, altitude, distance, speed };
        [points appendBytes:&point length:sizeof point];
    }];
    NSUInteger count = points.length / sizeof(LSTrackPoint);
    if (count < 2) return nil;
    NSString *activity = options.recordedPace ? LSActivityForKmh(route.distance / MAX(1, duration) * 3.6) : LSActivityForKmh(options.speedKmh);
    NSData *data = nil;
    if ([format isEqualToString:@"GPX"]) data = [LSTrackIO GPXDataForPoints:points.bytes count:count name:route.name activity:activity];
    else if ([format isEqualToString:@"TCX"]) data = [LSTrackIO TCXDataForPoints:points.bytes count:count name:route.name activity:activity];
    else data = [LSTrackIO FITDataForPoints:points.bytes count:count activity:activity];
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"LSpoof Export"] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *file = [folder URLByAppendingPathComponent:[LSTrackIO safeFileName:route.name extension:format.lowercaseString]];
    return data && [data writeToURL:file atomically:YES] ? file : nil;
}

static LSRoute *LSRouteFromTrackFile(NSURL *url, LSTrack **trackOut, NSString **errorOut) {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSData *data = size.unsignedLongLongValue <= 64 * 1024 * 1024 ? [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    NSString *error = nil;
    LSTrack *track = data ? [LSTrackIO trackFromData:data fileName:url.lastPathComponent error:&error] : nil;
    if (!track) {
        if (errorOut) *errorOut = error ?: @"The file could not be read.";
        return nil;
    }
    NSUInteger count = track.count;
    const LSTrackPoint *points = track.points;
    NSMutableData *coordinates = [NSMutableData dataWithLength:count * sizeof(CLLocationCoordinate2D)];
    NSMutableData *times = track.hasTimes ? [NSMutableData dataWithLength:count * sizeof(double)] : nil;
    CLLocationCoordinate2D *coordinateBytes = coordinates.mutableBytes;
    double *timeBytes = times.mutableBytes;
    for (NSUInteger index = 0; index < count; index++) {
        coordinateBytes[index] = CLLocationCoordinate2DMake(points[index].latitude, points[index].longitude);
        if (timeBytes) timeBytes[index] = points[index].time - points[0].time;
    }
    MKDirectionsTransportType transport = [track.activity isEqualToString:@"driving"] ? MKDirectionsTransportTypeAutomobile : MKDirectionsTransportTypeWalking;
    NSDate *start = track.hasTimes && count ? [NSDate dateWithTimeIntervalSince1970:points[0].time] : nil;
    LSRoute *route = count ? [LSRoute routeWithCoordinates:coordinateBytes times:timeBytes count:count name:track.name transportType:transport startDate:start] : nil;
    if (!route || route.distance < 5) {
        if (errorOut) *errorOut = @"The track is too short to play back.";
        return nil;
    }
    if (trackOut) *trackOut = track;
    return route;
}

@implementation MapPickerViewController (LSRouteUI)

#pragma mark - Building the panels

- (void)buildRouteUI {
    self.endpoint = LSEndpointFrom;
    self.draftSpeedKmh = 5;
    self.draftPaceMultiplier = 1;
    self.routeStops = [NSMutableArray array];
    self.routeFeedbackIsHint = YES;
    __weak typeof(self) weakSelf = self;

    // Playback instrument: first on the tab while a route plays or has just arrived.
    LSRouteInstrumentView *gauge = [[LSRouteInstrumentView alloc] init];
    self.routeInstrument = gauge;
    self.progressPercentLabel = gauge.percentLabel;
    self.progressLabel = gauge.detailLabel;
    self.liveSpeedRow = gauge.transportRow;
    self.liveSpeedLabel = gauge.speedLabel;
    self.slowerButton = gauge.slowerButton;
    self.fasterButton = gauge.fasterButton;
    [self.slowerButton addTarget:self action:@selector(slowerTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.fasterButton addTarget:self action:@selector(fasterTapped) forControlEvents:UIControlEventTouchUpInside];
    [gauge.playButton addTarget:self action:@selector(instrumentPlayPause) forControlEvents:UIControlEventTouchUpInside];
    gauge.speedLabel.increment = ^{ [weakSelf fasterTapped]; };
    gauge.speedLabel.decrement = ^{ [weakSelf slowerTapped]; };
    self.progressPanel = LSInsetPanel(gauge);
    self.progressPanel.hidden = YES;

    // From, stops and To on one connected rail, like a directions card.
    self.fromButton = LSEndpointButton(@"From");
    self.toButton = LSEndpointButton(@"To");
    [self.fromButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    [self.toButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    self.routeFromRail = [[LSRouteRailView alloc] initWithSymbol:kLSTargetSymbols[LSEndpointFrom] color:LSSuccessColor()];
    self.routeFromRail.lineBelow = YES;
    self.routeToRail = [[LSRouteRailView alloc] initWithSymbol:kLSTargetSymbols[LSEndpointTo] color:LSErrorColor()];
    self.routeToRail.lineAbove = YES;
    self.routeAddRail = [[LSRouteRailView alloc] initWithSymbol:@"plus.circle.fill" color:LSAccentColor()];
    self.routeAddRail.lineAbove = YES;
    self.routeAddRail.lineBelow = YES;
    self.stopsStack = LSStack(@[], 0);
    self.addStopButton = LSAddStopButton();
    self.addStopButton.accessibilityHint = @"Adds a place to pass through between From and To. Up to 10 stops.";
    [self.addStopButton addTarget:self action:@selector(addStopTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *list = LSStack(@[LSPlannerRow(self.routeFromRail, self.fromButton, nil, YES), self.stopsStack,
                                  LSPlannerRow(self.routeAddRail, self.addStopButton, nil, YES),
                                  LSPlannerRow(self.routeToRail, self.toButton, nil, NO)], 0);
    self.swapButton = LSIconButton(@"arrow.up.arrow.down", @"Reverse the route");
    self.swapButton.accessibilityHint = @"Swaps From and To and runs the stops backwards.";
    [self.swapButton addTarget:self action:@selector(swapEndpoints) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *endpointRow = LSRow(@[list, self.swapButton], 8);

    // endpointSegment is the shared model for what a map tap sets (the shell moves it to To
    // after From is tapped); people see and use the marker-coloured chips instead.
    self.endpointSegment = [[UISegmentedControl alloc] initWithItems:@[@"From", @"Stop", @"To"]];
    self.endpointSegment.selectedSegmentIndex = LSEndpointFrom;
    [self.endpointSegment addTarget:self action:@selector(endpointChanged) forControlEvents:UIControlEventValueChanged];
    NSArray *targetTitles = @[@"From", @"Stop", @"To"];
    NSArray *targetHints = @[@"Map taps set From.", @"Map taps add a stop.", @"Map taps set To."];
    NSMutableArray<UIButton *> *targetChips = [NSMutableArray array];
    for (NSInteger index = 0; index < 3; index++) {
        UIButton *chip = LSTargetChip(targetTitles[index], index);
        chip.accessibilityHint = targetHints[index];
        [chip addTarget:self action:@selector(targetChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [targetChips addObject:chip];
    }
    self.routeTargetChips = targetChips;
    LSTraitStack *targets = LSRouteRow(targetChips, 8, UIStackViewAlignmentFill, UIContentSizeCategoryExtraExtraLarge);
    targets.distribution = UIStackViewDistributionFillEqually;
    UILabel *targetTitle = LSSectionLabel(@"Map taps set");
    self.importButton = LSMenuChip(@"Import", @"square.and.arrow.down");
    self.importButton.accessibilityLabel = @"Import a route";
    self.importButton.accessibilityHint = @"Paste an Apple Maps, Google Maps or Waze link, or open a GPX, TCX or FIT file.";
    UIStackView *importRow = LSStack(@[self.importButton], 0);
    importRow.alignment = UIStackViewAlignmentLeading;
    // Shown while the planner is open over the route that is playing, to fold it away again.
    UIButton *done = LSTextButton(@"Done", nil);
    done.accessibilityHint = @"Folds the route back into one line.";
    [done addTarget:self action:@selector(closeRouteEditor) forControlEvents:UIControlEventTouchUpInside];
    self.routeEditHeader = LSRouteCollapsible(LSSectionHeader(@"Playing this route", done));
    self.routeEditHeader.hidden = YES;
    UIStackView *endpointContent = LSStack(@[self.routeEditHeader, endpointRow, targetTitle, targets, importRow], 12);
    [endpointContent setCustomSpacing:16 afterView:endpointRow];
    [endpointContent setCustomSpacing:6 afterView:targetTitle];
    [endpointContent setCustomSpacing:14 afterView:targets];
    self.routeEndpointsCard = LSInsetPanel(endpointContent);

    // While the drafted route plays, the planner folds into this one line.
    self.routeTripLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    self.routeTripLabel.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 28);
    self.routeTripLabel.numberOfLines = 0;
    [self.routeTripLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIButton *edit = LSTextButton(@"Edit route", @"pencil");
    edit.accessibilityHint = @"Shows From, the stops and To again.";
    [edit setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [edit setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [edit addTarget:self action:@selector(openRouteEditor) forControlEvents:UIControlEventTouchUpInside];
    LSTraitStack *trip = LSRouteRow(@[self.routeTripLabel, edit], 10, UIStackViewAlignmentCenter, UIContentSizeCategoryAccessibilityMedium);
    // One VoiceOver element: the trip opens the editor; Pause or Resume is its action.
    trip.isAccessibilityElement = YES;
    trip.accessibilityTraits = UIAccessibilityTraitButton;
    trip.accessibilityHint = @"Shows From, the stops and To again.";
    trip.accessibilityUserInputLabels = @[@"Edit route", @"Trip"];
    trip.activated = ^{ [weakSelf openRouteEditor]; };
    // The place symbols are drawn into the text, so rebuild it for new sizes and appearances.
    trip.traitsChanged = ^{ [weakSelf updateTripSummary]; };
    self.routeTripRow = trip;
    self.routeTripCard = LSInsetPanel(trip);
    self.routeTripCard.hidden = YES;
    self.routeEndpointsPanel = LSRouteCollapsible(LSStack(@[self.progressPanel, self.routeTripCard, self.routeEndpointsCard], 14));

    // Status card: empty state, progress of the lookup, errors with a way out, and the result.
    self.routeEmptyState = LSRouteCollapsible(LSEmptyState(@"point.topleft.down.to.point.bottomright.curvepath", @"Plan a route",
        @"Set From and To above, or tap the map. Add stops on the way, or import a map link or a GPX file.", nil));
    self.routeFeedbackIcon = [[UIImageView alloc] init];
    self.routeFeedbackIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleMedium];
    [self.routeFeedbackIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.routeFeedbackIcon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.routeSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.routeSpinner.hidesWhenStopped = YES;
    [self.routeSpinner setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.routeFeedback = LSLabel(@"", UIFontTextStyleSubheadline);
    self.routeFeedback.textColor = UIColor.secondaryLabelColor;
    self.routeFeedbackWrap = LSRouteCollapsible(LSRow(@[self.routeFeedbackIcon, self.routeSpinner, self.routeFeedback], 8));
    LSRouteStatView *distance = [[LSRouteStatView alloc] initHero:NO trailing:NO];
    LSRouteStatView *time = [[LSRouteStatView alloc] initHero:NO trailing:NO];
    LSRouteStatView *stops = [[LSRouteStatView alloc] initHero:NO trailing:NO];
    self.routeStats = @[distance, time, stops];
    UIView *stopsWrap = LSRouteCollapsible(stops);
    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    LSTraitStack *statsRow = LSRouteRow(@[distance, time, stopsWrap, spacer], 20, UIStackViewAlignmentLastBaseline, UIContentSizeCategoryAccessibilityMedium);
    self.routeStatsWrap = LSRouteCollapsible(statsRow);
    self.routeSummary = LSLabel(@"", UIFontTextStyleSubheadline);
    self.routeSummary.textColor = UIColor.secondaryLabelColor;
    self.buildRouteButton = LSButton(@"Build route", @"point.topleft.down.to.point.bottomright.curvepath", NO);
    [self.buildRouteButton addTarget:self action:@selector(fetchRoute) forControlEvents:UIControlEventTouchUpInside];
    self.routeRecoveryButton = LSButton(@"Try the driving path", @"car.fill", NO);
    self.routeRecoveryButton.hidden = YES;
    [self.routeRecoveryButton addTarget:self action:@selector(tryOtherPath) forControlEvents:UIControlEventTouchUpInside];
    self.finishButton = LSMenuChip(@"Finish in…", @"flag.checkered");
    self.finishButton.accessibilityHint = @"Sets the speed so the trip takes the time you choose, such as another app's arrival estimate.";
    self.shareButton = LSMenuChip(@"Share", @"square.and.arrow.up");
    self.shareButton.accessibilityLabel = @"Share or export the route";
    UIStackView *tools = LSRow(@[self.finishButton, self.shareButton], 8);
    UIStackView *toolsWrap = LSStack(@[tools], 0);
    toolsWrap.alignment = UIStackViewAlignmentLeading;
    self.routeToolsWrap = LSRouteCollapsible(toolsWrap);
    UIStackView *status = LSStack(@[self.routeEmptyState, self.routeStatsWrap, self.routeSummary, self.routeFeedbackWrap,
                                    self.buildRouteButton, self.routeRecoveryButton, self.routeToolsWrap], 12);
    [status setCustomSpacing:4 afterView:self.routeStatsWrap];
    UIView *statusCard = LSInsetPanel(status);

    // How it plays: path geometry, then speed and motion.
    self.profileSegment = [[UISegmentedControl alloc] initWithItems:@[@"Walking path", @"Driving path"]];
    self.profileSegment.selectedSegmentIndex = 0;
    self.profileSegment.accessibilityLabel = @"Route geometry";
    [self.profileSegment.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.profileSegment addTarget:self action:@selector(profileChanged) forControlEvents:UIControlEventValueChanged];
    NSArray *presetTitles = @[@"Walk", @"Bike", @"Drive"];
    NSArray *presetSymbols = @[@"figure.walk", @"bicycle", @"car.fill"];
    NSMutableArray<UIButton *> *chips = [NSMutableArray array];
    for (NSUInteger index = 0; index < 3; index++) {
        UIButton *chip = LSSpeedChip(presetTitles[index], presetSymbols[index], LSSpeedText(kLSPresetSpeeds[index]), YES);
        chip.tag = (NSInteger)index;
        chip.accessibilityLabel = presetTitles[index];
        chip.accessibilityValue = LSSpokenSpeed(kLSPresetSpeeds[index]);
        [chip addTarget:self action:@selector(speedChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chips addObject:chip];
    }
    self.speedRow = [[UIStackView alloc] initWithArrangedSubviews:[chips copy]];
    self.speedRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.speedRow.distribution = UIStackViewDistributionFillEqually;
    self.speedRow.spacing = 8;
    UIButton *custom = LSSpeedChip(@"Custom", @"slider.horizontal.3", @"Any speed", NO);
    custom.tag = 3;
    custom.accessibilityHint = @"Enter any speed from 1 to 500 km/h.";
    [custom addTarget:self action:@selector(speedChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *recorded = LSSpeedChip(@"Recorded", @"clock.arrow.circlepath", @"As timed", NO);
    recorded.tag = 4;
    recorded.accessibilityHint = @"Plays the file at the pace it was recorded, including its pauses.";
    recorded.hidden = YES;
    [recorded addTarget:self action:@selector(speedChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [chips addObjectsFromArray:@[custom, recorded]];
    self.speedChips = chips;
    self.speedButton = custom;
    self.recordedChip = recorded;
    LSTraitStack *extras = LSRouteRow(@[custom, recorded], 8, UIStackViewAlignmentCenter, UIContentSizeCategoryExtraExtraLarge);
    UIStackView *extrasWrap = LSStack(@[extras], 0);
    extrasWrap.alignment = UIStackViewAlignmentLeading;
    self.motionButton = LSMenuChip(@"Steady speed", @"speedometer");
    self.motionButton.accessibilityHint = @"Choose whether the location speeds up, brakes and slows for turns like a real trip.";
    self.waitButton = LSMenuChip(@"No wait at stops", @"hourglass");
    self.waitButton.accessibilityHint = @"How long to stay at each stop before moving on.";
    LSTraitStack *motionRow = LSRouteRow(@[self.motionButton, self.waitButton], 8, UIStackViewAlignmentCenter, UIContentSizeCategoryExtraExtraLarge);
    UIStackView *motionWrap = LSStack(@[motionRow], 0);
    motionWrap.alignment = UIStackViewAlignmentLeading;
    NSMutableArray<UIView *> *optionViews = [NSMutableArray array];
    if (!ls_routeExplained) {
        self.routeTip = LSTipView(@"lightbulb", @"Path and speed are separate",
            @"Path decides the streets you follow. Speed and motion only change how the location moves along them.", ^{ ls_routeExplained = YES; });
        [optionViews addObject:self.routeTip];
    }
    [optionViews addObjectsFromArray:@[LSSectionLabel(@"Path"), self.profileSegment, LSSectionLabel(@"Playback speed"), self.speedRow, extrasWrap, motionWrap]];
    UIStackView *options = LSStack(optionViews, 12);
    [options setCustomSpacing:6 afterView:optionViews[optionViews.count - 6]];
    [options setCustomSpacing:18 afterView:self.profileSegment];
    [options setCustomSpacing:6 afterView:optionViews[optionViews.count - 4]];
    if (self.routeTip) [options setCustomSpacing:16 afterView:self.routeTip];
    UIView *optionsCard = LSInsetPanel(options);

    // Also the cue to re-resolve the route overlay colours when the appearance changes.
    LSTraitStack *details = [[LSTraitStack alloc] initWithArrangedSubviews:@[statusCard, optionsCard]];
    details.translatesAutoresizingMaskIntoConstraints = NO;
    details.axis = UILayoutConstraintAxisVertical;
    details.spacing = 14;
    details.traitsChanged = ^{ [weakSelf restyleRouteOverlays]; };
    self.routeDetailsPanel = LSRouteCollapsible(details);

    // Built each time they open, from the current values, instead of on every refresh.
    self.motionButton.menu = LSLiveMenu(@"Motion", UIMenuOptionsSingleSelection, ^UIMenu *{ return [weakSelf motionMenu]; });
    self.waitButton.menu = LSLiveMenu(@"Wait at each stop", UIMenuOptionsSingleSelection, ^UIMenu *{ return [weakSelf waitMenu]; });
    self.finishButton.menu = LSLiveMenu(@"Arrive on time", 0, ^UIMenu *{ return [weakSelf finishMenu]; });
    self.shareButton.menu = LSLiveMenu(@"Share route", 0, ^UIMenu *{ return [weakSelf shareMenu]; });
    self.importButton.menu = [self importMenu];
    [self rebuildStopRows];
}

- (void)restoreRoute {
    LSSessionController *session = LSSessionController.shared;
    LSRoute *route = session.retainedRoute;
    if (!route || route.pointCount < 2) return;
    self.fetchedRoute = route;
    self.routePolyline = route.polyline;
    self.routeCasing = [MKPolyline polylineWithPoints:route.polyline.points count:route.polyline.pointCount];
    NSArray<LSRouteWaypoint *> *waypoints = route.waypoints;
    LSRouteWaypoint *first = waypoints.firstObject, *last = waypoints.lastObject;
    self.startPin = [[LSStartAnnotation alloc] init];
    self.startPin.coordinate = first ? first.coordinate : route.coordinates[0];
    self.startPin.title = @"From";
    self.startPin.subtitle = first.name;
    self.endPin = [[LSDestinationAnnotation alloc] init];
    self.endPin.coordinate = last ? last.coordinate : route.coordinates[route.pointCount - 1];
    self.endPin.title = @"To";
    self.endPin.subtitle = last.name;
    [self.routeStops removeAllObjects];
    for (NSUInteger index = 1; index + 1 < waypoints.count; index++) {
        LSStopAnnotation *stop = [[LSStopAnnotation alloc] init];
        stop.coordinate = waypoints[index].coordinate;
        stop.subtitle = waypoints[index].name;
        [self.routeStops addObject:stop];
    }
    [self renumberStops];
    LSPlaybackOptions *options = LSRouteSimulator.shared.options;
    self.draftSpeedKmh = options.speedKmh;
    self.draftRecordedPace = options.recordedPace && route.hasTiming;
    self.draftPaceMultiplier = options.paceMultiplier;
    self.profileSegment.selectedSegmentIndex = route.transportType == MKDirectionsTransportTypeAutomobile ? 1 : 0;
    self.tab = LSPickerTabRoute;
    self.tabs.selectedSegmentIndex = self.tab;
    self.endpointSegment.selectedSegmentIndex = LSEndpointTo;
    self.endpoint = LSEndpointTo;
    [self.mapView addAnnotations:@[self.startPin, self.endPin]];
    [self.mapView addAnnotations:self.routeStops];
    [self addRouteOverlays];
    [self focusMapOnRect:self.routePolyline.boundingMapRect animated:NO];
    [self setRouteFeedback:LSRouteSimulator.shared.isSimulating ? @"The applied route keeps moving when you close the picker." : @"Route retained. Replay it when you’re ready."
                      tone:LSRouteToneInfo];
    [self rebuildStopRows];
    [self updateRouteUI];
}

#pragma mark - Endpoints and stops

- (NSArray<LSRouteWaypoint *> *)draftWaypoints {
    if (!self.startPin || !self.endPin) return @[];
    NSMutableArray *waypoints = [NSMutableArray arrayWithObject:[LSRouteWaypoint waypointWithName:self.startPin.subtitle coordinate:self.startPin.coordinate]];
    for (LSStopAnnotation *stop in self.routeStops) [waypoints addObject:[LSRouteWaypoint waypointWithName:stop.subtitle coordinate:stop.coordinate]];
    [waypoints addObject:[LSRouteWaypoint waypointWithName:self.endPin.subtitle coordinate:self.endPin.coordinate]];
    return waypoints;
}

- (void)renumberStops {
    for (NSUInteger index = 0; index < self.routeStops.count; index++) {
        self.routeStops[index].title = [NSString stringWithFormat:@"Stop %lu", (unsigned long)index + 1];
        MKMarkerAnnotationView *view = (id)[self.mapView viewForAnnotation:self.routeStops[index]];
        if ([view isKindOfClass:MKMarkerAnnotationView.class]) [self styleRouteAnnotationView:view];
    }
}

- (void)rebuildStopRows {
    for (UIView *view in self.stopsStack.arrangedSubviews) { [self.stopsStack removeArrangedSubview:view]; [view removeFromSuperview]; }
    NSUInteger passed = [self passedStopCount];
    for (NSUInteger index = 0; index < self.routeStops.count; index++) {
        LSStopAnnotation *stop = self.routeStops[index];
        NSString *place = stop.subtitle.length ? stop.subtitle : LSCoordinateText(stop.coordinate);
        UIButton *button = LSEndpointButton([NSString stringWithFormat:@"Stop %lu", (unsigned long)index + 1]);
        LSSetEndpointText(button, place, NO);
        button.accessibilityLabel = [NSString stringWithFormat:@"Stop %lu: %@", (unsigned long)index + 1, place];
        button.accessibilityHint = @"Opens options to change, move or remove this stop.";
        button.showsMenuAsPrimaryAction = YES;
        button.menu = [self menuForStopAtIndex:index];
        button.accessibilityCustomActions = [self accessibilityActionsForStopAtIndex:index];
        button.tag = (NSInteger)index;
        LSRouteRailView *rail = [[LSRouteRailView alloc] initWithSymbol:[self railSymbolForStop:index passed:passed] color:index < passed ? UIColor.systemGrayColor : LSWarningColor()];
        rail.lineAbove = YES;
        rail.lineBelow = YES;
        UIButton *remove = LSRowIconButton(@"xmark.circle.fill", [NSString stringWithFormat:@"Remove stop %lu", (unsigned long)index + 1]);
        remove.tag = (NSInteger)index;
        [remove addTarget:self action:@selector(removeStopTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.stopsStack addArrangedSubview:LSPlannerRow(rail, button, remove, YES)];
    }
    self.stopsStack.hidden = self.routeStops.count == 0;
    NSUInteger count = self.routeStops.count;
    self.addStopButton.enabled = count < kLSMaximumStops;
    UIButtonConfiguration *add = self.addStopButton.configuration;
    add.subtitle = count == 0 ? @"Optional, up to 10" : (count < kLSMaximumStops ? [NSString stringWithFormat:@"%lu of %lu stops", (unsigned long)count, (unsigned long)kLSMaximumStops]
                                                                               : @"10 of 10 stops. Remove one to add another.");
    self.addStopButton.configuration = add;
    self.addStopButton.accessibilityLabel = count < kLSMaximumStops ? @"Add stop" : @"Add stop, limit reached";
    self.addStopButton.accessibilityValue = add.subtitle;
    [self.routeAddRail setSymbol:@"plus.circle.fill" color:count < kLSMaximumStops ? LSAccentColor() : UIColor.systemGrayColor];
}

- (NSString *)railSymbolForStop:(NSUInteger)index passed:(NSUInteger)passed {
    return index < passed ? @"checkmark.circle.fill" : [NSString stringWithFormat:@"%lu.circle.fill", (unsigned long)index + 1];
}

// Passed stops turn into grey checkmarks in the list, matching their markers.
- (void)refreshStopRails {
    NSUInteger passed = [self passedStopCount];
    NSArray<UIView *> *rows = self.stopsStack.arrangedSubviews;
    for (NSUInteger index = 0; index < rows.count; index++) {
        for (UIView *view in rows[index].subviews) {
            if (![view isKindOfClass:LSRouteRailView.class]) continue;
            [(LSRouteRailView *)view setSymbol:[self railSymbolForStop:index passed:passed] color:index < passed ? UIColor.systemGrayColor : LSWarningColor()];
        }
    }
}

- (NSArray<UIAccessibilityCustomAction *> *)accessibilityActionsForStopAtIndex:(NSUInteger)index {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAccessibilityCustomAction *> *actions = [NSMutableArray array];
    if (index > 0) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Move earlier" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            return [weakSelf moveStopAtIndex:index offset:-1];
        }]];
    }
    if (index + 1 < self.routeStops.count) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Move later" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            return [weakSelf moveStopAtIndex:index offset:1];
        }]];
    }
    [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Remove stop" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        typeof(self) self = weakSelf;
        if (!self || index >= self.routeStops.count) return NO;
        [self removeStopAtIndex:index];
        return YES;
    }]];
    return actions;
}

- (UIMenu *)menuForStopAtIndex:(NSUInteger)index {
    __weak typeof(self) weakSelf = self;
    UIAction *change = [UIAction actionWithTitle:@"Change place…" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(__unused UIAction *action) {
        typeof(self) self = weakSelf;
        if (!self || index >= self.routeStops.count) return;
        LSStopAnnotation *stop = self.routeStops[index];
        [self openPlaceChooser:[NSString stringWithFormat:@"Choose stop %lu", (unsigned long)index + 1] coordinate:stop.coordinate completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
            typeof(self) self = weakSelf;
            if (!self || index >= self.routeStops.count) return;
            [self moveStop:self.routeStops[index] to:coordinate name:name];
        }];
    }];
    UIAction *up = [UIAction actionWithTitle:@"Move earlier" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveStopAtIndex:index offset:-1]; }];
    UIAction *down = [UIAction actionWithTitle:@"Move later" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveStopAtIndex:index offset:1]; }];
    if (index == 0) up.attributes = UIMenuElementAttributesDisabled;
    if (index + 1 >= self.routeStops.count) down.attributes = UIMenuElementAttributesDisabled;
    UIAction *remove = [UIAction actionWithTitle:@"Remove stop" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf removeStopAtIndex:index]; }];
    remove.attributes = UIMenuElementAttributesDestructive;
    UIMenu *order = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[up, down]];
    return [UIMenu menuWithTitle:[NSString stringWithFormat:@"Stop %lu", (unsigned long)index + 1] children:@[change, order, remove]];
}

- (void)stopsChanged {
    [self renumberStops];
    [self rebuildStopRows];
    [self invalidateRouteDraft];
    [self updateRouteUI];
    if (self.startPin && self.endPin) [self fetchRoute];
}

- (void)addStopAt:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    if (self.routeStops.count >= kLSMaximumStops) {
        [self showMessage:@"A route can have up to 10 stops." symbol:@"exclamationmark.circle.fill"];
        LSHapticWarning();
        return;
    }
    self.selectionRevision++;
    LSStopAnnotation *stop = [[LSStopAnnotation alloc] init];
    stop.coordinate = coordinate;
    stop.subtitle = name.length ? name : @"Map point";
    [self.routeStops addObject:stop];
    [self.mapView addAnnotation:stop];
    LSAnnounce([NSString stringWithFormat:@"Stop %lu added", (unsigned long)self.routeStops.count]);
    [self stopsChanged];
}

- (void)moveStop:(LSStopAnnotation *)stop to:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (!CLLocationCoordinate2DIsValid(coordinate) || ![self.routeStops containsObject:stop]) return;
    stop.coordinate = coordinate;
    stop.subtitle = name.length ? name : @"Map point";
    [self stopsChanged];
}

- (BOOL)moveStopAtIndex:(NSUInteger)index offset:(NSInteger)offset {
    NSInteger target = (NSInteger)index + offset;
    if (index >= self.routeStops.count || target < 0 || target >= (NSInteger)self.routeStops.count) return NO;
    LSStopAnnotation *stop = self.routeStops[index];
    [self.routeStops removeObjectAtIndex:index];
    [self.routeStops insertObject:stop atIndex:(NSUInteger)target];
    LSHapticSelection();
    [self stopsChanged];
    LSAnnounce([NSString stringWithFormat:@"Moved to stop %ld", (long)target + 1]);
    [self focusStopAtIndex:(NSUInteger)target];
    return YES;
}

// Rows are rebuilt after a change; keep VoiceOver on the stop that moved.
- (void)focusStopAtIndex:(NSUInteger)index {
    if (!UIAccessibilityIsVoiceOverRunning() || index >= self.stopsStack.arrangedSubviews.count) return;
    for (UIView *view in self.stopsStack.arrangedSubviews[index].subviews) {
        if ([view isKindOfClass:UIButton.class] && view.tag == (NSInteger)index && view.accessibilityCustomActions.count) {
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, view);
            return;
        }
    }
}

- (void)removeStopAtIndex:(NSUInteger)index {
    if (index >= self.routeStops.count) return;
    LSStopAnnotation *stop = self.routeStops[index];
    NSString *place = stop.subtitle.length ? stop.subtitle : LSCoordinateText(stop.coordinate);
    [self.mapView removeAnnotation:stop];
    [self.routeStops removeObjectAtIndex:index];
    LSHapticSelection();
    [self stopsChanged];
    // VoiceOver moves to the toast, which reads the message and offers Undo.
    __weak typeof(self) weakSelf = self;
    LSShowActionToast(self.view, [self toastAnchorView], [NSString stringWithFormat:@"Removed stop %lu, %@", (unsigned long)index + 1, place],
                      @"trash.fill", @"Undo", ^{ [weakSelf restoreStop:stop atIndex:index]; });
}

- (void)restoreStop:(LSStopAnnotation *)stop atIndex:(NSUInteger)index {
    if (self.closed || [self.routeStops containsObject:stop]) return;
    if (self.routeStops.count >= kLSMaximumStops) {
        [self showMessage:@"A route can have up to 10 stops." symbol:@"exclamationmark.circle.fill"];
        LSHapticWarning();
        return;
    }
    NSUInteger position = MIN(index, self.routeStops.count);
    [self.routeStops insertObject:stop atIndex:position];
    // Route markers are only on the map on the Route tab; the shell adds them back there.
    if (self.tab == LSPickerTabRoute) [self.mapView addAnnotation:stop];
    LSHapticSelection();
    [self stopsChanged];
    LSAnnounce([NSString stringWithFormat:@"Stop %lu restored", (unsigned long)position + 1]);
    [self focusStopAtIndex:position];
}


- (void)removeStopTapped:(UIButton *)sender {
    if (sender.tag >= 0) [self removeStopAtIndex:(NSUInteger)sender.tag];
}

- (void)addStopTapped {
    __weak typeof(self) weakSelf = self;
    CLLocationCoordinate2D near = self.routeStops.lastObject ? self.routeStops.lastObject.coordinate : (self.startPin ? self.startPin.coordinate : kCLLocationCoordinate2DInvalid);
    [self openPlaceChooser:@"Add a stop" coordinate:near completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
        [weakSelf addStopAt:coordinate name:name];
    }];
}

- (void)chooseEndpoint:(UIButton *)sender {
    LSEndpoint endpoint = sender == self.fromButton ? LSEndpointFrom : LSEndpointTo;
    self.endpoint = endpoint;
    self.endpointSegment.selectedSegmentIndex = endpoint;
    MKPointAnnotation *pin = endpoint == LSEndpointFrom ? self.startPin : self.endPin;
    __weak typeof(self) weakSelf = self;
    [self openPlaceChooser:endpoint == LSEndpointFrom ? @"Choose From" : @"Choose To" coordinate:pin ? pin.coordinate : kCLLocationCoordinate2DInvalid completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
        typeof(self) self = weakSelf;
        if (!self) return;
        [self assignEndpoint:endpoint coordinate:coordinate name:name];
        if (!self.fetchedRoute && !self.directions) [self focusMapOnCoordinate:coordinate meters:2000 animated:LSMapAnimationsEnabled()];
    }];
    [self endpointChanged];
}

- (void)targetChipTapped:(UIButton *)chip {
    if (chip.tag < 0 || chip.tag > LSEndpointTo) return;
    LSHapticSelection();
    self.endpointSegment.selectedSegmentIndex = chip.tag;
    [self endpointChanged];
}

- (void)endpointChanged {
    self.endpoint = self.endpointSegment.selectedSegmentIndex;
    // Shown in the hint pill over the map, so it stays to one short line.
    switch (self.endpoint) {
        case LSEndpointFrom: self.mapHintLabel.text = @"Next tap sets From. Drag a pin to move it."; break;
        case LSEndpointStop:
            self.mapHintLabel.text = self.routeStops.count < kLSMaximumStops
                ? [NSString stringWithFormat:@"Next tap adds stop %lu.", (unsigned long)self.routeStops.count + 1]
                : @"10 stops is the most. Remove one to add another.";
            break;
        case LSEndpointTo: self.mapHintLabel.text = @"Next tap sets To. Drag a pin to move it."; break;
    }
    [self updateEndpointHighlight];
}

- (void)updateEndpointHighlight {
    LSEndpoint target = self.endpoint;
    self.routeFromRail.active = target == LSEndpointFrom;
    self.routeAddRail.active = target == LSEndpointStop;
    self.routeToRail.active = target == LSEndpointTo;
    for (UIButton *chip in self.routeTargetChips) LSSetTargetChip(chip, chip.tag == target);
    self.fromButton.accessibilityValue = target == LSEndpointFrom ? @"Map taps set this" : nil;
    self.toButton.accessibilityValue = target == LSEndpointTo ? @"Map taps set this" : nil;
}

// The shell moves the map-tap target right after an update (From set, To next), so read it
// once more when the current event has finished.
- (void)queueEndpointHighlight {
    [self updateEndpointHighlight];
    if (self.routeHighlightQueued) return;
    self.routeHighlightQueued = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        self.routeHighlightQueued = NO;
        [self updateEndpointHighlight];
    });
}

- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    [self assignEndpoint:endpoint coordinate:coordinate name:name build:YES];
}

- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name build:(BOOL)build {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    if (endpoint == LSEndpointStop) { [self addStopAt:coordinate name:name]; return; }
    [self invalidateRouteDraft];
    self.selectionRevision++;
    if (endpoint == LSEndpointFrom) {
        if (!self.startPin) self.startPin = [[LSStartAnnotation alloc] init];
        self.startPin.coordinate = coordinate;
        self.startPin.title = @"From";
        self.startPin.subtitle = name;
        if (![self.mapView.annotations containsObject:self.startPin]) [self.mapView addAnnotation:self.startPin];
    } else {
        if (!self.endPin) self.endPin = [[LSDestinationAnnotation alloc] init];
        self.endPin.coordinate = coordinate;
        self.endPin.title = @"To";
        self.endPin.subtitle = name;
        if (![self.mapView.annotations containsObject:self.endPin]) [self.mapView addAnnotation:self.endPin];
    }
    [self updateRouteUI];
    if (build && self.startPin && self.endPin) [self fetchRoute];
}

// Reverses the whole trip: To becomes From and the stops run backwards.
- (void)swapEndpoints {
    if (!self.startPin || !self.endPin) return;
    CLLocationCoordinate2D from = self.startPin.coordinate, to = self.endPin.coordinate;
    NSString *fromName = self.startPin.subtitle ?: @"Map point", *toName = self.endPin.subtitle ?: @"Map point";
    LSHapticSelection();
    NSArray *reversed = self.routeStops.reverseObjectEnumerator.allObjects;
    [self.routeStops setArray:reversed];
    [self renumberStops];
    [self rebuildStopRows];
    [self assignEndpoint:LSEndpointFrom coordinate:to name:toName build:NO];
    [self assignEndpoint:LSEndpointTo coordinate:from name:fromName build:YES];
    [self animateSwap];
    LSAnnounce([NSString stringWithFormat:@"Reversed. From %@, to %@.", toName, fromName]);
}

// The two places trade rows with a spring; with Reduce Motion they cross-fade in place.
- (void)animateSwap {
    UIButton *from = self.fromButton, *to = self.toButton, *swap = self.swapButton;
    if (!from.window) return;
    if (!LSMapAnimationsEnabled()) {
        from.alpha = 0.3; to.alpha = 0.3;
        LSAnimate(^{ from.alpha = 1; to.alpha = 1; }, nil);
        return;
    }
    CGFloat delta = [to convertPoint:CGPointZero toView:nil].y - [from convertPoint:CGPointZero toView:nil].y;
    from.transform = CGAffineTransformMakeTranslation(0, delta);
    to.transform = CGAffineTransformMakeTranslation(0, -delta);
    swap.transform = CGAffineTransformIdentity;
    LSAnimateBouncy(^{
        from.transform = CGAffineTransformIdentity;
        to.transform = CGAffineTransformIdentity;
        swap.transform = CGAffineTransformMakeRotation((CGFloat)M_PI - 0.001);
    }, ^{
        // The symbol is symmetric, so snapping back from a half turn is invisible.
        swap.transform = CGAffineTransformIdentity;
    });
}

- (void)clearRouteDraft {
    [self invalidateRouteDraft];
    for (MKPointAnnotation *pin in self.routeStops) [self.mapView removeAnnotation:pin];
    [self.routeStops removeAllObjects];
    if (self.startPin) [self.mapView removeAnnotation:self.startPin];
    if (self.endPin) [self.mapView removeAnnotation:self.endPin];
    self.startPin = nil;
    self.endPin = nil;
    [self rebuildStopRows];
}

#pragma mark - Feedback

// text nil shows the contextual hint for the current draft.
- (void)setRouteFeedback:(nullable NSString *)text tone:(LSRouteTone)tone {
    self.routeFeedbackTone = tone;
    self.routeFeedbackIsHint = text == nil;
    if (tone != LSRouteToneError) self.routeSuggestsOtherPath = NO;
    if (text) self.routeFeedback.text = text;
    [self applyFeedbackTone];
}

- (void)applyFeedbackTone {
    NSString *symbol = nil;
    UIColor *color = UIColor.secondaryLabelColor;
    switch ((LSRouteTone)self.routeFeedbackTone) {
        case LSRouteToneInfo: symbol = @"info.circle"; break;
        case LSRouteToneSuccess: symbol = @"checkmark.circle.fill"; color = LSSuccessColor(); break;
        case LSRouteToneError: symbol = @"exclamationmark.triangle.fill"; color = LSErrorColor(); break;
        case LSRouteToneBusy: break;
    }
    self.routeFeedbackIcon.hidden = symbol == nil || self.routeSpinner.isAnimating;
    if (symbol) self.routeFeedbackIcon.image = [UIImage systemImageNamed:symbol];
    self.routeFeedbackIcon.tintColor = color;
    self.routeFeedback.textColor = self.routeFeedbackTone == LSRouteToneError ? LSErrorColor() : UIColor.secondaryLabelColor;
}

- (NSString *)routeHint {
    BOOL applied = LSSessionController.shared.snapshot.mode != LSSessionModeOff;
    NSString *keeps = applied ? @" The applied session continues until you replace it." : @"";
    if (self.startPin && !self.endPin) return [@"Now choose To: search above or tap the map." stringByAppendingString:keeps];
    if (!self.startPin && self.endPin) return [@"Now choose From: search above or tap the map." stringByAppendingString:keeps];
    if (applied) return @"Editing a new route. The applied session continues until you replace it.";
    if (self.fetchedRoute) return @"Route ready. Tap Start route when you’re ready.";
    return self.startPin ? @"Tap Build route to find the streets between your points." : @"Choose From and To. The route builds automatically.";
}

#pragma mark - Directions

- (void)cancelDirections {
    if (self.directions) [self setRouteFeedback:@"Route lookup canceled. Tap Build route to try again." tone:LSRouteToneInfo];
    self.routeRevision++;
    [self.directions cancel];
    self.directions = nil;
    [self.linkSearch cancel];
    self.linkSearch = nil;
    [self.routeSpinner stopAnimating];
    if (self.routeImportActive) [self abandonRouteImport:self.routeImportToken];
    [self updateRouteStatus];
    [self updateFooter];
}

- (void)invalidateRouteDraft {
    [self cancelDirections];
    [self cancelRouteDrawIn];
    [self removeRouteOverlays];
    self.routePolyline = nil;
    self.routeCasing = nil;
    self.fetchedRoute = nil;
    self.draftRecordedPace = NO;
    self.routeDraftChanged = YES;
    [self setRouteFeedback:nil tone:LSRouteToneInfo];
}

- (void)profileChanged {
    BOOL shouldRefetch = self.startPin && self.endPin;
    LSHapticSelection();
    [self invalidateRouteDraft];
    [self updateRouteUI];
    if (shouldRefetch) [self fetchRoute];
}

- (void)tryOtherPath {
    self.profileSegment.selectedSegmentIndex = self.profileSegment.selectedSegmentIndex == 1 ? 0 : 1;
    [self profileChanged];
}

- (void)fetchRoute {
    if (!self.startPin || !self.endPin || self.closed) return;
    [self cancelDirections];
    NSArray<LSRouteWaypoint *> *waypoints = [self draftWaypoints];
    for (NSUInteger index = 1; index < waypoints.count; index++) {
        CLLocation *a = [[CLLocation alloc] initWithLatitude:waypoints[index - 1].coordinate.latitude longitude:waypoints[index - 1].coordinate.longitude];
        CLLocation *b = [[CLLocation alloc] initWithLatitude:waypoints[index].coordinate.latitude longitude:waypoints[index].coordinate.longitude];
        if ([a distanceFromLocation:b] >= 10) continue;
        // MapKit answers identical endpoints with a generic failure.
        [self setRouteFeedback:waypoints.count == 2
            ? @"From and To are the same place. Move one of them to build a route."
            : [NSString stringWithFormat:@"%@ and %@ are the same place. Move or remove one of them.", [self legName:index - 1 count:waypoints.count], [self legName:index count:waypoints.count]]
                          tone:LSRouteToneError];
        LSAnnounce(self.routeFeedback.text);
        [self updateRouteUI];
        return;
    }
    [self setRouteFeedback:@"Looking up the streets. The current session keeps running." tone:LSRouteToneBusy];
    MKDirectionsTransportType transport = self.profileSegment.selectedSegmentIndex == 1 ? MKDirectionsTransportTypeAutomobile : MKDirectionsTransportTypeWalking;
    [self fetchLegs:waypoints legs:[NSMutableArray array] transport:transport revision:self.routeRevision];
    [self updateRouteUI];
}

- (NSString *)legName:(NSUInteger)index count:(NSUInteger)count {
    if (index == 0) return @"From";
    if (index + 1 == count) return @"To";
    return [NSString stringWithFormat:@"Stop %lu", (unsigned long)index];
}

// One MapKit request per leg, in order, so each stop is actually visited.
- (void)fetchLegs:(NSArray<LSRouteWaypoint *> *)waypoints legs:(NSMutableArray<MKRoute *> *)legs transport:(MKDirectionsTransportType)transport revision:(NSUInteger)revision {
    NSUInteger index = legs.count;
    if (index + 1 >= waypoints.count) { [self finishLegs:legs waypoints:waypoints]; return; }
    if (waypoints.count > 2) {
        self.routeFeedback.text = [NSString stringWithFormat:@"Looking up part %lu of %lu of the route…", (unsigned long)index + 1, (unsigned long)waypoints.count - 1];
    }
    MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
    request.source = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:waypoints[index].coordinate]];
    request.destination = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:waypoints[index + 1].coordinate]];
    request.transportType = transport;
    request.requestsAlternateRoutes = NO;
    self.directions = [self directionsForRequest:request];
    __weak typeof(self) weakSelf = self;
    [self.directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.routeRevision || self.tab != LSPickerTabRoute) return;
        self.directions = nil;
        MKRoute *leg = response.routes.firstObject;
        if (error || !leg || leg.polyline.pointCount < 2 || !isfinite(leg.distance) || leg.distance <= 0) {
            [self.routeSpinner stopAnimating];
            BOOL notFound = error.code == MKErrorDirectionsNotFound || !error;
            NSString *between = waypoints.count == 2 ? @"these points" : [NSString stringWithFormat:@"%@ and %@", [self legName:index count:waypoints.count], [self legName:index + 1 count:waypoints.count]];
            [self setRouteFeedback:notFound
                ? [NSString stringWithFormat:@"No route between %@. Try the other path type or move a point.", between]
                : (error.code == MKErrorLoadingThrottled ? @"Apple Maps is limiting requests. Wait a minute and tap Try again."
                                                         : @"Directions are unavailable right now. Check your connection and tap Try again.")
                              tone:LSRouteToneError];
            self.routeSuggestsOtherPath = notFound;
            LSAnnounce(self.routeFeedback.text);
            LSHapticWarning();
            [self updateRouteUI];
            return;
        }
        [legs addObject:leg];
        [self fetchLegs:waypoints legs:legs transport:transport revision:revision];
    }];
}

- (void)finishLegs:(NSArray<MKRoute *> *)legs waypoints:(NSArray<LSRouteWaypoint *> *)waypoints {
    [self.routeSpinner stopAnimating];
    LSRoute *route = [LSRoute routeWithLegs:legs waypoints:waypoints];
    if (!route) {
        [self setRouteFeedback:@"This route could not be built. Move a point and try again." tone:LSRouteToneError];
        [self updateRouteUI];
        return;
    }
    [self showDraftRoute:route];
    [self setRouteFeedback:LSSessionController.shared.snapshot.mode == LSSessionModeOff
        ? @"Route ready. Tap Start route when you’re ready."
        : @"Route ready. Replace the applied session to follow it."
                      tone:LSRouteToneSuccess];
    [self routeWasBuilt];
    [self updateRouteUI];
    NSTimeInterval duration = [LSRouteSimulator estimatedDurationForRoute:route options:[self draftOptions]];
    // With VoiceOver, focus moves to the new route (its distance is read there), and the
    // queued announcement adds the rest.
    UIView *summary = !self.routeTripCard.hidden ? self.routeTripRow : (!self.routeStatsWrap.hidden ? self.routeStats.firstObject : nil);
    if (UIAccessibilityIsVoiceOverRunning() && summary.window) {
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, summary);
        LSAnnounce([NSString stringWithFormat:@"Route ready, about %@.", LSTimeText(duration, YES)]);
    } else {
        LSAnnounce([NSString stringWithFormat:@"Route ready. %@, about %@.", LSSpokenDistance(route.distance), LSTimeText(duration, YES)]);
    }
}

// The first route teaches the rest, so the path-versus-speed tip goes away.
- (void)routeWasBuilt {
    LSHapticImpact(UIImpactFeedbackStyleLight);
    if (ls_routeExplained && !self.routeTip) return;
    ls_routeExplained = YES;
    if (self.routeTip) LSSetHidden(self.routeTip, YES, self.view.window != nil);
}

- (void)showDraftRoute:(LSRoute *)route {
    [self cancelRouteDrawIn];
    [self removeRouteOverlays];
    self.fetchedRoute = route;
    self.routePolyline = route.polyline;
    self.routeCasing = [MKPolyline polylineWithPoints:route.polyline.points count:route.polyline.pointCount];
    BOOL drawIn = LSMapAnimationsEnabled() && self.mapView.window && !self.mapView.hidden && self.tab == LSPickerTabRoute;
    // Set before the overlays are added, so their renderers start hidden for the draw-in.
    self.routeDrawInPending = drawIn;
    [self addRouteOverlays];
    [self focusMapOnRect:self.routePolyline.boundingMapRect animated:LSMapAnimationsEnabled()];
    if (drawIn) [self waitToDrawRoute:self.routeDrawRevision attempt:0 lastRect:MKMapRectNull];
}

- (MKDirections *)directionsForRequest:(MKDirectionsRequest *)request {
    return [[MKDirections alloc] initWithRequest:request];
}

#pragma mark - Route overlays

- (void)addRouteOverlays {
    MKMapView *map = self.mapView;
    if (!self.routePolyline || !map) return;
    if (![map.overlays containsObject:self.routePolyline]) [map addOverlay:self.routePolyline];
    [self syncRouteCasing];
}

- (void)removeRouteOverlays {
    if (self.routePolyline) [self.mapView removeOverlay:self.routePolyline];
    if (self.routeCasing) [self.mapView removeOverlay:self.routeCasing];
}

// The shell shows and hides the route line per tab and after a map retry; the outline follows it.
- (void)syncRouteCasing {
    MKMapView *map = self.mapView;
    MKPolyline *casing = self.routeCasing;
    if (!casing || !map) return;
    NSArray *overlays = map.overlays;
    BOOL lineShown = self.routePolyline && [overlays containsObject:self.routePolyline];
    BOOL casingShown = [overlays containsObject:casing];
    if (lineShown && !casingShown) [map insertOverlay:casing belowOverlay:self.routePolyline];
    else if (!lineShown && casingShown) [map removeOverlay:casing];
}

- (void)restyleRouteOverlays {
    UITraitCollection *traits = self.mapView.traitCollection;
    if ([self.routeLineRenderer isKindOfClass:LSRouteLineRenderer.class]) {
        LSRouteLineRenderer *line = (LSRouteLineRenderer *)self.routeLineRenderer;
        line.lineWidth = LSRouteLineWidth();
        [line applyTraveled:line.traveled traits:traits];
        [line setNeedsDisplay];
    }
    if ([self.routeCasingRenderer isKindOfClass:LSRouteCasingRenderer.class]) {
        LSRouteCasingRenderer *casing = (LSRouteCasingRenderer *)self.routeCasingRenderer;
        casing.lineWidth = LSRouteLineWidth() + 4;
        [casing applyTraits:traits];
        [casing setNeedsDisplay];
    }
}

// How far along the drawn route the applied playback is, in the polyline's own length measure.
- (double)traveledLocation {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    LSRoute *route = self.fetchedRoute;
    if (!route || self.routeDraftChanged || engine.route != route || route.polyline != self.routePolyline || route.pointCount < 2) return 0;
    double total = route.distance;
    BOOL complete = engine.totalDistance > 0 && engine.distanceCovered >= engine.totalDistance;
    if (complete) return 1;
    if (!engine.isSimulating || !(total > 0)) return 0;
    double covered = MIN(total, MAX(0, engine.distanceCovered));
    const double *cumulative = route.cumulativeDistances;
    NSUInteger low = 0, high = route.pointCount - 1;
    while (high - low > 1) {
        NSUInteger middle = (low + high) / 2;
        if (cumulative[middle] <= covered) low = middle; else high = middle;
    }
    double span = cumulative[high] - cumulative[low];
    double t = span > 0 ? MIN(1, MAX(0, (covered - cumulative[low]) / span)) : 0;
    MKPolyline *polyline = self.routePolyline;
    CGFloat a = [polyline locationAtPointIndex:low], b = [polyline locationAtPointIndex:high];
    double location = a + (b - a) * t;
    return isfinite(location) ? MIN(1, MAX(0, location)) : 0;
}

- (void)updateRouteTraveled:(BOOL)force {
    if (![self.routeLineRenderer isKindOfClass:LSRouteLineRenderer.class]) return;
    LSRouteLineRenderer *renderer = (LSRouteLineRenderer *)self.routeLineRenderer;
    double location = [self traveledLocation];
    if (fabs(location - self.routeTraveledShown) < 1e-5) return;
    // Redrawing the overlay is the costly part, so it trails the marker about once a second;
    // starting, finishing and resets apply at once.
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL jump = (location <= 0) != (self.routeTraveledShown <= 0) || location >= 1 || location < self.routeTraveledShown;
    if (!force && !jump && now - self.routeTraveledAt < 1.0) return;
    self.routeTraveledShown = location;
    self.routeTraveledAt = now;
    [renderer applyTraveled:location traits:self.mapView.traitCollection];
    [renderer setNeedsDisplay];
}

#pragma mark - Draw-in

- (void)cancelRouteDrawIn {
    self.routeDrawRevision++;
    self.routeDrawInPending = NO;
    [self.routeTraceView removeFromSuperview];
    self.routeTraceView = nil;
    [self revealRouteOverlays];
    [self stopWatchingMapGestures];
    // Markers held back for the draw-in come back at once, as they were.
    NSArray<MKAnnotationView *> *markers = self.routeHiddenMarkers;
    NSArray<NSNumber *> *alphas = self.routeHiddenMarkerAlphas;
    self.routeHiddenMarkers = nil;
    self.routeHiddenMarkerAlphas = nil;
    [markers enumerateObjectsUsingBlock:^(MKAnnotationView *view, NSUInteger index, __unused BOOL *stop) {
        view.alpha = index < alphas.count ? (CGFloat)alphas[index].doubleValue : 1;
        view.transform = CGAffineTransformIdentity;
    }];
}

// The trace is drawn in screen points and cannot follow a moving map, so a pan, pinch or
// rotation ends the draw-in at once. The relay rides on each recognizer, so it can never
// outlive one that still points at it.
- (void)watchMapGesturesForDrawIn {
    [self stopWatchingMapGestures];
    MKMapView *map = self.mapView;
    if (!map) return;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:map];
    for (UIView *child in map.subviews) {
        [views addObject:child];
        [views addObjectsFromArray:child.subviews];
    }
    LSRouteGestureRelay *relay = [[LSRouteGestureRelay alloc] init];
    __weak typeof(self) weakSelf = self;
    relay.moved = ^{ [weakSelf mapMovedDuringDrawIn]; };
    NSMutableArray<UIGestureRecognizer *> *watched = [NSMutableArray array];
    for (UIView *view in views) {
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            BOOL moves = [gesture isKindOfClass:UIPanGestureRecognizer.class] || [gesture isKindOfClass:UIPinchGestureRecognizer.class] ||
                         [gesture isKindOfClass:UIRotationGestureRecognizer.class] ||
                         ([gesture isKindOfClass:UITapGestureRecognizer.class] && (((UITapGestureRecognizer *)gesture).numberOfTapsRequired >= 2 ||
                                                                                       ((UITapGestureRecognizer *)gesture).numberOfTouchesRequired >= 2));
            if (!moves || [watched containsObject:gesture]) continue;
            [gesture addTarget:relay action:@selector(fire:)];
            objc_setAssociatedObject(gesture, &ls_routeRelayKey, relay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [watched addObject:gesture];
        }
    }
    self.routeDrawGestures = watched;
}

- (void)stopWatchingMapGestures {
    for (UIGestureRecognizer *gesture in self.routeDrawGestures) {
        id relay = objc_getAssociatedObject(gesture, &ls_routeRelayKey);
        if (relay) [gesture removeTarget:relay action:@selector(fire:)];
        objc_setAssociatedObject(gesture, &ls_routeRelayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self.routeDrawGestures = nil;
}

- (void)mapMovedDuringDrawIn {
    UIView *trace = self.routeTraceView;
    if (!trace) return;
    self.routeTraceView = nil;
    // A quick fade rather than a cut, short enough that the drift under the finger stays small.
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ trace.alpha = 0; }
                     completion:^(__unused BOOL finished) { [trace removeFromSuperview]; }];
    [self finishRouteDrawIn:self.routeDrawRevision];
}

// From, the stops in order, then To: the order they land in after the draw-in.
- (NSArray<MKAnnotationView *> *)routeMarkerViews {
    NSMutableArray<id<MKAnnotation>> *pins = [NSMutableArray array];
    if (self.startPin) [pins addObject:self.startPin];
    [pins addObjectsFromArray:self.routeStops];
    if (self.endPin) [pins addObject:self.endPin];
    NSMutableArray<MKAnnotationView *> *views = [NSMutableArray array];
    for (id<MKAnnotation> pin in pins) {
        MKAnnotationView *view = [self.mapView viewForAnnotation:pin];
        if (view.window && !view.hidden) [views addObject:view];
    }
    return views;
}

- (void)revealRouteOverlays {
    for (MKOverlayRenderer *renderer in @[self.routeLineRenderer ?: (id)NSNull.null, self.routeCasingRenderer ?: (id)NSNull.null]) {
        if (![renderer isKindOfClass:MKOverlayRenderer.class] || renderer.alpha >= 1) continue;
        renderer.alpha = 1;
        [renderer setNeedsDisplay];
    }
}

// Waits for the camera move to the new route to settle (the visible rect stops changing),
// then traces the route on screen. Gives up and simply shows it after about 1.5 s.
- (void)waitToDrawRoute:(NSUInteger)revision attempt:(NSUInteger)attempt lastRect:(MKMapRect)last {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || revision != self.routeDrawRevision) return;
        MKMapRect rect = self.mapView.visibleMapRect;
        if (attempt > 0 && MKMapRectEqualToRect(rect, last)) { [self drawRouteIn:revision]; return; }
        if (attempt >= 10) { [self finishRouteDrawIn:revision]; return; }
        [self waitToDrawRoute:revision attempt:attempt + 1 lastRect:rect];
    });
}

// The route draws itself from From to To with a bright head, on Core Animation layers between
// the map and its markers; the real overlay appears underneath as the trace fades, and the
// markers then land one after another.
- (void)drawRouteIn:(NSUInteger)revision {
    MKMapView *map = self.mapView;
    MKPolyline *polyline = self.routePolyline;
    CGFloat length = 0;
    UIBezierPath *path = polyline && map.window && !map.hidden && self.tab == LSPickerTabRoute ? LSTracePath(map, polyline, &length) : nil;
    if (!path) { [self finishRouteDrawIn:revision]; return; }
    UITraitCollection *traits = map.traitCollection;
    UIView *trace = [[UIView alloc] initWithFrame:map.bounds];
    trace.userInteractionEnabled = NO;
    trace.accessibilityElementsHidden = YES;
    trace.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAShapeLayer *casing = LSTraceLayer(path, [LSRouteCasingColor() resolvedColorWithTraitCollection:traits], LSRouteLineWidth() + 4);
    CAShapeLayer *line = LSTraceLayer(path, [LSRouteColor() resolvedColorWithTraitCollection:traits], LSRouteLineWidth());
    UIColor *routeColor = [LSRouteColor() resolvedColorWithTraitCollection:traits];
    CALayer *head = [CALayer layer];
    head.bounds = CGRectMake(0, 0, 14, 14);
    head.cornerRadius = 7;
    head.backgroundColor = UIColor.whiteColor.CGColor;
    head.borderColor = routeColor.CGColor;
    head.borderWidth = 3;
    head.shadowColor = routeColor.CGColor;
    head.shadowOpacity = 0.6;
    head.shadowRadius = 6;
    head.shadowOffset = CGSizeZero;
    head.shadowPath = [UIBezierPath bezierPathWithOvalInRect:head.bounds].CGPath;
    head.position = path.currentPoint;
    [trace.layer addSublayer:casing];
    [trace.layer addSublayer:line];
    [trace.layer addSublayer:head];
    // Below the view that holds the markers, so the trace never paints over a pin; when that
    // view cannot be found the trace goes on top, with the markers hidden until it is done.
    // Only directly under the map (or one level down) and untransformed, where map points and
    // the host's points line up.
    NSArray<MKAnnotationView *> *markers = [self routeMarkerViews];
    UIView *markerHost = markers.firstObject.superview;
    UIView *hostParent = markerHost.superview;
    BOOL placeable = markerHost && markerHost != map && hostParent && (hostParent == map || hostParent.superview == map) &&
                     CGAffineTransformIsIdentity(markerHost.transform) && CGAffineTransformIsIdentity(hostParent.transform);
    if (placeable) {
        trace.frame = [map convertRect:map.bounds toView:hostParent];
        [hostParent insertSubview:trace belowSubview:markerHost];
    } else {
        [map addSubview:trace];
    }
    self.routeTraceView = trace;
    [self watchMapGesturesForDrawIn];
    // The markers land after the line. Not with VoiceOver, where hiding a pin would lose its
    // focus, and not ones MapKit has already faded out to avoid a collision.
    NSMutableArray<MKAnnotationView *> *hidden = [NSMutableArray array];
    NSMutableArray<NSNumber *> *alphas = [NSMutableArray array];
    if (!UIAccessibilityIsVoiceOverRunning()) {
        for (MKAnnotationView *view in markers) {
            if (view.alpha < 0.01) continue;
            [hidden addObject:view];
            [alphas addObject:@(view.alpha)];
            view.alpha = 0;
            view.transform = CGAffineTransformMakeScale(0.5, 0.5);
        }
    }
    self.routeHiddenMarkers = hidden;
    self.routeHiddenMarkerAlphas = alphas;
    NSTimeInterval duration = MIN(0.9, MAX(0.5, length / 1000.0));
    CAMediaTimingFunction *timing = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    __weak typeof(self) weakSelf = self;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [weakSelf finishRouteDrawIn:revision]; }];
    CABasicAnimation *draw = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    draw.fromValue = @0;
    draw.toValue = @1;
    draw.duration = duration;
    draw.timingFunction = timing;
    [casing addAnimation:draw forKey:@"draw"];
    [line addAnimation:draw forKey:@"draw"];
    CAKeyframeAnimation *move = [CAKeyframeAnimation animationWithKeyPath:@"position"];
    move.path = path.CGPath;
    move.calculationMode = kCAAnimationPaced;
    move.duration = duration;
    move.timingFunction = timing;
    [head addAnimation:move forKey:@"move"];
    [CATransaction commit];
    // Backstop in case the animation never reports back; finishing twice is harmless.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 1.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf finishRouteDrawIn:revision];
    });
}

- (void)finishRouteDrawIn:(NSUInteger)revision {
    if (revision != self.routeDrawRevision) return;
    self.routeDrawInPending = NO;
    [self revealRouteOverlays];
    [self stopWatchingMapGestures];
    UIView *trace = self.routeTraceView;
    self.routeTraceView = nil;
    if (trace) {
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ trace.alpha = 0; }
                         completion:^(__unused BOOL finished) { [trace removeFromSuperview]; }];
    }
    // The markers spring in 60 ms apart, From first and To last.
    NSArray<MKAnnotationView *> *markers = self.routeHiddenMarkers;
    NSArray<NSNumber *> *alphas = self.routeHiddenMarkerAlphas;
    self.routeHiddenMarkers = nil;
    self.routeHiddenMarkerAlphas = nil;
    if (!markers.count) return;
    LSHapticPinDrop();
    __weak typeof(self) weakSelf = self;
    [markers enumerateObjectsUsingBlock:^(MKAnnotationView *view, NSUInteger index, __unused BOOL *stop) {
        CGFloat alpha = index < alphas.count ? (CGFloat)alphas[index].doubleValue : 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(index * 0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // A newer draw-in may have hidden this marker again in the meantime.
            if ([weakSelf.routeHiddenMarkers containsObject:view]) return;
            LSAnimateBouncy(^{
                view.alpha = alpha;
                view.transform = CGAffineTransformIdentity;
            }, nil);
        });
    }];
}

#pragma mark - Options

- (LSPlaybackOptions *)draftOptions {
    LSPlaybackOptions *options = [LSPlaybackOptions optionsWithSpeedKmh:self.draftSpeedKmh];
    PersistenceManager *store = PersistenceManager.shared;
    options.smooth = store.smoothMotion;
    options.accelerationProfile = (LSAccelerationProfile)store.accelerationProfile;
    options.stopDwell = store.stopDwell;
    options.recordedPace = self.draftRecordedPace && self.fetchedRoute.hasTiming;
    options.paceMultiplier = isfinite(self.draftPaceMultiplier) && self.draftPaceMultiplier >= 0.1 ? self.draftPaceMultiplier : 1;
    return options.isValid ? options : [LSPlaybackOptions optionsWithSpeedKmh:5];
}

- (BOOL)isPlayingDraft {
    return !self.routeDraftChanged && self.fetchedRoute && self.fetchedRoute == LSSessionController.shared.retainedRoute && LSRouteSimulator.shared.isSimulating;
}

- (void)optionsChanged:(NSString *)message {
    if ([self isPlayingDraft]) {
        [LSSessionController.shared updatePlaybackOptions:[self draftOptions]];
        if (message) [self setRouteFeedback:message tone:LSRouteToneInfo];
    }
    [self updateRouteUI];
}

- (UIMenu *)motionMenu {
    PersistenceManager *store = PersistenceManager.shared;
    __weak typeof(self) weakSelf = self;
    UIAction *steady = [UIAction actionWithTitle:@"Steady speed" image:[UIImage systemImageNamed:@"equal"] identifier:nil handler:^(__unused UIAction *action) {
        PersistenceManager.shared.smoothMotion = NO;
        [weakSelf optionsChanged:@"Motion updated: steady speed."];
    }];
    steady.subtitle = @"Moves at the set speed the whole way";
    steady.state = store.smoothMotion ? UIMenuElementStateOff : UIMenuElementStateOn;
    NSMutableArray *styles = [NSMutableArray arrayWithObject:steady];
    NSArray *names = @[@"Smooth · Gentle", @"Smooth · Normal", @"Smooth · Sporty"];
    NSArray *details = @[@"Eases off early, like a careful driver", @"Speeds up, brakes and slows for turns", @"Quicker starts and later braking"];
    for (NSInteger profile = 0; profile < 3; profile++) {
        UIAction *action = [UIAction actionWithTitle:names[profile] image:nil identifier:nil handler:^(__unused UIAction *item) {
            PersistenceManager.shared.smoothMotion = YES;
            PersistenceManager.shared.accelerationProfile = profile;
            [weakSelf optionsChanged:@"Motion updated."];
        }];
        action.subtitle = details[profile];
        action.state = store.smoothMotion && store.accelerationProfile == profile ? UIMenuElementStateOn : UIMenuElementStateOff;
        [styles addObject:action];
    }
    return [UIMenu menuWithTitle:@"Motion" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:styles];
}

- (UIMenu *)waitMenu {
    double current = PersistenceManager.shared.stopDwell;
    __weak typeof(self) weakSelf = self;
    NSMutableArray *items = [NSMutableArray array];
    BOOL matched = NO;
    for (NSNumber *value in @[@0, @15, @30, @60, @120, @300]) {
        double seconds = value.doubleValue;
        UIAction *action = [UIAction actionWithTitle:seconds > 0 ? LSWaitText(seconds) : @"Don't wait" image:nil identifier:nil handler:^(__unused UIAction *item) {
            [weakSelf setStopWait:seconds];
        }];
        if (fabs(current - seconds) < 0.5) { action.state = UIMenuElementStateOn; matched = YES; }
        [items addObject:action];
    }
    UIAction *custom = [UIAction actionWithTitle:matched ? @"Custom…" : [NSString stringWithFormat:@"Custom (%@)…", LSWaitText(current)] image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(__unused UIAction *item) {
        [weakSelf enterCustomWait];
    }];
    if (!matched) custom.state = UIMenuElementStateOn;
    [items addObject:custom];
    return [UIMenu menuWithTitle:@"Wait at each stop" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:items];
}

- (void)setStopWait:(double)seconds {
    if (!isfinite(seconds) || seconds < 0 || seconds > 3600) return;
    PersistenceManager.shared.stopDwell = seconds;
    [self optionsChanged:@"Wait at stops updated."];
}

// The confirm button follows the typed value, and the message says what is allowed.
- (void)validateAlert:(UIAlertController *)alert action:(UIAlertAction *)save valid:(BOOL (^)(NSNumber *number))valid help:(NSString *)help error:(NSString *)error {
    __weak UIAlertController *weakAlert = alert;
    __weak UIAlertAction *weakSave = save;
    void (^check)(void) = ^{
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        BOOL ok = number && valid(number);
        weakSave.enabled = ok;
        weakAlert.message = ok ? help : error;
    };
    [alert.textFields.firstObject addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { check(); }] forControlEvents:UIControlEventEditingChanged];
    check();
}

- (void)enterCustomWait {
    NSString *help = @"Enter minutes, from 0 to 60. Decimals are fine, like 1.5.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Wait at each stop" message:help preferredStyle:UIAlertControllerStyleAlert];
    double current = PersistenceManager.shared.stopDwell / 60.0;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = LSFormatDecimal(current, 1);
        field.placeholder = @"minutes";
        field.accessibilityLabel = @"Wait in minutes";
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Set wait" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        if (number && number.doubleValue >= 0 && number.doubleValue <= 60) [weakSelf setStopWait:round(number.doubleValue * 60)];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self validateAlert:alert action:save valid:^BOOL(NSNumber *number) { return number.doubleValue >= 0 && number.doubleValue <= 60; }
                   help:help error:@"Enter a number of minutes from 0 to 60."];
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

#pragma mark - Finish in

- (UIMenu *)finishMenu {
    LSRoute *route = self.fetchedRoute;
    __weak typeof(self) weakSelf = self;
    NSMutableArray *items = [NSMutableArray array];
    if (route.expectedTravelTime > 60 && !route.fromTrack) {
        NSTimeInterval eta = route.expectedTravelTime;
        UIAction *match = [UIAction actionWithTitle:[NSString stringWithFormat:@"Match Apple Maps (%@)", LSDuration(eta)] image:[UIImage systemImageNamed:@"applelogo"] identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf finishIn:eta];
        }];
        match.subtitle = @"Apple's arrival estimate for this route";
        [items addObject:match];
    }
    if (route.hasTiming) {
        NSTimeInterval recorded = route.recordedDuration;
        UIAction *original = [UIAction actionWithTitle:[NSString stringWithFormat:@"As recorded (%@)", LSDuration(recorded)] image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(__unused UIAction *action) {
            typeof(self) self = weakSelf;
            self.draftRecordedPace = YES;
            self.draftPaceMultiplier = 1;
            [self optionsChanged:@"Playing at the recorded pace."];
        }];
        [items addObject:original];
    }
    UIAction *custom = [UIAction actionWithTitle:@"Finish in…" image:[UIImage systemImageNamed:@"timer"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf enterFinishTime]; }];
    custom.subtitle = @"Type the minutes another app shows, such as Google Maps or Waze";
    [items addObject:custom];
    return [UIMenu menuWithTitle:@"Arrive on time" children:items];
}

- (void)enterFinishTime {
    NSString *help = @"Enter the trip time in minutes, up to 30 days (43,200 minutes). Waits at stops are included.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Finish in" message:help preferredStyle:UIAlertControllerStyleAlert];
    LSPlaybackOptions *options = [self draftOptions];
    double current = self.fetchedRoute ? [LSRouteSimulator estimatedDurationForRoute:self.fetchedRoute options:options] / 60.0 : 15;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = isfinite(current) ? LSFormatDecimal(MAX(1, round(current)), 0) : @"";
        field.placeholder = @"minutes";
        field.accessibilityLabel = @"Trip time in minutes";
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Set speed" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        if (number && number.doubleValue > 0 && number.doubleValue <= kLSLongestTripMinutes) [weakSelf finishIn:number.doubleValue * 60];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self validateAlert:alert action:save valid:^BOOL(NSNumber *number) { return number.doubleValue > 0 && number.doubleValue <= kLSLongestTripMinutes; }
                   help:help error:@"Enter a trip time longer than 0 minutes and no more than 30 days (43,200 minutes)."];
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)finishIn:(NSTimeInterval)seconds {
    LSRoute *route = self.fetchedRoute;
    if (!route || !isfinite(seconds) || seconds <= 0) return;
    LSPlaybackOptions *options = [self draftOptions];
    if (options.recordedPace) {
        // Recorded timing (pauses included) scales with the multiplier.
        options.paceMultiplier = 1;
        double base = [LSRouteSimulator estimatedDurationForRoute:route options:options];
        double multiplier = base / seconds;
        if (!isfinite(multiplier) || multiplier < 0.1 || multiplier > 20) {
            [self showMessage:@"That time is out of range for the recorded pace (0.1× to 20×)." symbol:@"exclamationmark.triangle.fill"];
            LSHapticWarning();
            return;
        }
        self.draftPaceMultiplier = multiplier;
        NSString *message = [NSString stringWithFormat:@"Recorded pace ×%@ to finish in %@.", LSFormatDecimal(multiplier, 2), LSDuration(seconds)];
        [self setRouteFeedback:message tone:LSRouteToneSuccess];
        [self optionsChanged:message];
        LSAnnounce(message);
        return;
    }
    double kmh = [LSRouteSimulator speedKmhForRoute:route options:options finishingIn:seconds];
    if (!isfinite(kmh)) {
        [self showMessage:@"No speed from 1 to 500 km/h finishes in that time. Shorten the waits or pick another time." symbol:@"exclamationmark.triangle.fill"];
        LSHapticWarning();
        return;
    }
    self.draftSpeedKmh = round(kmh * 10) / 10;
    self.draftRecordedPace = NO;
    LSHapticSelection();
    NSString *message = [NSString stringWithFormat:@"Speed set to %@ km/h to finish in %@.", LSFormatDecimal(self.draftSpeedKmh, 1), LSDuration(seconds)];
    [self setRouteFeedback:message tone:LSRouteToneSuccess];
    [self optionsChanged:message];
    LSAnnounce(message);
}

#pragma mark - Share and export

- (NSString *)linkMode {
    if (LSModeForSpeed(self.draftSpeedKmh) == LSTransportModeCycling) return @"cycling";
    MKDirectionsTransportType type = self.fetchedRoute ? self.fetchedRoute.transportType
        : (self.profileSegment.selectedSegmentIndex == 1 ? MKDirectionsTransportTypeAutomobile : MKDirectionsTransportTypeWalking);
    return type == MKDirectionsTransportTypeWalking ? @"walking" : @"driving";
}

- (NSArray<LSMapLinkPlace *> *)linkPlaces {
    NSArray<LSRouteWaypoint *> *waypoints = self.fetchedRoute.waypoints.count >= 2 ? self.fetchedRoute.waypoints : [self draftWaypoints];
    NSMutableArray *places = [NSMutableArray array];
    for (LSRouteWaypoint *waypoint in waypoints) {
        NSString *name = [@[@"Map point", @"Track start", @"Track end", @"Start", @"End"] containsObject:waypoint.name] ? nil : waypoint.name;
        [places addObject:[LSMapLinkPlace placeWithLatitude:waypoint.coordinate.latitude longitude:waypoint.coordinate.longitude name:name]];
    }
    return places;
}

- (UIMenu *)shareMenu {
    __weak typeof(self) weakSelf = self;
    NSArray<LSMapLinkPlace *> *places = [self linkPlaces];
    // @available needs a compiler-rt helper the Linux toolchain doesn't ship.
    BOOL modernApple = [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){18, 4, 0}];
    BOOL legacyApple = !modernApple && places.count <= 2;
    NSMutableArray *links = [NSMutableArray array];
    NSArray *apps = @[@(LSMapAppApple), @(LSMapAppGoogle), @(LSMapAppWaze)];
    NSArray *titles = @[@"Apple Maps link", @"Google Maps link", @"Waze link"];
    NSArray *symbols = @[@"map", @"globe", @"car"];
    for (NSUInteger index = 0; index < apps.count; index++) {
        LSMapApp app = (LSMapApp)[apps[index] integerValue];
        NSUInteger limit = [LSMapLinks maximumPlacesForApp:app legacyApple:legacyApple];
        UIAction *action = [UIAction actionWithTitle:titles[index] image:[UIImage systemImageNamed:symbols[index]] identifier:nil handler:^(__unused UIAction *item) {
            typeof(self) self = weakSelf;
            NSURL *url = [LSMapLinks URLForApp:app places:[self linkPlaces] mode:[self linkMode] legacyApple:legacyApple];
            if (url) [self presentShareItems:@[url] from:self.shareButton];
        }];
        if (app == LSMapAppWaze) action.subtitle = @"Destination only; Waze starts where you are";
        else if (places.count > limit) action.subtitle = [NSString stringWithFormat:@"Keeps the first %lu stops", (unsigned long)(limit - 2)];
        [links addObject:action];
    }
    UIMenu *linkMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:links];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *format in @[@"GPX", @"TCX", @"FIT"]) {
        UIAction *action = [UIAction actionWithTitle:[NSString stringWithFormat:@"Export %@ file", format] image:[UIImage systemImageNamed:@"doc.badge.arrow.up"] identifier:nil handler:^(__unused UIAction *item) {
            [weakSelf exportRouteAs:format];
        }];
        [files addObject:action];
    }
    ((UIAction *)files[0]).subtitle = @"Works with most map and fitness apps";
    ((UIAction *)files[2]).subtitle = @"Garmin and Strava activity, timed at the playback speed";
    UIMenu *fileMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:files];
    if (!self.fetchedRoute) for (UIAction *action in files) action.attributes = UIMenuElementAttributesDisabled;
    return [UIMenu menuWithTitle:@"Share route" children:@[linkMenu, fileMenu]];
}

// Sampling a long trip and writing the file runs off the main thread.
- (void)exportRouteAs:(NSString *)format {
    LSRoute *route = self.fetchedRoute;
    if (!route) return;
    LSPlaybackOptions *options = [self draftOptions];
    double altitude = PersistenceManager.shared.altitude;
    NSUInteger revision = ++self.routeExportRevision;
    [self.routeSpinner startAnimating];
    [self setRouteFeedback:[NSString stringWithFormat:@"Preparing the %@ file…", format] tone:LSRouteToneBusy];
    [self updateRouteStatus];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *file = LSExportRoute(route, options, format, altitude);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.closed || revision != self.routeExportRevision) return;
            [self.routeSpinner stopAnimating];
            if (!file) {
                [self setRouteFeedback:@"The route could not be exported." tone:LSRouteToneError];
                [self showMessage:@"The route could not be exported." symbol:@"exclamationmark.triangle.fill"];
                LSHapticWarning();
                [self updateRouteStatus];
                return;
            }
            [self setRouteFeedback:[NSString stringWithFormat:@"%@ file ready to share.", format] tone:LSRouteToneSuccess];
            [self updateRouteStatus];
            [self presentShareItems:@[file] from:self.shareButton];
        });
    });
}

#pragma mark - Import

- (UIMenu *)importMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *paste = [UIAction actionWithTitle:@"Paste map link" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(__unused UIAction *action) {
        typeof(self) self = weakSelf;
        NSString *text = UIPasteboard.generalPasteboard.hasStrings ? UIPasteboard.generalPasteboard.string : nil;
        if (text.length && [LSMapLinks firstMapLinkInText:text]) [self importMapLinkText:text];
        else [self enterMapLink];
    }];
    paste.subtitle = @"Apple Maps, Google Maps or Waze, including short links";
    UIAction *type = [UIAction actionWithTitle:@"Type or paste a link…" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf enterMapLink];
    }];
    UIAction *file = [UIAction actionWithTitle:@"Open GPX, TCX or FIT file…" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf openTrackFile];
    }];
    file.subtitle = @"Replay a recorded trip, at its own pace if it has times";
    return [UIMenu menuWithTitle:@"Import a route" children:@[paste, type, file]];
}

- (void)enterMapLink {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Map link" message:@"Paste a link shared from Apple Maps, Google Maps or Waze." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.placeholder = @"https://maps.app.goo.gl/…";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *open = [UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf importMapLinkText:weakAlert.textFields.firstObject.text ?: @""];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:open];
    alert.preferredAction = open;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)setImportStatus:(NSString *)text error:(BOOL)error busy:(BOOL)busy {
    self.routeImportActive = busy;
    if (busy) [self.routeSpinner startAnimating]; else [self.routeSpinner stopAnimating];
    [self setRouteFeedback:text tone:error ? LSRouteToneError : (busy ? LSRouteToneBusy : LSRouteToneInfo)];
    [self updateRouteStatus];
    if (self.tab != LSPickerTabRoute || error) [self showMessage:text symbol:error ? @"exclamationmark.triangle.fill" : @"link"];
    if (!busy) LSAnnounce(text);
}

// Whether a returning import result still applies. One that something newer replaced (a map
// tap, a tab switch, another import) clears its busy status instead of leaving it behind.
- (BOOL)routeImportCurrent:(NSUInteger)token revision:(NSUInteger)revision {
    if (self.closed) return NO;
    if (revision != self.selectionRevision) { [self abandonRouteImport:token]; return NO; }
    return self.routeImportActive && token == self.routeImportToken;
}

- (void)abandonRouteImport:(NSUInteger)token {
    if (self.closed || !self.routeImportActive || token != self.routeImportToken) return;
    self.routeImportActive = NO;
    [self.routeSpinner stopAnimating];
    [self setRouteFeedback:@"Import cancelled. Try it again when you’re ready." tone:LSRouteToneInfo];
    [self updateRouteStatus];
}

- (void)importMapLinkText:(NSString *)text {
    NSURL *url = [LSMapLinks firstMapLinkInText:text];
    if (!url) {
        [self setImportStatus:@"No Apple Maps, Google Maps or Waze link found." error:YES busy:NO];
        LSHapticWarning();
        return;
    }
    NSUInteger revision = ++self.selectionRevision;
    NSUInteger token = ++self.routeImportToken;
    if (![LSMapLinks needsResolving:url]) { [self importMapLink:[LSMapLinks parseURL:url] revision:revision]; return; }
    [self setImportStatus:@"Opening the link…" error:NO busy:YES];
    __weak typeof(self) weakSelf = self;
    [LSMapLinks resolveURL:url completion:^(NSURL *resolved, NSString *html) {
        typeof(self) self = weakSelf;
        if (![self routeImportCurrent:token revision:revision]) return;
        LSMapLink *link = resolved ? [LSMapLinks parseURL:resolved] : nil;
        if (!link && html) {
            // Apple place links with only a place id name their coordinate in the page.
            LSMapLinkPlace *place = [LSMapLinks placeFromHTML:html];
            if (place) {
                self.routeImportActive = NO;
                [self.routeSpinner stopAnimating];
                [self useLinkPlace:[LSRouteWaypoint waypointWithName:place.name coordinate:CLLocationCoordinate2DMake(place.latitude, place.longitude)]];
                return;
            }
        }
        if (!link) {
            [self setImportStatus:resolved ? @"That link doesn't name a place LSpoof can read." : @"The link could not be opened. Check your connection and try again." error:YES busy:NO];
            LSHapticWarning();
            return;
        }
        [self importMapLink:link revision:revision];
    }];
}

- (void)importMapLink:(LSMapLink *)link revision:(NSUInteger)revision {
    if (!link.places.count) {
        [self setImportStatus:@"That link doesn't name a place LSpoof can read." error:YES busy:NO];
        LSHapticWarning();
        return;
    }
    [self setImportStatus:@"Finding the places in the link…" error:NO busy:YES];
    NSUInteger token = self.routeImportToken;
    __weak typeof(self) weakSelf = self;
    [self locateLinkPlaces:link.places index:0 found:[NSMutableArray array] revision:revision completion:^(NSArray<LSRouteWaypoint *> *waypoints, NSString *failure) {
        typeof(self) self = weakSelf;
        if (![self routeImportCurrent:token revision:revision]) return;
        if (failure || !waypoints.count) { [self setImportStatus:failure ?: @"The places in the link could not be found." error:YES busy:NO]; LSHapticWarning(); return; }
        self.routeImportActive = NO;
        [self.routeSpinner stopAnimating];
        if (!link.isDirections) [self useLinkPlace:waypoints.firstObject];
        else [self useLinkWaypoints:waypoints link:link];
    }];
}

// A link to one place: an endpoint on the Route tab, otherwise a location to preview.
- (void)useLinkPlace:(LSRouteWaypoint *)place {
    if (!place) return;
    if (self.tab == LSPickerTabRoute) {
        [self assignEndpoint:self.endpoint coordinate:place.coordinate name:place.name];
        [self setImportStatus:[NSString stringWithFormat:@"Imported “%@”.", place.name] error:NO busy:NO];
    } else {
        self.tab = LSPickerTabLocation;
        [self updateWorkspace];
        [self setSelection:place.coordinate name:place.name];
        [self focusMapOnCoordinate:place.coordinate meters:2000 animated:LSMapAnimationsEnabled()];
        [self showMessage:[NSString stringWithFormat:@"Imported “%@”. Apply it when you’re ready.", place.name] symbol:@"link"];
    }
    LSHapticSuccess();
}

// Looks up text places one at a time, near where the link's map was looking.
- (void)locateLinkPlaces:(NSArray<LSMapLinkPlace *> *)places index:(NSUInteger)index found:(NSMutableArray<LSRouteWaypoint *> *)found
                revision:(NSUInteger)revision completion:(void (^)(NSArray<LSRouteWaypoint *> *, NSString *))completion {
    if (index >= places.count) { completion(found, nil); return; }
    LSMapLinkPlace *place = places[index];
    if (place.hasCoordinate) {
        [found addObject:[LSRouteWaypoint waypointWithName:place.name coordinate:CLLocationCoordinate2DMake(place.latitude, place.longitude)]];
        [self locateLinkPlaces:places index:index + 1 found:found revision:revision completion:completion];
        return;
    }
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = place.query;
    if (place.hasHint) request.region = MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2DMake(place.hintLatitude, place.hintLongitude), 30000, 30000);
    else if (found.count) request.region = MKCoordinateRegionMakeWithDistance(found.lastObject.coordinate, 200000, 200000);
    else request.region = self.mapView.region;
    self.linkSearch = [[MKLocalSearch alloc] initWithRequest:request];
    __weak typeof(self) weakSelf = self;
    [self.linkSearch startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.closed) return;
        // Superseded: report back so the import can clear its busy status.
        if (revision != self.selectionRevision) { completion(nil, nil); return; }
        self.linkSearch = nil;
        MKMapItem *item = response.mapItems.firstObject;
        CLLocationCoordinate2D coordinate = item.placemark.coordinate;
        if (!item || !CLLocationCoordinate2DIsValid(coordinate)) {
            if (place.hasHint) {
                // The map view the link was made from is the best remaining guess.
                coordinate = CLLocationCoordinate2DMake(place.hintLatitude, place.hintLongitude);
            } else {
                completion(nil, error && error.code != MKErrorPlacemarkNotFound
                    ? @"Place lookup is unavailable right now. Check your connection and try again."
                    : [NSString stringWithFormat:@"Couldn't find “%@” from the link.", place.query]);
                return;
            }
        }
        [found addObject:[LSRouteWaypoint waypointWithName:item.name ?: place.name coordinate:coordinate]];
        [self locateLinkPlaces:places index:index + 1 found:found revision:revision completion:completion];
    }];
}

- (void)useLinkWaypoints:(NSArray<LSRouteWaypoint *> *)waypoints link:(LSMapLink *)link {
    NSMutableArray<LSRouteWaypoint *> *points = [waypoints mutableCopy];
    BOOL needsFrom = NO;
    if (link.startsAtCurrentLocation) {
        // "From your location": the applied location if there is one, else the real one.
        CLLocation *applied = LSSessionController.shared.snapshot.location;
        if (applied) [points insertObject:[LSRouteWaypoint waypointWithName:@"Applied location" coordinate:applied.coordinate] atIndex:0];
        else if (self.realPin) [points insertObject:[LSRouteWaypoint waypointWithName:@"My real location" coordinate:self.realPin.coordinate] atIndex:0];
        else needsFrom = YES;
    }
    NSUInteger dropped = 0;
    while (points.count > kLSMaximumStops + (needsFrom ? 1 : 2)) { [points removeObjectAtIndex:points.count - 2]; dropped++; }
    self.tab = LSPickerTabRoute;
    [self updateWorkspace];
    [self clearRouteDraft];
    NSString *mode = link.mode;
    self.profileSegment.selectedSegmentIndex = [mode isEqualToString:@"driving"] || [mode isEqualToString:@"transit"] ? 1 : 0;
    self.draftSpeedKmh = [mode isEqualToString:@"walking"] ? 5 : ([mode isEqualToString:@"cycling"] ? 15 : ([mode isEqualToString:@"driving"] || [mode isEqualToString:@"transit"] ? 50 : self.draftSpeedKmh));
    NSUInteger first = needsFrom ? 0 : 1;
    if (!needsFrom) [self assignEndpoint:LSEndpointFrom coordinate:points.firstObject.coordinate name:points.firstObject.name build:NO];
    for (NSUInteger index = first; index + 1 < points.count; index++) {
        LSStopAnnotation *stop = [[LSStopAnnotation alloc] init];
        stop.coordinate = points[index].coordinate;
        stop.subtitle = points[index].name;
        [self.routeStops addObject:stop];
        [self.mapView addAnnotation:stop];
    }
    [self renumberStops];
    [self rebuildStopRows];
    [self assignEndpoint:LSEndpointTo coordinate:points.lastObject.coordinate name:points.lastObject.name build:!needsFrom];
    if (needsFrom) {
        self.endpoint = LSEndpointFrom;
        self.endpointSegment.selectedSegmentIndex = LSEndpointFrom;
        [self endpointChanged];
        [self setImportStatus:@"The link starts at your location. Choose From, or tap the map to set it." error:NO busy:NO];
        [self focusMapOnCoordinate:points.lastObject.coordinate meters:4000 animated:LSMapAnimationsEnabled()];
    } else if (dropped) {
        [self showMessage:[NSString stringWithFormat:@"Imported. %lu extra stops were left out (10 is the most).", (unsigned long)dropped] symbol:@"link"];
    } else {
        [self showMessage:@"Route imported from the link." symbol:@"link"];
    }
    LSHapticSuccess();
}

- (void)openTrackFile {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *extension in @[@"gpx", @"tcx", @"fit"]) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type) [types addObject:type];
    }
    [types addObjectsFromArray:@[UTTypeXML, UTTypeData]];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (urls.firstObject) [self importTrackAtURL:urls.firstObject];
}

// Files can be up to 64 MB, so reading and parsing run off the main thread.
- (void)importTrackAtURL:(NSURL *)url {
    NSUInteger revision = ++self.selectionRevision;
    NSUInteger token = ++self.routeImportToken;
    [self setImportStatus:@"Reading the file…" error:NO busy:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LSTrack *track = nil;
        NSString *error = nil;
        LSRoute *route = LSRouteFromTrackFile(url, &track, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (![self routeImportCurrent:token revision:revision]) return;
            if (!route || !track) {
                [self setImportStatus:error ?: @"The file could not be read." error:YES busy:NO];
                LSHapticWarning();
                return;
            }
            self.routeImportActive = NO;
            [self useImportedRoute:route track:track];
        });
    });
}

- (void)useImportedRoute:(LSRoute *)route track:(LSTrack *)track {
    MKDirectionsTransportType transport = route.transportType;
    self.tab = LSPickerTabRoute;
    [self updateWorkspace];
    [self clearRouteDraft];
    self.startPin = [[LSStartAnnotation alloc] init];
    self.startPin.coordinate = route.coordinates[0];
    self.startPin.title = @"From";
    self.startPin.subtitle = @"Track start";
    self.endPin = [[LSDestinationAnnotation alloc] init];
    self.endPin.coordinate = route.coordinates[route.pointCount - 1];
    self.endPin.title = @"To";
    self.endPin.subtitle = @"Track end";
    [self.mapView addAnnotations:@[self.startPin, self.endPin]];
    self.profileSegment.selectedSegmentIndex = transport == MKDirectionsTransportTypeAutomobile ? 1 : 0;
    [self showDraftRoute:route];
    self.draftRecordedPace = route.hasTiming;
    self.draftPaceMultiplier = 1;
    if (!route.hasTiming) {
        self.draftSpeedKmh = [track.activity isEqualToString:@"driving"] ? 50 : ([track.activity isEqualToString:@"cycling"] ? 15 : self.draftSpeedKmh);
    }
    [self setImportStatus:route.hasTiming
        ? [NSString stringWithFormat:@"Imported “%@” (%@). It plays at its recorded pace; pick a speed to change that.", route.name, track.format]
        : [NSString stringWithFormat:@"Imported “%@” (%@). The file has no times, so it plays at the speed you pick.", route.name, track.format]
                   error:NO busy:NO];
    self.routeFeedbackTone = LSRouteToneSuccess;
    [self routeWasBuilt];
    [self updateRouteUI];
    LSHapticSuccess();
}

#pragma mark - Panel state

- (void)updateRouteUI {
    for (UIButton *button in @[self.fromButton, self.toButton]) {
        MKPointAnnotation *pin = button == self.fromButton ? self.startPin : self.endPin;
        NSString *name = button == self.fromButton ? @"From" : @"To";
        NSString *place = pin ? (pin.subtitle.length ? pin.subtitle : LSCoordinateText(pin.coordinate)) : @"Search, pick a saved place, or tap the map";
        LSSetEndpointText(button, place, pin == nil);
        button.accessibilityLabel = pin ? [NSString stringWithFormat:@"%@: %@", name, place] : [NSString stringWithFormat:@"%@: not set", name];
        button.accessibilityHint = @"Choose a place or enter coordinates for this endpoint.";
    }
    LSRoute *route = self.fetchedRoute;
    BOOL fromTrack = route.fromTrack;
    self.swapButton.enabled = self.startPin && self.endPin && !fromTrack;
    __weak typeof(self) weakSelf = self;
    UIAccessibilityCustomAction *reverse = [[UIAccessibilityCustomAction alloc] initWithName:@"Reverse the route" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        [weakSelf swapEndpoints];
        return YES;
    }];
    self.fromButton.accessibilityCustomActions = self.swapButton.enabled ? @[reverse] : nil;
    self.toButton.accessibilityCustomActions = self.swapButton.enabled ? @[reverse] : nil;
    [self queueEndpointHighlight];

    self.profileSegment.enabled = !fromTrack;
    self.recordedChip.hidden = !route.hasTiming;
    if (!route.hasTiming) self.draftRecordedPace = NO;
    LSTransportMode mode = LSModeForSpeed(self.draftSpeedKmh);
    for (NSUInteger index = 0; index < 3 && index < self.speedChips.count; index++) {
        LSSetChipSelected(self.speedChips[index], !self.draftRecordedPace && (NSInteger)index == mode);
    }
    BOOL custom = !self.draftRecordedPace && mode == LSTransportModeCustom;
    LSSetChipSubtitle(self.speedButton, mode == LSTransportModeCustom ? LSSpeedText(self.draftSpeedKmh) : @"Any speed");
    LSSetChipSelected(self.speedButton, custom);
    self.speedButton.accessibilityLabel = @"Custom speed";
    self.speedButton.accessibilityValue = mode == LSTransportModeCustom ? LSSpokenSpeed(self.draftSpeedKmh) : nil;
    BOOL scaled = self.draftRecordedPace && fabs(self.draftPaceMultiplier - 1) > 0.01;
    LSSetChipSubtitle(self.recordedChip, scaled ? [NSString stringWithFormat:@"×%@", LSFormatDecimal(self.draftPaceMultiplier, 2)] : @"As timed");
    LSSetChipSelected(self.recordedChip, self.draftRecordedPace);
    self.recordedChip.accessibilityLabel = @"Recorded pace";
    self.recordedChip.accessibilityValue = scaled ? [NSString stringWithFormat:@"%@ times the recorded speed", LSFormatDecimal(self.draftPaceMultiplier, 2)] : @"As recorded";

    PersistenceManager *store = PersistenceManager.shared;
    NSArray *profiles = @[@"Gentle", @"Normal", @"Sporty"];
    LSSetChipTitle(self.motionButton, store.smoothMotion ? [NSString stringWithFormat:@"Smooth · %@", profiles[MAX(0, MIN(2, store.accelerationProfile))]] : @"Steady speed");
    NSUInteger stops = route ? route.plannedStopCount : self.routeStops.count;
    self.waitButton.hidden = stops == 0 || self.draftRecordedPace;
    LSSetChipTitle(self.waitButton, store.stopDwell > 0 ? [NSString stringWithFormat:@"Wait %@ at stops", LSWaitText(store.stopDwell)] : @"No wait at stops");
    [self updateTripSummary];
    [self updateRouteStatus];
    [self syncRouteCasing];
    [self updatePlayback];
    [self updateFooter];
}

// The status card: one of empty, busy, error or ready, plus the tools that fit the state.
- (void)updateRouteStatus {
    LSRoute *route = self.fetchedRoute;
    BOOL busy = self.directions != nil;
    BOOL both = self.startPin && self.endPin;
    BOOL error = self.routeFeedbackTone == LSRouteToneError;
    if (self.routeFeedbackIsHint) self.routeFeedback.text = [self routeHint];
    BOOL empty = !self.startPin && !self.endPin && !route && self.routeFeedbackIsHint && !self.routeSpinner.isAnimating;
    self.routeEmptyState.hidden = !empty;
    self.routeFeedbackWrap.hidden = empty;
    [self applyFeedbackTone];

    // Build route doubles as the lookup's progress and as the retry after an error.
    UIButtonConfiguration *build = self.buildRouteButton.configuration;
    build.showsActivityIndicator = busy;
    build.title = busy ? @"Building route…" : (error ? @"Try again" : @"Build route");
    build.image = busy ? nil : [UIImage systemImageNamed:error ? @"arrow.clockwise" : @"point.topleft.down.to.point.bottomright.curvepath"];
    self.buildRouteButton.configuration = build;
    self.buildRouteButton.accessibilityLabel = build.title;
    self.buildRouteButton.hidden = !both || route != nil;
    self.buildRouteButton.enabled = both && !busy;
    BOOL driving = self.profileSegment.selectedSegmentIndex == 1;
    UIButtonConfiguration *other = self.routeRecoveryButton.configuration;
    other.title = driving ? @"Try the walking path" : @"Try the driving path";
    other.image = [UIImage systemImageNamed:driving ? @"figure.walk" : @"car.fill"];
    self.routeRecoveryButton.configuration = other;
    self.routeRecoveryButton.accessibilityLabel = other.title;
    self.routeRecoveryButton.hidden = !(error && self.routeSuggestsOtherPath && both && !busy && !route && !route.fromTrack);

    self.routeStatsWrap.hidden = route == nil;
    self.routeSummary.hidden = route == nil;
    if (route) {
        LSPlaybackOptions *options = [self draftOptions];
        NSTimeInterval duration = [LSRouteSimulator estimatedDurationForRoute:route options:options];
        LSRouteStatView *distance = self.routeStats[0], *time = self.routeStats[1], *stops = self.routeStats[2];
        [distance setValue:LSDistance(route.distance) caption:@"distance" spoken:LSSpokenDistance(route.distance)];
        [time setValue:LSTimeText(duration, NO) caption:@"trip time" spoken:[NSString stringWithFormat:@"about %@", LSTimeText(duration, YES)]];
        NSUInteger count = route.plannedStopCount;
        [stops setValue:[NSString stringWithFormat:@"%lu", (unsigned long)count] caption:count == 1 ? @"stop" : @"stops" spoken:nil];
        stops.superview.hidden = count == 0;
        PersistenceManager *store = PersistenceManager.shared;
        NSString *path = route.fromTrack ? @"Recorded track" : (route.transportType == MKDirectionsTransportTypeAutomobile ? @"Driving path" : @"Walking path");
        NSString *pace = options.recordedPace
            ? (fabs(options.paceMultiplier - 1) > 0.01 ? [NSString stringWithFormat:@"recorded pace ×%@", LSFormatDecimal(options.paceMultiplier, 2)] : @"recorded pace")
            : [NSString stringWithFormat:@"at %@", LSSpeedText(self.draftSpeedKmh)];
        NSString *motion = options.recordedPace ? nil : (store.smoothMotion ? @"smooth motion" : @"steady speed");
        NSMutableArray *parts = [NSMutableArray arrayWithObjects:path, pace, nil];
        if (motion) [parts addObject:motion];
        if (count && store.stopDwell > 0 && !options.recordedPace) [parts addObject:[NSString stringWithFormat:@"waits %@ per stop", LSWaitText(store.stopDwell)]];
        self.routeSummary.text = [parts componentsJoinedByString:@" · "];
    } else {
        self.routeSummary.text = @"";
    }
    self.finishButton.hidden = route == nil;
    self.shareButton.hidden = !both;
    self.routeToolsWrap.hidden = self.finishButton.hidden && self.shareButton.hidden;
}

- (void)startDraftRoute {
    LSRoute *route = self.fetchedRoute;
    if (!route || self.directions) return;
    LSPlaybackOptions *options = [self draftOptions];
    __weak typeof(self) weakSelf = self;
    dispatch_block_t start = ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed) return;
        if ([LSSessionController.shared startRoute:route options:options]) {
            self.routeDraftChanged = NO;
            [self setRouteFeedback:PersistenceManager.shared.continueInBackground
                ? @"Route started. It keeps moving in the background while iOS lets the app run."
                : @"Route started. Close the picker to return to your app. Leaving the app pauses movement until you come back."
                              tone:LSRouteToneSuccess];
            LSHapticApplied();
            [self showMessage:@"Route started." symbol:@"location.north.line.fill"];
            [self refreshSession];
            [self updateRouteUI];
            [self springAppliedMarker];
        } else {
            [self setRouteFeedback:@"This route could not be started. Rebuild it and try again." tone:LSRouteToneError];
            [self updateRouteStatus];
            LSHapticWarning();
        }
        LSAnnounce(self.routeFeedback.text);
    };
    if (LSSessionController.shared.snapshot.mode == LSSessionModeOff ||
        (LSSessionController.shared.snapshot.mode == LSSessionModeStatic && route == LSSessionController.shared.retainedRoute && !self.routeDraftChanged)) start();
    else [self confirmAction:@"Replace applied session?" message:@"The app will start at From and follow this route. The currently applied location or route will be replaced." button:@"Replace and start" action:start];
}

- (void)speedChipTapped:(UIButton *)chip {
    if (chip == self.recordedChip) {
        LSHapticSelection();
        self.draftRecordedPace = YES;
        [self optionsChanged:@"Playing at the recorded pace."];
        return;
    }
    if (chip.tag >= 0 && chip.tag < 3) { LSHapticSelection(); [self setPlaybackSpeed:kLSPresetSpeeds[chip.tag]]; }
    else [self enterCustomSpeed];
}

- (void)chooseSpeed {
    [self enterCustomSpeed];
}

- (void)setPlaybackSpeed:(double)speed {
    if (!isfinite(speed) || speed < 1 || speed > 500) return;
    self.draftSpeedKmh = speed;
    self.draftRecordedPace = NO;
    [self optionsChanged:@"Playback speed updated. The route path is unchanged."];
}

- (void)enterCustomSpeed {
    NSString *help = @"Enter a speed from 1 to 500 km/h. The path stays the same.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom playback speed" message:help preferredStyle:UIAlertControllerStyleAlert];
    double current = self.draftSpeedKmh;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = LSFormatDecimal(current, 1);
        field.placeholder = @"km/h";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.accessibilityLabel = @"Speed in kilometers per hour";
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Set speed" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        if (number) [weakSelf setPlaybackSpeed:number.doubleValue];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self validateAlert:alert action:save valid:^BOOL(NSNumber *number) { return number.doubleValue >= 1 && number.doubleValue <= 500; }
                   help:help error:@"Enter a number from 1 to 500 km/h."];
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

#pragma mark - Playback

- (void)nudge:(NSInteger)direction {
    if (![LSSessionController.shared nudgeSpeed:direction]) {
        LSHapticWarning();
        LSAnnounce(direction > 0 ? @"Already at the fastest speed." : @"Already at the slowest speed.");
        return;
    }
    LSHapticSelection();
    if ([self isPlayingDraft]) {
        LSPlaybackOptions *options = LSRouteSimulator.shared.options;
        self.draftRecordedPace = options.recordedPace;
        self.draftPaceMultiplier = options.paceMultiplier;
        if (!options.recordedPace) self.draftSpeedKmh = options.speedKmh;
    }
    [self updateRouteUI];
    LSBump(self.liveSpeedLabel);
    LSAnnounce(self.liveSpeedLabel.text);
}
- (void)slowerTapped { [self nudge:-1]; }
- (void)fasterTapped { [self nudge:1]; }

- (void)instrumentPlayPause {
    LSSessionController *session = LSSessionController.shared;
    if (session.snapshot.mode == LSSessionModePaused) [session resume];
    else [session pause];
    LSHapticImpact(UIImpactFeedbackStyleMedium);
    [self refreshSession];
}

// Called from the session refresh (up to 4 Hz): keep it to label updates and cheap checks.
- (void)updatePlayback {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    BOOL active = engine.isSimulating;
    BOOL complete = LSSessionController.shared.retainedRoute && engine.totalDistance > 0 && engine.distanceCovered >= engine.totalDistance;
    BOOL show = active || complete;
    BOOL animated = self.view.window != nil;
    LSSetHidden(self.progressPanel, !show, animated);
    // The planner folds away while the route it drafted plays, until Edit route opens it.
    BOOL playingDraft = show && self.fetchedRoute && !self.routeDraftChanged && engine.route == self.fetchedRoute;
    if (!playingDraft) self.routeEditorOpen = NO;
    BOOL folded = playingDraft && !self.routeEditorOpen;
    LSSetHidden(self.routeEndpointsCard, folded, animated);
    LSSetHidden(self.routeTripCard, !folded, animated);
    LSSetHidden(self.routeEditHeader, !(playingDraft && self.routeEditorOpen), animated);
    [self trackMilestonesActive:active complete:complete];
    [self syncRouteCasing];
    [self updateRouteTraveled:NO];
    if (show) [self renderInstrumentActive:active complete:complete];
}

- (void)openRouteEditor {
    self.routeEditorOpen = YES;
    LSHapticSelection();
    [self updatePlayback];
    UIButton *from = self.fromButton;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (from.window) UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, from);
    });
}

// The trip row's one action follows the playback state; renamed only when that changes.
- (void)setTripRowPauseAction:(nullable NSString *)name {
    UIView *trip = self.routeTripRow;
    NSArray<UIAccessibilityCustomAction *> *actions = trip.accessibilityCustomActions;
    if (!name) { if (actions.count) trip.accessibilityCustomActions = nil; return; }
    if ([actions.firstObject.name isEqualToString:name]) return;
    __weak typeof(self) weakSelf = self;
    trip.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc] initWithName:name actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        [weakSelf instrumentPlayPause];
        return YES;
    }]];
}

- (void)closeRouteEditor {
    self.routeEditorOpen = NO;
    LSHapticSelection();
    [self updatePlayback];
    UIView *trip = self.routeTripRow;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (trip.window) UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, trip);
    });
}

// "◉ Home → ⦿ Office · 3 stops · next: Stop 2". Rebuilt when the plan changes and on
// milestones, not on the playback tick.
- (void)updateTripSummary {
    NSString *from = self.startPin ? (self.startPin.subtitle.length ? self.startPin.subtitle : LSCoordinateText(self.startPin.coordinate)) : @"From";
    NSString *to = self.endPin ? (self.endPin.subtitle.length ? self.endPin.subtitle : LSCoordinateText(self.endPin.coordinate)) : @"To";
    NSUInteger stops = self.routeStops.count;
    NSString *count = [NSString stringWithFormat:@"%lu %@", (unsigned long)stops, stops == 1 ? @"stop" : @"stops"];
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    BOOL playing = self.fetchedRoute && !self.routeDraftChanged && engine.route == self.fetchedRoute && engine.isSimulating;
    NSUInteger passed = [self passedStopCount];
    NSString *next = playing && stops && passed < stops ? [NSString stringWithFormat:@"Stop %lu", (unsigned long)passed + 1] : nil;
    NSMutableString *tail = [NSMutableString string];
    if (stops) [tail appendFormat:@" · %@", count];
    if (next) [tail appendFormat:@" · next: %@", next];
    UILabel *label = self.routeTripLabel;
    BOOL rtl = label.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSString *plain = [NSString stringWithFormat:@"%@ %@ %@%@", from, rtl ? @"←" : @"→", to, tail];
    // Text and appearance both count: the marker colours are resolved into the images.
    NSString *key = [NSString stringWithFormat:@"%@|%ld|%ld|%@", plain, (long)label.traitCollection.userInterfaceStyle,
                     (long)label.traitCollection.accessibilityContrast, label.traitCollection.preferredContentSizeCategory];
    if (!label.attributedText.length || ![self.routeTripKey isEqualToString:key]) {
        self.routeTripKey = key;
        UIFont *font = label.font;
        UITraitCollection *traits = label.traitCollection;
        NSDictionary *attributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.labelColor};
        NSAttributedString *(^marker)(NSInteger) = ^NSAttributedString *(NSInteger target) {
            UIColor *color = [LSFillColor(LSTargetColor(target)) resolvedColorWithTraitCollection:traits];
            UIImage *image = [UIImage systemImageNamed:kLSTargetSymbols[target] withConfiguration:[UIImageSymbolConfiguration configurationWithFont:font scale:UIImageSymbolScaleMedium]];
            NSMutableAttributedString *mark = [[NSAttributedString attributedStringWithAttachment:
                [NSTextAttachment textAttachmentWithImage:[image imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal]]] mutableCopy];
            [mark appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u00A0" attributes:attributes]];
            return mark;
        };
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
        [text appendAttributedString:marker(LSEndpointFrom)];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ %@ ", from, rtl ? @"←" : @"→"] attributes:attributes]];
        [text appendAttributedString:marker(LSEndpointTo)];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:to attributes:attributes]];
        if (tail.length) {
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:tail
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
        }
        // Reaching a stop changes "next: Stop N"; that change cross-dissolves (not motion).
        BOOL nextChanged = self.routeTripNext && ![self.routeTripNext isEqualToString:next ?: @""];
        if (nextChanged && label.window) {
            [UIView transitionWithView:label duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                            animations:^{ label.attributedText = text; } completion:nil];
        } else {
            label.attributedText = text;
        }
        self.routeTripNext = next ?: @"";
    }
    NSMutableString *spoken = [NSMutableString stringWithFormat:@"Route from %@ to %@", from, to];
    if (stops) [spoken appendFormat:@", via %@", count];
    if (next) [spoken appendFormat:@", next %@", next];
    self.routeTripRow.accessibilityLabel = spoken;
}

- (NSString *)destinationOfRoute:(LSRoute *)route {
    NSString *name = route.waypoints.count >= 2 ? route.waypoints.lastObject.name : nil;
    if (!name.length || [@[@"Map point", @"Track end", @"End"] containsObject:name]) return route.name.length ? route.name : @"Applied route";
    return [NSString stringWithFormat:@"To %@", name];
}

- (void)renderInstrumentActive:(BOOL)active complete:(BOOL)complete {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    LSRouteInstrumentView *gauge = self.routeInstrument;
    LSRoute *route = engine.route;
    double total = engine.totalDistance;
    double covered = complete ? total : MIN(total, MAX(0, engine.distanceCovered));
    double progress = total > 0 ? covered / total : 0;
    double remaining = MAX(0, total - covered);
    if (gauge.boundRoute != route) {
        gauge.boundRoute = route;
        NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
        for (NSUInteger index = 0; index < route.stopDistances.count && index < route.stopDwells.count; index++) {
            if (route.stopDwells[index].doubleValue < 0 && total > 0) [fractions addObject:@(route.stopDistances[index].doubleValue / total)];
        }
        gauge.bar.stopFractions = fractions;
        LSSetText(gauge.headingLabel, [self destinationOfRoute:route]);
    }
    NSUInteger planned = gauge.bar.stopFractions.count;
    NSUInteger reached = complete ? planned : MIN(planned, engine.plannedStopsReached);
    BOOL paused = active && engine.isPaused;
    BOOL waiting = active && !paused && engine.isWaitingAtStop;
    gauge.bar.stopsPassed = reached;
    gauge.bar.fillColor = paused || waiting ? LSCachedWarningColor() : LSCachedRouteColor();
    [gauge.bar setProgress:progress animated:YES];
    LSSetText(gauge.percentLabel, LSPercentText(progress));

    NSMutableArray<NSString *> *spoken = [NSMutableArray array];
    NSString *detail = @"";
    if (complete) {
        [self setTripRowPauseAction:nil];
        [gauge.stateChip setTitle:@"Arrived" symbol:@"flag.checkered" color:LSSuccessColor() active:NO];
        [gauge.timeLeft setValue:LSDistance(total) caption:@"travelled" spoken:LSSpokenDistance(total)];
        LSSetText(gauge.doneLabel, @"Whole route done");
        LSSetText(gauge.leftLabel, @"");
        detail = @"Holding the destination until you replay or replace it.";
        [spoken addObjectsFromArray:@[@"Arrived", [NSString stringWithFormat:@"%@ travelled", LSSpokenDistance(total)]]];
    } else {
        NSTimeInterval timeLeft = [engine remainingTimeEstimate];
        NSString *state = paused ? @"Paused" : (waiting ? [NSString stringWithFormat:@"Waiting at stop %lu", (unsigned long)MAX((NSUInteger)1, reached)] : @"Moving");
        NSString *symbol = paused ? @"pause.circle.fill" : (waiting ? @"hourglass" : @"location.north.line.fill");
        // No pulse here: the header's status chip already pulses and the knob glides.
        [gauge.stateChip setTitle:state symbol:symbol color:paused || waiting ? LSWarningColor() : LSSuccessColor() active:NO];
        [gauge.timeLeft setValue:LSTimeText(timeLeft, NO) caption:@"left" spoken:LSTimeText(timeLeft, YES)];
        double kmh = engine.currentSpeed * 3.6;
        [gauge.speedNow setValue:LSSpeedText(kmh) caption:@"now" spoken:LSSpokenSpeed(kmh)];
        LSSetText(gauge.doneLabel, [NSString stringWithFormat:@"%@ done", LSDistance(covered)]);
        LSSetText(gauge.leftLabel, [NSString stringWithFormat:@"%@ to go", LSDistance(remaining)]);
        LSSetText(gauge.etaLabel, paused ? @"" : [NSString stringWithFormat:@"Arrives %@", LSClockTime([NSDate dateWithTimeIntervalSinceNow:timeLeft])]);
        if (paused) detail = @"Paused. The location stays put until you resume.";
        else if (waiting) detail = [NSString stringWithFormat:@"Moving on in %@.", LSClock(engine.waitRemaining)];
        [spoken addObjectsFromArray:@[state, [NSString stringWithFormat:@"%@ left", LSTimeText(timeLeft, YES)],
                                      [NSString stringWithFormat:@"%@ to go", LSSpokenDistance(remaining)], LSPercentText(progress),
                                      [NSString stringWithFormat:@"%@ now", LSSpokenSpeed(kmh)]]];
        if (!paused) [spoken addObject:gauge.etaLabel.text];

        LSPlaybackOptions *options = engine.options;
        BOOL recorded = options.recordedPace && route.hasTiming;
        LSSetText(gauge.speedLabel, recorded ? [NSString stringWithFormat:@"Recorded pace ×%@", LSFormatDecimal(options.paceMultiplier, 2)]
                                             : [NSString stringWithFormat:@"Set to %@", LSSpeedText(options.speedKmh)]);
        gauge.speedLabel.accessibilityLabel = @"Playback speed";
        gauge.speedLabel.accessibilityValue = recorded ? [NSString stringWithFormat:@"%@ times the recorded pace", LSFormatDecimal(options.paceMultiplier, 2)] : LSSpokenSpeed(options.speedKmh);
        BOOL fastest = recorded ? options.paceMultiplier >= kLSFastestPace - 0.001 : options.speedKmh >= kLSFastestKmh - 0.01;
        BOOL slowest = recorded ? options.paceMultiplier <= kLSSlowestPace + 0.001 : options.speedKmh <= kLSSlowestKmh + 0.01;
        if (gauge.fasterButton.enabled == fastest) gauge.fasterButton.enabled = !fastest;
        if (gauge.slowerButton.enabled == slowest) gauge.slowerButton.enabled = !slowest;
        gauge.fasterButton.accessibilityValue = fastest ? @"Fastest speed" : nil;
        gauge.slowerButton.accessibilityValue = slowest ? @"Slowest speed" : nil;
        [gauge setPaused:paused];
        [self setTripRowPauseAction:paused ? @"Resume route" : @"Pause route"];
    }
    gauge.speedNow.hidden = complete;
    gauge.etaLabel.hidden = complete || paused;
    gauge.leftLabel.hidden = complete;
    if (gauge.transport.hidden != complete) gauge.transport.hidden = complete;
    gauge.speedLabel.hidden = complete;
    LSSetText(gauge.detailLabel, detail);
    gauge.detailLabel.hidden = detail.length == 0;
    if (detail.length) [spoken addObject:detail];
    gauge.readout.accessibilityValue = [spoken componentsJoinedByString:@". "];
}

// Spoken milestones while the picker is open: halfway, each planned stop, and arrival, each
// once per run. Opening the picker mid-route only records where it is, silently.
- (void)trackMilestonesActive:(BOOL)active complete:(BOOL)complete {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    LSRoute *route = engine.route;
    if (!route || (!active && !complete)) return;
    double total = engine.totalDistance;
    double covered = complete ? total : engine.distanceCovered;
    NSUInteger stops = complete ? route.plannedStopCount : engine.plannedStopsReached;
    BOOL halfway = total > 0 && covered >= total / 2;
    if (route != self.milestoneRoute || covered + 5 < self.milestoneCovered) {
        self.milestoneRoute = route;
        self.milestoneCovered = covered;
        self.milestoneStops = stops;
        self.milestoneHalfway = halfway;
        self.milestoneArrived = complete;
        [self refreshStopProgress];
        return;
    }
    self.milestoneCovered = covered;
    NSString *message = nil;
    BOOL arrived = complete && !self.milestoneArrived;
    if (arrived) {
        NSString *destination = [self destinationOfRoute:route];
        message = [destination hasPrefix:@"To "] ? [NSString stringWithFormat:@"Arrived at %@.", [destination substringFromIndex:3]] : @"Arrived.";
        [self celebrateArrival];
    } else if (stops > self.milestoneStops) {
        message = [NSString stringWithFormat:@"Reached stop %lu of %lu.", (unsigned long)stops, (unsigned long)route.plannedStopCount];
    } else if (halfway && !self.milestoneHalfway) {
        message = [NSString stringWithFormat:@"Halfway. About %@ left.", LSTimeText(engine.remainingTimeEstimate, YES)];
    }
    BOOL stopsChanged = stops != self.milestoneStops;
    self.milestoneArrived = complete;
    self.milestoneStops = stops;
    self.milestoneHalfway = halfway;
    if (stopsChanged || arrived) [self refreshStopProgress];
    if (message && self.view.window) LSAnnounce(message);
}

- (void)celebrateArrival {
    if (!self.view.window) return;
    LSHapticSuccess();
    LSBump(self.routeInstrument.stateChip);
    [self springAppliedMarker];
}

// A short spring on the applied marker when a route starts or arrives.
- (void)springAppliedMarker {
    if (!self.appliedPin || !LSMapAnimationsEnabled()) return;
    MKAnnotationView *view = [self.mapView viewForAnnotation:self.appliedPin];
    if (!view) return;
    view.transform = CGAffineTransformMakeScale(0.55, 0.55);
    LSAnimateBouncy(^{ view.transform = CGAffineTransformIdentity; }, nil);
}

- (NSUInteger)passedStopCount {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    LSRoute *route = self.fetchedRoute;
    if (!route || self.routeDraftChanged || engine.route != route) return 0;
    if (engine.totalDistance > 0 && engine.distanceCovered >= engine.totalDistance) return route.plannedStopCount;
    return engine.isSimulating ? engine.plannedStopsReached : 0;
}

- (void)refreshStopProgress {
    [self updateTripSummary];
    for (LSStopAnnotation *stop in self.routeStops) {
        MKMarkerAnnotationView *view = (id)[self.mapView viewForAnnotation:stop];
        if ([view isKindOfClass:MKMarkerAnnotationView.class]) [self styleRouteAnnotationView:view];
    }
    [self refreshStopRails];
}
@end

@implementation MapPickerViewController (LSRouteMapStyle)
- (MKOverlayRenderer *)routeRendererForOverlay:(id<MKOverlay>)overlay {
    UITraitCollection *traits = self.mapView.traitCollection;
    if (self.routePolyline && (id)overlay == self.routePolyline) {
        LSRouteLineRenderer *renderer = [[LSRouteLineRenderer alloc] initWithPolyline:self.routePolyline];
        renderer.lineWidth = LSRouteLineWidth();
        renderer.lineCap = kCGLineCapRound;
        renderer.lineJoin = kCGLineJoinRound;
        double location = [self traveledLocation];
        [renderer applyTraveled:location traits:traits];
        renderer.alpha = self.routeDrawInPending ? 0 : 1;
        self.routeLineRenderer = renderer;
        self.routeTraveledShown = location;
        self.routeTraveledAt = NSProcessInfo.processInfo.systemUptime;
        return renderer;
    }
    if (self.routeCasing && (id)overlay == self.routeCasing) {
        LSRouteCasingRenderer *renderer = [[LSRouteCasingRenderer alloc] initWithPolyline:self.routeCasing];
        renderer.lineWidth = LSRouteLineWidth() + 4;
        renderer.lineCap = kCGLineCapRound;
        renderer.lineJoin = kCGLineJoinRound;
        [renderer applyTraits:traits];
        renderer.alpha = self.routeDrawInPending ? 0 : 1;
        self.routeCasingRenderer = renderer;
        return renderer;
    }
    return nil;
}

- (void)styleRouteAnnotationView:(MKMarkerAnnotationView *)view {
    id<MKAnnotation> annotation = view.annotation;
    view.titleVisibility = MKFeatureVisibilityAdaptive;
    view.subtitleVisibility = MKFeatureVisibilityHidden;
    if ([annotation isKindOfClass:LSStartAnnotation.class]) {
        // From shows how the trip is played: on foot, by bike or by car.
        NSString *activity = LSActivityForKmh(self.draftSpeedKmh);
        NSString *glyph = [activity isEqualToString:@"walking"] ? @"figure.walk" : ([activity isEqualToString:@"cycling"] ? @"bicycle" : @"car.fill");
        view.markerTintColor = LSFillColor(LSSuccessColor());
        view.glyphText = nil;
        view.glyphImage = [UIImage systemImageNamed:glyph];
        view.accessibilityLabel = [NSString stringWithFormat:@"From: %@", annotation.subtitle.length ? annotation.subtitle : LSCoordinateText(annotation.coordinate)];
    } else if ([annotation isKindOfClass:LSDestinationAnnotation.class]) {
        view.markerTintColor = LSFillColor(LSErrorColor());
        view.glyphText = nil;
        view.glyphImage = [UIImage systemImageNamed:@"flag.checkered"];
        view.accessibilityLabel = [NSString stringWithFormat:@"To: %@", annotation.subtitle.length ? annotation.subtitle : LSCoordinateText(annotation.coordinate)];
    } else if ([annotation isKindOfClass:LSStopAnnotation.class]) {
        NSUInteger index = [self.routeStops indexOfObject:(LSStopAnnotation *)annotation];
        BOOL passed = index != NSNotFound && index < [self passedStopCount];
        // Numbered while ahead; a grey check once the playing route has passed it.
        view.markerTintColor = passed ? UIColor.systemGrayColor : LSFillColor(LSWarningColor());
        view.glyphImage = passed ? [UIImage systemImageNamed:@"checkmark"] : nil;
        view.glyphText = passed || index == NSNotFound ? nil : [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
        NSString *place = annotation.subtitle.length ? annotation.subtitle : LSCoordinateText(annotation.coordinate);
        view.accessibilityLabel = index == NSNotFound ? place : [NSString stringWithFormat:@"Stop %lu%@: %@", (unsigned long)index + 1, passed ? @", passed" : @"", place];
    }
}
@end
