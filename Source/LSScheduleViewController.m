#import "LSScheduleViewController.h"
#import "LSScheduler.h"
#import "LSUI.h"

// Same grouped-list geometry as Settings: 30 pt badges, separators from the text edge.
static const CGFloat kLSScheduleBadge = 30;
static const CGFloat kLSScheduleInset = 16;
static const CGFloat kLSScheduleTextInset = 16 + 30 + 12;
// LSScheduler refuses starts more than 366 days ahead.
static const NSTimeInterval kLSScheduleHorizon = 365 * 24 * 3600;

static BOOL LSScheduleLargeText(UITraitCollection *traits) {
    UIContentSizeCategory category = traits.preferredContentSizeCategory;
    if (!category.length || [category isEqualToString:UIContentSizeCategoryUnspecified]) category = UIApplication.sharedApplication.preferredContentSizeCategory;
    return UIContentSizeCategoryIsAccessibilityCategory(category);
}
static NSDate *LSRoundedFuture(NSTimeInterval ahead) {
    NSTimeInterval value = NSDate.date.timeIntervalSinceReferenceDate + ahead;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:ceil(value / 300.0) * 300.0];
}
static NSDate *LSScheduleNextMinute(NSTimeInterval ahead) {
    NSTimeInterval value = NSDate.date.timeIntervalSinceReferenceDate + ahead;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:ceil(value / 60.0) * 60.0];
}
static NSDate *LSScheduleTomorrowAt(NSInteger hour) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *tomorrow = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:[calendar startOfDayForDate:NSDate.date] options:0];
    return [calendar dateBySettingHour:hour minute:0 second:0 ofDate:tomorrow options:0] ?: tomorrow;
}
static NSString *LSScheduleTime(NSDate *date) {
    return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
}
static NSString *LSScheduleDay(NSDate *date, BOOL inSentence) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    if ([calendar isDateInToday:date]) return inSentence ? @"today" : @"Today";
    if ([calendar isDateInTomorrow:date]) return inSentence ? @"tomorrow" : @"Tomorrow";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setLocalizedDateFormatFromTemplate:@"EEEdMMM"];
    return [formatter stringFromDate:date];
}
static NSString *LSScheduleDuration(NSTimeInterval seconds, NSDateComponentsFormatterUnitsStyle style) {
    NSDateComponentsFormatter *formatter = [[NSDateComponentsFormatter alloc] init];
    formatter.unitsStyle = style;
    formatter.allowedUnits = NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute;
    formatter.maximumUnitCount = 2;
    return [formatter stringFromTimeInterval:MAX(60, ceil(seconds / 60.0) * 60.0)] ?: @"";
}
// The one thing that matters, in big type: "Starts in 25 min", "On until 9:00 PM".
static NSString *LSScheduleHeadline(NSDate *start, NSDate *end, BOOL active) {
    if (active) return end ? [NSString stringWithFormat:@"On until %@", LSScheduleTime(end)] : @"On now";
    NSTimeInterval ahead = start.timeIntervalSinceNow;
    if (ahead < 60) return @"Starts now";
    if (ahead < 12 * 3600) return [NSString stringWithFormat:@"Starts in %@", LSScheduleDuration(ahead, NSDateComponentsFormatterUnitsStyleShort)];
    return [NSString stringWithFormat:@"Starts %@ at %@", LSScheduleDay(start, YES), LSScheduleTime(start)];
}

#pragma mark - Building blocks

// Title and control side by side when both fit at their natural width; otherwise (a small
// phone, large or accessibility text) the title goes above the control instead of being
// squeezed into a sliver.
@interface LSScheduleFlowStack : UIStackView
@property (nonatomic) BOOL stacksWhenNarrow;
@end
@implementation LSScheduleFlowStack
- (BOOL)shouldStack {
    if (LSScheduleLargeText(self.traitCollection)) return YES;
    CGFloat width = CGRectGetWidth(self.bounds);
    if (!self.stacksWhenNarrow || width <= 0) return NO;
    CGFloat needed = 0;
    NSUInteger visible = 0;
    for (UIView *view in self.arrangedSubviews) {
        if (view.hidden) continue;
        visible++;
        // A wrapped label reports its wrapped width, so measure it on one line.
        CGSize size = [view isKindOfClass:UILabel.class] ? [view sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)] : view.intrinsicContentSize;
        if (size.width <= 0) size = [view systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
        needed += size.width;
    }
    if (visible > 1) needed += self.spacing * (visible - 1);
    return needed > width + 0.5;
}
- (void)layoutSubviews {
    // The decision depends only on the width this stack is given, so it settles in one pass.
    BOOL stacked = [self shouldStack];
    UILayoutConstraintAxis axis = stacked ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    UIStackViewAlignment alignment = stacked ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    if (self.axis != axis) self.axis = axis;
    if (self.alignment != alignment) self.alignment = alignment;
    [super layoutSubviews];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsLayout];
}
@end

// A switch row that is one VoiceOver stop and toggles from a tap anywhere on it.
@interface LSScheduleToggleRow : UIControl
@property (nonatomic, strong) UISwitch *toggle;
@end
@implementation LSScheduleToggleRow
- (void)flip {
    [self.toggle setOn:!self.toggle.on animated:LSMapAnimationsEnabled()];
    [self.toggle sendActionsForControlEvents:UIControlEventValueChanged];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return !hit || [hit isDescendantOfView:self.toggle] ? hit : self;
}
- (NSString *)accessibilityValue { return self.toggle.on ? @"On" : @"Off"; }
- (BOOL)accessibilityActivate { [self flip]; return YES; }
@end

