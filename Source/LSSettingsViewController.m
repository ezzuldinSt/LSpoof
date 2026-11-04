#import "LSSettingsViewController.h"
#import "LSSettings.h"
#import "LSUI.h"
#import "SessionController.h"
#import "OverlayWindow.h"
#import "LSBackup.h"
#import "BookmarksManager.h"
#import "PersistenceManager.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Grouped-list geometry, like iOS Settings: a 30 pt badge, then the row's text. Separators
// and child rows start where the text does.
static const CGFloat kLSSettingsBadge = 30;
static const CGFloat kLSSettingsInset = 16;
static const CGFloat kLSSettingsTextInset = 16 + 30 + 12;
// Radius presets: slider detents (with a haptic tick) and VoiceOver adjust steps.
static const double kLSSettingsRadiusDetents[] = {10, 25, 50, 100, 250};
static const double kLSSettingsRadiusSteps[] = {1, 5, 10, 25, 50, 100, 250, 500, 1000};

static BOOL LSSettingsLargeText(UITraitCollection *traits) {
    UIContentSizeCategory category = traits.preferredContentSizeCategory;
    if (!category.length || [category isEqualToString:UIContentSizeCategoryUnspecified]) category = UIApplication.sharedApplication.preferredContentSizeCategory;
    return UIContentSizeCategoryIsAccessibilityCategory(category);
}

#pragma mark - Plain-language readings of the values

static NSString *LSSettingsAltitudeText(double meters) {
    if (fabs(meters) < 1) return @"At sea level";
    static const struct { double meters; const char *text; } marks[] = {
        {-430, "About as low as the Dead Sea shore"}, {330, "About the height of the Eiffel Tower"},
        {828, "About the height of the Burj Khalifa"}, {1609, "About as high as Denver"},
        {2240, "About as high as Mexico City"}, {3640, "About as high as La Paz"},
        {5364, "About as high as Everest Base Camp"}, {8849, "About as high as the top of Everest"}};
    for (size_t i = 0; i < sizeof(marks) / sizeof(marks[0]); i++) {
        if (fabs(meters - marks[i].meters) <= fabs(marks[i].meters) * 0.15) return @(marks[i].text);
    }
    if (meters < 0) return [NSString stringWithFormat:@"%@ m below sea level", LSFormatDecimal(-meters, 0)];
    if (meters < 50) return @"Near sea level, like most coastal cities";
    return [NSString stringWithFormat:@"%@ m above sea level", LSFormatDecimal(meters, 0)];
}
static NSString *LSSettingsCourseText(double course) {
    NSArray<NSString *> *names = @[@"north", @"northeast", @"east", @"southeast", @"south", @"southwest", @"west", @"northwest"];
    NSUInteger index = (NSUInteger)floor(fmod(course + 22.5, 360.0) / 45.0) % 8;
    return [NSString stringWithFormat:@"Facing %@", names[index]];
}
static NSString *LSSettingsWanderComparison(double radius) {
    double across = radius * 2;
    if (across < 6) return @"About the size of a room";
    if (across < 15) return @"About the size of a house";
    if (across < 35) return @"About a tennis court";
    if (across < 70) return @"About an Olympic pool";
    if (across < 140) return @"About a soccer field";
    if (across < 300) return @"About a city block";
    if (across < 700) return @"A few city blocks";
    if (across < 1400) return @"About a neighborhood";
    return @"About a small town center";
}
static NSString *LSSettingsWanderText(double radius) {
    return [NSString stringWithFormat:@"%@ · %@ m across", LSSettingsWanderComparison(radius), LSFormatDecimal(radius * 2, 1)];
}
// The slider runs on a square-root scale so 1 to 50 m, where most choices are, gets most of its travel.
static float LSSettingsSliderValue(double meters) { return (float)sqrt(MAX(0, MIN(1, (meters - 1) / 999.0))); }
static double LSSettingsSliderMeters(float value) {
    double meters = 1 + 999 * (double)value * (double)value;
    double step = meters < 100 ? 1 : (meters < 300 ? 5 : 10);
    meters = MAX(1, MIN(1000, round(meters / step) * step));
    for (size_t i = 0; i < sizeof(kLSSettingsRadiusDetents) / sizeof(double); i++) {
        // A light magnet: about ±1 m at 10 m, ±6 m at 250 m.
        if (fabs(value - LSSettingsSliderValue(kLSSettingsRadiusDetents[i])) < 0.006) return kLSSettingsRadiusDetents[i];
    }
    return meters;
}

#pragma mark - Building blocks

// Side by side normally. At accessibility text sizes the views stack (or, with keepsAxis,
// top-align) so titles and values get the full width instead of a word per line.
@interface LSSettingsReflowStack : UIStackView
@property (nonatomic) BOOL keepsAxis;
@property (nonatomic) UIStackViewAlignment stackedAlignment;
- (void)applyTextSize;
@end
@implementation LSSettingsReflowStack
- (void)applyTextSize {
    BOOL large = LSSettingsLargeText(self.traitCollection);
    if (!self.keepsAxis) self.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.alignment = large ? self.stackedAlignment : UIStackViewAlignmentCenter;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) [self applyTextSize];
}
@end

static LSSettingsReflowStack *LSSettingsFlow(NSArray<UIView *> *views, CGFloat spacing, UIStackViewAlignment stacked, BOOL keepsAxis) {
    LSSettingsReflowStack *stack = [[LSSettingsReflowStack alloc] initWithArrangedSubviews:views];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.spacing = spacing;
    stack.keepsAxis = keepsAxis;
    stack.stackedAlignment = stacked;
    [stack applyTextSize];
    return stack;
}

// Tappable card row that highlights like a table cell while pressed.
@interface LSSettingsActionRow : UIControl
@end
@implementation LSSettingsActionRow
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? UIColor.systemFillColor : UIColor.clearColor;
}
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1 : 0.45;
    self.accessibilityTraits = enabled ? UIAccessibilityTraitButton : (UIAccessibilityTraitButton | UIAccessibilityTraitNotEnabled);
}
@end

// A switch row that is one VoiceOver stop and toggles from a tap anywhere on it.
@interface LSSettingsToggleRow : UIControl
@property (nonatomic, strong) UISwitch *toggle;
@end
@implementation LSSettingsToggleRow
- (void)flip {
    [self.toggle setOn:!self.toggle.on animated:LSMapAnimationsEnabled()];
    [self.toggle sendActionsForControlEvents:UIControlEventValueChanged];
}
// Touches anywhere but on the switch itself belong to the row.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return !hit || [hit isDescendantOfView:self.toggle] ? hit : self;
}
- (NSString *)accessibilityValue { return self.toggle.on ? @"On" : @"Off"; }
- (BOOL)accessibilityActivate { [self flip]; return YES; }
@end

// Wander radius slider whose VoiceOver adjust steps through round presets.
@interface LSSettingsRadiusSlider : UISlider
@property (nonatomic, copy) NSString *(^describe)(void);
@end
@implementation LSSettingsRadiusSlider
- (void)stepBy:(NSInteger)direction {
    double current = 1 + 999 * (double)self.value * (double)self.value;
    size_t count = sizeof(kLSSettingsRadiusSteps) / sizeof(double);
    double target = direction > 0 ? kLSSettingsRadiusSteps[count - 1] : kLSSettingsRadiusSteps[0];
    for (size_t i = 0; i < count; i++) {
        double step = direction > 0 ? kLSSettingsRadiusSteps[i] : kLSSettingsRadiusSteps[count - 1 - i];
        if (direction > 0 ? step > current + 0.5 : step < current - 0.5) { target = step; break; }
    }
    self.value = LSSettingsSliderValue(target);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)accessibilityIncrement { [self stepBy:1]; }
