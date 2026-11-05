#import "LSCoordinateEntryController.h"
#import "LSUI.h"
#import "LSMapLinks.h"
#import <MapKit/MapKit.h>

#pragma mark - Reading pasted coordinates

typedef NS_ENUM(NSInteger, LSCoordinateNotation) {
    LSCoordinateNotationDecimal = 1,
    LSCoordinateNotationMinutes,
    LSCoordinateNotationSeconds
};

typedef struct {
    BOOL valid;
    double value;          // Signed degrees.
    unichar hemisphere;    // 'N', 'S', 'E', 'W' or 0.
    BOOL marked;           // Written with °, ' or ".
    NSInteger parts;       // 1 degrees, 2 with minutes, 3 with seconds.
    BOOL commaDecimal;     // Plain degrees written with a decimal comma.
} LSAngle;

// Maps the typographic variants apps copy (primes, curly quotes, ordinal and ring degree
// signs, Unicode minus) onto one grammar, and drops labels such as "Lat:" or "lng=".
static NSString *LSNormalizedCoordinateText(NSString *text) {
    static NSArray<NSArray<NSString *> *> *replacements;
    static NSRegularExpression *labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        replacements = @[@[@"′", @"'"], @[@"’", @"'"], @[@"‘", @"'"], @[@"´", @"'"], @[@"`", @"'"],
                         @[@"″", @"\""], @[@"”", @"\""], @[@"“", @"\""], @[@"''", @"\""],
                         @[@"º", @"°"], @[@"˚", @"°"], @[@"−", @"-"], @[@"–", @"-"],
                         @[@"\u00A0", @" "], @[@"\u202F", @" "]];
        labels = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:LATITUDE|LONGITUDE|LAT|LNG|LONG|LON)\\b\\s*[:=]?" options:0 error:nil];
    });
    NSString *result = text.uppercaseString;
    for (NSArray<NSString *> *pair in replacements) result = [result stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    if (!labels) return result;
    return [labels stringByReplacingMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@" "];
}

// Degrees, then optional minutes and seconds. Marks are optional so "N 48 51.493" reads too;
// ASCII digits only, because doubleValue reads native digits as zero.
#define LS_ANGLE @"([0-9]{1,3}(?:[.,][0-9]+)?)\\s*(°)?\\s*(?:([0-9]{1,2}(?:[.,][0-9]+)?)\\s*(')?\\s*(?:([0-9]{1,2}(?:[.,][0-9]+)?)\\s*(\")?)?)?"
static NSRegularExpression *LSTrailingPair, *LSLeadingPair, *LSTrailingSingle, *LSLeadingSingle;
static void LSPrepareAngleExpressions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Hemisphere after each value ("48°51'29.6"N 2°17'40.2"E") or before it ("N 48 51.493 E 2 17.670").
        // Trying the styles separately keeps "N 48 E 2" from pairing the E with the first value.
        LSTrailingPair = [NSRegularExpression regularExpressionWithPattern:@"^\\s*([+-])?\\s*" LS_ANGLE @"\\s*([NSEW])?\\s*(?:[,;/]\\s*)?([+-])?\\s*" LS_ANGLE @"\\s*([NSEW])?\\s*$" options:0 error:nil];
        LSLeadingPair = [NSRegularExpression regularExpressionWithPattern:@"^\\s*([NSEW])?\\s*([+-])?\\s*" LS_ANGLE @"\\s*(?:[,;/]\\s*)?([NSEW])?\\s*([+-])?\\s*" LS_ANGLE @"\\s*$" options:0 error:nil];
        LSTrailingSingle = [NSRegularExpression regularExpressionWithPattern:@"^\\s*([+-])?\\s*" LS_ANGLE @"\\s*([NSEW])?\\s*$" options:0 error:nil];
        LSLeadingSingle = [NSRegularExpression regularExpressionWithPattern:@"^\\s*([NSEW])\\s*([+-])?\\s*" LS_ANGLE @"\\s*$" options:0 error:nil];
    });
}

static NSString *LSMatchGroup(NSTextCheckingResult *match, NSString *text, NSUInteger index) {
    if (index >= match.numberOfRanges) return nil;
    NSRange range = [match rangeAtIndex:index];
    return range.location == NSNotFound ? nil : [text substringWithRange:range];
}
static BOOL LSHasFraction(NSString *number) {
    return [number rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".,"]].location != NSNotFound;
}
static double LSNumberValue(NSString *number) { return [number stringByReplacingOccurrencesOfString:@"," withString:@"."].doubleValue; }
static BOOL LSIsLatitudeLetter(unichar letter) { return letter == 'N' || letter == 'S'; }
static BOOL LSIsLongitudeLetter(unichar letter) { return letter == 'E' || letter == 'W'; }

static LSAngle LSReadAngle(NSTextCheckingResult *match, NSString *text, NSUInteger signGroup, NSUInteger angleGroup, NSUInteger hemisphereGroup) {
    LSAngle angle = {0};
    NSString *degrees = LSMatchGroup(match, text, angleGroup);
    NSString *minutes = LSMatchGroup(match, text, angleGroup + 2);
    NSString *seconds = LSMatchGroup(match, text, angleGroup + 4);
    // Only the last component may have a fraction: "48.5° 30'" is not an angle.
    if (!degrees.length || (minutes && LSHasFraction(degrees)) || (seconds && LSHasFraction(minutes))) return angle;
    double value = LSNumberValue(degrees);
    if (minutes) { double m = LSNumberValue(minutes); if (m >= 60) return angle; value += m / 60.0; }
    if (seconds) { double s = LSNumberValue(seconds); if (s >= 60) return angle; value += s / 3600.0; }
    if (!isfinite(value)) return angle;
    NSString *hemisphere = LSMatchGroup(match, text, hemisphereGroup);
    unichar letter = hemisphere.length ? [hemisphere characterAtIndex:0] : 0;
    BOOL negative = [LSMatchGroup(match, text, signGroup) isEqualToString:@"-"];
    if (negative && (letter == 'N' || letter == 'E')) return angle; // Contradicts itself.
    if (letter == 'S' || letter == 'W') negative = YES;
    angle.valid = YES;
    angle.value = negative ? -value : value;
    angle.hemisphere = letter;
    angle.marked = LSMatchGroup(match, text, angleGroup + 1) || LSMatchGroup(match, text, angleGroup + 3) || LSMatchGroup(match, text, angleGroup + 5);
    angle.parts = seconds ? 3 : minutes ? 2 : 1;
    angle.commaDecimal = !minutes && [degrees containsString:@","];
    return angle;
}

static BOOL LSCombineAngles(LSAngle first, LSAngle second, CLLocationCoordinate2D *coordinate, LSCoordinateNotation *notation) {
    if (!first.valid || !second.valid) return NO;
    BOOL labelled = first.hemisphere || second.hemisphere || first.marked || second.marked;
    // Bare numbers are only read here as a decimal-comma pair ("48,85; 2,29"). Point pairs
    // go through LSParseCoordinatePair, and "48 51 2 17" is too ambiguous to guess.
    if (!labelled && !(first.parts == 1 && second.parts == 1 && first.commaDecimal && second.commaDecimal)) return NO;
    if ((LSIsLatitudeLetter(first.hemisphere) && LSIsLatitudeLetter(second.hemisphere)) ||
        (LSIsLongitudeLetter(first.hemisphere) && LSIsLongitudeLetter(second.hemisphere))) return NO;
    BOOL swapped = LSIsLongitudeLetter(first.hemisphere) || LSIsLatitudeLetter(second.hemisphere);
    double latitude = swapped ? second.value : first.value;
    double longitude = swapped ? first.value : second.value;
    if (fabs(latitude) > 90 || fabs(longitude) > 180) return NO;
    if (coordinate) *coordinate = CLLocationCoordinate2DMake(latitude, longitude);
    if (notation) *notation = (LSCoordinateNotation)MAX(first.parts, second.parts);
    return YES;
}

// Decimal pairs, decimal-comma pairs, and degrees/minutes/seconds with or without N/S/E/W.
static BOOL LSParseCoordinateText(NSString *text, CLLocationCoordinate2D *coordinate, LSCoordinateNotation *notation) {
    if (!text.length || text.length > 160) return NO;
    // The labelled grammar goes first so the status names the notation that was read; the
    // shared pair parser (which also reads some DMS) only handles what this one leaves.
    NSString *normalized = LSNormalizedCoordinateText(text);
    LSPrepareAngleExpressions();
    NSRange whole = NSMakeRange(0, normalized.length);
    NSTextCheckingResult *match = [LSTrailingPair firstMatchInString:normalized options:0 range:whole];
    if (match && LSCombineAngles(LSReadAngle(match, normalized, 1, 2, 8), LSReadAngle(match, normalized, 9, 10, 16), coordinate, notation)) return YES;
    match = [LSLeadingPair firstMatchInString:normalized options:0 range:whole];
    if (match && LSCombineAngles(LSReadAngle(match, normalized, 2, 3, 1), LSReadAngle(match, normalized, 10, 11, 9), coordinate, notation)) return YES;
    CLLocationCoordinate2D pair;
    if (!LSParseCoordinatePair(text, &pair) && !LSParseCoordinatePair(normalized, &pair)) return NO;
    if (coordinate) *coordinate = pair;
    if (notation) *notation = LSCoordinateNotationDecimal;
    return YES;
}

// One value pasted into Latitude or Longitude, such as 48°51'29.6"N. A bare number is
// ordinary typing and is left to the field.
static BOOL LSParseSingleAngle(NSString *text, BOOL latitude, double *value) {
    if (!text.length || text.length > 64) return NO;
    LSPrepareAngleExpressions();
    NSString *normalized = LSNormalizedCoordinateText(text);
    NSRange whole = NSMakeRange(0, normalized.length);
    LSAngle angle = {0};
    NSTextCheckingResult *match = [LSTrailingSingle firstMatchInString:normalized options:0 range:whole];
    if (match) angle = LSReadAngle(match, normalized, 1, 2, 8);
    if (!angle.valid) {
        match = [LSLeadingSingle firstMatchInString:normalized options:0 range:whole];
        if (match) angle = LSReadAngle(match, normalized, 2, 3, 1);
    }
    if (!angle.valid || !(angle.hemisphere || angle.marked)) return NO;
    if (latitude ? LSIsLongitudeLetter(angle.hemisphere) : LSIsLatitudeLetter(angle.hemisphere)) return NO;
    if (fabs(angle.value) > (latitude ? 90 : 180)) return NO;
    if (value) *value = angle.value;
    return YES;
}

static NSString *LSNotationMessage(LSCoordinateNotation notation) {
    switch (notation) {
        case LSCoordinateNotationSeconds: return @"Read as degrees, minutes and seconds.";
        case LSCoordinateNotationMinutes: return @"Read as degrees and decimal minutes.";
        case LSCoordinateNotationDecimal: break;
    }
    return @"Read as decimal degrees.";
}

#pragma mark - Formatting