static UILabel *LSScheduleTitle(NSString *text) {
    UILabel *label = LSLabel(text, UIFontTextStyleBody);
    label.font = LSFont(UIFontTextStyleBody, UIFontWeightRegular, 40);
    return label;
}
// Card row content inset like a grouped cell, at least 52 pt, with a hairline above that
// starts at the text. Bottom and centering are optional so a hidden row collapses cleanly.
static UIView *LSScheduleRow(UIView *row, UIView *content, BOOL separator, CGFloat leading) {
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
        [content.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kLSScheduleInset],
        hug, bottom, center, minimum]];
    if (separator) {
        UIView *line = LSSeparator();
        [row addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [line.topAnchor constraintEqualToAnchor:row.topAnchor],
            [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kLSScheduleTextInset],
            [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]]];
    }
    return row;
}
static UIView *LSScheduleCard(NSArray<UIView *> *rows) {
    UIStackView *stack = LSStack(rows, 0);
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = LSCardColor();
    card.layer.cornerRadius = LSRadiusM;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor]]];
    return card;
}
static UIStackView *LSScheduleInset(UIView *view) {
    UIStackView *wrap = LSStack(@[view], 0);
    wrap.layoutMargins = UIEdgeInsetsMake(0, kLSScheduleInset, 0, kLSScheduleInset);
    wrap.layoutMarginsRelativeArrangement = YES;
    return wrap;
}
static UILabel *LSScheduleFootnote(NSString *text) {
    UILabel *label = LSLabel(text, UIFontTextStyleFootnote);
    label.font = LSFont(UIFontTextStyleFootnote, UIFontWeightRegular, 30);
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}
static UIView *LSScheduleBullet(NSString *symbol, NSString *text) {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.contentMode = UIViewContentModeCenter;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleMedium];
    icon.isAccessibilityElement = NO;
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *label = LSLabel(text, UIFontTextStyleSubheadline);
    label.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightRegular, 32);
    label.textColor = UIColor.secondaryLabelColor;
    UIStackView *row = LSRow(@[icon, label], 10);
    row.alignment = UIStackViewAlignmentFirstBaseline;
    return row;
}
static UIButton *LSScheduleChip(NSString *title, NSString *spoken) {
    UIButton *chip = LSChipButton(title, nil);
    chip.accessibilityLabel = spoken;
    return chip;
}
// Chips scroll sideways instead of wrapping, so large text never pushes them off screen.
static UIView *LSScheduleChipStrip(NSArray<UIButton *> *chips) {
    UIStackView *row = LSRow(chips, LSSpaceS);
    UIScrollView *strip = [[UIScrollView alloc] init];
    strip.translatesAutoresizingMaskIntoConstraints = NO;
    strip.showsHorizontalScrollIndicator = NO;
    [strip addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:strip.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:strip.contentLayoutGuide.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:strip.contentLayoutGuide.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:strip.contentLayoutGuide.trailingAnchor],
        [row.heightAnchor constraintEqualToAnchor:strip.frameLayoutGuide.heightAnchor]]];
    return strip;
}

// Soft fade from clear to the page colour behind the pinned action, so content scrolling
// under it dims instead of colliding with it.
@interface LSScheduleFadeView : UIView
@end
@implementation LSScheduleFadeView
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
        [self updateColors];
    }
    return self;
}
- (void)updateColors {
    UIColor *page = [UIColor.systemGroupedBackgroundColor resolvedColorWithTraitCollection:self.traitCollection];
    CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
    gradient.colors = @[(__bridge id)[page colorWithAlphaComponent:0].CGColor, (__bridge id)[page colorWithAlphaComponent:0.9].CGColor, (__bridge id)page.CGColor];
    gradient.locations = @[@0, @0.5, @1];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateColors];
}
@end

// A countdown under an hour is live: VoiceOver re-reads it while focused.
static UIAccessibilityTraits LSScheduleSummaryTraits(NSDate *start, BOOL active) {
    NSTimeInterval ahead = start.timeIntervalSinceNow;
    return UIAccessibilityTraitStaticText | (!active && ahead > 0 && ahead < 3600 ? UIAccessibilityTraitUpdatesFrequently : UIAccessibilityTraitNone);
}

#pragma mark - Controller

@interface LSScheduleViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *currentSection;
@property (nonatomic, strong, nullable) LSStatusChip *currentChip;
@property (nonatomic) NSInteger chipState; // 0 unset, 1 waiting, 2 on
@property (nonatomic, strong) UIStackView *currentSlot;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, copy, nullable) NSString *currentSignature;
@property (nonatomic, copy, nullable) NSString *previewSignature;
@property (nonatomic, strong) UILabel *previewHeader;
@property (nonatomic, strong) UIStackView *previewSlot;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, strong) UIDatePicker *startPicker;
@property (nonatomic, strong) UIDatePicker *endPicker;
@property (nonatomic, strong) UISwitch *endSwitch;
@property (nonatomic, strong) UISwitch *dailySwitch;
@property (nonatomic, strong) UIView *endRow;
@property (nonatomic, strong) UIStackView *errorRow;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong, nullable) UIView *actionBar;
@property (nonatomic, strong, nullable) NSTimer *clock;
@property (nonatomic) NSTimeInterval duration;
@end