- (void)accessibilityDecrement { [self stepBy:-1]; }
- (NSString *)accessibilityValue { return self.describe ? self.describe() : [super accessibilityValue]; }
@end

// A small street grid (streets about 100 m apart) with the wander circle at the same scale,
// the chosen spot in the middle and a dot drifting the way the reported position does.
@interface LSSettingsWanderPreview : UIView
// Called while the ring is dragged, with the radius under the finger in meters.
@property (nonatomic, copy, nullable) void (^dragged)(double meters);
- (void)setRadius:(double)radius animated:(BOOL)animated;
@end
@implementation LSSettingsWanderPreview {
    CAShapeLayer *_streets, *_circle;
    CALayer *_spot, *_dot, *_knob;
    UILabel *_readout;
    BOOL _dragging;
    double _radius;
    CGSize _laidOut;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = LSRadiusS;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.isAccessibilityElement = NO; // The radius slider is the accessible control.
        _radius = 25;
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restartDrift) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        _streets = [CAShapeLayer layer];
        _streets.fillColor = nil;
        _circle = [CAShapeLayer layer];
        _spot = [CALayer layer];
        _spot.bounds = CGRectMake(0, 0, 10, 10);
        _spot.cornerRadius = 5;
        _spot.borderWidth = 2;
        _dot = [CALayer layer];
        _dot.bounds = CGRectMake(0, 0, 14, 14);
        _dot.cornerRadius = 7;
        _dot.borderWidth = 2.5;
        _dot.shadowOpacity = 0.25;
        _dot.shadowRadius = 3;
        _dot.shadowOffset = CGSizeMake(0, 1);
        // A handle on the ring at 3 o'clock says "drag me".
        _knob = [CALayer layer];
        _knob.bounds = CGRectMake(0, 0, 12, 12);
        _knob.cornerRadius = 6;
        _knob.backgroundColor = UIColor.whiteColor.CGColor;
        _knob.shadowColor = UIColor.blackColor.CGColor;
        _knob.shadowOpacity = 0.3;
        _knob.shadowRadius = 2.5;
        _knob.shadowOffset = CGSizeMake(0, 1);
        for (CALayer *layer in @[_streets, _circle, _spot, _dot, _knob]) [self.layer addSublayer:layer];
        _readout = LSPillLabel(@"", LSAccentTextColor());
        _readout.translatesAutoresizingMaskIntoConstraints = YES; // Placed by frame next to the knob.
        _readout.alpha = 0;
        [self addSubview:_readout];
        [self updateColors];
    }
    return self;
}
- (CGFloat)circlePoints {
    CGFloat largest = MAX(12, CGRectGetHeight(self.bounds) / 2 - 8);
    // Log scale: 1 m is a small ring, 1,000 m fills the height.
    return 7 + (largest - 7) * (CGFloat)(log10(MAX(1, MIN(1000, _radius))) / 3.0);
}
// Inverse of circlePoints: distance from the centre back to meters on the same log scale.
- (double)metersAtDistance:(CGFloat)distance {
    CGFloat largest = MAX(12, CGRectGetHeight(self.bounds) / 2 - 8);
    double t = (distance - 7) / MAX(1.0, largest - 7);
    return pow(10, 3 * MAX(0, MIN(1, t)));
}
- (CGFloat)distanceOf:(UIGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self];
    return (CGFloat)hypot(point.x - CGRectGetMidX(self.bounds), point.y - CGRectGetMidY(self.bounds));
}
// Grab the ring, or swipe sideways anywhere on the preview; a vertical swipe that starts
// away from the ring still scrolls the page. UIKit also asks this view about its ancestors'
// recognizers (the page scroll), which are always allowed.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture.view != self || ![gesture isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    CGPoint velocity = [(UIPanGestureRecognizer *)gesture velocityInView:self];
    return fabs([self distanceOf:gesture] - [self circlePoints]) < 24 || fabs(velocity.x) > fabs(velocity.y);
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    UIGestureRecognizerState state = pan.state;
    if (state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        LSHapticImpact(UIImpactFeedbackStyleLight);
        [self setGrabbed:YES];
    }
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
        if (self.dragged) self.dragged([self metersAtDistance:[self distanceOf:pan]]);
        [self placeReadout];
    } else if (_dragging) {
        _dragging = NO;
        [self setGrabbed:NO];
    }
}
- (CGPoint)knobPosition {
    return CGPointMake(CGRectGetMidX(self.bounds) + [self circlePoints], CGRectGetMidY(self.bounds));
}
- (void)setGrabbed:(BOOL)grabbed {
    [CATransaction begin];
    [CATransaction setDisableActions:!LSMapAnimationsEnabled()];
    [CATransaction setAnimationDuration:0.18];
    _knob.transform = grabbed ? CATransform3DMakeScale(1.25, 1.25, 1) : CATransform3DIdentity;
    [CATransaction commit];
    if (grabbed) [self placeReadout];
    UILabel *readout = _readout;
    LSAnimate(^{ readout.alpha = grabbed ? 1 : 0; }, nil);
}
// "40 m" in a small capsule just above the knob, kept inside the preview.
- (void)placeReadout {
    _readout.text = [NSString stringWithFormat:@"%@ m", LSFormatDecimal(_radius, 0)];
    CGSize size = _readout.intrinsicContentSize;
    CGPoint knob = [self knobPosition];
    CGFloat x = MAX(4, MIN(CGRectGetWidth(self.bounds) - size.width - 4, knob.x - size.width / 2));
    CGFloat y = knob.y - 12 - size.height;
    if (y < 4) y = knob.y + 12;
    _readout.frame = CGRectMake(x, y, size.width, size.height);
}
- (void)updateColors {
    UITraitCollection *traits = self.traitCollection;
    BOOL contrast = LSIncreaseContrast();
    self.backgroundColor = UIColor.tertiarySystemFillColor;
    _streets.strokeColor = [UIColor.systemBackgroundColor resolvedColorWithTraitCollection:traits].CGColor;
    _circle.fillColor = [[LSAccentColor() colorWithAlphaComponent:contrast ? 0.22 : 0.14] resolvedColorWithTraitCollection:traits].CGColor;
    _circle.strokeColor = [LSAccentColor() resolvedColorWithTraitCollection:traits].CGColor;
    _circle.lineWidth = contrast ? 2.5 : 1.5;
    _spot.borderColor = [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:traits].CGColor;
    _dot.backgroundColor = [LSAccentColor() resolvedColorWithTraitCollection:traits].CGColor;
    _dot.borderColor = UIColor.whiteColor.CGColor;
    _knob.borderWidth = contrast ? 1.5 : 0;
    _knob.borderColor = [LSAccentColor() resolvedColorWithTraitCollection:traits].CGColor;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateColors];
}
- (UIBezierPath *)circlePath {
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    return [UIBezierPath bezierPathWithArcCenter:center radius:[self circlePoints] startAngle:-M_PI_2 endAngle:1.5 * M_PI clockwise:YES];
}
- (void)updateStreets {
    CGRect bounds = self.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGFloat spacing = 100.0 * [self circlePoints] / MAX(1.0, _radius);
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (spacing >= 4 && spacing < 4 * CGRectGetWidth(bounds)) {
        // The chosen spot sits mid-block, as it usually would.
        for (CGFloat x = fmod(center.x + spacing / 2, spacing); x <= CGRectGetWidth(bounds); x += spacing) {
            [path moveToPoint:CGPointMake(x, 0)]; [path addLineToPoint:CGPointMake(x, CGRectGetHeight(bounds))];
        }
        for (CGFloat y = fmod(center.y + spacing / 2, spacing); y <= CGRectGetHeight(bounds); y += spacing) {
            [path moveToPoint:CGPointMake(0, y)]; [path addLineToPoint:CGPointMake(CGRectGetWidth(bounds), y)];
        }
    }
    _streets.lineWidth = MIN(3, MAX(1, spacing * 0.3));
    _streets.path = path.CGPath;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in @[_streets, _circle]) layer.frame = self.bounds;
    _circle.path = [self circlePath].CGPath;
    _spot.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _knob.position = [self knobPosition];
    [self updateStreets];
    [CATransaction commit];
    if (!CGSizeEqualToSize(_laidOut, self.bounds.size)) {
        _laidOut = self.bounds.size;
        [self restartDrift];
    }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self restartDrift];
}
- (void)setRadius:(double)radius animated:(BOOL)animated {
    if (!isfinite(radius) || fabs(radius - _radius) < 0.001) return;
    id from = (__bridge id)_circle.path; // Kept alive past the path change below.
    CGPoint knobFrom = _knob.position;
    _radius = radius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _circle.path = [self circlePath].CGPath;
    _knob.position = [self knobPosition];
    [self updateStreets];
    [CATransaction commit];
    if (animated && from && LSMapAnimationsEnabled()) {
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"path"];
        grow.fromValue = from;
        grow.duration = 0.3;
        grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_circle addAnimation:grow forKey:@"grow"];
        CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"position"];
        slide.fromValue = [NSValue valueWithCGPoint:knobFrom];
        slide.duration = grow.duration;
        slide.timingFunction = grow.timingFunction;
        [_knob addAnimation:slide forKey:@"slide"];
    }
    if (_dragging) [self placeReadout];
    // Restarting the drift on every slider tick made the dot jump; wait for a pause.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restartDrift) object:nil];
    [self performSelector:@selector(restartDrift) withObject:nil afterDelay:0.25];
}
- (void)restartDrift {
    [_dot removeAnimationForKey:@"drift"];
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat reach = [self circlePoints] * 0.72;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _dot.position = LSMapAnimationsEnabled() ? center : CGPointMake(center.x + reach * 0.6, center.y - reach * 0.4);
    [CATransaction commit];
    if (!self.window || !LSMapAnimationsEnabled() || CGRectIsEmpty(self.bounds)) return;
    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:center]];
    for (int i = 0; i < 7; i++) {
        double angle = arc4random_uniform(360) * M_PI / 180.0;
        double distance = reach * sqrt(arc4random_uniform(1000) / 1000.0);
        [points addObject:[NSValue valueWithCGPoint:CGPointMake(center.x + cos(angle) * distance, center.y + sin(angle) * distance)]];
    }
    [points addObject:[NSValue valueWithCGPoint:center]];
    CAKeyframeAnimation *drift = [CAKeyframeAnimation animationWithKeyPath:@"position"];
    drift.values = points;
    drift.duration = 12;
    drift.calculationMode = kCAAnimationCubic;
    drift.repeatCount = HUGE_VALF;
    drift.removedOnCompletion = NO;
    [_dot addAnimation:drift forKey:@"drift"];
}
- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end