// 48° 51′ 30.24″ N, or its spoken form. Whole hundredths of a second avoid a 60.00″ carry.
static NSString *LSAngleText(double value, BOOL latitude, BOOL spoken) {
    long hundredths = lround(fabs(value) * 360000.0);
    long degrees = hundredths / 360000, minutes = (hundredths % 360000) / 6000;
    double seconds = (hundredths % 6000) / 100.0;
    BOOL negative = value < 0;
    if (spoken) {
        NSString *direction = latitude ? (negative ? @"south" : @"north") : (negative ? @"west" : @"east");
        return [NSString stringWithFormat:@"%ld degrees, %ld minutes, %.2f seconds %@", degrees, minutes, seconds, direction];
    }
    NSString *letter = latitude ? (negative ? @"S" : @"N") : (negative ? @"W" : @"E");
    return [NSString stringWithFormat:@"%ld° %02ld′ %05.2f″ %@", degrees, minutes, seconds, letter];
}
static NSString *LSHemisphereText(CLLocationCoordinate2D coordinate) {
    return [NSString stringWithFormat:@"%.6f° %@, %.6f° %@", fabs(coordinate.latitude), coordinate.latitude < 0 ? @"S" : @"N",
            fabs(coordinate.longitude), coordinate.longitude < 0 ? @"W" : @"E"];
}
static NSString *LSSpokenCoordinate(CLLocationCoordinate2D coordinate) {
    return [NSString stringWithFormat:@"%@ degrees %@, %@ degrees %@",
            LSFormatDecimal(fabs(coordinate.latitude), 6), coordinate.latitude < 0 ? @"south" : @"north",
            LSFormatDecimal(fabs(coordinate.longitude), 6), coordinate.longitude < 0 ? @"west" : @"east"];
}
static NSString *LSTrimmed(NSString *text) {
    return [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static BOOL LSTextIsNegative(NSString *text) {
    NSString *trimmed = LSTrimmed(text);
    return [trimmed hasPrefix:@"-"] || [trimmed hasPrefix:@"−"];
}
// Flips the sign as text so a half-typed value ("", "-", "48.") keeps what was typed.
static NSString *LSFlippedSignText(NSString *text) {
    NSString *trimmed = LSTrimmed(text);
    if ([trimmed hasPrefix:@"-"] || [trimmed hasPrefix:@"−"]) return [trimmed substringFromIndex:1];
    if ([trimmed hasPrefix:@"+"]) trimmed = [trimmed substringFromIndex:1];
    return [@"-" stringByAppendingString:trimmed];
}
static CLLocationDistance LSDistanceBetween(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    if (!CLLocationCoordinate2DIsValid(a) || !CLLocationCoordinate2DIsValid(b)) return CLLocationDistanceMax;
    CLLocation *first = [[CLLocation alloc] initWithLatitude:a.latitude longitude:a.longitude];
    return [first distanceFromLocation:[[CLLocation alloc] initWithLatitude:b.latitude longitude:b.longitude]];
}
static NSString *LSPlacemarkName(CLPlacemark *placemark) {
    if (!placemark) return nil;
    NSArray<NSString *> *candidates = @[placemark.areasOfInterest.firstObject ?: @"", placemark.name ?: @"", placemark.ocean ?: @"",
                                        placemark.inlandWater ?: @"", placemark.locality ?: @"", placemark.administrativeArea ?: @"", placemark.country ?: @""];
    for (NSString *candidate in candidates) if (candidate.length) return candidate;
    return nil;
}
static NSString *LSPlacemarkContext(CLPlacemark *placemark, NSString *name) {
    if (!placemark) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *area = placemark.locality ?: placemark.subAdministrativeArea ?: placemark.administrativeArea;
    for (NSString *part in @[area ?: @"", placemark.country ?: @""]) {
        if (part.length && ![part isEqualToString:name] && ![parts containsObject:part]) [parts addObject:part];
    }
    return parts.count ? [parts componentsJoinedByString:@", "] : nil;
}
static NSString *LSMapAppName(LSMapApp app) {
    switch (app) {
        case LSMapAppApple: return @"Apple Maps";
        case LSMapAppGoogle: return @"Google Maps";
        case LSMapAppWaze: return @"Waze";
    }
    return @"map";
}
// Distances in the user's units ("33 ft", "10 m"). Kept: building a formatter is not cheap.
static MKDistanceFormatter *LSShortDistanceFormatter(void) {
    static MKDistanceFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[MKDistanceFormatter alloc] init];
        formatter.unitStyle = MKDistanceFormatterUnitStyleAbbreviated;
    });
    return formatter;
}
// Initial compass bearing from one point to another, 0 to 360 degrees clockwise from north.
static double LSBearingBetween(CLLocationCoordinate2D from, CLLocationCoordinate2D to) {
    double phi1 = from.latitude * M_PI / 180, phi2 = to.latitude * M_PI / 180, dLambda = (to.longitude - from.longitude) * M_PI / 180;
    double bearing = atan2(sin(dLambda) * cos(phi2), cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)) * 180 / M_PI;
    return fmod(bearing + 360, 360);
}
// "Moved 12 m north-east": distance in the user's units and the nearest of eight directions.
static NSString *LSMoveText(CLLocationCoordinate2D from, CLLocationCoordinate2D to) {
    CLLocationDistance distance = LSDistanceBetween(from, to);
    if (distance == CLLocationDistanceMax) return nil;
    MKDistanceFormatter *formatter = LSShortDistanceFormatter();
    if (distance < 1) return [NSString stringWithFormat:@"Moved less than %@", [formatter stringFromDistance:1]];
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"north", @"north-east", @"east", @"south-east", @"south", @"south-west", @"west", @"north-west"]; });
    long index = lround(LSBearingBetween(from, to) / 45) % 8;
    return [NSString stringWithFormat:@"Moved %@ %@", [formatter stringFromDistance:distance], names[(NSUInteger)index]];
}

static NSString *const kLSMoveArrowSymbol = @"location.north.fill";

// Floating button that lets touches beside it reach the content underneath.
@interface LSPassThroughView : UIView
@end
@implementation LSPassThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

// Soft fade from clear to the screen background behind the floating action.
@interface LSFadeView : UIView
@end
@implementation LSFadeView
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.userInteractionEnabled = NO;
    [self updateColors];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reduceTransparencyChanged:)
                                               name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)reduceTransparencyChanged:(__unused NSNotification *)notification {
    [self updateColors];
}
- (void)updateColors {
    UIColor *base = [UIColor.systemGroupedBackgroundColor resolvedColorWithTraitCollection:self.traitCollection];
    CGFloat solid = LSReduceTransparency() ? 1 : 0.94;
    CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
    gradient.colors = @[(id)[base colorWithAlphaComponent:0].CGColor, (id)[base colorWithAlphaComponent:solid].CGColor, (id)[base colorWithAlphaComponent:solid].CGColor];
    gradient.locations = @[@0, @0.55, @1];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateColors];
}
@end


#pragma mark - Inline status line

typedef NS_ENUM(NSInteger, LSEntryTone) { LSEntryToneNeutral, LSEntryToneWorking, LSEntryToneSuccess, LSEntryToneError };

// Symbol plus text, so state never depends on colour alone.
@interface LSEntryStatusView : UIView
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) LSEntryTone tone;
- (void)setTone:(LSEntryTone)tone text:(NSString *)text spoken:(NSString *)spoken;
@end
@implementation LSEntryStatusView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _icon = [[UIImageView alloc] init];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote scale:UIImageSymbolScaleMedium];
    [_icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_icon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidden = YES;
    [_spinner setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _label = LSLabel(@"", UIFontTextStyleFootnote);
    _label.textColor = UIColor.secondaryLabelColor;
    // Symbol images take part in baseline alignment, so the icon sits on the first text line.
    UIStackView *row = LSRow(@[_icon, _spinner, _label], 6);
    row.alignment = UIStackViewAlignmentFirstBaseline;
    [self addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:self.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];
    return self;
}
- (void)setTone:(LSEntryTone)tone text:(NSString *)text spoken:(NSString *)spoken {
    BOOL changed = tone != _tone;
    _tone = tone;
    self.label.text = text;
    self.label.accessibilityLabel = spoken ?: text;
    NSString *symbol = nil;
    UIColor *color = UIColor.secondaryLabelColor;
    switch (tone) {
        case LSEntryToneNeutral: symbol = @"info.circle"; break;
        case LSEntryToneWorking: break;
        case LSEntryToneSuccess: symbol = @"checkmark.circle.fill"; color = LSSuccessColor(); break;
        case LSEntryToneError: symbol = @"exclamationmark.triangle.fill"; color = LSErrorColor(); break;
    }
    self.icon.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    self.icon.tintColor = color;
    self.icon.hidden = tone == LSEntryToneWorking;
    self.spinner.hidden = tone != LSEntryToneWorking;
    if (tone == LSEntryToneWorking) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    self.label.textColor = tone == LSEntryToneError ? LSErrorColor() : UIColor.secondaryLabelColor;
    if (changed && (tone == LSEntryToneSuccess || tone == LSEntryToneError) && self.window && LSMapAnimationsEnabled()) {
        self.icon.transform = CGAffineTransformMakeScale(0.4, 0.4);
        UIImageView *icon = self.icon;
        LSAnimateBouncy(^{ icon.transform = CGAffineTransformIdentity; }, nil);
    }
}
@end

#pragma mark - Controller

typedef NS_ENUM(NSInteger, LSSmartTrigger) { LSSmartTriggerTyping, LSSmartTriggerCommit, LSSmartTriggerPaste };
typedef NS_ENUM(NSInteger, LSReadoutState) { LSReadoutStateNone = -1, LSReadoutStateEmpty, LSReadoutStateCoordinate, LSReadoutStateNamed, LSReadoutStateDragging };

// The "drag the map" hint shows until the first drag in this app session.
static BOOL LSMapDragTaught;

@interface LSCoordinateEntryController () <UITextFieldDelegate, MKMapViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *mapCard;
@property (nonatomic, strong) UIView *mapContainer;
@property (nonatomic, strong) MKMapView *map;
@property (nonatomic, strong) UIView *mapDim;
@property (nonatomic, strong) UIView *pinView;
@property (nonatomic, strong) UIView *pinShadow;
@property (nonatomic, strong) UIView *dragHint;
@property (nonatomic, strong) NSArray<UIGestureRecognizer *> *mapGestures;
@property (nonatomic, strong) UIStackView *readoutRow;
@property (nonatomic, strong) UIView *readoutText;
@property (nonatomic, strong) UIImageView *readoutIcon;
@property (nonatomic, strong) UILabel *readoutTitle;
@property (nonatomic, strong) UILabel *readoutSubtitle;
@property (nonatomic, strong) UIButton *undoButton;
@property (nonatomic, strong) NSLayoutConstraint *mapLimit;
@property (nonatomic, strong) NSLayoutConstraint *mapLimitLarge;
// Portrait: the preview above the fields. Landscape on a phone: the preview beside them.
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *stackedLayout;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *sideLayout;
@property (nonatomic) BOOL usesSideLayout;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *smartCard;
@property (nonatomic, strong) UIStackView *smartRow;
@property (nonatomic, strong) UITextField *smartField;
@property (nonatomic, strong) LSEntryStatusView *smartStatus;
@property (nonatomic, strong) UITextField *latitudeField;
@property (nonatomic, strong) UITextField *longitudeField;
@property (nonatomic, strong) UIView *latitudeRow;
@property (nonatomic, strong) UIView *longitudeRow;
@property (nonatomic, strong) UIButton *latitudeHemisphere;
@property (nonatomic, strong) UIButton *longitudeHemisphere;
@property (nonatomic, strong) LSEntryStatusView *latitudeStatus;
@property (nonatomic, strong) LSEntryStatusView *longitudeStatus;
@property (nonatomic, strong) UIView *footer;
@property (nonatomic, strong) UIButton *clipboardButton;
@property (nonatomic) BOOL dragHintAllowed;
@property (nonatomic) CLLocationCoordinate2D dragStartCoordinate;
@property (nonatomic, copy) NSString *moveNote;
@property (nonatomic) double moveBearing; // Degrees from north, NAN when the move has no direction.
@property (nonatomic, copy) NSString *readoutIconSymbol;
@property (nonatomic) CGFloat readoutIconRotation;
@property (nonatomic) NSUInteger clipboardFlashToken;
@property (nonatomic) NSUInteger moveNoteToken;
@property (nonatomic, copy) NSString *announcementPrefix;
@property (nonatomic) NSInteger readoutActionsSignature;
@property (nonatomic, strong) UIButton *chooseButton;
@property (nonatomic, strong) UIColor *fieldBaseColor;
@property (nonatomic, strong) UIColor *smartBaseColor;
@property (nonatomic, strong) UIFont *nameFont;
@property (nonatomic, strong) UIFont *coordinateFont;
@property (nonatomic) BOOL choosing;
@property (nonatomic) CFTimeInterval lastMapMotion;
@property (nonatomic) BOOL settleCheckPending;
@property (nonatomic) BOOL keyboardVisible;
@property (nonatomic) BOOL finished;
@property (nonatomic) CGSize previousScrollSize;
// Preview state
@property (nonatomic) BOOL hasPreview;
@property (nonatomic) CLLocationCoordinate2D previewCoordinate;
@property (nonatomic) NSUInteger previewRevision;
@property (nonatomic) BOOL mapShowsPreview;
@property (nonatomic) BOOL needsMapRefresh;
@property (nonatomic) BOOL pinLifted;
@property (nonatomic) NSUInteger liftToken;
@property (nonatomic) BOOL hapticOnLand;
@property (nonatomic) BOOL landHaptic;
@property (nonatomic) BOOL userMovingMap;
@property (nonatomic, copy) NSString *dragStartLatitude;
@property (nonatomic, copy) NSString *dragStartLongitude;
@property (nonatomic) LSReadoutState readoutState;
@property (nonatomic) BOOL announcePlaceName;
// Smart entry state
@property (nonatomic) BOOL smartInsertIsPaste;
@property (nonatomic) NSUInteger smartRevision;
@property (nonatomic, copy) NSString *lastSmartText;
@property (nonatomic, strong) MKLocalSearch *linkSearch;
@property (nonatomic, copy) NSString *linkName;
@property (nonatomic) CLLocationCoordinate2D linkCoordinate;
@property (nonatomic, copy) NSString *undoLatitude;
@property (nonatomic, copy) NSString *undoLongitude;
// Reverse lookup
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic) BOOL geocoding;
@property (nonatomic, copy) NSString *resolvedName;
@property (nonatomic, copy) NSString *resolvedContext;
@property (nonatomic) CLLocationCoordinate2D resolvedCoordinate;
@end