@implementation LSScheduleViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Schedule";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.duration = 3600;
    // Fallback for callers that don't set the flag: the picker words routes "Play the route …".
    if (!self.subjectIsRoute && [self.subject hasPrefix:@"Play the route"]) self.subjectIsRoute = YES;
    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    self.currentSection = LSStack(@[], LSSpaceS);
    NSMutableArray<UIView *> *sections = [NSMutableArray arrayWithObject:self.currentSection];
    if (self.subject.length) [self buildFormInto:sections];
    self.emptyView = [self buildEmptyState];
    [sections addObject:self.emptyView];
    UIStackView *page = LSStack(sections, LSSpaceXL + LSSpaceXS);
    [self.scroll addSubview:page];
    UILayoutGuide *content = self.scroll.contentLayoutGuide, *frame = self.scroll.frameLayoutGuide;
    NSLayoutConstraint *fullWidth = [page.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-40];
    fullWidth.priority = 999;
    // Fills the visible height when shown (taller content wins); a hidden one collapses.
    NSLayoutConstraint *emptyHeight = [self.emptyView.heightAnchor constraintEqualToAnchor:frame.heightAnchor constant:-72];
    emptyHeight.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [page.topAnchor constraintEqualToAnchor:content.topAnchor constant:LSSpaceL],
        [page.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-32],
        [page.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [content.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        [page.widthAnchor constraintLessThanOrEqualToConstant:640],
        fullWidth, emptyHeight
    ]];
    if (self.subject.length) [self buildActionBar];
    [self reloadContent];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleChanged:) name:LSSchedulerDidChangeNotification object:nil];
}

// The one primary action floats on glass above the bottom safe area, so it stays in reach
// on small phones and at accessibility sizes however long the page gets.
- (void)buildActionBar {
    LSScheduleFadeView *fade = [[LSScheduleFadeView alloc] init];
    UIView *bar = LSGlassCapsule(self.saveButton, LSSpaceS);
    self.actionBar = bar;
    [self.view addSubview:fade];
    [self.view addSubview:bar];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *fullWidth = [bar.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-40];
    fullWidth.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [bar.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [bar.widthAnchor constraintLessThanOrEqualToConstant:640],
        fullWidth,
        [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-LSSpaceS],
        [fade.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [fade.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [fade.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [fade.topAnchor constraintEqualToAnchor:bar.topAnchor constant:-LSSpaceXL]]];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.actionBar) return;
    // Lets the last card scroll clear of the pinned action; the safe area is added by UIKit.
    CGFloat covered = MAX(0, CGRectGetHeight(self.view.bounds) - self.view.safeAreaInsets.bottom - CGRectGetMinY(self.actionBar.frame) + LSSpaceS);
    if (fabs(self.scroll.contentInset.bottom - covered) < 0.5) return;
    UIEdgeInsets inset = self.scroll.contentInset;
    inset.bottom = covered;
    self.scroll.contentInset = inset;
    UIEdgeInsets indicators = self.scroll.verticalScrollIndicatorInsets;
    indicators.bottom = covered;
    self.scroll.verticalScrollIndicatorInsets = indicators;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.clock invalidate];
    __weak typeof(self) weakSelf = self;
    // Keeps "Starts in 10 min" and the earliest allowed start current while open.
    self.clock = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf tick]; }];
    self.clock.tolerance = 5;
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.clock invalidate];
    self.clock = nil;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // Timeline dots are placed from font metrics and hold resolved colors.
    UITraitCollection *traits = self.traitCollection;
    if (![previous.preferredContentSizeCategory isEqualToString:traits.preferredContentSizeCategory] ||
        previous.userInterfaceStyle != traits.userInterfaceStyle || previous.accessibilityContrast != traits.accessibilityContrast) {
        self.currentSignature = nil;
        self.previewSignature = nil;
        [self reloadContent];
    }
}
- (void)scheduleChanged:(NSNotification *)note {
    (void)note;
    [self reloadContent];
}
- (void)tick {
    if (self.startPicker) {
        NSDate *before = self.startPicker.date;
        [self updatePickerLimits];
        if (![before isEqualToDate:self.startPicker.date]) self.endPicker.date = [self.startPicker.date dateByAddingTimeInterval:self.duration];
    }
    [self reloadContent];
}

#pragma mark Content

- (void)reloadContent {
    LSSchedule *current = LSScheduler.shared.schedule;
    [self renderCurrent:current];
    self.emptyView.hidden = current != nil || self.subject.length > 0;
    if (!self.subject.length) return;
    self.previewHeader.text = current ? @"Replace with" : @"New schedule";
    NSString *title = current ? @"Replace schedule" : @"Schedule";
    UIButtonConfiguration *config = self.saveButton.configuration;
    config.title = title;
    self.saveButton.configuration = config;
    self.saveButton.accessibilityLabel = title;
    [self refreshPreview];
}