static UILabel *LSSettingsTitle(NSString *text) {
    UILabel *label = LSLabel(text, UIFontTextStyleBody);
    label.font = LSFont(UIFontTextStyleBody, UIFontWeightRegular, 40);
    return label;
}
static UILabel *LSSettingsDetail(NSString *text) {
    UILabel *label = LSLabel(text, UIFontTextStyleFootnote);
    label.font = LSFont(UIFontTextStyleFootnote, UIFontWeightRegular, 30);
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}
// Error text with a symbol, so the state never depends on red alone. The row is what
// shows and hides; its last arranged view is the label.
static UIStackView *LSSettingsErrorRow(void) {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.circle.fill"]];
    icon.tintColor = LSErrorColor();
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote];
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [icon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    icon.isAccessibilityElement = NO;
    UILabel *label = LSLabel(@"", UIFontTextStyleFootnote);
    label.font = LSFont(UIFontTextStyleFootnote, UIFontWeightMedium, 30);
    label.textColor = LSErrorColor();
    UIStackView *row = LSRow(@[icon, label], 6);
    row.alignment = UIStackViewAlignmentFirstBaseline;
    row.hidden = YES;
    row.alpha = 0;
    return row;
}
static void LSSettingsAddUnit(UITextField *field, NSString *unit) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 34, 44)];
    label.text = unit;
    label.font = LSFont(UIFontTextStyleBody, UIFontWeightRegular, 28);
    label.textColor = UIColor.secondaryLabelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.isAccessibilityElement = NO;
    field.rightView = label;
    field.rightViewMode = UITextFieldViewModeAlways;
    // The unit takes the clear button's place; these values are short to delete.
    field.clearButtonMode = UITextFieldViewModeNever;
}
// Puts content in a card row: inset like a grouped cell, at least 52 pt, with a hairline
// above it (except the first row) that starts where the text does. Bottom and centering
// constraints are optional so a hidden row collapses without conflicts.
static UIView *LSSettingsRow(UIView *row, UIView *content, BOOL separator, CGFloat leading) {
    row.translatesAutoresizingMaskIntoConstraints = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:content];
    NSLayoutConstraint *hug = [content.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-11];
    hug.priority = UILayoutPriorityDefaultLow;
    NSLayoutConstraint *bottom = [content.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-11];
    bottom.priority = 999;
    NSLayoutConstraint *center = [content.centerYAnchor constraintEqualToAnchor:row.centerYAnchor];
    center.priority = 999;
    NSLayoutConstraint *minimum = [row.heightAnchor constraintGreaterThanOrEqualToConstant:52];
    minimum.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:11],
        [content.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:leading],
        [content.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kLSSettingsInset],
        hug, bottom, center, minimum]];
    if (separator) {
        UIView *line = LSSeparator();
        [row addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [line.topAnchor constraintEqualToAnchor:row.topAnchor],
            [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kLSSettingsTextInset],
            [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]]];
    }
    return row;
}
static UIView *LSSettingsCard(NSArray<UIView *> *rows) {
    UIStackView *stack = LSStack(rows, 0);
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = LSCardColor();
    card.layer.cornerRadius = LSRadiusM;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES; // Pressed rows highlight right up to the rounded edge.
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor]]];
    return card;
}
static UIView *LSSettingsInset(UIView *view) {
    UIStackView *wrap = LSStack(@[view], 0);
    wrap.layoutMargins = UIEdgeInsetsMake(0, kLSSettingsInset, 0, kLSSettingsInset);
    wrap.layoutMarginsRelativeArrangement = YES;
    return wrap;
}
static UIView *LSSettingsSection(NSString *header, UIView *card, NSString *footer) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    if (header) [views addObject:LSSettingsInset(LSSectionLabel(header))];
    [views addObject:card];
    if (footer) [views addObject:LSSettingsInset(LSSettingsDetail(footer))];
    return LSStack(views, LSSpaceS);
}