@implementation LSCoordinateEntryController
- (instancetype)init {
    self = [super init];
    if (self) {
        _initialCoordinate = kCLLocationCoordinate2DInvalid;
        _linkCoordinate = kCLLocationCoordinate2DInvalid;
        _resolvedCoordinate = kCLLocationCoordinate2DInvalid;
        _readoutState = LSReadoutStateNone;
        _readoutActionsSignature = -1;
        _dragHintAllowed = YES;
        _dragStartCoordinate = kCLLocationCoordinate2DInvalid;
    }
    return self;
}
- (void)dealloc {
    [_geocoder cancelGeocode];
    [_linkSearch cancel];
    _map.delegate = nil;
}

#pragma mark Building

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Coordinates";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self buildMapCard];
    [self buildForm];
    [self buildFooter];
    [self installConstraints];
    if (CLLocationCoordinate2DIsValid(self.initialCoordinate)) {
        self.latitudeField.text = LSFormatDecimal(self.initialCoordinate.latitude, 6);
        self.longitudeField.text = LSFormatDecimal(self.initialCoordinate.longitude, 6);
    }
    [self refreshStatusForField:self.latitudeField strict:NO];
    [self refreshStatusForField:self.longitudeField strict:NO];
    [self showSmartHint];
    [self applyTraitDependentLayout];
    [self updateDraftPreviewImmediately:YES];
}

- (void)buildMapCard {
    self.map = [[MKMapView alloc] init];
    self.map.translatesAutoresizingMaskIntoConstraints = NO;
    // Muted cartography keeps the pin the loudest thing on the preview.
    self.map.preferredConfiguration = [[MKStandardMapConfiguration alloc] initWithElevationStyle:MKMapElevationStyleFlat emphasisStyle:MKStandardMapEmphasisStyleMuted];
    self.map.showsUserLocation = NO;
    self.map.showsCompass = NO;
    self.map.showsScale = NO;
    self.map.rotateEnabled = NO;
    self.map.pitchEnabled = NO;
    self.map.userInteractionEnabled = NO;
    self.map.delegate = self;
    // MapKit's own recognizers move the map; these only tell a drag from a programmatic move.
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mapGesture:)];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(mapGesture:)];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapGesture:)];
    doubleTap.numberOfTapsRequired = 2;
    self.mapGestures = @[pan, pinch, doubleTap];
    for (UIGestureRecognizer *gesture in self.mapGestures) {
        gesture.delegate = self;
        gesture.cancelsTouchesInView = NO;
        [self.map addGestureRecognizer:gesture];
    }

    self.mapDim = [[UIView alloc] init];
    self.mapDim.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapDim.userInteractionEnabled = NO;

    // A fixed centre pin: the map slides beneath it, so a typed change reads as the pin flying there.
    self.pinShadow = [[UIView alloc] init];
    self.pinShadow.translatesAutoresizingMaskIntoConstraints = NO;
    self.pinShadow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
    self.pinShadow.layer.cornerRadius = 3;
    self.pinShadow.userInteractionEnabled = NO;
    self.pinView = [[UIView alloc] init];
    self.pinView.translatesAutoresizingMaskIntoConstraints = NO;
    self.pinView.userInteractionEnabled = NO;
    self.pinView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.pinView.layer.shadowOpacity = 0.25;
    self.pinView.layer.shadowRadius = 4;
    self.pinView.layer.shadowOffset = CGSizeMake(0, 2);
    UIImageSymbolConfiguration *headConfig = [[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightBold]
        configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithPaletteColors:@[UIColor.whiteColor, LSAccentColor()]]];
    UIImageView *head = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mappin.circle.fill" withConfiguration:headConfig]];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *stem = [[UIView alloc] init];
    stem.translatesAutoresizingMaskIntoConstraints = NO;
    stem.backgroundColor = LSAccentColor();
    stem.layer.cornerRadius = 1.5;
    [self.pinView addSubview:stem];
    [self.pinView addSubview:head];

    // First-use hint for direct manipulation; bottom trailing keeps it off the pin and the legal link.
    UIVisualEffectView *hint = LSGlassView(15, NO);
    hint.userInteractionEnabled = NO;
    UIImageView *hand = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hand.draw"]];
    hand.tintColor = UIColor.labelColor;
    hand.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleCaption1 scale:UIImageSymbolScaleMedium];
    UILabel *hintLabel = LSLabel(@"Drag to fine-tune", UIFontTextStyleCaption1);
    hintLabel.font = LSFont(UIFontTextStyleCaption1, UIFontWeightSemibold, 17);
    hintLabel.numberOfLines = 1;
    UIStackView *hintRow = LSRow(@[hand, hintLabel], 5);
    [hint.contentView addSubview:hintRow];
    hint.alpha = 0;
    self.dragHint = hint;

    self.mapContainer = [[UIView alloc] init];
    self.mapContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapContainer.clipsToBounds = YES;
    self.mapContainer.accessibilityElementsHidden = YES; // The readout below speaks for it.
    for (UIView *view in @[self.map, self.mapDim, self.pinShadow, self.pinView, hint]) [self.mapContainer addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [self.map.topAnchor constraintEqualToAnchor:self.mapContainer.topAnchor],
        [self.map.leadingAnchor constraintEqualToAnchor:self.mapContainer.leadingAnchor],
        [self.map.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor],
        [self.map.bottomAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor],
        [self.mapDim.topAnchor constraintEqualToAnchor:self.mapContainer.topAnchor],
        [self.mapDim.leadingAnchor constraintEqualToAnchor:self.mapContainer.leadingAnchor],
        [self.mapDim.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor],
        [self.mapDim.bottomAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor],
        [self.pinShadow.centerXAnchor constraintEqualToAnchor:self.mapContainer.centerXAnchor],
        [self.pinShadow.centerYAnchor constraintEqualToAnchor:self.mapContainer.centerYAnchor],
        [self.pinShadow.widthAnchor constraintEqualToConstant:16],
        [self.pinShadow.heightAnchor constraintEqualToConstant:6],
        [self.pinView.centerXAnchor constraintEqualToAnchor:self.mapContainer.centerXAnchor],
        [self.pinView.bottomAnchor constraintEqualToAnchor:self.mapContainer.centerYAnchor constant:1],
        [head.topAnchor constraintEqualToAnchor:self.pinView.topAnchor],
        [head.leadingAnchor constraintEqualToAnchor:self.pinView.leadingAnchor],
        [head.trailingAnchor constraintEqualToAnchor:self.pinView.trailingAnchor],
        [stem.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:-4],
        [stem.centerXAnchor constraintEqualToAnchor:self.pinView.centerXAnchor],
        [stem.widthAnchor constraintEqualToConstant:3],
        [stem.heightAnchor constraintEqualToConstant:12],
        [stem.bottomAnchor constraintEqualToAnchor:self.pinView.bottomAnchor],
        [hintRow.topAnchor constraintEqualToAnchor:hint.contentView.topAnchor constant:6],
        [hintRow.bottomAnchor constraintEqualToAnchor:hint.contentView.bottomAnchor constant:-6],
        [hintRow.leadingAnchor constraintEqualToAnchor:hint.contentView.leadingAnchor constant:10],
        [hintRow.trailingAnchor constraintEqualToAnchor:hint.contentView.trailingAnchor constant:-11],
        [hint.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor constant:-8],
        [hint.bottomAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor constant:-8]
    ]];

    // Readout: what the preview shows, in words. Its text half is one VoiceOver element.
    self.readoutIcon = [[UIImageView alloc] init];
    self.readoutIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.readoutIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2 scale:UIImageSymbolScaleMedium];
    [self.readoutIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.readoutIcon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.readoutTitle = LSLabel(@"", UIFontTextStyleSubheadline);
    self.readoutTitle.numberOfLines = 2;
    self.readoutSubtitle = LSLabel(@"", UIFontTextStyleFootnote);
    self.readoutSubtitle.font = LSFont(UIFontTextStyleFootnote, UIFontWeightRegular, 22);
    self.readoutSubtitle.textColor = UIColor.secondaryLabelColor;
    self.readoutSubtitle.numberOfLines = 2;
    UIStackView *texts = LSStack(@[self.readoutTitle, self.readoutSubtitle], 2);
    texts.isAccessibilityElement = YES;
    texts.accessibilityLabel = @"Preview";
    texts.accessibilityTraits = UIAccessibilityTraitStaticText;
    [texts setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.readoutText = texts;
    self.undoButton = LSChipButton(@"Undo", @"arrow.uturn.backward");
    self.undoButton.accessibilityHint = @"Restores the coordinates from before the last change.";
    self.undoButton.hidden = YES;
    [self.undoButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.undoButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.undoButton addTarget:self action:@selector(undoLastChange) forControlEvents:UIControlEventTouchUpInside];
    UIButtonConfiguration *copyConfig = UIButtonConfiguration.plainButtonConfiguration;
    copyConfig.image = [UIImage systemImageNamed:@"doc.on.doc"];
    copyConfig.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleMedium];
    copyConfig.baseForegroundColor = LSAccentTextColor();
    copyConfig.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
    self.clipboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.clipboardButton.configuration = copyConfig;
    self.clipboardButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipboardButton.accessibilityLabel = @"Copy coordinates";
    self.clipboardButton.largeContentTitle = @"Copy coordinates";
    self.clipboardButton.showsLargeContentViewer = YES;
    [self.clipboardButton addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    self.clipboardButton.hidden = YES;
    NSLayoutConstraint *copyWidth = [self.clipboardButton.widthAnchor constraintGreaterThanOrEqualToConstant:44];
    NSLayoutConstraint *copyHeight = [self.clipboardButton.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    copyWidth.priority = 999; copyHeight.priority = 999; // Hidden arranged subviews get zero-size constraints.
    [NSLayoutConstraint activateConstraints:@[copyWidth, copyHeight]];
    [self.clipboardButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.clipboardButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.clipboardButton addTarget:self action:@selector(putCoordinatesOnClipboard) forControlEvents:UIControlEventTouchUpInside];
    LSAddPressFeedback(self.clipboardButton);
    UIStackView *readoutActions = LSRow(@[self.undoButton, self.clipboardButton], LSSpaceXS);
    [readoutActions setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.readoutRow = LSRow(@[self.readoutIcon, texts, readoutActions], LSSpaceM);
    self.readoutRow.layoutMargins = UIEdgeInsetsMake(LSSpaceM, LSSpaceL, LSSpaceM, LSSpaceM);
    self.readoutRow.layoutMarginsRelativeArrangement = YES;

    self.mapCard = [[UIView alloc] init];
    self.mapCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapCard.backgroundColor = LSCardColor();
    self.mapCard.layer.cornerRadius = LSRadiusM;
    self.mapCard.layer.cornerCurve = kCACornerCurveContinuous;
    self.mapCard.clipsToBounds = YES;
    UIStackView *column = LSStack(@[self.mapContainer, self.readoutRow], 0);
    [self.mapCard addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:self.mapCard.topAnchor],
        [column.leadingAnchor constraintEqualToAnchor:self.mapCard.leadingAnchor],
        [column.trailingAnchor constraintEqualToAnchor:self.mapCard.trailingAnchor],
        [column.bottomAnchor constraintEqualToAnchor:self.mapCard.bottomAnchor]
    ]];
    self.mapDim.alpha = 1;
    self.pinView.alpha = 0;
    self.pinShadow.alpha = 0;
    [self.view addSubview:self.mapCard];
}

- (UIToolbar *)toolbarWithPrevious:(BOOL)previous next:(BOOL)next sign:(BOOL)sign {
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *up = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.up"] style:UIBarButtonItemStylePlain target:self action:@selector(focusPrevious)];
    up.accessibilityLabel = @"Previous field";
    up.enabled = previous;
    UIBarButtonItem *down = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"] style:UIBarButtonItemStylePlain target:self action:@selector(focusNext)];
    down.accessibilityLabel = @"Next field";
    down.enabled = next;
    UIBarButtonItem *gap = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    gap.width = 8;
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObjects:up, gap, down, nil];
    if (sign) {
        // The Numbers and Punctuation keyboard hides its minus a page away; this flips it in place.
        UIBarButtonItem *flip = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.forwardslash.minus"] style:UIBarButtonItemStylePlain target:self action:@selector(flipFocusedSign)];
        flip.accessibilityLabel = @"Switch sign";
        flip.accessibilityHint = @"Makes the value negative or positive, which switches the hemisphere.";
        UIBarButtonItem *gap2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        gap2.width = 16;
        [items addObjectsFromArray:@[gap2, flip]];
    }
    [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)]];
    toolbar.items = items;
    [toolbar sizeToFit];
    return toolbar;
}

