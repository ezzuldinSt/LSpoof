#import "LSCoordinateEntryController.h"
#import "LSUI.h"
#import <MapKit/MapKit.h>

@interface LSCoordinateEntryController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITextField *latitudeField;
@property (nonatomic, strong) UITextField *longitudeField;
@property (nonatomic, strong) UILabel *latitudeError;
@property (nonatomic, strong) UILabel *longitudeError;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) MKMapView *map;
@property (nonatomic, strong) MKPointAnnotation *pin;
@property (nonatomic, strong) UIButton *chooseButton;
@property (nonatomic) BOOL finished;
@property (nonatomic) CGSize previousScrollSize;
@end
@implementation LSCoordinateEntryController
- (instancetype)init {
    self = [super init];
    if (self) _initialCoordinate = kCLLocationCoordinate2DInvalid;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Coordinates";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.scroll];
    self.latitudeField = LSNumberField(@"Latitude");
    self.longitudeField = LSNumberField(@"Longitude");
    self.latitudeField.returnKeyType = UIReturnKeyNext;
    self.longitudeField.returnKeyType = UIReturnKeyDone;
    self.latitudeError = LSLabel(@"Enter a latitude from −90 to 90.", UIFontTextStyleFootnote);
    self.longitudeError = LSLabel(@"Enter a longitude from −180 to 180.", UIFontTextStyleFootnote);
    self.map = [[MKMapView alloc] init];
    self.map.translatesAutoresizingMaskIntoConstraints = NO;
    self.map.layer.cornerRadius = 20;
    self.map.layer.cornerCurve = kCACornerCurveContinuous;
    self.map.clipsToBounds = YES;
    self.map.showsUserLocation = NO;
    self.map.userInteractionEnabled = NO;
    self.map.accessibilityElementsHidden = YES;
    [self.map.heightAnchor constraintEqualToConstant:180].active = YES;
    self.previewLabel = LSLabel(@"Enter coordinates to preview this location.", UIFontTextStyleFootnote);
    self.previewLabel.textColor = UIColor.secondaryLabelColor;
    for (UITextField *field in @[self.latitudeField, self.longitudeField]) {
        field.delegate = self;
        [field addTarget:self action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
        LSInstallNumberToolbar(field, self, @selector(dismissKeyboard));
    }
    if (CLLocationCoordinate2DIsValid(self.initialCoordinate)) {
        self.latitudeField.text = LSFormatDecimal(self.initialCoordinate.latitude, 6);
        self.longitudeField.text = LSFormatDecimal(self.initialCoordinate.longitude, 6);
    }
    self.chooseButton = LSButton(@"Use these coordinates", @"mappin.and.ellipse", YES);
    [self.chooseButton addTarget:self action:@selector(choose) forControlEvents:UIControlEventTouchUpInside];
    UILabel *hint = LSLabel(@"Type numbers with a decimal point or comma; south and west are negative. You can also paste a pair like “48.8584, 2.2945” into Latitude and both fields fill in.", UIFontTextStyleFootnote);
    hint.textColor = UIColor.secondaryLabelColor;
    UIView *fields = LSInsetPanel(LSStack(@[
        LSFieldRow(@"Latitude · −90 to 90", self.latitudeField, self.latitudeError),
        LSFieldRow(@"Longitude · −180 to 180", self.longitudeField, self.longitudeError)], 14));
    UIStackView *stack = LSStack(@[fields, hint, self.map, self.previewLabel, self.chooseButton], 16);
    [stack setCustomSpacing:8 afterView:self.map];
    [stack setCustomSpacing:24 afterView:self.previewLabel];
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
    [self updateDraftPreview];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.scroll.bounds.size;
    if (CGSizeEqualToSize(size, self.previousScrollSize)) return;
    self.previousScrollSize = size;
    for (UITextField *field in @[self.latitudeField, self.longitudeField]) if (field.isFirstResponder) {
        [self.scroll scrollRectToVisible:CGRectInset([field convertRect:field.bounds toView:self.scroll], 0, -8) animated:NO];
    }
}
- (NSNumber *)valueForField:(UITextField *)field {
    NSNumber *value = LSParseDecimal(field.text, NSLocale.currentLocale);
    double limit = field == self.latitudeField ? 90 : 180;
    return value && fabs(value.doubleValue) <= limit ? value : nil;
}
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    // Pasting "lat, lon" splits it across both fields. Only a multi-character insert
    // (paste or dictation) does this: splitting while typing "48.85 2" sent the rest of
    // the longitude's digits into Latitude.
    if (string.length < 2) return YES;
    NSString *text = [(field.text ?: @"") stringByReplacingCharactersInRange:range withString:string];
    CLLocationCoordinate2D pair;
    if (!LSParseCoordinatePair(text, &pair)) return YES;
    self.latitudeField.text = LSFormatDecimal(pair.latitude, 6);
    self.longitudeField.text = LSFormatDecimal(pair.longitude, 6);
    self.latitudeError.hidden = YES;
    self.longitudeError.hidden = YES;
    self.latitudeField.accessibilityHint = nil;
    self.longitudeField.accessibilityHint = nil;
    [self updateDraftPreview];
    LSAnnounce(@"Latitude and longitude filled in");
    return NO;
}
- (void)editingChanged:(UITextField *)field {
    UILabel *error = field == self.latitudeField ? self.latitudeError : self.longitudeError;
    error.hidden = YES;
    field.accessibilityHint = nil;
    [self updateDraftPreview];
}
- (void)updateDraftPreview {
    // Never rewrite a live text field; intermediate '-', separators, and selections stay intact.
    NSNumber *latitude = [self valueForField:self.latitudeField];
    NSNumber *longitude = [self valueForField:self.longitudeField];
    self.chooseButton.enabled = latitude && longitude;
    if (!latitude || !longitude) {
        self.map.alpha = 0.5;
        self.previewLabel.text = @"Finish entering both coordinates to preview the location.";
        return;
    }
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
    if (!self.pin) { self.pin = [[MKPointAnnotation alloc] init]; [self.map addAnnotation:self.pin]; }
    self.map.alpha = 1;
    self.pin.coordinate = coordinate;
    [self.map setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 1500, 1500) animated:NO];
    self.previewLabel.text = [NSString stringWithFormat:@"Preview · %@", LSCoordinateText(coordinate)];
}
- (BOOL)validate:(UITextField *)field {
    NSNumber *value = [self valueForField:field];
    UILabel *error = field == self.latitudeField ? self.latitudeError : self.longitudeError;
    error.hidden = value != nil;
    field.accessibilityHint = value ? nil : error.text;
    if (value) field.text = LSFormatDecimal(value.doubleValue, 6);
    return value != nil;
}
- (void)textFieldDidEndEditing:(UITextField *)field { [self validate:field]; [self updateDraftPreview]; }
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.latitudeField) [self.longitudeField becomeFirstResponder];
    else [self dismissKeyboard];
    return YES;
}
- (void)textFieldDidBeginEditing:(UITextField *)field {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.scroll scrollRectToVisible:[field convertRect:field.bounds toView:self.scroll] animated:LSMapAnimationsEnabled()];
    });
}
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (void)choose {
    if (self.finished) return;
    [self.view endEditing:YES];
    BOOL lat = [self validate:self.latitudeField], lon = [self validate:self.longitudeField];
    if (!lat || !lon) {
        UITextField *invalid = lat ? self.longitudeField : self.latitudeField;
        [invalid becomeFirstResponder];
        LSAnnounce(invalid.accessibilityHint);
        return;
    }
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([self valueForField:self.latitudeField].doubleValue, [self valueForField:self.longitudeField].doubleValue);
    self.finished = YES;
    if (self.didChoose) self.didChoose(coordinate);
}
- (void)cancel {
    self.finished = YES;
    if (self.navigationController.viewControllers.count > 1) [self.navigationController popViewControllerAnimated:LSMapAnimationsEnabled()];
    else [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands { return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancel)]]; }
@end