#pragma mark - Controller

@interface LSSettingsViewController () <UITextFieldDelegate, UIAdaptivePresentationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) LSSettings *original;
@property (nonatomic, strong) LSSettings *draft;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITextField *altitudeField, *courseField, *radiusField;
@property (nonatomic, strong) UIStackView *altitudeErrorRow, *courseErrorRow, *radiusErrorRow;
@property (nonatomic, strong) UILabel *altitudeDetail, *courseDetail, *radiusDetail, *radiusValue;
@property (nonatomic, strong) UIImageView *compassArrow;
@property (nonatomic, strong) LSSettingsWanderPreview *wanderPreview;
@property (nonatomic, strong) LSSettingsRadiusSlider *radiusSlider;
@property (nonatomic) double lastDetent;
@property (nonatomic, strong) UIView *radiusRow;
@property (nonatomic, strong) UISwitch *fluctuationSwitch, *rememberSwitch, *realSwitch, *openerSwitch, *backgroundSwitch;
@property (nonatomic, strong) LSSettingsActionRow *clipboardRestoreRow;
@property (nonatomic, strong) UILabel *editedLabel;
@property (nonatomic, strong) UIView *titleStack;
@property (nonatomic) BOOL edited;
@property (nonatomic) BOOL saving;
@property (nonatomic) CGSize previousScrollSize;
@end

@implementation LSSettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.original = LSSettings.storedSettings;
    self.draft = [self.original copy];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    save.style = UIBarButtonItemStyleDone;
    save.enabled = NO;
    self.navigationItem.rightBarButtonItem = save;
    [self buildTitleView];
    [self buildControls];

    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];
    UIStackView *page = LSStack(@[[self locationSection], [self wanderSection], [self screenSection], [self routineSection], [self backupSection]], LSSpaceXL + LSSpaceXS);
    [self.scroll addSubview:page];
    UILayoutGuide *content = self.scroll.contentLayoutGuide, *frame = self.scroll.frameLayoutGuide;
    NSLayoutConstraint *fullWidth = [page.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-40];
    fullWidth.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [page.topAnchor constraintEqualToAnchor:content.topAnchor constant:LSSpaceL],
        [page.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-32],
        [page.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [content.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        // Readable width on iPad and in landscape.
        [page.widthAnchor constraintLessThanOrEqualToConstant:640],
        fullWidth
    ]];
    LSAnchorAboveKeyboard(self.scroll, self.view);
    [self updateLiveDetailsAnimated:NO];
    [self syncSliderToField];
    [self updateEditedState];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(updateClipboardButton) name:UIPasteboardChangedNotification object:nil];
    [center addObserver:self selector:@selector(updateClipboardButton) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)buildTitleView {
    UILabel *title = LSLabel(@"Settings", UIFontTextStyleHeadline);
    title.font = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 20);
    title.numberOfLines = 1;
    title.textAlignment = NSTextAlignmentCenter;
    self.editedLabel = LSLabel(@"Unsaved changes", UIFontTextStyleCaption1);
    self.editedLabel.font = LSFont(UIFontTextStyleCaption1, UIFontWeightMedium, 14);
    self.editedLabel.textColor = UIColor.secondaryLabelColor;
    self.editedLabel.numberOfLines = 1;
    self.editedLabel.hidden = YES;
    UIStackView *stack = LSStack(@[title, self.editedLabel], 0);
    stack.alignment = UIStackViewAlignmentCenter;
    stack.isAccessibilityElement = YES;
    stack.accessibilityTraits = UIAccessibilityTraitHeader;
    stack.accessibilityLabel = @"Settings";
    self.titleStack = stack;
    self.navigationItem.titleView = stack;
}
- (void)buildControls {
    self.altitudeField = LSNumberField(@"Altitude in meters");
    self.courseField = LSNumberField(@"Course in degrees");
    self.radiusField = LSNumberField(@"Exact wander radius in meters");
    for (UITextField *field in @[self.altitudeField, self.courseField, self.radiusField]) field.accessibilityLabel = [self labelForField:field];
    self.altitudeField.placeholder = @"0";
    self.courseField.placeholder = @"0";
    self.radiusField.placeholder = @"25";
    LSSettingsAddUnit(self.altitudeField, @"m");
    LSSettingsAddUnit(self.courseField, @"°");
    LSSettingsAddUnit(self.radiusField, @"m");
    self.altitudeField.returnKeyType = UIReturnKeyNext;
    self.courseField.returnKeyType = UIReturnKeyNext;
    self.radiusField.returnKeyType = UIReturnKeyDone;
    for (UITextField *field in @[self.altitudeField, self.courseField, self.radiusField]) {
        field.text = [self initialTextForField:field];
        field.delegate = self;
        field.accessibilityHint = [self hintForField:field];
        [field addTarget:self action:@selector(fieldEdited:) forControlEvents:UIControlEventEditingChanged];
        LSInstallNumberToolbar(field, self, @selector(dismissKeyboard));
        NSLayoutConstraint *width = [field.widthAnchor constraintEqualToConstant:124];
        width.priority = 999; // Gives way to the full width when the row stacks.
        width.active = YES;
    }
    self.altitudeErrorRow = LSSettingsErrorRow();
    self.courseErrorRow = LSSettingsErrorRow();
    self.radiusErrorRow = LSSettingsErrorRow();
    self.altitudeDetail = LSSettingsDetail(@"");
    self.courseDetail = LSSettingsDetail(@"");
    self.radiusDetail = LSSettingsDetail(@"");
    self.fluctuationSwitch = [[UISwitch alloc] init];
    self.rememberSwitch = [[UISwitch alloc] init];
    self.realSwitch = [[UISwitch alloc] init];
    self.openerSwitch = [[UISwitch alloc] init];
    self.backgroundSwitch = [[UISwitch alloc] init];
    self.fluctuationSwitch.on = self.original.fluctuationEnabled;
    self.rememberSwitch.on = self.original.rememberLocation;
    self.realSwitch.on = self.original.showRealLocation;
    self.openerSwitch.on = self.original.showFloatingButton;
    self.backgroundSwitch.on = self.original.continueInBackground;
}
- (NSString *)initialTextForField:(UITextField *)field {
    if (field == self.altitudeField) return LSFormatDecimal(self.original.altitude, 2);
    if (field == self.courseField) return LSFormatDecimal(self.original.course, 1);
    return LSFormatDecimal(self.original.fluctuationRadius, 1);
}
- (NSString *)labelForField:(UITextField *)field {
    if (field == self.altitudeField) return @"Altitude in meters";
    if (field == self.courseField) return @"Course in degrees";
    return @"Exact wander radius in meters";
}
- (NSString *)hintForField:(UITextField *)field {
    if (field == self.altitudeField) return @"From −500 to 10,000 meters, sent with held spots and routes.";
    if (field == self.courseField) return @"From 0 to less than 360 degrees. 0 is north, 90 is east.";
    return @"From 1 to 1,000 meters.";
}

#pragma mark Sections