- (UIButton *)hemisphereButtonWithSymbol:(NSString *)symbol {
    UIButtonConfiguration *config = UIButtonConfiguration.grayButtonConfiguration;
    config.title = @" ";
    config.image = [UIImage systemImageNamed:symbol];
    config.imagePlacement = NSDirectionalRectEdgeTrailing;
    config.imagePadding = 4;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleCaption1 scale:UIImageSymbolScaleSmall];
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.baseForegroundColor = UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsMake(8, 12, 8, 12);
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold] maximumPointSize:30];
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.showsLargeContentViewer = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    NSLayoutConstraint *width = [button.widthAnchor constraintGreaterThanOrEqualToConstant:64];
    width.priority = 999;
    width.active = YES;
    [button addTarget:self action:@selector(flipHemisphere:) forControlEvents:UIControlEventTouchUpInside];
    LSAddPressFeedback(button);
    return button;
}

- (UIView *)rowWithTitle:(NSString *)title field:(UITextField *)field hemisphere:(UIButton *)hemisphere status:(LSEntryStatusView *)status {
    UILabel *label = LSLabel(title, UIFontTextStyleSubheadline);
    label.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 24);
    label.isAccessibilityElement = NO; // The field carries the same name.
    UIStackView *input = LSRow(@[field, hemisphere], LSSpaceS);
    input.alignment = UIStackViewAlignmentFill;
    status.accessibilityElementsHidden = YES; // Spoken through the field's label and hint.
    return LSStack(@[label, input, status], 6);
}

static UIView *LSEntryHeader(NSString *text) {
    UIStackView *wrap = LSStack(@[LSSectionLabel(text)], 0);
    wrap.layoutMargins = UIEdgeInsetsMake(0, LSSpaceL, 0, LSSpaceL);
    wrap.layoutMarginsRelativeArrangement = YES;
    return wrap;
}

- (void)buildForm {
    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    // One field that reads whatever was copied; the precise fields below stay editable.
    self.smartField = LSNumberField(@"Paste or type coordinates");
    self.smartField.placeholder = @"Coordinates or a map link";
    self.smartField.keyboardType = UIKeyboardTypeDefault;
    self.smartField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.smartField.smartQuotesType = UITextSmartQuotesTypeNo; // Curly quotes are accepted, but straight ones are what people expect to see.
    self.smartField.smartDashesType = UITextSmartDashesTypeNo;
    self.smartField.font = LSFont(UIFontTextStyleBody, UIFontWeightRegular, 34);
    self.smartField.returnKeyType = UIReturnKeyDone;
    self.smartField.accessibilityHint = @"Accepts decimal degrees, degrees minutes and seconds, or an Apple Maps, Google Maps or Waze link.";
    UIView *glyphBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 44)];
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"text.viewfinder"]];
    glyph.tintColor = UIColor.secondaryLabelColor;
    glyph.contentMode = UIViewContentModeCenter;
    glyph.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    glyph.frame = CGRectMake(10, 0, 26, 44);
    glyph.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [glyphBox addSubview:glyph];
    self.smartField.leftView = glyphBox;
    self.smartField.leftViewMode = UITextFieldViewModeAlways;
    self.smartBaseColor = self.smartField.backgroundColor;

    // The system paste control reads the clipboard on a tap without the "Allow Paste" prompt,
    // and greys itself out when there is nothing to paste.
    UIPasteConfiguration *accepts = [[UIPasteConfiguration alloc] initWithTypeIdentifiersForAcceptingClass:NSString.class];
    [accepts addTypeIdentifiersForAcceptingClass:NSURL.class];
    self.pasteConfiguration = accepts;
    UIPasteControlConfiguration *pasteLook = [[UIPasteControlConfiguration alloc] init];
    pasteLook.displayMode = UIPasteControlDisplayModeIconAndLabel;
    pasteLook.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    pasteLook.baseBackgroundColor = LSAccentColor();
    pasteLook.baseForegroundColor = UIColor.whiteColor;
    UIPasteControl *paste = [[UIPasteControl alloc] initWithConfiguration:pasteLook];
    paste.translatesAutoresizingMaskIntoConstraints = NO;
    paste.target = self;
    [paste setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [paste setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    NSLayoutConstraint *pasteHeight = [paste.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    pasteHeight.priority = 999;
    pasteHeight.active = YES;
    self.smartRow = LSRow(@[self.smartField, paste], LSSpaceS);
    self.smartRow.alignment = UIStackViewAlignmentFill;
    self.smartStatus = [[LSEntryStatusView alloc] init];
    self.smartCard = LSInsetPanel(LSStack(@[self.smartRow, self.smartStatus], 10));

    self.latitudeField = LSNumberField(@"Latitude");
    self.longitudeField = LSNumberField(@"Longitude");
    self.fieldBaseColor = self.latitudeField.backgroundColor;
    // Big tabular digits: the numbers are the point of this screen.
    UIFont *valueFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle3] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightMedium] maximumPointSize:40];
    for (UITextField *field in @[self.latitudeField, self.longitudeField]) {
        field.font = valueFont;
        field.placeholder = @"Decimal degrees";
    }
    self.latitudeField.returnKeyType = UIReturnKeyNext;
    self.longitudeField.returnKeyType = UIReturnKeyDone;
    self.latitudeHemisphere = [self hemisphereButtonWithSymbol:@"arrow.up.arrow.down"];
    self.longitudeHemisphere = [self hemisphereButtonWithSymbol:@"arrow.left.arrow.right"];
    self.latitudeStatus = [[LSEntryStatusView alloc] init];
    self.longitudeStatus = [[LSEntryStatusView alloc] init];
    self.latitudeRow = [self rowWithTitle:@"Latitude" field:self.latitudeField hemisphere:self.latitudeHemisphere status:self.latitudeStatus];
    self.longitudeRow = [self rowWithTitle:@"Longitude" field:self.longitudeField hemisphere:self.longitudeHemisphere status:self.longitudeStatus];
    UIView *fieldsCard = LSInsetPanel(LSStack(@[self.latitudeRow, LSSeparator(), self.longitudeRow], 14));

    self.smartField.inputAccessoryView = [self toolbarWithPrevious:NO next:YES sign:NO];
    self.latitudeField.inputAccessoryView = [self toolbarWithPrevious:YES next:YES sign:YES];
    self.longitudeField.inputAccessoryView = [self toolbarWithPrevious:YES next:NO sign:YES];
    for (UITextField *field in @[self.smartField, self.latitudeField, self.longitudeField]) {
        field.delegate = self;
        [field addTarget:self action:@selector(editingChanged:) forControlEvents:UIControlEventEditingChanged];
    }

    UIStackView *stack = LSStack(@[LSEntryHeader(@"Paste or type"), self.smartCard, LSEntryHeader(@"Latitude and longitude"), fieldsCard], LSSpaceS);
    [stack setCustomSpacing:LSSpaceXL afterView:self.smartCard];
    [self.scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:LSSpaceM],
        [stack.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:LSSpaceL],
        [stack.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-LSSpaceL],
        [stack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-LSSpaceXL],
        [stack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-2 * LSSpaceL]
    ]];
}

- (void)buildFooter {
    // The action floats on the keyboard, so it stays in reach while typing; the content fades
    // out beneath it instead of being cut by a bar.
    LSFadeView *fade = [[LSFadeView alloc] init];
    [self.view addSubview:fade];
    self.footer = [[LSPassThroughView alloc] init];
    self.footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.footer];
    self.chooseButton = LSButton(@"Use this spot", @"mappin.and.ellipse", YES);
    UIButtonConfiguration *config = self.chooseButton.configuration;
    config.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    self.chooseButton.configuration = config;
    [self.chooseButton addTarget:self action:@selector(choose) forControlEvents:UIControlEventTouchUpInside];
    // With Liquid Glass the prominent button is already glass and floats on its own (glass on
    // glass refracts twice). Otherwise a frosted capsule rings it and casts the one shadow.
    UIView *action = self.chooseButton;
    if (!LSLiquidGlassAvailable()) {
        LSSetButtonGlow(self.chooseButton, NO);
        action = LSGlassCapsule(self.chooseButton, 6);
    }
    [self.footer addSubview:action];
    [NSLayoutConstraint activateConstraints:@[
        [fade.topAnchor constraintEqualToAnchor:self.footer.topAnchor constant:-LSSpaceXL],
        [fade.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [fade.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [action.topAnchor constraintEqualToAnchor:self.footer.topAnchor constant:LSSpaceS],
        [action.bottomAnchor constraintEqualToAnchor:self.footer.bottomAnchor constant:-LSSpaceS],
        [action.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-LSSpaceL]
    ]];
    // Full width under the preview; in landscape only under the fields (installConstraints).
    self.stackedLayout = [NSMutableArray arrayWithObjects:
        [fade.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [action.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:LSSpaceL], nil];
    self.sideLayout = [NSMutableArray arrayWithObjects:
        [fade.leadingAnchor constraintEqualToAnchor:self.scroll.leadingAnchor],
        [action.leadingAnchor constraintEqualToAnchor:self.scroll.leadingAnchor constant:LSSpaceL], nil];
}

- (void)installConstraints {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UIKeyboardLayoutGuide *keyboard = self.view.keyboardLayoutGuide;
    // Docked keyboards resize the viewport; a floating keyboard leaves it usable.
    keyboard.followsUndockedKeyboard = NO;
    // The sticky preview takes a share of whatever room the keyboard and footer leave.
    NSLayoutDimension *room = [safe.topAnchor anchorWithOffsetToAnchor:self.footer.topAnchor];
    NSLayoutConstraint *preferred = [self.mapContainer.heightAnchor constraintEqualToConstant:184];
    preferred.priority = UILayoutPriorityDefaultHigh;
    self.mapLimit = [self.mapContainer.heightAnchor constraintLessThanOrEqualToAnchor:room multiplier:0.32];
    self.mapLimitLarge = [self.mapContainer.heightAnchor constraintLessThanOrEqualToAnchor:room multiplier:0.2];
    [NSLayoutConstraint activateConstraints:@[
        [self.mapCard.topAnchor constraintEqualToAnchor:safe.topAnchor constant:LSSpaceS],
        [self.mapCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:LSSpaceL],
        // A bottom constraint is active from the first layout (keyboard or not); the footer
        // floats over the end of the content, which is inset by its height.
        [self.scroll.bottomAnchor constraintEqualToAnchor:keyboard.topAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.footer.bottomAnchor constraintEqualToAnchor:keyboard.topAnchor]
    ]];
    // Portrait: the sticky preview over the fields, a share of the room the keyboard leaves.
    [self.stackedLayout addObjectsFromArray:@[
        [self.mapCard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-LSSpaceL],
        preferred,
        [self.scroll.topAnchor constraintEqualToAnchor:self.mapCard.bottomAnchor constant:LSSpaceXS],
        [self.scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor]
    ]];
    // Landscape on a phone: the share of a short screen left the preview a sliver, so it sits
    // beside the fields at full height (down to the keyboard) and the button floats under them.
    NSLayoutConstraint *sideBottom = [self.mapCard.bottomAnchor constraintEqualToAnchor:keyboard.topAnchor constant:-LSSpaceS];
    sideBottom.priority = 999; // A very tall keyboard pushes the readout under it, not the layout apart.
    [self.sideLayout addObjectsFromArray:@[
        [self.mapCard.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:0.44 constant:-LSSpaceL],
        sideBottom,
        [self.scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.mapCard.trailingAnchor constant:LSSpaceXS],
        [self.footer.leadingAnchor constraintEqualToAnchor:self.scroll.leadingAnchor]
    ]];
    [NSLayoutConstraint activateConstraints:self.stackedLayout];
}

#pragma mark Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.needsMapRefresh) {
        // Nested views get their frames after this callback; lay the card out now so the
        // first region is set on a sized map rather than waiting for another pass.
        [self.mapCard layoutIfNeeded];
        if (!CGRectIsEmpty(self.map.bounds)) [self applyPreviewToMap];
    }
    CGFloat inset = CGRectGetHeight(self.footer.frame);
    if (fabs(self.scroll.contentInset.bottom - inset) > 0.5) {
        self.scroll.contentInset = UIEdgeInsetsMake(0, 0, inset, 0);
        self.scroll.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, inset, 0);
    }
    // While typing, drop the button's subtitle so the bar above the keyboard stays slim.
    BOOL keyboard = CGRectGetHeight(self.view.keyboardLayoutGuide.layoutFrame) > self.view.safeAreaInsets.bottom + 1;
    if (keyboard != self.keyboardVisible) {
        self.keyboardVisible = keyboard;
        [self refreshChooseButton];
    }
    CGSize size = self.scroll.bounds.size;
    if (CGSizeEqualToSize(size, self.previousScrollSize)) return;
    self.previousScrollSize = size;
    UITextField *field = [self focusedField];
    if (field) [self revealField:field animated:NO];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.needsMapRefresh) [self applyPreviewToMap];
    [self takeKeyFocusIfIdle];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyTraitDependentLayout];
}
- (void)applyTraitDependentLayout {
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.nameFont = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 26);
    self.coordinateFont = LSNumberFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 26);
    if (self.readoutState != LSReadoutStateNone) self.readoutTitle.font = self.readoutState == LSReadoutStateNamed || self.readoutState == LSReadoutStateEmpty ? self.nameFont : self.coordinateFont;
    self.smartRow.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    // At accessibility sizes the Undo and Copy actions move under the text instead of squeezing it.
    self.readoutRow.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.readoutRow.alignment = large ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    // The one-line drag hint would cover the pin at those sizes; the readout's actions remain.
    self.dragHintAllowed = !large;
    if (!self.dragHintAllowed) self.dragHint.alpha = 0;
    else if (self.mapShowsPreview && !LSMapDragTaught) self.dragHint.alpha = 1;
    BOOL side = self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact;
    if (side != self.usesSideLayout && self.sideLayout.count) {
        self.usesSideLayout = side;
        [NSLayoutConstraint deactivateConstraints:side ? self.stackedLayout : self.sideLayout];
        [NSLayoutConstraint activateConstraints:side ? self.sideLayout : self.stackedLayout];
        // Centre the preview again once the map has its new size.
        if (self.hasPreview) self.needsMapRefresh = YES;
        [self.view setNeedsLayout];
    }
    // Deactivate before activating so the two limits never apply together. Beside the fields
    // the preview is sized by the screen instead.
    self.mapLimit.active = NO;
    self.mapLimitLarge.active = NO;
    if (!side) (large ? self.mapLimitLarge : self.mapLimit).active = YES;
    BOOL contrast = self.traitCollection.accessibilityContrast == UIAccessibilityContrastHigh;
    self.mapCard.layer.borderWidth = contrast ? 1 : 0;
    self.mapCard.layer.borderColor = [UIColor.separatorColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    self.mapDim.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:contrast ? 0.7 : 0.5];
}
- (UITextField *)focusedField {
    for (UITextField *field in @[self.smartField, self.latitudeField, self.longitudeField]) if (field.isFirstResponder) return field;
    return nil;
}
- (void)revealField:(UITextField *)field animated:(BOOL)animated {
    UIView *row = field == self.smartField ? self.smartCard : field == self.latitudeField ? self.latitudeRow : self.longitudeRow;
    // Include the footer's height: it floats over the bottom of the scroll view.
    CGRect rect = [row convertRect:row.bounds toView:self.scroll];
    rect.size.height += self.scroll.contentInset.bottom + LSSpaceS;
    [self.scroll scrollRectToVisible:rect animated:animated];
}

