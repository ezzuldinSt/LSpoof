#import "LSSettingsViewController.h"
#import "LSSettings.h"
#import "LSUI.h"
#import "SessionController.h"
#import "OverlayWindow.h"

@interface LSSettingsViewController () <UITextFieldDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) LSSettings *draft;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITextField *altitudeField;
@property (nonatomic, strong) UITextField *courseField;
@property (nonatomic, strong) UITextField *radiusField;
@property (nonatomic, strong) UILabel *altitudeError;
@property (nonatomic, strong) UILabel *courseError;
@property (nonatomic, strong) UILabel *radiusError;
@property (nonatomic, strong) UIView *radiusRow;
@property (nonatomic, strong) UISwitch *fluctuationSwitch;
@property (nonatomic, strong) UISwitch *rememberSwitch;
@property (nonatomic, strong) UISwitch *realSwitch;
@property (nonatomic, strong) UISwitch *openerSwitch;
@property (nonatomic) CGSize previousScrollSize;
@end

@implementation LSSettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.draft = [LSSettings.storedSettings copy];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.scroll];
    self.altitudeField = LSNumberField(@"Altitude in meters");
    self.courseField = LSNumberField(@"Course in degrees");
    self.radiusField = LSNumberField(@"Variation radius in meters");
    self.altitudeField.text = LSFormatDecimal(self.draft.altitude, 2);
    self.courseField.text = LSFormatDecimal(self.draft.course, 1);
    self.radiusField.text = LSFormatDecimal(self.draft.fluctuationRadius, 1);
    self.altitudeField.returnKeyType = UIReturnKeyNext;
    self.courseField.returnKeyType = UIReturnKeyNext;
    self.radiusField.returnKeyType = UIReturnKeyDone;
    for (UITextField *field in @[self.altitudeField, self.courseField, self.radiusField]) {
        field.delegate = self;
        [field addTarget:self action:@selector(markEdited) forControlEvents:UIControlEventEditingChanged];
        LSInstallNumberToolbar(field, self, @selector(dismissKeyboard));
    }
    self.altitudeError = LSLabel(@"", UIFontTextStyleFootnote);
    self.courseError = LSLabel(@"", UIFontTextStyleFootnote);
    self.radiusError = LSLabel(@"", UIFontTextStyleFootnote);
    self.fluctuationSwitch = [[UISwitch alloc] init];
    self.rememberSwitch = [[UISwitch alloc] init];
    self.realSwitch = [[UISwitch alloc] init];
    self.openerSwitch = [[UISwitch alloc] init];
    self.fluctuationSwitch.on = self.draft.fluctuationEnabled;
    self.rememberSwitch.on = self.draft.rememberLocation;
    self.realSwitch.on = self.draft.showRealLocation;
    self.openerSwitch.on = self.draft.showFloatingButton;
    [self.fluctuationSwitch addTarget:self action:@selector(fluctuationChanged) forControlEvents:UIControlEventValueChanged];
    for (UISwitch *control in @[self.fluctuationSwitch, self.rememberSwitch, self.realSwitch, self.openerSwitch]) {
        [control addTarget:self action:@selector(markEdited) forControlEvents:UIControlEventValueChanged];
    }
    self.radiusRow = LSFieldRow(@"Radius · 1–1,000 m", self.radiusField, self.radiusError);
    self.radiusRow.hidden = !self.fluctuationSwitch.on;
    UILabel *sampleHint = LSLabel(@"Altitude applies to held locations and routes. Course and small position variations apply while holding a location; routes determine their own travel direction.", UIFontTextStyleFootnote);
    sampleHint.textColor = UIColor.secondaryLabelColor;
    UIStackView *sample = LSStack(@[
        LSFieldRow(@"Altitude · −500 to 10,000 m", self.altitudeField, self.altitudeError),
        LSFieldRow(@"Course · 0 to less than 360°", self.courseField, self.courseError),
        LSSeparator(),
        [self switchRow:@"Vary held position" detail:@"The point drifts slowly within a radius, like a real GPS fix." symbol:@"dot.radiowaves.left.and.right" color:LSRouteColor() control:self.fluctuationSwitch], self.radiusRow], 16);
    UIStackView *preferences = LSStack(@[
        [self switchRow:@"Remember last selection" detail:@"Turn off still stops spoofing. Keep the coordinate to use again." symbol:@"clock.arrow.circlepath" color:UIColor.systemIndigoColor control:self.rememberSwitch],
        LSSeparator(),
        [self switchRow:@"Show real location on map" detail:@"Uses existing permission only. This does not change the location sent to the app." symbol:@"person.crop.circle" color:UIColor.systemGrayColor control:self.realSwitch],
        LSSeparator(),
        [self switchRow:@"Show floating button" detail:@"A draggable button opens this picker. You can also hold three fingers on the screen for a moment." symbol:@"hand.tap.fill" color:LSAccentColor() control:self.openerSwitch]], 14);
    UILabel *saveHint = LSLabel(@"Save updates the current session and these preferences. Cancel discards your edits.", UIFontTextStyleFootnote);
    saveHint.textColor = UIColor.secondaryLabelColor;
    UIButton *save = LSButton(@"Save settings", @"checkmark.circle.fill", YES);
    [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = LSStack(@[LSSectionLabel(@"Location details"), LSInsetPanel(LSStack(@[sampleHint, sample], 14)),
                                   LSSectionLabel(@"Preferences"), LSInsetPanel(preferences), saveHint, save], 8);
    [stack setCustomSpacing:24 afterView:stack.arrangedSubviews[1]];
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews[3]];
    [stack setCustomSpacing:16 afterView:saveHint];
    [self.scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    LSAnchorAboveKeyboard(self.scroll, self.view);
}
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
}
- (void)markEdited { self.modalInPresentation = YES; }
- (void)presentationControllerDidAttemptToDismiss:(UIPresentationController *)controller {
    (void)controller;
    // Swiping down used to throw away edited settings without a word.
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:@"You have unsaved changes." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save settings" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self save]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Discard changes" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Keep editing" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    [self presentViewController:sheet animated:LSMapAnimationsEnabled() completion:nil];
}
- (UIView *)switchRow:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol color:(UIColor *)color control:(UISwitch *)control {
    control.accessibilityLabel = title;
    control.accessibilityHint = detail;
    control.onTintColor = LSAccentColor();
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [control.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UILabel *hint = LSLabel(detail, UIFontTextStyleFootnote);
    hint.textColor = UIColor.secondaryLabelColor;
    UILabel *name = LSLabel(title, UIFontTextStyleBody);
    name.font = LSFont(UIFontTextStyleBody, UIFontWeightMedium, 30);
    UIStackView *text = LSStack(@[name, hint], 3);
    UIView *badge = LSIconBadge(symbol, color, 32);
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[badge, text, control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    [control setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return row;
}
- (void)fluctuationChanged { self.radiusRow.hidden = !self.fluctuationSwitch.on; }
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (BOOL)validateField:(UITextField *)field format:(BOOL)format {
    NSNumber *number = LSParseDecimal(field.text, NSLocale.currentLocale);
    double value = number.doubleValue;
    UILabel *error;
    BOOL valid;
    if (field == self.altitudeField) {
        error = self.altitudeError;
        valid = number && value >= -500 && value <= 10000;
        error.text = @"Enter an altitude from −500 to 10,000 meters.";
        if (valid) self.draft.altitude = value;
    } else if (field == self.courseField) {
        error = self.courseError;
        // 359.9999999 was shown as 360 at six decimals and then failed its own check.
        if (number) value = fmod(round(value * 1e6) / 1e6, 360.0);
        valid = number && value >= 0 && value < 360;
        error.text = @"Enter a course from 0 to less than 360 degrees.";
        if (valid) self.draft.course = value;
    } else {
        error = self.radiusError;
        valid = number && value >= 1 && value <= 1000;
        error.text = @"Enter a radius from 1 to 1,000 meters.";
        if (valid) self.draft.fluctuationRadius = value;
    }
    error.hidden = valid;
    field.accessibilityHint = valid ? nil : error.text;
    if (valid && format) field.text = LSFormatDecimal(value, 6);
    return valid;
}
- (void)textFieldDidBeginEditing:(UITextField *)field {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.scroll scrollRectToVisible:[field convertRect:field.bounds toView:self.scroll] animated:LSMapAnimationsEnabled()];
    });
}
- (void)textFieldDidEndEditing:(UITextField *)field { [self validateField:field format:YES]; }
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.altitudeField) [self.courseField becomeFirstResponder];
    else if (field == self.courseField && self.fluctuationSwitch.on) [self.radiusField becomeFirstResponder];
    else [self dismissKeyboard];
    return YES;
}
- (void)save {
    [self.view endEditing:YES];
    BOOL altitude = [self validateField:self.altitudeField format:NO];
    BOOL course = [self validateField:self.courseField format:NO];
    BOOL radius = !self.fluctuationSwitch.on || [self validateField:self.radiusField format:NO];
    if (!altitude || !course || !radius) {
        UITextField *invalid = !altitude ? self.altitudeField : (!course ? self.courseField : self.radiusField);
        [invalid becomeFirstResponder];
        LSAnnounce(invalid.accessibilityHint);
        return;
    }
    self.draft.fluctuationEnabled = self.fluctuationSwitch.on;
    self.draft.rememberLocation = self.rememberSwitch.on;
    self.draft.showRealLocation = self.realSwitch.on;
    self.draft.showFloatingButton = self.openerSwitch.on;
    if (![LSSessionController.shared saveSettings:self.draft]) return;
    [LSOverlayManager refreshOpeners];
    if (self.didSave) self.didSave();
    LSAnnounce(@"Settings saved");
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (void)cancel {
    if (self.modalInPresentation) { [self presentationControllerDidAttemptToDismiss:self.navigationController.presentationController]; return; }
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancel)]];
}
@end