- (UIView *)locationSection {
    UIView *altitude = [self fieldRow:@"Altitude" badge:LSIconBadge(@"mountain.2.fill", UIColor.systemBrownColor, kLSSettingsBadge)
                                field:self.altitudeField detail:self.altitudeDetail error:self.altitudeErrorRow separator:NO];
    UIView *course = [self fieldRow:@"Course" badge:[self compassBadge]
                              field:self.courseField detail:self.courseDetail error:self.courseErrorRow separator:YES];
    return LSSettingsSection(@"Reported location", LSSettingsCard(@[altitude, course]),
                             @"Altitude is sent with held spots and routes. Course applies to held spots; a route faces the way it travels.");
}
- (UIView *)wanderSection {
    UIView *toggle = [self switchRow:@"Wander while holding" detail:@"Drifts slowly, like a real GPS fix"
                                hint:@"While a spot is held, the reported position drifts slowly inside the radius at an uneven pace, the way a real GPS fix does."
                              symbol:@"dot.radiowaves.left.and.right" color:LSRouteColor() control:self.fluctuationSwitch separator:NO];
    self.wanderPreview = [[LSSettingsWanderPreview alloc] init];
    [self.wanderPreview.heightAnchor constraintEqualToConstant:104].active = YES;

    self.radiusValue = LSLabel(@"", UIFontTextStyleTitle1);
    UIFontDescriptor *rounded = [[UIFont systemFontOfSize:28 weight:UIFontWeightBold].fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    UIFont *big = rounded ? [UIFont fontWithDescriptor:rounded size:28] : [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    self.radiusValue.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:big maximumPointSize:52];
    self.radiusValue.isAccessibilityElement = NO;
    UIStackView *reading = LSStack(@[self.radiusValue, self.radiusDetail], 2);
    LSSettingsReflowStack *line = LSSettingsFlow(@[reading, self.radiusField], LSSpaceM, UIStackViewAlignmentFill, NO);

    self.radiusSlider = [[LSSettingsRadiusSlider alloc] init];
    self.radiusSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.radiusSlider.minimumTrackTintColor = LSAccentColor();
    UIImageSymbolConfiguration *small = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleCaption2];
    UIImageSymbolConfiguration *large = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle3];
    self.radiusSlider.minimumValueImage = [UIImage systemImageNamed:@"circle" withConfiguration:small];
    self.radiusSlider.maximumValueImage = [UIImage systemImageNamed:@"circle" withConfiguration:large];
    self.radiusSlider.tintColor = UIColor.secondaryLabelColor;
    self.radiusSlider.accessibilityLabel = @"Wander radius";
    self.radiusSlider.accessibilityHint = @"Swipe up or down to step through 1, 5, 10, 25, 50, 100, 250, 500 and 1,000 meters.";
    __weak typeof(self) weakSelf = self;
    self.radiusSlider.describe = ^NSString *{
        NSNumber *radius = [weakSelf liveValue:weakSelf.radiusField];
        return radius ? [NSString stringWithFormat:@"%@ meters, %@", LSFormatDecimal(radius.doubleValue, 1), LSSettingsWanderComparison(radius.doubleValue).lowercaseString] : @"Not set";
    };
    [self.radiusSlider addTarget:self action:@selector(radiusSlid) forControlEvents:UIControlEventValueChanged];
    // Same rounding and detents as the slider.
    self.wanderPreview.dragged = ^(double meters) { [weakSelf applyRadius:LSSettingsSliderMeters(LSSettingsSliderValue(meters))]; };
    [self.radiusSlider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;

    UIStackView *content = LSStack(@[self.wanderPreview, line, self.radiusSlider, self.radiusErrorRow], LSSpaceM);
    [content setCustomSpacing:LSSpaceXS afterView:line];
    self.radiusRow = LSSettingsRow([[UIView alloc] init], content, YES, kLSSettingsTextInset);
    self.radiusRow.accessibilityElements = @[self.radiusSlider, self.radiusField, self.radiusErrorRow.arrangedSubviews.lastObject];
    self.radiusRow.hidden = !self.fluctuationSwitch.on;
    self.radiusRow.alpha = self.fluctuationSwitch.on ? 1 : 0;
    return LSSettingsSection(@"Wander", LSSettingsCard(@[toggle, self.radiusRow]),
                             @"Drag the circle to resize it; its streets are about 100 m apart. Outdoors a phone is usually accurate to 5–20 m, so a small radius looks most natural. Saved places can set their own radius.");
}
- (UIView *)screenSection {
    UIView *real = [self switchRow:@"Real location on map" detail:@"A separate marker; the app still sees the spoof"
                              hint:@"Shows where you really are as a separate marker, using permission the app already has. It never changes the location the app receives."
                            symbol:@"person.crop.circle" color:UIColor.systemGrayColor control:self.realSwitch separator:NO];
    UIView *opener = [self switchRow:@"Floating button" detail:@"Tap to open, hold for route controls"
                                hint:@"A button you can drag anywhere over the app. Tap it to open this picker, or touch and hold it for quick route controls."
                              symbol:@"hand.tap.fill" color:LSAccentColor() control:self.openerSwitch separator:YES];
    return LSSettingsSection(@"On screen", LSSettingsCard(@[real, opener]),
                             @"With the button hidden, hold three fingers on the screen for a moment to open the picker.");
}
- (UIView *)routineSection {
    UIView *background = [self switchRow:@"Keep routes moving in the background" detail:@"Keeps playing after you leave the app"
                                    hint:@"A playing route keeps going after you leave the app, as long as the app already has background location access and iOS keeps it running. Otherwise the route pauses until you come back. Schedules need this to start on time in the background."
                                  symbol:@"figure.walk.motion" color:LSSuccessColor() control:self.backgroundSwitch separator:NO];
    UIView *remember = [self switchRow:@"Remember last selection" detail:@"Keeps your last spot to apply again"
                                  hint:@"Keeps the last spot you applied ready to apply again after Turn off or a relaunch. Turning this off forgets that spot."
                                symbol:@"clock.arrow.circlepath" color:UIColor.systemIndigoColor control:self.rememberSwitch separator:YES];
    return LSSettingsSection(@"Routes and memory", LSSettingsCard(@[background, remember]),
                             @"Turn off in the picker always stops spoofing, whatever is remembered.");
}
- (UIView *)backupSection {
    UIView *export = [self actionRow:@"Export backup file" symbol:@"square.and.arrow.up" color:LSAccentColor()
                                hint:@"Opens the share sheet with a backup file to keep in Files or iCloud Drive." action:@selector(exportBackup:) separator:NO];
    UIView *copy = [self actionRow:@"Copy backup" symbol:@"doc.on.doc" color:UIColor.systemGrayColor
                              hint:@"Copies the backup as text to paste into Notes or a message." action:@selector(copyBackup) separator:YES];
    UIView *file = [self actionRow:@"Restore from file" symbol:@"folder" color:UIColor.systemOrangeColor
                              hint:@"Choose a backup file. You see what it holds before anything changes." action:@selector(restoreFromFile) separator:YES];
    self.clipboardRestoreRow = [self actionRow:@"Restore from clipboard" symbol:@"doc.on.clipboard" color:UIColor.systemOrangeColor
                                          hint:@"Reads a copied backup. You see what it holds before anything changes." action:@selector(restoreFromClipboard) separator:YES];
    return LSSettingsSection(@"Backup", LSSettingsCard(@[export, copy, file, self.clipboardRestoreRow]),
                             @"Holds settings, saved places, recents and route preferences.");
}