#pragma mark Field statuses

- (NSNumber *)valueForField:(UITextField *)field {
    NSNumber *value = LSParseDecimal(field.text, NSLocale.currentLocale);
    double limit = field == self.latitudeField ? 90 : 180;
    return value && fabs(value.doubleValue) <= limit ? value : nil;
}
// Errors that more typing cannot fix (out of range) show live; "not a number" waits until
// the field is left, so "-" or "48," mid-typing never flashes red.
- (void)refreshStatusForField:(UITextField *)field strict:(BOOL)strict {
    BOOL latitude = field == self.latitudeField;
    LSEntryStatusView *status = latitude ? self.latitudeStatus : self.longitudeStatus;
    NSString *range = latitude ? @"From −90 (south) to 90 (north)." : @"From −180 (west) to 180 (east).";
    NSString *text = LSTrimmed(field.text);
    NSNumber *value = LSParseDecimal(text, NSLocale.currentLocale);
    double limit = latitude ? 90 : 180;
    if (value && fabs(value.doubleValue) <= limit) {
        [status setTone:LSEntryToneSuccess text:LSAngleText(value.doubleValue, latitude, NO) spoken:LSAngleText(value.doubleValue, latitude, YES)];
    } else if (value) {
        [status setTone:LSEntryToneError text:latitude ? @"Latitude goes from −90 to 90." : @"Longitude goes from −180 to 180." spoken:nil];
    } else if (strict && text.length) {
        [status setTone:LSEntryToneError text:[NSString stringWithFormat:@"Enter a number like %@, with a point or comma for decimals.", LSFormatDecimal(latitude ? 48.8584 : 2.2945, 4)] spoken:nil];
    } else if (strict) {
        [status setTone:LSEntryToneError text:latitude ? @"Enter a latitude from −90 to 90." : @"Enter a longitude from −180 to 180." spoken:nil];
    } else {
        [status setTone:LSEntryToneNeutral text:range spoken:nil];
    }
    field.accessibilityHint = status.tone == LSEntryToneSuccess ? [NSString stringWithFormat:@"%@. %@", status.label.accessibilityLabel, range] : range;
    // The ring, and the message in the label, since VoiceOver users can turn hints off.
    LSSetFieldError(field, status.tone == LSEntryToneError ? status.label.text : nil);
}
- (BOOL)validate:(UITextField *)field {
    NSNumber *value = [self valueForField:field];
    if (value) field.text = LSFormatDecimal(value.doubleValue, 6);
    [self refreshStatusForField:field strict:YES];
    return value != nil;
}
- (void)showSmartHint {
    [self.smartStatus setTone:LSEntryToneNeutral text:@"Try 48.8584, 2.2945 · 48°51′30″N 2°17′40″E · a map link"
                       spoken:@"Accepts decimal degrees such as 48.8584, 2.2945, degrees minutes and seconds, or a map link."];
}
- (void)refreshHemisphereButton:(UIButton *)button {
    BOOL latitude = button == self.latitudeHemisphere;
    BOOL negative = LSTextIsNegative((latitude ? self.latitudeField : self.longitudeField).text);
    NSString *letter = latitude ? (negative ? @"S" : @"N") : (negative ? @"W" : @"E");
    NSString *word = latitude ? (negative ? @"South" : @"North") : (negative ? @"West" : @"East");
    NSString *other = latitude ? (negative ? @"north" : @"south") : (negative ? @"east" : @"west");
    button.accessibilityLabel = latitude ? @"Latitude hemisphere" : @"Longitude hemisphere";
    button.accessibilityValue = word;
    button.accessibilityHint = [NSString stringWithFormat:@"Switches to %@.", other];
    button.largeContentTitle = word;
    if ([button.configuration.title isEqualToString:letter]) return;
    void (^apply)(void) = ^{
        UIButtonConfiguration *config = button.configuration;
        config.title = letter;
        button.configuration = config;
    };
    BOOL initial = [button.configuration.title isEqualToString:@" "];
    if (initial || !self.view.window) { apply(); return; }
    UIViewAnimationOptions flip = latitude ? UIViewAnimationOptionTransitionFlipFromTop : UIViewAnimationOptionTransitionFlipFromLeft;
    [UIView transitionWithView:button duration:0.3 options:(LSMapAnimationsEnabled() ? flip : UIViewAnimationOptionTransitionCrossDissolve) | UIViewAnimationOptionAllowUserInteraction
                    animations:apply completion:nil];
}
- (void)refreshChooseButton {
    BOOL valid = self.hasPreview;
    // Stays enabled: a tap on an incomplete form says what is missing and goes there.
    NSString *subtitle = self.keyboardVisible ? nil : valid ? LSCoordinateText(self.previewCoordinate) : @"Enter a latitude and longitude";
    UIButtonConfiguration *config = self.chooseButton.configuration;
    if (!(config.subtitle == subtitle || [config.subtitle isEqualToString:subtitle])) {
        config.subtitle = subtitle;
        self.chooseButton.configuration = config;
    }
    self.chooseButton.accessibilityValue = valid ? LSSpokenCoordinate(self.previewCoordinate) : nil;
    self.chooseButton.accessibilityHint = valid ? nil : @"Enter a latitude and longitude first.";
}

#pragma mark Editing

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (field == self.smartField) {
        self.smartInsertIsPaste = string.length > 1;
        return YES;
    }
    // Only a multi-character insert (paste or dictation) is read as a pair, link or angle:
    // splitting while typing "48.85 2" sent the rest of the longitude's digits into Latitude.
    if (string.length < 2) return YES;
    NSString *text = [(field.text ?: @"") stringByReplacingCharactersInRange:range withString:string];
    CLLocationCoordinate2D pair;
    LSCoordinateNotation notation;
    if (LSParseCoordinateText(text, &pair, &notation) || LSParseCoordinateText(string, &pair, &notation)) {
        [self invalidateSmartLookup];
        [self fillCoordinate:pair name:nil message:@"Split the pasted pair into latitude and longitude." feedback:YES];
        return NO;
    }
    if ([LSMapLinks firstMapLinkInText:string]) {
        [self takeSmartText:LSTrimmed(string) trigger:LSSmartTriggerPaste];
        return NO;
    }
    double single;
    if (LSParseSingleAngle(string, field == self.latitudeField, &single)) {
        field.text = LSFormatDecimal(single, 6);
        [self fieldEdited:field immediate:YES];
        [self flashField:field];
        LSAnnounce([NSString stringWithFormat:@"Converted to %@", field.text]);
        return NO;
    }
    return YES;
}
- (void)editingChanged:(UITextField *)field {
    if (field == self.smartField) [self smartTextChanged];
    else [self fieldEdited:field immediate:NO];
}
- (void)fieldEdited:(UITextField *)field immediate:(BOOL)immediate {
    [self invalidateSmartLookup];
    if (self.smartStatus.tone == LSEntryToneSuccess) [self showSmartHint];
    [self clearUndo];
    self.linkName = nil;
    self.moveNote = nil;
    [self refreshStatusForField:field strict:NO];
    [self updateDraftPreviewImmediately:immediate];
}
- (void)textFieldDidBeginEditing:(UITextField *)field {
    dispatch_async(dispatch_get_main_queue(), ^{ [self revealField:field animated:LSMapAnimationsEnabled()]; });
}
- (void)textFieldDidEndEditing:(UITextField *)field {
    // After the next field (if any) has taken over, so focus is never stolen from it.
    dispatch_async(dispatch_get_main_queue(), ^{ [self takeKeyFocusIfIdle]; });
    if (field == self.smartField) { [self processSmartText:LSSmartTriggerCommit]; return; }
    if (!LSTrimmed(field.text).length) {
        // Leaving an empty field is not a mistake yet; Use this spot reports it.
        [self refreshStatusForField:field strict:NO];
    } else if (![self validate:field] && !self.finished && !self.choosing) {
        LSAnnounce(((field == self.latitudeField) ? self.latitudeStatus : self.longitudeStatus).label.text);
    }
    [self updateDraftPreviewImmediately:NO];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.smartField) {
        if ([self processSmartText:LSSmartTriggerPaste]) [self dismissKeyboard];
    } else if (field == self.latitudeField) {
        [self.longitudeField becomeFirstResponder];
    } else if ([self valueForField:self.latitudeField] && [self valueForField:self.longitudeField]) {
        [self choose];
    } else {
        [self dismissKeyboard];
    }
    return NO;
}
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (void)moveFocus:(NSInteger)delta {
    NSArray<UITextField *> *order = @[self.smartField, self.latitudeField, self.longitudeField];
    UITextField *current = [self focusedField];
    if (!current) return;
    NSInteger index = (NSInteger)[order indexOfObject:current] + delta;
    if (index >= 0 && index < (NSInteger)order.count) [order[(NSUInteger)index] becomeFirstResponder];
}
- (void)focusPrevious { [self moveFocus:-1]; }
- (void)focusNext { [self moveFocus:1]; }
- (void)flipFocusedSign {
    UITextField *field = [self focusedField];
    if (field == self.latitudeField) [self flipHemisphere:self.latitudeHemisphere];
    else if (field == self.longitudeField) [self flipHemisphere:self.longitudeHemisphere];
}
- (void)flipHemisphere:(UIButton *)button {
    if (self.finished) return;
    UITextField *field = button == self.latitudeHemisphere ? self.latitudeField : self.longitudeField;
    field.text = LSFlippedSignText(field.text);
    self.hapticOnLand = YES;
    self.announcePlaceName = YES;
    [self fieldEdited:field immediate:YES];
    LSHapticSelection();
    LSAnnounce(button.accessibilityValue);
    // A sign with no digits yet: put the cursor there to type them.
    if (![self valueForField:field] && !field.isFirstResponder) [field becomeFirstResponder];
}
- (void)flashField:(UITextField *)field {
    UIColor *base = field == self.smartField ? self.smartBaseColor : self.fieldBaseColor;
    BOOL contrast = self.traitCollection.accessibilityContrast == UIAccessibilityContrastHigh;
    field.backgroundColor = [LSAccentColor() colorWithAlphaComponent:contrast ? 0.36 : 0.22];
    [UIView animateWithDuration:0.9 delay:0.15 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                     animations:^{ field.backgroundColor = base; } completion:nil];
    if (!LSMapAnimationsEnabled()) return;
    field.transform = CGAffineTransformMakeScale(1.03, 1.03);
    LSAnimateBouncy(^{ field.transform = CGAffineTransformIdentity; }, nil);
}