// Built once and updated in place, so the 30 s refresh never moves VoiceOver focus or
// restarts the status pulse.
- (void)buildCurrentSection {
    self.currentChip = [[LSStatusChip alloc] init];
    UIStackView *chipLine = LSStack(@[self.currentChip], 0);
    chipLine.alignment = UIStackViewAlignmentLeading;
    self.currentSlot = LSStack(@[], 0);
    self.cancelButton = LSButton(@"Cancel schedule", @"xmark.circle", NO);
    UIButtonConfiguration *style = self.cancelButton.configuration;
    style.baseForegroundColor = LSErrorColor();
    style.baseBackgroundColor = LSErrorColor(); // Tinted style: a soft red pill, not red on blue.
    self.cancelButton.configuration = style;
    [self.cancelButton addTarget:self action:@selector(confirmCancel:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *body = LSStack(@[chipLine, self.currentSlot, self.cancelButton], LSSpaceL);
    [self.currentSection addArrangedSubview:LSScheduleInset(LSSectionLabel(@"Current schedule"))];
    [self.currentSection addArrangedSubview:LSInsetPanel(body)];
    if (!self.subject.length) {
        [self.currentSection addArrangedSubview:LSScheduleInset(LSScheduleFootnote(@"To schedule something else, pick a spot or build a route, then tap the clock button."))];
    }
}

- (void)renderCurrent:(nullable LSSchedule *)current {
    self.currentSection.hidden = current == nil;
    if (!current) { self.currentSignature = nil; return; }
    if (!self.currentChip) [self buildCurrentSection];
    NSInteger state = current.isActive ? 2 : 1;
    if (state != self.chipState) {
        self.chipState = state;
        [self.currentChip setTitle:current.isActive ? @"On now" : @"Waiting to start" color:current.isActive ? LSSuccessColor() : UIColor.systemIndigoColor active:current.isActive];
        self.cancelButton.accessibilityHint = current.isActive ? @"Stops the schedule. What is on now stays on." : @"Asks before removing the schedule.";
    }
    NSString *what = current.isRoute ? [NSString stringWithFormat:@"Play the route “%@”", current.name] : [NSString stringWithFormat:@"Hold “%@”", current.name];
    self.currentSignature = [self fillSlot:self.currentSlot signature:self.currentSignature what:what route:current.isRoute
                                     start:current.startDate end:current.endDate daily:current.repeatsDaily active:current.isActive draft:NO];
}

// Rebuilds an agenda only when what it shows changes; otherwise the countdown headline and
// the spoken summary are updated in place. Returns the new signature to keep.
- (NSString *)fillSlot:(UIStackView *)slot signature:(nullable NSString *)previous what:(NSString *)what route:(BOOL)route
                 start:(NSDate *)start end:(nullable NSDate *)end daily:(BOOL)daily active:(BOOL)active draft:(BOOL)draft {
    BOOL now = !active && start.timeIntervalSinceNow < 60;
    NSString *signature = [NSString stringWithFormat:@"%@|%d|%.0f|%.0f|%d|%d|%d|%@|%@", what, route, start.timeIntervalSinceReferenceDate,
                           end ? end.timeIntervalSinceReferenceDate : -1.0, daily, active, now, LSScheduleDay(start, NO), end ? LSScheduleDay(end, NO) : @""];
    UIStackView *summary = (UIStackView *)slot.arrangedSubviews.firstObject;
    UILabel *headline = (UILabel *)summary.arrangedSubviews.firstObject;
    if ([signature isEqualToString:previous] && [summary isKindOfClass:UIStackView.class] && [headline isKindOfClass:UILabel.class]) {
        NSString *text = LSScheduleHeadline(start, end, active);
        if (![headline.text isEqualToString:text]) {
            [UIView transitionWithView:headline duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                            animations:^{ headline.text = text; } completion:nil];
        }
        summary.accessibilityLabel = [self spokenWhat:what start:start end:end daily:daily active:active];
        summary.accessibilityTraits = LSScheduleSummaryTraits(start, active);
        return signature;
    }
    for (UIView *view in slot.arrangedSubviews) [view removeFromSuperview];
    [slot addArrangedSubview:[self summaryWhat:what route:route start:start end:end daily:daily active:active draft:draft]];
    return signature;
}

- (NSString *)spokenWhat:(NSString *)what start:(NSDate *)start end:(nullable NSDate *)end daily:(BOOL)daily active:(BOOL)active {
    BOOL now = !active && start.timeIntervalSinceNow < 60;
    NSMutableString *spoken = [NSMutableString stringWithFormat:@"%@. ", LSScheduleHeadline(start, end, active)];
    if (active) [spoken appendFormat:@"%@ started %@ at %@. ", what, LSScheduleDay(start, YES), LSScheduleTime(start)];
    else if (now) [spoken appendFormat:@"%@ right away. ", what];
    else [spoken appendFormat:@"%@ %@ at %@. ", what, LSScheduleDay(start, YES), LSScheduleTime(start)];
    if (end) [spoken appendFormat:@"Turns off %@ at %@, after %@. ", LSScheduleDay(end, YES), LSScheduleTime(end), LSScheduleDuration([end timeIntervalSinceDate:start], NSDateComponentsFormatterUnitsStyleFull)];
    else [spoken appendString:@"Stays on until you turn it off. "];
    [spoken appendString:daily ? @"Repeats every day." : @"Runs once."];
    return spoken;
}

// Big headline, then an agenda: when it starts and what happens, when it turns off, and
// whether it repeats. Read by VoiceOver as one sentence.
- (UIView *)summaryWhat:(NSString *)what route:(BOOL)route start:(NSDate *)start end:(nullable NSDate *)end daily:(BOOL)daily active:(BOOL)active draft:(BOOL)draft {
    UILabel *headline = LSLabel(LSScheduleHeadline(start, end, active), UIFontTextStyleTitle1);
    // Rounded with steady digit widths, so the countdown never jitters as it changes.
    headline.font = LSNumberFont(UIFontTextStyleTitle1, UIFontWeightBold, 48);
    headline.isAccessibilityElement = NO;
    BOOL now = !active && start.timeIntervalSinceNow < 60;
    NSString *startAux = active ? @"Started" : (now ? (draft ? @"As soon as you schedule it" : @"Starting") : LSScheduleDay(start, NO));
    UIView *first = [self eventTime:now ? @"Now" : LSScheduleTime(start) aux:startAux text:what
                              color:active ? LSSuccessColor() : (route ? LSRouteColor() : LSAccentColor()) filled:YES connects:YES];
    UIView *second;
    if (end) {
        NSString *after = [NSString stringWithFormat:@"after %@", LSScheduleDuration([end timeIntervalSinceDate:start], NSDateComponentsFormatterUnitsStyleShort)];
        NSString *aux = [NSCalendar.currentCalendar isDate:end inSameDayAsDate:start] ? after : [NSString stringWithFormat:@"%@ · %@", LSScheduleDay(end, NO), after];
        second = [self eventTime:LSScheduleTime(end) aux:aux text:@"Turn off · your real location comes back" color:UIColor.secondaryLabelColor filled:NO connects:NO];
    } else {
        second = [self eventTime:nil aux:nil text:@"Stays on until you turn it off" color:UIColor.tertiaryLabelColor filled:NO connects:NO];
    }
    UIView *repeat = LSScheduleBullet(daily ? @"repeat" : @"1.circle", daily ? @"Repeats every day at these times" : @"Runs once");
    UIStackView *stack = LSStack(@[headline, LSStack(@[first, second], 0), repeat], LSSpaceM);
    stack.isAccessibilityElement = YES;
    stack.accessibilityLabel = [self spokenWhat:what start:start end:end daily:daily active:active];
    stack.accessibilityTraits = LSScheduleSummaryTraits(start, active);
    return stack;
}

- (UIView *)eventTime:(nullable NSString *)time aux:(nullable NSString *)aux text:(NSString *)text color:(UIColor *)color filled:(BOOL)filled connects:(BOOL)connects {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UIFont *timeFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle3] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightSemibold] maximumPointSize:38];
    UILabel *headline = nil;
    if (time.length || aux.length) {
        NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:time ?: @"" attributes:@{NSFontAttributeName: timeFont, NSForegroundColorAttributeName: UIColor.labelColor}];
        if (aux.length) {
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@%@", time.length ? @"  " : @"", aux]
                attributes:@{NSFontAttributeName: LSFont(UIFontTextStyleSubheadline, UIFontWeightMedium, 30), NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
        }
        headline = LSLabel(@"", UIFontTextStyleTitle3);
        headline.attributedText = line;
    }
    UILabel *body = LSLabel(text, UIFontTextStyleBody);
    body.font = LSFont(UIFontTextStyleBody, UIFontWeightRegular, 40);
    body.textColor = headline ? UIColor.labelColor : UIColor.secondaryLabelColor;
    UIStackView *texts = LSStack(headline ? @[headline, body] : @[body], 2);
    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 7;
    UIColor *resolved = [color resolvedColorWithTraitCollection:self.traitCollection];
    if (filled) dot.backgroundColor = resolved;
    else {
        dot.layer.borderWidth = 2.5;
        dot.layer.borderColor = resolved.CGColor;
    }
    UIView *track = [[UIView alloc] init];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    track.backgroundColor = UIColor.separatorColor;
    track.layer.cornerRadius = 1;
    track.hidden = !connects;
    for (UIView *view in @[track, dot, texts]) [row addSubview:view];
    UILabel *anchor = headline ?: body;
    UIFont *anchorFont = headline ? timeFont : body.font;
    [NSLayoutConstraint activateConstraints:@[
        [dot.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:4],
        [dot.widthAnchor constraintEqualToConstant:14],
        [dot.heightAnchor constraintEqualToConstant:14],
        // The dot sits on the middle of the first line's capitals at any text size.
        [dot.centerYAnchor constraintEqualToAnchor:anchor.firstBaselineAnchor constant:-anchorFont.capHeight / 2],
        [texts.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:LSSpaceM + 2],
        [texts.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [texts.topAnchor constraintEqualToAnchor:row.topAnchor],
        [texts.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:connects ? -LSSpaceL - 4 : 0],
        [track.centerXAnchor constraintEqualToAnchor:dot.centerXAnchor],
        [track.widthAnchor constraintEqualToConstant:2],
        [track.topAnchor constraintEqualToAnchor:dot.bottomAnchor constant:LSSpaceXS],
        [track.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:LSSpaceXS]
    ]];
    return row;
}