#pragma mark Rows

- (UIView *)compassBadge {
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = UIColor.systemOrangeColor;
    badge.layer.cornerRadius = kLSSettingsBadge * 0.28;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.isAccessibilityElement = NO;
    // The arrow turns to the course as you type: a live compass.
    self.compassArrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"location.north.fill"]];
    self.compassArrow.translatesAutoresizingMaskIntoConstraints = NO;
    self.compassArrow.tintColor = UIColor.whiteColor;
    self.compassArrow.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:kLSSettingsBadge * 0.48 weight:UIImageSymbolWeightSemibold];
    [badge addSubview:self.compassArrow];
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:kLSSettingsBadge],
        [badge.heightAnchor constraintEqualToConstant:kLSSettingsBadge],
        [self.compassArrow.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [self.compassArrow.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor]]];
    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return badge;
}
- (UIView *)fieldRow:(NSString *)title badge:(UIView *)badge field:(UITextField *)field detail:(UILabel *)detail error:(UIStackView *)error separator:(BOOL)separator {
    UILabel *name = LSSettingsTitle(title);
    name.isAccessibilityElement = NO;
    detail.isAccessibilityElement = NO; // Read as the field's hint: one stop per setting.
    UIStackView *text = LSStack(@[name, detail], 2);
    LSSettingsReflowStack *line = LSSettingsFlow(@[text, field], LSSpaceM, UIStackViewAlignmentFill, NO);
    UIStackView *column = LSStack(@[line, error], 6);
    LSSettingsReflowStack *row = LSSettingsFlow(@[badge, column], LSSpaceM, UIStackViewAlignmentTop, YES);
    UIView *wrapper = LSSettingsRow([[UIView alloc] init], row, separator, kLSSettingsInset);
    wrapper.accessibilityElements = @[field, error.arrangedSubviews.lastObject];
    return wrapper;
}
- (UIView *)switchRow:(NSString *)title detail:(NSString *)detail hint:(NSString *)hint symbol:(NSString *)symbol color:(UIColor *)color control:(UISwitch *)control separator:(BOOL)separator {
    control.onTintColor = LSAccentColor();
    [control addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [control setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *text = LSStack(@[LSSettingsTitle(title), LSSettingsDetail(detail)], 2);
    text.userInteractionEnabled = NO;
    LSSettingsReflowStack *line = LSSettingsFlow(@[text, control], LSSpaceM, UIStackViewAlignmentLeading, NO);
    UIView *badge = LSIconBadge(symbol, color, kLSSettingsBadge);
    badge.userInteractionEnabled = NO;
    LSSettingsReflowStack *row = LSSettingsFlow(@[badge, line], LSSpaceM, UIStackViewAlignmentTop, YES);
    LSSettingsToggleRow *wrapper = [[LSSettingsToggleRow alloc] init];
    wrapper.toggle = control;
    [wrapper addTarget:wrapper action:@selector(flip) forControlEvents:UIControlEventTouchUpInside];
    LSSettingsRow(wrapper, row, separator, kLSSettingsInset);
    wrapper.isAccessibilityElement = YES;
    wrapper.accessibilityLabel = title;
    wrapper.accessibilityHint = hint;
    // Reuses the switch's own traits so VoiceOver says "switch button".
    wrapper.accessibilityTraits = control.accessibilityTraits | UIAccessibilityTraitButton;
    return wrapper;
}
- (LSSettingsActionRow *)actionRow:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color hint:(NSString *)hint action:(SEL)action separator:(BOOL)separator {
    LSSettingsActionRow *row = [[LSSettingsActionRow alloc] init];
    UILabel *name = LSSettingsTitle(title);
    name.textColor = LSAccentTextColor();
    LSSettingsReflowStack *content = LSSettingsFlow(@[LSIconBadge(symbol, color, kLSSettingsBadge), name], LSSpaceM, UIStackViewAlignmentTop, YES);
    content.userInteractionEnabled = NO;
    LSSettingsRow(row, content, separator, kLSSettingsInset);
    row.isAccessibilityElement = YES;
    row.accessibilityLabel = title;
    row.accessibilityHint = hint;
    row.accessibilityTraits = UIAccessibilityTraitButton;
    [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return row;
}

#pragma mark State

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.scroll.bounds.size;
    if (CGSizeEqualToSize(size, self.previousScrollSize)) return;
    self.previousScrollSize = size;
    for (UITextField *field in @[self.altitudeField, self.courseField, self.radiusField]) if (field.isFirstResponder) {
        [self.scroll scrollRectToVisible:CGRectInset([field convertRect:field.bounds toView:self.scroll], 0, -8) animated:NO];
    }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.presentationController.delegate = self;
    [self updateClipboardButton];
}
- (void)updateClipboardButton {
    // Reading the clipboard shows a paste banner; hasStrings does not.
    BOOL available = UIPasteboard.generalPasteboard.hasStrings;
    self.clipboardRestoreRow.enabled = available;
    self.clipboardRestoreRow.accessibilityHint = available ? @"Reads a copied backup. You see what it holds before anything changes." : @"The clipboard is empty. Copy a backup first.";
}
- (BOOL)field:(UITextField *)field changedFrom:(NSString *)initial {
    NSNumber *now = LSParseDecimal(field.text, NSLocale.currentLocale), *was = LSParseDecimal(initial, NSLocale.currentLocale);
    if (!now || !was) return ![field.text isEqualToString:initial];
    return fabs(now.doubleValue - was.doubleValue) > 1e-9;
}
- (BOOL)fieldChanged:(UITextField *)field { return [self field:field changedFrom:[self initialTextForField:field]]; }
- (NSArray<NSString *> *)changedSettingNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([self fieldChanged:self.altitudeField]) [names addObject:@"Altitude"];
    if ([self fieldChanged:self.courseField]) [names addObject:@"Course"];
    if (self.fluctuationSwitch.on != self.original.fluctuationEnabled) [names addObject:@"Wander while holding"];
    if ([self fieldChanged:self.radiusField]) [names addObject:@"Wander radius"];
    if (self.realSwitch.on != self.original.showRealLocation) [names addObject:@"Real location on map"];
    if (self.openerSwitch.on != self.original.showFloatingButton) [names addObject:@"Floating button"];
    if (self.backgroundSwitch.on != self.original.continueInBackground) [names addObject:@"Keep routes moving"];
    if (self.rememberSwitch.on != self.original.rememberLocation) [names addObject:@"Remember last selection"];
    return names;
}
// Save is only offered, and swipe-to-dismiss only guarded, while something differs from
// what is stored; changing a value back counts as no change.
- (void)updateEditedState {
    BOOL edited = [self changedSettingNames].count > 0;
    self.navigationItem.rightBarButtonItem.enabled = edited;
    self.modalInPresentation = edited;
    if (edited == self.edited) return;
    self.edited = edited;
    self.titleStack.accessibilityLabel = edited ? @"Settings, unsaved changes" : @"Settings";
    self.editedLabel.hidden = !edited;
    if (edited) {
        self.editedLabel.alpha = 0;
        LSAnimate(^{ self.editedLabel.alpha = 1; }, nil);
    }
    [self.titleStack setNeedsLayout];
    [self.navigationController.navigationBar setNeedsLayout];
}
- (nullable NSNumber *)liveValue:(UITextField *)field {
    NSNumber *number = LSParseDecimal(field.text, NSLocale.currentLocale);
    if (!number) return nil;
    double value = number.doubleValue;
    if (field == self.altitudeField) return value >= -500 && value <= 10000 ? number : nil;
    if (field == self.courseField) {
        // 359.9999999 was shown as 360 at six decimals and then failed its own check.
        value = fmod(round(value * 1e6) / 1e6, 360.0);
        return value >= 0 && value < 360 ? @(value) : nil;
    }
    return value >= 1 && value <= 1000 ? number : nil;
}
- (UIStackView *)errorRowForField:(UITextField *)field {
    return field == self.altitudeField ? self.altitudeErrorRow : (field == self.courseField ? self.courseErrorRow : self.radiusErrorRow);
}
- (UILabel *)errorForField:(UITextField *)field { return (UILabel *)[self errorRowForField:field].arrangedSubviews.lastObject; }
- (void)showError:(BOOL)visible forField:(UITextField *)field {
    UILabel *error = [self errorForField:field];
    // Ring plus the message in the field's label (hints can be turned off), in one call.
    LSSetFieldError(field, visible ? error.text : nil);
    field.accessibilityHint = [self hintForField:field];
    UIView *row = [self errorRowForField:field];
    if (row.hidden == !visible) return;
    if (visible && !self.saving) LSAnnounce(error.text); // Save announces its own.
    LSAnimate(^{
        row.hidden = !visible;
        row.alpha = visible ? 1 : 0;
        [self.scroll layoutIfNeeded];
    }, nil);
}
- (void)updateLiveDetailsAnimated:(BOOL)animated {
    NSNumber *altitude = [self liveValue:self.altitudeField];
    self.altitudeDetail.text = altitude ? LSSettingsAltitudeText(altitude.doubleValue) : @"From −500 to 10,000 m";
    NSNumber *course = [self liveValue:self.courseField];
    self.courseDetail.text = course ? LSSettingsCourseText(course.doubleValue) : @"From 0 to less than 360°";
    if (course) {
        CGAffineTransform turn = CGAffineTransformMakeRotation((CGFloat)(course.doubleValue * M_PI / 180.0));
        if (animated) LSAnimate(^{ self.compassArrow.transform = turn; }, nil);
        else self.compassArrow.transform = turn;
    }
    NSNumber *radius = [self liveValue:self.radiusField];
    self.radiusValue.text = radius ? [NSString stringWithFormat:@"%@ m", LSFormatDecimal(radius.doubleValue, 1)] : @"–";
    self.radiusDetail.text = radius ? LSSettingsWanderText(radius.doubleValue) : @"From 1 to 1,000 m";
    if (radius) [self.wanderPreview setRadius:radius.doubleValue animated:animated];
    for (UITextField *field in @[self.altitudeField, self.courseField]) {
        if ([self errorRowForField:field].hidden) {
            UILabel *detail = field == self.altitudeField ? self.altitudeDetail : self.courseDetail;
            field.accessibilityHint = [NSString stringWithFormat:@"%@. %@", detail.text, [self hintForField:field]];
        }
    }
}
- (void)syncSliderToField {
    NSNumber *radius = [self liveValue:self.radiusField];
    if (radius && !self.radiusSlider.isTracking) self.radiusSlider.value = LSSettingsSliderValue(radius.doubleValue);
    self.lastDetent = radius ? radius.doubleValue : 0;
}

#pragma mark Events

- (void)fieldEdited:(UITextField *)field {
    if (![self errorRowForField:field].hidden && [self liveValue:field]) [self showError:NO forField:field];
    if (field == self.radiusField) [self syncSliderToField];
    [self updateLiveDetailsAnimated:YES];
    [self updateEditedState];
}
- (void)radiusSlid { [self applyRadius:LSSettingsSliderMeters(self.radiusSlider.value)]; }
// From the slider or a drag on the preview: a haptic tick on each preset, then field,
// slider, readout and preview follow.
- (void)applyRadius:(double)meters {
    BOOL detent = NO;
    for (size_t i = 0; i < sizeof(kLSSettingsRadiusDetents) / sizeof(double); i++) detent = detent || meters == kLSSettingsRadiusDetents[i];
    if (detent && meters != self.lastDetent) LSHapticSelection();
    self.lastDetent = meters;
    NSString *text = LSFormatDecimal(meters, 0);
    if ([text isEqualToString:self.radiusField.text]) return;
    self.radiusField.text = text;
    [self validateField:self.radiusField format:NO];
    if (!self.radiusSlider.isTracking) self.radiusSlider.value = LSSettingsSliderValue(meters);
    [self updateLiveDetailsAnimated:NO];
    [self updateEditedState];
}
- (void)switchChanged:(UISwitch *)control {
    LSHapticSelection();
    if (control == self.fluctuationSwitch) [self setRadiusRowVisible:control.on];
    [self updateEditedState];
}
- (void)setRadiusRowVisible:(BOOL)visible {
    if (self.radiusRow.hidden == !visible) return;
    if (visible) [self syncSliderToField];
    LSAnimate(^{
        self.radiusRow.hidden = !visible;
        self.radiusRow.alpha = visible ? 1 : 0;
        [self.scroll layoutIfNeeded];
    }, ^{
        if (visible) [self.scroll scrollRectToVisible:[self.radiusRow convertRect:self.radiusRow.bounds toView:self.scroll] animated:LSMapAnimationsEnabled()];
    });
}
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (BOOL)validateField:(UITextField *)field format:(BOOL)format {
    NSNumber *value = [self liveValue:field];
    UILabel *error = [self errorForField:field];
    if (field == self.altitudeField) {
        error.text = @"Enter an altitude from −500 to 10,000 meters.";
        if (value) self.draft.altitude = value.doubleValue;
    } else if (field == self.courseField) {
        error.text = @"Enter a course from 0 to less than 360 degrees.";
        if (value) self.draft.course = value.doubleValue;
    } else {
        error.text = @"Enter a radius from 1 to 1,000 meters.";
        if (value) self.draft.fluctuationRadius = value.doubleValue;
    }
    [self showError:value == nil forField:field];
    if (value && format) field.text = LSFormatDecimal(value.doubleValue, 6);
    return value != nil;
}
- (void)textFieldDidBeginEditing:(UITextField *)field {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.scroll scrollRectToVisible:CGRectInset([field convertRect:field.bounds toView:self.scroll], 0, -12) animated:LSMapAnimationsEnabled()];
    });
}
- (void)textFieldDidEndEditing:(UITextField *)field {
    [self validateField:field format:YES];
    if (field == self.radiusField) [self syncSliderToField];
    [self updateLiveDetailsAnimated:YES];
    [self updateEditedState];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.altitudeField) [self.courseField becomeFirstResponder];
    else if (field == self.courseField && self.fluctuationSwitch.on) [self.radiusField becomeFirstResponder];
    else [self dismissKeyboard];
    return YES;
}
- (void)save {
    self.saving = YES;
    [self saveNow];
    self.saving = NO;
}
- (void)saveNow {
    [self.view endEditing:YES];
    if (!self.edited) { [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil]; return; }
    BOOL altitude = [self validateField:self.altitudeField format:NO];
    BOOL course = [self validateField:self.courseField format:NO];
    BOOL radius = !self.fluctuationSwitch.on || [self validateField:self.radiusField format:NO];
    if (!altitude || !course || !radius) {
        UITextField *invalid = !altitude ? self.altitudeField : (!course ? self.courseField : self.radiusField);
        [invalid becomeFirstResponder];
        LSHapticWarning();
        LSAnnounce([self errorForField:invalid].text);
        return;
    }
    // Untouched fields keep their stored precision rather than the rounded text shown.
    if (![self fieldChanged:self.altitudeField]) self.draft.altitude = self.original.altitude;
    if (![self fieldChanged:self.courseField]) self.draft.course = self.original.course;
    if (![self fieldChanged:self.radiusField]) self.draft.fluctuationRadius = self.original.fluctuationRadius;
    self.draft.fluctuationEnabled = self.fluctuationSwitch.on;
    self.draft.rememberLocation = self.rememberSwitch.on;
    self.draft.showRealLocation = self.realSwitch.on;
    self.draft.showFloatingButton = self.openerSwitch.on;
    self.draft.continueInBackground = self.backgroundSwitch.on;
    if (![LSSessionController.shared saveSettings:self.draft]) {
        LSShowToast(self.view, @"These settings couldn’t be saved. Check the values and try again.", @"exclamationmark.triangle.fill");
        LSHapticWarning();
        return;
    }
    [LSOverlayManager refreshOpeners];
    LSHapticSuccess();
    if (self.didSave) self.didSave();
    LSAnnounce(@"Settings saved");
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (void)presentationControllerDidAttemptToDismiss:(UIPresentationController *)controller {
    (void)controller;
    [self confirmDiscard];
}
// Swiping down used to throw away edited settings without a word; this names what changed.
- (void)confirmDiscard {
    if (self.presentedViewController) return;
    NSArray<NSString *> *names = [self changedSettingNames];
    NSString *list = [NSListFormatter localizedStringByJoiningStrings:names];
    NSString *message = names.count
        ? [NSString stringWithFormat:@"You changed %@. Save to apply %@ now, or discard to keep things as they were.", list, names.count == 1 ? @"it" : @"them"]
        : @"You have unsaved changes.";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save changes" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf save]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Discard changes" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Keep editing" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    [self presentViewController:sheet animated:LSMapAnimationsEnabled() completion:nil];
}
#pragma mark - Backup (#21)

- (void)exportBackup:(UIView *)sender {
    NSData *data = [LSBackup exportData];
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"LSpoof Backup"] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *file = [folder URLByAppendingPathComponent:[LSBackup suggestedFileName]];
    if (!data.length || ![data writeToURL:file atomically:YES]) {
        LSShowToast(self.view, @"The backup could not be written.", @"exclamationmark.triangle.fill");
        LSHapticWarning();
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sender;
    share.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:share animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)copyBackup {
    NSString *text = [[NSString alloc] initWithData:[LSBackup exportData] encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    UIPasteboard.generalPasteboard.string = text;
    LSHapticSuccess();
    LSShowToast(self.view, @"Backup copied. Paste it into Notes or a message to keep it.", @"doc.on.doc.fill");
    [self updateClipboardButton];
}

- (void)restoreFromFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON, UTTypePlainText, UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSData *data = size.unsignedLongLongValue <= 2 * 1024 * 1024 ? [NSData dataWithContentsOfURL:url] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data) {
        LSShowToast(self.view, size.unsignedLongLongValue > 2 * 1024 * 1024 ? @"That file is too large to be an LSpoof backup." : @"The file could not be read.", @"exclamationmark.triangle.fill");
        LSHapticWarning();
        return;
    }
    [self offerRestore:data];
}