#pragma mark Smart entry

- (void)invalidateSmartLookup {
    self.smartRevision++;
    self.lastSmartText = nil;
    [self.linkSearch cancel];
    self.linkSearch = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(processTypedSmartText) object:nil];
    if (self.smartStatus.tone == LSEntryToneWorking) [self showSmartHint];
}
- (void)smartTextChanged {
    BOOL paste = self.smartInsertIsPaste;
    self.smartInsertIsPaste = NO;
    [self invalidateSmartLookup];
    if (!LSTrimmed(self.smartField.text).length) { [self showSmartHint]; return; }
    if (paste) { [self processSmartText:LSSmartTriggerPaste]; return; }
    // Typed text is read once the typing pauses, so the fields don't flicker per keystroke.
    [self performSelector:@selector(processTypedSmartText) withObject:nil afterDelay:0.6];
}
- (void)processTypedSmartText { [self processSmartText:LSSmartTriggerTyping]; }
- (void)takeSmartText:(NSString *)text trigger:(LSSmartTrigger)trigger {
    self.smartField.text = text;
    [self invalidateSmartLookup];
    [self processSmartText:trigger];
}
// Returns YES when the text was understood (filled in, or a link lookup started).
- (BOOL)processSmartText:(LSSmartTrigger)trigger {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(processTypedSmartText) object:nil];
    if (self.finished) return NO;
    NSString *text = LSTrimmed(self.smartField.text);
    if (!text.length) { [self showSmartHint]; return NO; }
    if ([text isEqualToString:self.lastSmartText] && (self.smartStatus.tone == LSEntryToneSuccess || self.smartStatus.tone == LSEntryToneWorking)) return YES;
    BOOL explicit = trigger != LSSmartTriggerTyping;
    if (text.length > 2048) {
        if (explicit) [self smartFailure:@"That's too long to read as coordinates." haptic:trigger == LSSmartTriggerPaste];
        return NO;
    }
    CLLocationCoordinate2D coordinate;
    LSCoordinateNotation notation;
    if (LSParseCoordinateText(text, &coordinate, &notation)) {
        self.lastSmartText = text;
        [self fillCoordinate:coordinate name:nil message:LSNotationMessage(notation) feedback:explicit];
        return YES;
    }
    NSURL *url = [LSMapLinks firstMapLinkInText:text];
    if (url) {
        self.lastSmartText = text;
        [self openMapLink:url feedback:explicit];
        return YES;
    }
    if (!explicit) { [self showSmartHint]; return NO; }
    BOOL looksLikeLink = [text rangeOfString:@"://"].location != NSNotFound || [text.lowercaseString hasPrefix:@"www."];
    [self smartFailure:looksLikeLink ? @"That link isn't from Apple Maps, Google Maps or Waze." : @"Couldn't read that. Try 48.8584, 2.2945 or 48°51′30″N 2°17′40″E."
                haptic:trigger == LSSmartTriggerPaste];
    return NO;
}
- (void)smartFailure:(NSString *)message haptic:(BOOL)haptic {
    self.lastSmartText = nil;
    [self.smartStatus setTone:LSEntryToneError text:message spoken:nil];
    if (haptic) LSHapticWarning();
    LSAnnounce(message);
}
- (void)openMapLink:(NSURL *)url feedback:(BOOL)feedback {
    NSUInteger revision = self.smartRevision;
    if (![LSMapLinks needsResolving:url]) { [self useMapLink:[LSMapLinks parseURL:url] revision:revision feedback:feedback]; return; }
    [self.smartStatus setTone:LSEntryToneWorking text:@"Opening the link…" spoken:nil];
    if (feedback) LSAnnounce(@"Opening the link");
    __weak typeof(self) weakSelf = self;
    [LSMapLinks resolveURL:url completion:^(NSURL *resolved, NSString *html) {
        typeof(self) self = weakSelf;
        if (!self || self.finished || revision != self.smartRevision) return;
        LSMapLink *link = resolved ? [LSMapLinks parseURL:resolved] : nil;
        if (!link && html) {
            // Apple place links with only a place id name their coordinate in the page.
            LSMapLinkPlace *place = [LSMapLinks placeFromHTML:html];
            if (place.hasCoordinate) {
                [self fillCoordinate:CLLocationCoordinate2DMake(place.latitude, place.longitude) name:place.name message:@"Read from the map link." feedback:feedback];
                return;
            }
        }
        if (!link) {
            [self smartFailure:resolved ? @"That link doesn't name a place LSpoof can read." : @"The link could not be opened. Check your connection and try again." haptic:feedback];
            return;
        }
        [self useMapLink:link revision:revision feedback:feedback];
    }];
}
- (void)useMapLink:(LSMapLink *)link revision:(NSUInteger)revision feedback:(BOOL)feedback {
    if (!link.places.count) { [self smartFailure:@"That link doesn't name a place LSpoof can read." haptic:feedback]; return; }
    // Directions name several places; the destination is the one people mean.
    BOOL directions = link.isDirections && link.places.count > 1;
    LSMapLinkPlace *place = directions ? link.places.lastObject : link.places.firstObject;
    NSString *app = LSMapAppName(link.app);
    NSString *message = directions ? [NSString stringWithFormat:@"Used the destination of the %@ directions.", app]
                                   : [NSString stringWithFormat:@"Read from the %@ link.", app];
    if (place.hasCoordinate) {
        [self fillCoordinate:CLLocationCoordinate2DMake(place.latitude, place.longitude) name:place.name message:message feedback:feedback];
        return;
    }
    if (!place.query.length) { [self smartFailure:@"That link doesn't name a place LSpoof can read." haptic:feedback]; return; }
    [self.smartStatus setTone:LSEntryToneWorking text:[NSString stringWithFormat:@"Finding “%@”…", place.query] spoken:nil];
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = place.query;
    if (place.hasHint) request.region = MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2DMake(place.hintLatitude, place.hintLongitude), 30000, 30000);
    else if (self.hasPreview) request.region = MKCoordinateRegionMakeWithDistance(self.previewCoordinate, 200000, 200000);
    self.linkSearch = [[MKLocalSearch alloc] initWithRequest:request];
    __weak typeof(self) weakSelf = self;
    [self.linkSearch startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.finished || revision != self.smartRevision) return;
        self.linkSearch = nil;
        MKMapItem *item = response.mapItems.firstObject;
        CLLocationCoordinate2D coordinate = item.placemark.coordinate;
        if (!item || !CLLocationCoordinate2DIsValid(coordinate)) {
            if (!place.hasHint) {
                [self smartFailure:error && error.code != MKErrorPlacemarkNotFound
                    ? @"Place lookup is unavailable right now. Check your connection and try again."
                    : [NSString stringWithFormat:@"Couldn't find “%@” from the link.", place.query] haptic:feedback];
                return;
            }
            // The map view the link was made from is the best remaining guess.
            coordinate = CLLocationCoordinate2DMake(place.hintLatitude, place.hintLongitude);
        }
        [self fillCoordinate:coordinate name:item.name ?: place.name ?: place.query message:message feedback:feedback];
    }];
}

// Writes a whole coordinate into both fields, with a highlight, a status line and an undo.
- (void)fillCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name message:(NSString *)message feedback:(BOOL)feedback {
    if (self.finished || !CLLocationCoordinate2DIsValid(coordinate)) return;
    NSString *oldLatitude = self.latitudeField.text ?: @"", *oldLongitude = self.longitudeField.text ?: @"";
    NSString *latitude = LSFormatDecimal(coordinate.latitude, 6), *longitude = LSFormatDecimal(coordinate.longitude, 6);
    BOOL latitudeChanged = ![latitude isEqualToString:oldLatitude], longitudeChanged = ![longitude isEqualToString:oldLongitude];
    self.latitudeField.text = latitude;
    self.longitudeField.text = longitude;
    self.linkName = name.length ? name : nil;
    self.linkCoordinate = name.length ? coordinate : kCLLocationCoordinate2DInvalid;
    self.moveNote = nil;
    [self refreshStatusForField:self.latitudeField strict:NO];
    [self refreshStatusForField:self.longitudeField strict:NO];
    self.announcePlaceName = feedback;
    [self updateDraftPreviewImmediately:YES];
    if (latitudeChanged) [self flashField:self.latitudeField];
    if (longitudeChanged) [self flashField:self.longitudeField];
    [self.smartStatus setTone:LSEntryToneSuccess text:message spoken:nil];
    if ((oldLatitude.length || oldLongitude.length) && (latitudeChanged || longitudeChanged)) [self offerUndoLatitude:oldLatitude longitude:oldLongitude];
    else [self clearUndo];
    if (!feedback) return;
    LSHapticSuccess();
    [self announceReadoutWithPrefix:message];
}

#pragma mark Undo

- (void)offerUndoLatitude:(NSString *)latitude longitude:(NSString *)longitude {
    self.undoLatitude = latitude;
    self.undoLongitude = longitude;
    if (!self.undoButton.hidden) return;
    self.undoButton.hidden = NO;
    self.undoButton.alpha = 0;
    LSAnimate(^{ self.undoButton.alpha = 1; [self.mapCard layoutIfNeeded]; }, nil);
    [self refreshReadoutActions];
}
- (void)clearUndo {
    self.undoLatitude = nil;
    self.undoLongitude = nil;
    if (self.undoButton.hidden) return;
    self.undoButton.hidden = YES;
    LSAnimate(^{ [self.mapCard layoutIfNeeded]; }, nil);
    [self refreshReadoutActions];
}
- (void)undoLastChange {
    if (!self.undoLatitude && !self.undoLongitude) return;
    self.latitudeField.text = self.undoLatitude ?: @"";
    self.longitudeField.text = self.undoLongitude ?: @"";
    [self invalidateSmartLookup];
    [self clearUndo];
    self.linkName = nil;
    self.moveNote = nil;
    [self refreshStatusForField:self.latitudeField strict:NO];
    [self refreshStatusForField:self.longitudeField strict:NO];
    [self.smartStatus setTone:LSEntryToneNeutral text:@"Restored the previous coordinates." spoken:nil];
    [self updateDraftPreviewImmediately:YES];
    [self flashField:self.latitudeField];
    [self flashField:self.longitudeField];
    LSHapticSelection();
    // The Undo button just went away; move VoiceOver to what changed instead of losing focus.
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.readoutText);
}

#pragma mark Paste control

- (BOOL)canPasteItemProviders:(NSArray<NSItemProvider *> *)itemProviders {
    for (NSItemProvider *provider in itemProviders) {
        if ([provider canLoadObjectOfClass:NSString.class] || [provider canLoadObjectOfClass:NSURL.class]) return YES;
    }
    return NO;
}
- (void)pasteItemProviders:(NSArray<NSItemProvider *> *)itemProviders {
    NSItemProvider *provider = nil;
    for (NSItemProvider *candidate in itemProviders) {
        if ([candidate canLoadObjectOfClass:NSString.class] || [candidate canLoadObjectOfClass:NSURL.class]) { provider = candidate; break; }
    }
    if (!provider) { [self smartFailure:@"The clipboard doesn't hold any text." haptic:YES]; return; }
    __weak typeof(self) weakSelf = self;
    void (^deliver)(NSString *) = ^(NSString *text) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf receivePastedText:text]; });
    };
    if ([provider canLoadObjectOfClass:NSString.class]) {
        [provider loadObjectOfClass:NSString.class completionHandler:^(id<NSItemProviderReading> object, __unused NSError *error) {
            deliver([object isKindOfClass:NSString.class] ? (NSString *)object : nil);
        }];
    } else {
        [provider loadObjectOfClass:NSURL.class completionHandler:^(id<NSItemProviderReading> object, __unused NSError *error) {
            deliver([object isKindOfClass:NSURL.class] ? ((NSURL *)object).absoluteString : nil);
        }];
    }
}
- (void)receivePastedText:(NSString *)text {
    if (self.finished) return;
    NSString *trimmed = LSTrimmed(text);
    if (!trimmed.length) { [self smartFailure:@"The clipboard is empty." haptic:YES]; return; }
    if (trimmed.length > 2048) { [self smartFailure:@"That's too long to read as coordinates." haptic:YES]; return; }
    [self takeSmartText:trimmed trigger:LSSmartTriggerPaste];
}

#pragma mark Preview

