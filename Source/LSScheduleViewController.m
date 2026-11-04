#import "LSScheduleViewController.h"
#import "LSScheduler.h"
#import "LSUI.h"

@interface LSScheduleViewController ()
@property (nonatomic, strong) UIDatePicker *startPicker;
@property (nonatomic, strong) UIDatePicker *endPicker;
@property (nonatomic, strong) UISwitch *endSwitch;
@property (nonatomic, strong) UISwitch *dailySwitch;
@property (nonatomic, strong) UIView *endRow;
@property (nonatomic, strong) UILabel *errorLabel;
@end

@implementation LSScheduleViewController

static UIView *LSScheduleRow(NSString *title, UIView *control) {
    UILabel *label = LSLabel(title, UIFontTextStyleBody);
    label.font = LSFont(UIFontTextStyleBody, UIFontWeightMedium, 30);
    [control setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = LSRow(@[label, control], 12);
    row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return row;
}

static NSDate *LSRoundedFuture(NSTimeInterval ahead) {
    NSTimeInterval value = NSDate.date.timeIntervalSinceReferenceDate + ahead;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:ceil(value / 300.0) * 300.0];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Schedule";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    NSMutableArray<UIView *> *sections = [NSMutableArray array];

    LSSchedule *current = LSScheduler.shared.schedule;
    if (current) {
        UILabel *summary = LSLabel(current.summary, UIFontTextStyleBody);
        UIButton *cancel = LSButton(@"Cancel schedule", @"xmark.circle", NO);
        UIButtonConfiguration *style = cancel.configuration;
        style.baseForegroundColor = LSErrorColor();
        cancel.configuration = style;
        [cancel addTarget:self action:@selector(cancelSchedule) forControlEvents:UIControlEventTouchUpInside];
        [sections addObject:LSSectionLabel(@"Current schedule")];
        [sections addObject:LSInsetPanel(LSStack(@[summary, cancel], 12))];
    }

    if (self.subject.length) {
        UILabel *subject = LSLabel(self.subject, UIFontTextStyleHeadline);
        self.startPicker = [[UIDatePicker alloc] init];
        self.startPicker.datePickerMode = UIDatePickerModeDateAndTime;
        self.startPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        self.startPicker.minuteInterval = 1;
        self.startPicker.date = LSRoundedFuture(10 * 60);
        self.startPicker.accessibilityLabel = @"Start time";
        [self.startPicker addTarget:self action:@selector(startChanged) forControlEvents:UIControlEventValueChanged];
        self.endSwitch = [[UISwitch alloc] init];
        self.endSwitch.onTintColor = LSAccentColor();
        self.endSwitch.accessibilityLabel = @"Turn off at a set time";
        [self.endSwitch addTarget:self action:@selector(endToggled) forControlEvents:UIControlEventValueChanged];
        self.endPicker = [[UIDatePicker alloc] init];
        self.endPicker.datePickerMode = UIDatePickerModeDateAndTime;
        self.endPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        self.endPicker.date = [self.startPicker.date dateByAddingTimeInterval:3600];
        self.endPicker.accessibilityLabel = @"Turn off time";
        self.dailySwitch = [[UISwitch alloc] init];
        self.dailySwitch.onTintColor = LSAccentColor();
        self.dailySwitch.accessibilityLabel = @"Repeat every day";
        self.endRow = LSScheduleRow(@"Turn off at", self.endPicker);
        self.endRow.hidden = YES;
        UILabel *note = LSLabel(@"iOS only lets LSpoof act on time while this app is open, or running in the background with “Keep routes moving in the background” on. If the app is closed at the start time, a location is applied when you next open it, and a route is skipped if it is more than 15 minutes late. Turning off ends whatever is applied at that time.", UIFontTextStyleFootnote);
        note.textColor = UIColor.secondaryLabelColor;
        self.errorLabel = LSLabel(@"", UIFontTextStyleFootnote);
        self.errorLabel.textColor = LSErrorColor();
        self.errorLabel.hidden = YES;
        UIButton *save = LSButton(current ? @"Replace schedule" : @"Schedule", @"clock.badge.checkmark", YES);
        [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
        [sections addObject:LSSectionLabel(current ? @"Replace with" : @"Start later")];
        [sections addObject:LSInsetPanel(LSStack(@[subject, LSSeparator(), LSScheduleRow(@"Start at", self.startPicker),
                                                   LSScheduleRow(@"Turn off later", self.endSwitch), self.endRow,
                                                   LSScheduleRow(@"Every day", self.dailySwitch), self.errorLabel], 10))];
        [sections addObject:note];
        [sections addObject:save];
    } else if (!current) {
        UILabel *empty = LSLabel(@"Choose a location, or build a route, then come back here to start it later.", UIFontTextStyleBody);
        empty.textColor = UIColor.secondaryLabelColor;
        [sections addObject:LSInsetPanel(empty)];
    }

    UIStackView *stack = LSStack(sections, 10);
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
}

- (void)startChanged {
    if ([self.endPicker.date timeIntervalSinceDate:self.startPicker.date] < 60) self.endPicker.date = [self.startPicker.date dateByAddingTimeInterval:3600];
}

- (void)endToggled {
    self.endRow.hidden = !self.endSwitch.on;
    [self startChanged];
}

- (void)save {
    NSDate *start = self.startPicker.date;
    NSDate *end = self.endSwitch.on ? self.endPicker.date : nil;
    if (end && [end timeIntervalSinceDate:start] < 60) {
        self.errorLabel.text = @"Turn off has to be at least a minute after the start.";
        self.errorLabel.hidden = NO;
        LSAnnounce(self.errorLabel.text);
        LSHapticWarning();
        return;
    }
    if (!self.schedule || !self.schedule(start, end, self.dailySwitch.on)) {
        self.errorLabel.text = @"This schedule could not be saved. Check the times and try again.";
        self.errorLabel.hidden = NO;
        LSAnnounce(self.errorLabel.text);
        LSHapticWarning();
        return;
    }
    LSHapticSuccess();
    NSString *message = LSScheduler.shared.schedule.summary ?: @"Scheduled.";
    [self finish:message];
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
@end