- (void)restoreFromClipboard {
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (![LSBackup textLooksLikeBackup:text]) {
        LSShowToast(self.view, @"The clipboard doesn’t hold an LSpoof backup.", @"doc.on.clipboard");
        LSHapticWarning();
        return;
    }
    [self offerRestore:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSString *LSSettingsCount(NSUInteger count, NSString *one, NSString *many) {
    return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? one : many];
}

- (void)offerRestore:(NSData *)data {
    NSString *error = nil;
    LSBackupSummary *summary = [LSBackup inspectData:data error:&error];
    if (!summary) {
        LSShowToast(self.view, error ?: @"This isn’t an LSpoof backup.", @"exclamationmark.triangle.fill");
        LSHapticWarning();
        return;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:LSSettingsCount(summary.placeCount, @"saved place", @"saved places")];
    [parts addObject:LSSettingsCount(summary.recentCount, @"recent location", @"recent locations")];
    if (summary.hasSettings) [parts addObject:@"settings"];
    NSString *when = summary.exportedAt ? [NSString stringWithFormat:@" from %@", [NSDateFormatter localizedStringFromDate:summary.exportedAt dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]] : @"";
    NSUInteger places = BookmarksManager.shared.allBookmarks.count, recents = PersistenceManager.shared.recentLocations.count;
    // Names what each choice does to what is on this device now.
    NSString *mergeText = places ? [NSString stringWithFormat:@"Merge keeps your %@ and adds the ones you don’t have yet.", LSSettingsCount(places, @"saved place", @"saved places")]
                             : @"Merge adds the backup’s places.";
    NSString *replaceText = places || recents
        ? [NSString stringWithFormat:@"Replace removes your %@ and %@ and uses the backup’s instead.", LSSettingsCount(places, @"saved place", @"saved places"), LSSettingsCount(recents, @"recent location", @"recent locations")]
        : @"Replace uses the backup’s places and recents.";
    NSMutableString *message = [NSMutableString stringWithFormat:@"This backup%@ has %@.\n\n%@\n%@\nSettings are restored either way.",
                                when, [NSListFormatter localizedStringByJoiningStrings:parts], mergeText, replaceText];
    if (self.edited) [message appendString:@"\n\nRestoring closes Settings, so your unsaved changes here are discarded."];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore backup?" message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    UIAlertAction *merge = [UIAlertAction actionWithTitle:@"Merge" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf restore:data replace:NO]; }];
    [alert addAction:merge];
    [alert addAction:[UIAlertAction actionWithTitle:@"Replace" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [weakSelf restore:data replace:YES]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.preferredAction = merge;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)restore:(NSData *)data replace:(BOOL)replace {
    NSString *error = nil;
    LSBackupSummary *result = [LSBackup restoreData:data replace:replace error:&error];
    if (!result) {
        LSShowToast(self.view, error ?: @"The backup could not be restored.", @"exclamationmark.triangle.fill");
        LSHapticWarning();
        return;
    }
    // The stored settings changed underneath this screen's edits, so it closes.
    [LSOverlayManager refreshOpeners];
    LSHapticSuccess();
    NSString *message = [NSString stringWithFormat:@"Backup restored: %@ added.", LSSettingsCount(result.placeCount, @"place", @"places")];
    void (^done)(NSString *) = self.didRestore;
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:^{ if (done) done(message); }];
}

- (void)cancel {
    if (self.edited) { [self confirmDiscard]; return; }
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *save = [UIKeyCommand keyCommandWithInput:@"s" modifierFlags:UIKeyModifierCommand action:@selector(save)];
    save.discoverabilityTitle = @"Save settings";
    return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancel)], save];
}
@end