// Never rewrites a live text field; intermediate '-', separators, and selections stay intact.
- (void)updateDraftPreviewImmediately:(BOOL)immediate {
    [self refreshHemisphereButton:self.latitudeHemisphere];
    [self refreshHemisphereButton:self.longitudeHemisphere];
    NSNumber *latitude = [self valueForField:self.latitudeField];
    NSNumber *longitude = [self valueForField:self.longitudeField];
    if (!latitude || !longitude) {
        [self clearPreview];
        [self refreshChooseButton];
        return;
    }
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
    BOOL moved = !self.hasPreview || coordinate.latitude != self.previewCoordinate.latitude || coordinate.longitude != self.previewCoordinate.longitude;
    self.hasPreview = YES;
    self.map.userInteractionEnabled = YES;
    if (moved) {
        self.previewCoordinate = coordinate;
        self.previewRevision++;
        [self scheduleGeocode];
    }
    [self refreshReadout];
    [self refreshChooseButton];
    if (!moved) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyPreviewToMap) object:nil];
    // Coalesce keystrokes: the map glides once typing pauses instead of jumping per digit.
    if (immediate || !self.mapShowsPreview) [self applyPreviewToMap];
    else [self performSelector:@selector(applyPreviewToMap) withObject:nil afterDelay:0.25];
}
- (void)clearPreview {
    if (!self.hasPreview && !self.mapShowsPreview) { [self refreshReadout]; return; }
    self.hasPreview = NO;
    self.previewRevision++;
    self.geocoding = NO;
    [self.geocoder cancelGeocode];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyPreviewToMap) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reverseGeocodePreview) object:nil];
    self.mapShowsPreview = NO;
    self.pinLifted = NO;
    self.liftToken++;
    self.map.userInteractionEnabled = NO;
    self.moveNote = nil;
    [self clearUndo];
    LSAnimate(^{
        self.mapDim.alpha = 1;
        self.pinView.alpha = 0;
        self.pinShadow.alpha = 0;
        self.dragHint.alpha = 0;
    }, nil);
    [self refreshReadout];
}
- (void)applyPreviewToMap {
    if (!self.hasPreview || self.userMovingMap) return;
    if (CGRectIsEmpty(self.map.bounds)) { self.needsMapRefresh = YES; return; }
    self.needsMapRefresh = NO;
    CLLocationCoordinate2D coordinate = self.previewCoordinate;
    BOOL motion = LSMapAnimationsEnabled();
    BOOL haptic = self.hapticOnLand;
    self.hapticOnLand = NO;
    if (!self.mapShowsPreview) {
        self.mapShowsPreview = YES;
        [self.map setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 1400, 1400) animated:NO];
        [self dropPinAnimated:motion && self.view.window != nil haptic:haptic];
        return;
    }
    if (LSDistanceBetween(self.map.centerCoordinate, coordinate) < 0.5) {
        if (haptic) LSHapticPinDrop();
        return;
    }
    if (!motion) {
        [self.map setCenterCoordinate:coordinate animated:NO];
        if (haptic) LSHapticPinDrop();
        return;
    }
    [self liftPin];
    self.landHaptic = haptic;
    [self.map setCenterCoordinate:coordinate animated:YES];
    // regionDidChange lands the pin; this catches a move MapKit finishes without reporting.
    NSUInteger token = self.liftToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && self.liftToken == token) [self landPin];
    });
}
- (void)dropPinAnimated:(BOOL)animated haptic:(BOOL)haptic {
    self.pinLifted = NO;
    self.liftToken++;
    CGFloat hintAlpha = LSMapDragTaught || !self.dragHintAllowed ? 0 : 1;
    void (^settle)(void) = ^{
        self.mapDim.alpha = 0;
        self.pinView.alpha = 1;
        self.pinView.transform = CGAffineTransformIdentity;
        self.pinShadow.alpha = 1;
        self.pinShadow.transform = CGAffineTransformIdentity;
        self.dragHint.alpha = hintAlpha;
    };
    if (!animated) {
        settle();
        if (haptic) LSHapticPinDrop();
        return;
    }
    self.pinView.alpha = 0;
    self.pinView.transform = CGAffineTransformMakeTranslation(0, -36);
    self.pinShadow.transform = CGAffineTransformMakeScale(0.3, 0.3);
    LSAnimateBouncy(settle, ^{ if (haptic) LSHapticPinDrop(); });
}
- (void)liftPin {
    self.pinLifted = YES;
    self.liftToken++;
    if (!LSMapAnimationsEnabled()) return;
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut animations:^{
        self.pinView.transform = CGAffineTransformMakeTranslation(0, -14);
        self.pinShadow.transform = CGAffineTransformMakeScale(0.55, 0.55);
        self.pinShadow.alpha = 0.5;
    } completion:nil];
}
- (void)landPin {
    if (!self.pinLifted) return;
    self.pinLifted = NO;
    BOOL haptic = self.landHaptic;
    self.landHaptic = NO;
    LSAnimateBouncy(^{
        self.pinView.transform = CGAffineTransformIdentity;
        self.pinShadow.transform = CGAffineTransformIdentity;
        self.pinShadow.alpha = 1;
    }, nil);
    if (haptic) LSHapticPinDrop();
}
- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    if (mapView != self.map) return;
    // A drag is written back only once the map has been still for a moment, in case MapKit
    // reports the region before a fling's deceleration is over.
    if (self.userMovingMap) { [self scheduleMapSettleCheck]; return; }
    if (animated || self.pinLifted) [self landPin];
}
- (void)mapViewDidChangeVisibleRegion:(MKMapView *)mapView {
    if (mapView != self.map || !self.userMovingMap) return;
    CLLocationCoordinate2D center = mapView.centerCoordinate;
    if (!CLLocationCoordinate2DIsValid(center)) return;
    // Live readout while dragging; the fields are written once the map settles.
    self.lastMapMotion = CACurrentMediaTime();
    self.readoutState = LSReadoutStateDragging;
    if ([self.readoutIconSymbol isEqualToString:kLSMoveArrowSymbol]) [self showReadoutIcon:@"mappin.circle.fill" tint:LSAccentColor() rotation:0 dissolve:YES];
    self.readoutTitle.font = self.coordinateFont;
    self.readoutTitle.text = LSHemisphereText(center);
    self.readoutSubtitle.text = @"Release to use this spot";
}

#pragma mark Dragging the map

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return [self.mapGestures containsObject:gestureRecognizer] || [self.mapGestures containsObject:otherGestureRecognizer];
}
- (BOOL)mapGestureActive {
    for (UIGestureRecognizer *gesture in self.mapGestures) {
        if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) return YES;
    }
    return NO;
}
- (void)mapGesture:(UIGestureRecognizer *)gesture {
    BOOL starting = gesture.state == UIGestureRecognizerStateBegan ||
        ([gesture isKindOfClass:UITapGestureRecognizer.class] && gesture.state == UIGestureRecognizerStateEnded);
    if (starting && !self.userMovingMap && self.hasPreview && !self.finished) [self beginMapAdjustment];
    BOOL ended = gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed;
    if (ended && self.userMovingMap) [self scheduleMapSettleCheck];
}
// regionDidChange usually ends a drag, but not when the finger was still down at the time
// or the map never moved; this settles once no gesture is active and the map is still.
- (void)scheduleMapSettleCheck {
    if (self.settleCheckPending) return;
    self.settleCheckPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        self.settleCheckPending = NO;
        if (!self.userMovingMap) return;
        if ([self mapGestureActive] || CACurrentMediaTime() - self.lastMapMotion < 0.3) [self scheduleMapSettleCheck];
        else [self finishMapAdjustment];
    });
}
- (void)beginMapAdjustment {
    // The keyboard stays up: dismissing it here would resize the map under the finger.
    self.lastMapMotion = CACurrentMediaTime();
    self.landHaptic = NO; // The drag's own selection tick replaces an interrupted move's.
    self.dragStartLatitude = self.latitudeField.text ?: @"";
    self.dragStartLongitude = self.longitudeField.text ?: @"";
    self.dragStartCoordinate = self.previewCoordinate;
    self.userMovingMap = YES;
    LSHapticPrepare();
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyPreviewToMap) object:nil];
    [self invalidateSmartLookup];
    [self liftPin];
    if (!LSMapDragTaught) {
        LSMapDragTaught = YES;
        LSAnimate(^{ self.dragHint.alpha = 0; }, nil);
    }
}
- (void)finishMapAdjustment {
    self.userMovingMap = NO;
    [self landPin];
    CLLocationCoordinate2D center = self.map.centerCoordinate;
    self.readoutState = LSReadoutStateNone; // Redraw the readout from the fields.
    if (!CLLocationCoordinate2DIsValid(center) || self.finished) { [self refreshReadout]; return; }
    NSString *latitude = LSFormatDecimal(center.latitude, 6), *longitude = LSFormatDecimal(center.longitude, 6);
    if ([latitude isEqualToString:self.latitudeField.text ?: @""] && [longitude isEqualToString:self.longitudeField.text ?: @""]) {
        [self refreshReadout];
        return;
    }
    [self moveTo:center from:self.dragStartCoordinate previousLatitude:self.dragStartLatitude previousLongitude:self.dragStartLongitude];
    LSHapticSelection();
}
// Shared end of a map drag and a VoiceOver nudge: write the fields, offer Undo, and say how far it went.
- (void)moveTo:(CLLocationCoordinate2D)coordinate from:(CLLocationCoordinate2D)from previousLatitude:(NSString *)previousLatitude previousLongitude:(NSString *)previousLongitude {
    [self crossFadeField:self.latitudeField toText:LSFormatDecimal(coordinate.latitude, 6)];
    [self crossFadeField:self.longitudeField toText:LSFormatDecimal(coordinate.longitude, 6)];
    self.linkName = nil;
    [self invalidateSmartLookup];
    if (self.smartStatus.tone == LSEntryToneSuccess) [self showSmartHint];
    [self refreshStatusForField:self.latitudeField strict:NO];
    [self refreshStatusForField:self.longitudeField strict:NO];
    CLLocationDistance distance = LSDistanceBetween(from, coordinate);
    BOOL directed = distance >= 1 && distance != CLLocationDistanceMax;
    [self showMoveNote:LSMoveText(from, coordinate) bearing:directed ? LSBearingBetween(from, coordinate) : NAN];
    [self updateDraftPreviewImmediately:YES]; // After a drag the map is already centred there and stays put.
    [self offerUndoLatitude:previousLatitude longitude:previousLongitude];
    [self announceReadoutWithPrefix:nil];
}
// The new value fades in, so a drag or nudge visibly rewrites the fields.
- (void)crossFadeField:(UITextField *)field toText:(NSString *)text {
    if ([field.text isEqualToString:text]) return;
    if (!field.window || field.isFirstResponder) { field.text = text; return; } // Never fade text being edited.
    [UIView transitionWithView:field duration:0.15 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ field.text = text; } completion:nil];
}
- (void)showMoveNote:(NSString *)note bearing:(double)bearing {
    self.moveNote = note;
    self.moveBearing = bearing;
    NSUInteger token = ++self.moveNoteToken;
    __weak typeof(self) weakSelf = self;
    // Long enough to read; then the place name comes back.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || token != self.moveNoteToken || !self.moveNote) return;
        self.moveNote = nil;
        [self refreshReadout];
    });
}

#pragma mark VoiceOver and copy