- (void)refreshPreview {
    if (!self.previewSlot) return;
    NSDate *end = self.endSwitch.on ? self.endPicker.date : nil;
    self.previewSignature = [self fillSlot:self.previewSlot signature:self.previewSignature what:self.subject route:self.subjectIsRoute
                                     start:self.startPicker.date end:end daily:self.dailySwitch.on active:NO draft:YES];
}

#pragma mark Form

- (void)buildFormInto:(NSMutableArray<UIView *> *)sections {
    self.startPicker = [[UIDatePicker alloc] init];
    self.startPicker.datePickerMode = UIDatePickerModeDateAndTime;
    self.startPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    self.startPicker.minuteInterval = 1;
    self.startPicker.accessibilityLabel = @"Start time";
    self.endPicker = [[UIDatePicker alloc] init];
    self.endPicker.datePickerMode = UIDatePickerModeDateAndTime;
    self.endPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    self.endPicker.minuteInterval = 1;
    self.endPicker.accessibilityLabel = @"Turn off time";
    [self updatePickerLimits];
    self.startPicker.date = LSRoundedFuture(10 * 60);
    [self updatePickerLimits];
    self.endPicker.date = [self.startPicker.date dateByAddingTimeInterval:self.duration];
    [self.startPicker addTarget:self action:@selector(startChanged) forControlEvents:UIControlEventValueChanged];
    [self.endPicker addTarget:self action:@selector(endChanged) forControlEvents:UIControlEventValueChanged];
    self.endSwitch = [[UISwitch alloc] init];
    [self.endSwitch addTarget:self action:@selector(endToggled) forControlEvents:UIControlEventValueChanged];
    self.dailySwitch = [[UISwitch alloc] init];
    [self.dailySwitch addTarget:self action:@selector(dailyToggled) forControlEvents:UIControlEventValueChanged];

    __weak typeof(self) weakSelf = self;
    UIButton *soon = LSScheduleChip(@"In 15 min", @"Start in 15 minutes");
    [soon addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [weakSelf setStart:LSScheduleNextMinute(15 * 60)]; }] forControlEvents:UIControlEventTouchUpInside];
    UIButton *hour = LSScheduleChip(@"In 1 hour", @"Start in 1 hour");
    [hour addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [weakSelf setStart:LSScheduleNextMinute(3600)]; }] forControlEvents:UIControlEventTouchUpInside];
    NSString *morning = [NSString stringWithFormat:@"Tomorrow %@", LSScheduleTime(LSScheduleTomorrowAt(9))];
    UIButton *tomorrow = LSScheduleChip(morning, [NSString stringWithFormat:@"Start %@", morning.lowercaseString]);
    [tomorrow addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [weakSelf setStart:LSScheduleTomorrowAt(9)]; }] forControlEvents:UIControlEventTouchUpInside];
    NSMutableArray<UIButton *> *lengths = [NSMutableArray array];
    for (NSNumber *minutes in @[@30, @60, @120]) {
        NSTimeInterval seconds = minutes.doubleValue * 60;
        NSString *title = [NSString stringWithFormat:@"For %@", LSScheduleDuration(seconds, NSDateComponentsFormatterUnitsStyleShort)];
        UIButton *chip = LSScheduleChip(title, [NSString stringWithFormat:@"Turn off after %@", LSScheduleDuration(seconds, NSDateComponentsFormatterUnitsStyleFull)]);
        [chip addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [weakSelf setDuration:seconds fromChip:YES]; }] forControlEvents:UIControlEventTouchUpInside];
        [lengths addObject:chip];
    }

    UIView *startRow = [self dateRow:@"Starts" badge:LSIconBadge(@"play.fill", LSSuccessColor(), kLSScheduleBadge) picker:self.startPicker
                               chips:@[soon, hour, tomorrow] separator:NO];
    UIView *endToggle = [self switchRow:@"Turn off later" hint:@"Adds a time when LSpoof turns off and your real location comes back."
                                 symbol:@"stop.fill" color:LSErrorColor() control:self.endSwitch separator:YES];
    self.endRow = [self dateRow:@"Turns off" badge:nil picker:self.endPicker chips:lengths separator:YES];
    self.endRow.hidden = YES;
    self.endRow.alpha = 0;
    UIView *daily = [self switchRow:@"Every day" hint:@"Repeats at the same times each day until you cancel."
                             symbol:@"repeat" color:UIColor.systemIndigoColor control:self.dailySwitch separator:YES];

    UIImageView *errorIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.circle.fill"]];
    errorIcon.tintColor = LSErrorColor();
    errorIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote];
    errorIcon.isAccessibilityElement = NO;
    [errorIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.errorLabel = LSLabel(@"", UIFontTextStyleFootnote);
    self.errorLabel.font = LSFont(UIFontTextStyleFootnote, UIFontWeightMedium, 30);
    self.errorLabel.textColor = LSErrorColor();
    self.errorRow = LSRow(@[errorIcon, self.errorLabel], 6);
    self.errorRow.alignment = UIStackViewAlignmentFirstBaseline;
    self.errorRow.hidden = YES;
    self.errorRow.alpha = 0;

    self.previewHeader = LSSectionLabel(@"New schedule");
    self.previewSlot = LSStack(@[], 0);
    UIStackView *preview = LSStack(@[LSScheduleInset(self.previewHeader), LSInsetPanel(self.previewSlot)], LSSpaceS);
    UIStackView *form = LSStack(@[LSScheduleInset(LSSectionLabel(@"When")), LSScheduleCard(@[startRow, endToggle, self.endRow, daily]), LSScheduleInset(self.errorRow)], LSSpaceS);

    self.saveButton = LSButton(@"Schedule", @"clock.badge.checkmark", YES);
    [self.saveButton addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *notes = LSStack(@[
        LSScheduleBullet(@"iphone", @"Starts on time while this app is open, or in the background with “Keep routes moving in the background” on."),
        LSScheduleBullet(@"clock.arrow.circlepath", @"Missed while closed? A place starts when you next open the app; a route over 15 minutes late is skipped."),
        LSScheduleBullet(@"power", @"Turning off ends whatever is applied at that time.")], LSSpaceM);
    UIStackView *info = LSStack(@[LSScheduleInset(LSSectionLabel(@"Good to know")), LSInsetPanel(notes)], LSSpaceS);
    [sections addObjectsFromArray:@[preview, form, info]];
}

- (UIView *)dateRow:(NSString *)title badge:(nullable UIView *)badge picker:(UIDatePicker *)picker chips:(NSArray<UIButton *> *)chips separator:(BOOL)separator {
    UILabel *name = LSScheduleTitle(title);
    name.isAccessibilityElement = NO; // The picker carries the label.
    LSScheduleFlowStack *line = [[LSScheduleFlowStack alloc] initWithArrangedSubviews:@[name, picker]];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.spacing = LSSpaceM;
    line.stacksWhenNarrow = YES;
    [picker setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [picker setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *column = LSStack(@[line, LSScheduleChipStrip(chips)], LSSpaceS);
    UIView *content = column;
    if (badge) {
        UIStackView *row = LSRow(@[badge, column], LSSpaceM);
        row.alignment = UIStackViewAlignmentTop;
        content = row;
    }
    UIView *wrapper = LSScheduleRow([[UIView alloc] init], content, separator, badge ? kLSScheduleInset : kLSScheduleTextInset);
    wrapper.accessibilityElements = [@[picker] arrayByAddingObjectsFromArray:chips];
    return wrapper;
}

- (UIView *)switchRow:(NSString *)title hint:(NSString *)hint symbol:(NSString *)symbol color:(UIColor *)color control:(UISwitch *)control separator:(BOOL)separator {
    control.onTintColor = LSAccentColor();
    [control setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *name = LSScheduleTitle(title);
    LSScheduleFlowStack *line = [[LSScheduleFlowStack alloc] initWithArrangedSubviews:@[name, control]];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.spacing = LSSpaceM;
    UIView *badge = LSIconBadge(symbol, color, kLSScheduleBadge);
    UIStackView *row = LSRow(@[badge, line], LSSpaceM);
    LSScheduleToggleRow *wrapper = [[LSScheduleToggleRow alloc] init];
    wrapper.toggle = control;
    [wrapper addTarget:wrapper action:@selector(flip) forControlEvents:UIControlEventTouchUpInside];
    LSScheduleRow(wrapper, row, separator, kLSScheduleInset);
    wrapper.isAccessibilityElement = YES;
    wrapper.accessibilityLabel = title;
    wrapper.accessibilityHint = hint;
    wrapper.accessibilityTraits = control.accessibilityTraits | UIAccessibilityTraitButton;
    return wrapper;
}

- (UIView *)buildEmptyState {
    UIButton *back = LSButton(@"Back to the map", @"map", NO);
    [back addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    UIView *empty = LSEmptyState(@"calendar.badge.clock", @"Nothing to schedule yet",
                                 @"Pick a spot on the map or build a route, then tap the clock button to start it later, once or every day.", back);
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *holder = [[UIView alloc] init];
    holder.translatesAutoresizingMaskIntoConstraints = NO;
    [holder addSubview:empty];
    // Optional vertical constraints: centered when shown, nothing to break when hidden.
    NSLayoutConstraint *center = [empty.centerYAnchor constraintEqualToAnchor:holder.centerYAnchor];
    NSLayoutConstraint *top = [empty.topAnchor constraintGreaterThanOrEqualToAnchor:holder.topAnchor];
    NSLayoutConstraint *bottom = [empty.bottomAnchor constraintLessThanOrEqualToAnchor:holder.bottomAnchor];
    for (NSLayoutConstraint *constraint in @[center, top, bottom]) constraint.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [empty.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor],
        [empty.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor], center, top, bottom]];
    return holder;
}

#pragma mark Events

- (void)updatePickerLimits {
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    // Whole minutes, so the current minute stays selectable.
    self.startPicker.minimumDate = [NSDate dateWithTimeIntervalSinceReferenceDate:floor(now / 60.0) * 60.0];
    self.startPicker.maximumDate = [NSDate dateWithTimeIntervalSinceReferenceDate:now + kLSScheduleHorizon];
    self.endPicker.minimumDate = [self.startPicker.date dateByAddingTimeInterval:60];
}
- (void)setStart:(NSDate *)start {
    LSHapticSelection();
    [self.startPicker setDate:start animated:LSMapAnimationsEnabled()];
    [self startChanged];
    LSAnnounce([NSString stringWithFormat:@"Starts %@ at %@", LSScheduleDay(self.startPicker.date, YES), LSScheduleTime(self.startPicker.date)]);
}
- (void)setDuration:(NSTimeInterval)seconds fromChip:(BOOL)chip {
    if (chip) LSHapticSelection();
    self.duration = seconds;
    [self.endPicker setDate:[self.startPicker.date dateByAddingTimeInterval:seconds] animated:LSMapAnimationsEnabled()];
    [self endChanged];
    if (chip) LSAnnounce([NSString stringWithFormat:@"Turns off at %@", LSScheduleTime(self.endPicker.date)]);
}
// Moving the start moves the turn-off time with it, keeping the same length, like Calendar.
- (void)startChanged {
    [self updatePickerLimits];
    self.endPicker.date = [self.startPicker.date dateByAddingTimeInterval:self.duration];
    [self showError:nil];
    [self refreshPreview];
}
- (void)endChanged {
    NSTimeInterval length = [self.endPicker.date timeIntervalSinceDate:self.startPicker.date];
    if (length >= 60) self.duration = length;
    [self showError:nil];
    [self refreshPreview];
}
- (void)endToggled {
    LSHapticSelection();
    BOOL on = self.endSwitch.on;
    if (on) self.endPicker.date = [self.startPicker.date dateByAddingTimeInterval:self.duration];
    if (self.endRow.hidden == !on) { [self refreshPreview]; return; }
    LSAnimate(^{
        self.endRow.hidden = !on;
        self.endRow.alpha = on ? 1 : 0;
        [self.scroll layoutIfNeeded];
    }, nil);
    [self showError:nil];
    [self refreshPreview];
}
- (void)dailyToggled {
    LSHapticSelection();
    [self refreshPreview];
}
- (void)showError:(nullable NSString *)message {
    if (message) {
        self.errorLabel.text = message;
        LSAnnounce(message);
        LSHapticWarning();
    }
    BOOL visible = message != nil;
    if (self.errorRow.hidden == !visible) return;
    LSAnimate(^{
        self.errorRow.hidden = !visible;
        self.errorRow.alpha = visible ? 1 : 0;
        [self.scroll layoutIfNeeded];
    }, ^{
        // The action is pinned, so the message may be off screen when it appears.
        if (visible) [self.scroll scrollRectToVisible:CGRectInset([self.errorRow convertRect:self.errorRow.bounds toView:self.scroll], 0, -LSSpaceXL) animated:LSMapAnimationsEnabled()];
    });
}

- (void)save {
    if (!self.startPicker) return;
    NSDate *start = self.startPicker.date;
    NSDate *end = self.endSwitch.on ? self.endPicker.date : nil;
    if (end && [end timeIntervalSinceDate:start] < 60) {
        [self showError:@"Turn off has to be at least a minute after the start."];
        return;
    }
    if ([start timeIntervalSinceNow] > kLSScheduleHorizon) {
        [self showError:@"Pick a start within the next year."];
        return;
    }
    if (!self.schedule || !self.schedule(start, end, self.dailySwitch.on)) {
        [self showError:@"This schedule couldn’t be saved. Check the times and try again."];
        return;
    }
    LSHapticSuccess();
    NSString *message = LSScheduler.shared.schedule.summary ?: @"Scheduled.";
    [self finish:message];
}

// Canceling can't be undone (the scheduler keeps no copy), so it asks, and says exactly
// what will and won't happen.
- (void)confirmCancel:(UIButton *)sender {
    LSSchedule *current = LSScheduler.shared.schedule;
    if (!current || self.presentedViewController) return;
    NSString *name = [NSString stringWithFormat:@"“%@”", current.name];
    NSString *message;
    if (current.isActive) {
        NSMutableString *text = [NSMutableString stringWithFormat:@"%@ stays on", name];
        if (current.endDate) [text appendFormat:@", but won’t turn off at %@ by itself", LSScheduleTime(current.endDate)];
        [text appendString:current.repeatsDaily ? @" and won’t start again tomorrow." : @"."];
        [text appendString:@" Use Turn off in the picker to stop it now."];
        message = text;
    } else {
        message = [NSString stringWithFormat:@"%@ won’t start %@ at %@%@", name, LSScheduleDay(current.startDate, YES), LSScheduleTime(current.startDate),
                   current.repeatsDaily ? @", or on any later day." : @"."];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cancel this schedule?" message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep schedule" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel schedule" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [weakSelf cancelSchedule]; }]];
    alert.popoverPresentationController.sourceView = sender;
    alert.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)cancelSchedule {
    [LSScheduler.shared cancel];
    LSHapticSelection();
    [self finish:@"Schedule canceled."];
}

- (void)finish:(NSString *)message {
    void (^done)(NSString *) = self.didFinish;
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:^{ if (done) done(message); }];
}

- (void)close { [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil]; }
- (BOOL)accessibilityPerformEscape { [self close]; return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray arrayWithObject:[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(close)]];
    if (self.startPicker) {
        UIKeyCommand *save = [UIKeyCommand keyCommandWithInput:@"s" modifierFlags:UIKeyModifierCommand action:@selector(save)];
        save.discoverabilityTitle = @"Save schedule";
        [commands addObject:save];
    }
    return commands;
}
- (void)dealloc { [_clock invalidate]; }
@end
