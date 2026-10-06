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
    self.map.layer.cornerRadius = 16;
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
    self.chooseButton = LSButton(@"Use these coordinates", @"mappin", YES);
    [self.chooseButton addTarget:self action:@selector(choose) forControlEvents:UIControlEventTouchUpInside];
    UILabel *hint = LSLabel(@"Type or paste numbers using a decimal point or comma. Negative values are supported. Coordinates also work when place search is unavailable.", UIFontTextStyleFootnote);
    hint.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = LSStack(@[hint,
        LSFieldRow(@"Latitude · −90 to 90", self.latitudeField, self.latitudeError),
        LSFieldRow(@"Longitude · −180 to 180", self.longitudeField, self.longitudeError),
        self.map, self.previewLabel, self.chooseButton], 16);
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
        self.previewLabel.text = @"Finish entering both coordinates to preview the location.";
        return;
    }
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
    if (!self.pin) { self.pin = [[MKPointAnnotation alloc] init]; [self.map addAnnotation:self.pin]; }
    self.pin.coordinate = coordinate;
    [self.map setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 1500, 1500) animated:NO];
    self.previewLabel.text = [NSString stringWithFormat:@"Preview: %@", LSCoordinateText(coordinate)];
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