// About ten metres, the VoiceOver equivalent of a small drag of the map.
- (BOOL)nudgeNorth:(double)north east:(double)east {
    if (!self.hasPreview || self.finished) return NO;
    CLLocationCoordinate2D from = self.previewCoordinate;
    double latitude = MAX(-90.0, MIN(90.0, from.latitude + north / 111320.0));
    double metresPerDegree = 111320.0 * cos(from.latitude * M_PI / 180.0);
    double longitude = from.longitude + (metresPerDegree > 1 ? east / metresPerDegree : 0);
    if (longitude > 180) longitude -= 360;
    if (longitude < -180) longitude += 360;
    [self moveTo:CLLocationCoordinate2DMake(latitude, longitude) from:from previousLatitude:self.latitudeField.text ?: @"" previousLongitude:self.longitudeField.text ?: @""];
    return YES;
}
- (BOOL)putCoordinatesOnClipboard {
    if (!self.hasPreview) return NO;
    NSString *text = LSHemisphereText(self.previewCoordinate);
    UIPasteboard.generalPasteboard.string = text; // Writing never triggers the paste prompt.
    LSHapticSuccess();
    LSShowToastAbove(self.view, self.footer, [NSString stringWithFormat:@"Copied %@", text], @"doc.on.doc");
    // The button itself confirms the copy for a moment.
    NSUInteger token = ++self.clipboardFlashToken;
    [self showClipboardSymbol:@"checkmark" color:LSSuccessColor()];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || token != self.clipboardFlashToken) return;
        [self showClipboardSymbol:@"doc.on.doc" color:LSAccentTextColor()];
    });
    return YES;
}
- (void)showClipboardSymbol:(NSString *)symbol color:(UIColor *)color {
    UIButtonConfiguration *config = self.clipboardButton.configuration;
    config.image = [UIImage systemImageNamed:symbol];
    config.baseForegroundColor = color;
    if (!self.clipboardButton.window) { self.clipboardButton.configuration = config; return; }
    [UIView transitionWithView:self.clipboardButton duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ self.clipboardButton.configuration = config; } completion:nil];
}
- (void)refreshReadoutActions {
    BOOL undo = !self.undoButton.hidden;
    NSInteger signature = (self.hasPreview ? 1 : 0) | (undo ? 2 : 0);
    if (signature == self.readoutActionsSignature) return;
    self.readoutActionsSignature = signature;
    LSSetHidden(self.clipboardButton, !self.hasPreview, self.view.window != nil);
    if (!self.hasPreview) { self.readoutText.accessibilityCustomActions = nil; return; }
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAccessibilityCustomAction *> *actions = [NSMutableArray array];
    NSArray<NSArray *> *moves = @[@[@"north", @10, @0], @[@"south", @-10, @0], @[@"east", @0, @10], @[@"west", @0, @-10]];
    NSString *step = [LSShortDistanceFormatter() stringFromDistance:10]; // "33 ft" or "10 m"
    for (NSArray *move in moves) {
        double north = [move[1] doubleValue], east = [move[2] doubleValue];
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:[NSString stringWithFormat:@"Move %@ %@", step, move[0]]
                                                               actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            return [weakSelf nudgeNorth:north east:east];
        }]];
    }
    [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Copy coordinates" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        return [weakSelf putCoordinatesOnClipboard];
    }]];
    if (undo) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Undo" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            typeof(self) self = weakSelf;
            if (!self || self.undoButton.hidden) return NO;
            [self undoLastChange];
            return YES;
        }]];
    }
    self.readoutText.accessibilityCustomActions = actions;
}
// Speaks the readout once things settle, so a drag, nudge or paste is described in one go.
- (void)announceReadoutWithPrefix:(NSString *)prefix {
    self.announcementPrefix = prefix;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(announceReadout) object:nil];
    [self performSelector:@selector(announceReadout) withObject:nil afterDelay:0.5];
}
- (void)announceReadout {
    NSString *readout = self.readoutText.accessibilityValue;
    if (!readout.length || self.finished) return;
    LSAnnounce(self.announcementPrefix.length ? [NSString stringWithFormat:@"%@ %@", self.announcementPrefix, readout] : readout);
    self.announcementPrefix = nil;
}

#pragma mark Readout and place name

- (NSString *)previewName {
    if (!self.hasPreview) return nil;
    if (self.linkName && LSDistanceBetween(self.previewCoordinate, self.linkCoordinate) < 1) return self.linkName;
    // Nudges of a few metres keep the last answer; reverse lookups are rate limited.
    if (self.resolvedName && LSDistanceBetween(self.previewCoordinate, self.resolvedCoordinate) < 25) return self.resolvedName;
    return nil;
}
- (NSString *)previewContext {
    if (!self.hasPreview || [self.previewName isEqualToString:self.linkName]) return nil;
    return self.resolvedName && LSDistanceBetween(self.previewCoordinate, self.resolvedCoordinate) < 25 ? self.resolvedContext : nil;
}
- (void)refreshReadout {
    if (self.userMovingMap) return;
    [self refreshReadoutActions];
    LSReadoutState state;
    NSString *title, *subtitle, *symbol, *spoken;
    UIColor *tint = LSAccentColor();
    CGFloat rotation = 0;
    if (!self.hasPreview) {
        state = LSReadoutStateEmpty;
        symbol = @"mappin.slash";
        tint = UIColor.secondaryLabelColor;
        title = @"No spot yet";
        subtitle = @"Paste or type a latitude and longitude.";
        spoken = [NSString stringWithFormat:@"%@. %@", title, subtitle];
    } else {
        NSString *name = [self previewName], *context = [self previewContext];
        NSString *coordinate = LSHemisphereText(self.previewCoordinate);
        symbol = @"mappin.circle.fill";
        if (self.moveNote && !isnan(self.moveBearing)) {
            symbol = kLSMoveArrowSymbol; // Points the way the spot just moved.
            rotation = (self.moveBearing > 180 ? self.moveBearing - 360 : self.moveBearing) * M_PI / 180;
        }
        if (name.length) {
            state = LSReadoutStateNamed;
            title = name;
            subtitle = self.moveNote ?: context ?: coordinate;
            spoken = [NSString stringWithFormat:@"%@%@%@. %@", self.moveNote ? [self.moveNote stringByAppendingString:@". "] : @"", name,
                      context ? [@", " stringByAppendingString:context] : @"", LSSpokenCoordinate(self.previewCoordinate)];
        } else {
            state = LSReadoutStateCoordinate;
            title = coordinate;
            // Always one subtitle line, so the sticky header never jumps while a lookup runs.
            subtitle = self.moveNote ?: (self.geocoding ? @"Looking up this place…" : @"Dropped pin");
            spoken = [NSString stringWithFormat:@"%@. %@", LSSpokenCoordinate(self.previewCoordinate), subtitle];
        }
    }
    self.readoutText.accessibilityValue = spoken;
    BOOL stateChanged = state != self.readoutState;
    // The row cross-dissolves as a whole when the state changes; otherwise only the icon does.
    [self showReadoutIcon:symbol tint:tint rotation:rotation dissolve:!stateChanged];
    if (!stateChanged && [title isEqualToString:self.readoutTitle.text] && [subtitle isEqualToString:self.readoutSubtitle.text]) return;
    self.readoutState = state;
    UIFont *font = state == LSReadoutStateCoordinate ? self.coordinateFont : self.nameFont;
    void (^apply)(void) = ^{
        self.readoutTitle.font = font;
        self.readoutTitle.text = title;
        self.readoutSubtitle.text = subtitle;
    };
    if (!stateChanged || !self.view.window) { apply(); return; }
    [UIView transitionWithView:self.readoutRow duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
    LSAnimate(^{ [self.view layoutIfNeeded]; }, nil);
}
- (void)showReadoutIcon:(NSString *)symbol tint:(UIColor *)tint rotation:(CGFloat)rotation dissolve:(BOOL)dissolve {
    BOOL changed = ![symbol isEqualToString:self.readoutIconSymbol];
    BOOL turned = fabs(rotation - self.readoutIconRotation) > 0.001;
    self.readoutIconSymbol = symbol;
    self.readoutIconRotation = rotation;
    void (^image)(void) = ^{
        self.readoutIcon.image = [UIImage systemImageNamed:symbol];
        self.readoutIcon.tintColor = tint;
    };
    void (^turn)(void) = ^{ self.readoutIcon.transform = CGAffineTransformMakeRotation(rotation); };
    if (!self.readoutIcon.window) { image(); turn(); return; }
    if (!changed) {
        // Only the same arrow taking a new bearing turns; a new symbol arrives already upright.
        self.readoutIcon.tintColor = tint;
        if (turned) LSAnimate(turn, nil);
        return;
    }
    turn();
    if (dissolve) [UIView transitionWithView:self.readoutIcon duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction animations:image completion:nil];
    else image();
}
- (void)scheduleGeocode {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reverseGeocodePreview) object:nil];
    if ([self previewName]) { self.geocoding = NO; return; }
    self.geocoding = YES;
    [self performSelector:@selector(reverseGeocodePreview) withObject:nil afterDelay:0.9];
}
- (void)reverseGeocodePreview {
    if (!self.hasPreview || self.finished) { self.geocoding = NO; return; }
    if (!self.geocoder) self.geocoder = [[CLGeocoder alloc] init];
    [self.geocoder cancelGeocode];
    CLLocationCoordinate2D coordinate = self.previewCoordinate;
    NSUInteger revision = self.previewRevision;
    __weak typeof(self) weakSelf = self;
    [self.geocoder reverseGeocodeLocation:[[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude]
                        completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.finished || revision != self.previewRevision) return;
        self.geocoding = NO;
        CLPlacemark *placemark = error ? nil : placemarks.firstObject;
        NSString *name = LSPlacemarkName(placemark);
        if (name) {
            self.resolvedName = name;
            self.resolvedContext = LSPlacemarkContext(placemark, name);
            self.resolvedCoordinate = coordinate;
        }
        [self refreshReadout];
        BOOL announce = self.announcePlaceName;
        self.announcePlaceName = NO;
        if (name && announce && ![self focusedField]) {
            NSString *context = [self previewContext];
            LSAnnounce(context ? [NSString stringWithFormat:@"%@, %@", name, context] : name);
        }
    }];
}

#pragma mark Finishing

- (void)cancelPendingAnnouncement {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(announceReadout) object:nil];
    self.announcementPrefix = nil;
}
- (void)stopLookups {
    [self cancelPendingAnnouncement];
    self.smartRevision++;
    self.previewRevision++;
    self.geocoding = NO;
    [self.geocoder cancelGeocode];
    [self.linkSearch cancel];
    self.linkSearch = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self cancelPendingAnnouncement]; // Nothing is read out about a screen that is leaving.
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopLookups];
}
- (void)choose {
    if (self.finished) return;
    self.choosing = YES; // choose announces the first problem itself.
    [self.view endEditing:YES];
    self.choosing = NO;
    BOOL latitudeValid = [self validate:self.latitudeField];
    BOOL longitudeValid = [self validate:self.longitudeField];
    if (!latitudeValid || !longitudeValid) {
        UITextField *invalid = latitudeValid ? self.longitudeField : self.latitudeField;
        [invalid becomeFirstResponder];
        LSHapticError();
        LSAnnounce((invalid == self.latitudeField ? self.latitudeStatus : self.longitudeStatus).label.text);
        return;
    }
    [self updateDraftPreviewImmediately:YES];
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([self valueForField:self.latitudeField].doubleValue, [self valueForField:self.longitudeField].doubleValue);
    NSString *name = [self previewName];
    self.finished = YES;
    [self stopLookups];
    LSHapticSuccess();
    if (LSMapAnimationsEnabled()) {
        self.pinView.transform = CGAffineTransformMakeScale(1.18, 1.18);
        LSAnimateBouncy(^{ self.pinView.transform = CGAffineTransformIdentity; }, nil);
    }
    if (self.didChooseNamed) self.didChooseNamed(coordinate, name);
    else if (self.didChoose) self.didChoose(coordinate);
}
- (void)cancel {
    self.finished = YES;
    [self stopLookups];
    if (self.navigationController.viewControllers.count > 1) [self.navigationController popViewControllerAnimated:LSMapAnimationsEnabled()];
    else [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)isEditingField {
    return self.smartField.isFirstResponder || self.latitudeField.isFirstResponder || self.longitudeField.isFirstResponder;
}
// With no field editing, the screen itself takes hardware-keyboard commands.
- (void)takeKeyFocusIfIdle {
    if (self.finished || !self.view.window || self.isEditingField || self.isFirstResponder) return;
    [self becomeFirstResponder];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *use = [UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:UIKeyModifierCommand action:@selector(choose)];
    use.discoverabilityTitle = @"Use this spot";
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray arrayWithObjects:[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancel)], use, nil];
    // Option + arrow nudges the spot like the VoiceOver actions; arrows stay with text while editing.
    if (self.hasPreview && !self.finished && !self.isEditingField) {
        NSString *step = [LSShortDistanceFormatter() stringFromDistance:10];
        NSArray<NSArray<NSString *> *> *moves = @[@[UIKeyInputUpArrow, @"north"], @[UIKeyInputDownArrow, @"south"], @[UIKeyInputRightArrow, @"east"], @[UIKeyInputLeftArrow, @"west"]];
        for (NSArray<NSString *> *move in moves) {
            UIKeyCommand *nudge = [UIKeyCommand keyCommandWithInput:move[0] modifierFlags:UIKeyModifierAlternate action:@selector(nudgeFromKeyCommand:)];
            nudge.discoverabilityTitle = [NSString stringWithFormat:@"Move %@ %@", step, move[1]];
            [commands addObject:nudge];
        }
    }
    return commands;
}
- (void)nudgeFromKeyCommand:(UIKeyCommand *)command {
    NSString *input = command.input;
    double north = [input isEqualToString:UIKeyInputUpArrow] ? 10 : [input isEqualToString:UIKeyInputDownArrow] ? -10 : 0;
    double east = [input isEqualToString:UIKeyInputRightArrow] ? 10 : [input isEqualToString:UIKeyInputLeftArrow] ? -10 : 0;
    if (north || east) [self nudgeNorth:north east:east];
}
@end
