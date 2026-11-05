#import "LSPlaceSearchController.h"
#import "LSCoordinateEntryController.h"
#import "LSUI.h"
#import "LSMapLinks.h"
#import "BookmarksManager.h"
#import "PersistenceManager.h"

#pragma mark - Palette and categories

// Colour families for result badges and category chips. Light variants keep white text and
// glyphs at 4.5:1 or better and Increase Contrast darkens them further; dark variants are a
// little brighter for glyphs on dark surfaces. The category is always spelled out in text too.
typedef NS_ENUM(NSInteger, LSTone) {
    LSToneFood, LSToneStay, LSToneTravel, LSToneNature, LSToneCulture, LSToneShop,
    LSToneHealth, LSToneService, LSToneLeisure, LSTonePlace, LSToneNeutral, LSToneWarning
};

static UIColor *LSBadgeTone(CGFloat red, CGFloat green, CGFloat blue) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        CGFloat scale = traits.accessibilityContrast == UIAccessibilityContrastHigh ? 0.8 : (traits.userInterfaceStyle == UIUserInterfaceStyleDark ? 1.08 : 1.0);
        return [UIColor colorWithRed:MIN(1.0, red * scale) green:MIN(1.0, green * scale) blue:MIN(1.0, blue * scale) alpha:1.0];
    }];
}

static UIColor *LSToneColor(LSTone tone) {
    switch (tone) {
        case LSToneFood: return LSBadgeTone(0.78, 0.32, 0.0);
        case LSToneStay: return LSBadgeTone(0.47, 0.33, 0.84);
        case LSToneTravel: return LSBadgeTone(0.25, 0.42, 0.88);
        case LSToneNature: return LSBadgeTone(0.13, 0.50, 0.24);
        case LSToneCulture: return LSBadgeTone(0.80, 0.20, 0.45);
        case LSToneShop: return LSBadgeTone(0.64, 0.40, 0.0);
        case LSToneHealth: return LSBadgeTone(0.84, 0.18, 0.20);
        case LSToneService: return LSBadgeTone(0.40, 0.45, 0.53);
        case LSToneLeisure: return LSBadgeTone(0.0, 0.48, 0.53);
        case LSTonePlace: return LSAccentColor();
        case LSToneNeutral: return LSBadgeTone(0.42, 0.44, 0.48);
        case LSToneWarning: return LSBadgeTone(0.70, 0.36, 0.0);
    }
    return LSBadgeTone(0.42, 0.44, 0.48);
}

// Symbol, display name and colour family for a MapKit point-of-interest category.
static NSArray *LSCategoryInfo(MKPointOfInterestCategory category) {
    static NSDictionary<MKPointOfInterestCategory, NSArray *> *info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        info = @{
            MKPointOfInterestCategoryAirport: @[@"airplane", @"Airport", @(LSToneTravel)],
            MKPointOfInterestCategoryAmusementPark: @[@"ferriswheel", @"Amusement park", @(LSToneLeisure)],
            MKPointOfInterestCategoryAquarium: @[@"fish.fill", @"Aquarium", @(LSToneLeisure)],
            MKPointOfInterestCategoryATM: @[@"banknote.fill", @"ATM", @(LSToneService)],
            MKPointOfInterestCategoryBakery: @[@"birthday.cake.fill", @"Bakery", @(LSToneFood)],
            MKPointOfInterestCategoryBank: @[@"building.columns.fill", @"Bank", @(LSToneService)],
            MKPointOfInterestCategoryBeach: @[@"beach.umbrella.fill", @"Beach", @(LSToneNature)],
            MKPointOfInterestCategoryBrewery: @[@"mug.fill", @"Brewery", @(LSToneFood)],
            MKPointOfInterestCategoryCafe: @[@"cup.and.saucer.fill", @"Café", @(LSToneFood)],
            MKPointOfInterestCategoryCampground: @[@"tent.fill", @"Campground", @(LSToneNature)],
            MKPointOfInterestCategoryCarRental: @[@"car.fill", @"Car rental", @(LSToneTravel)],
            MKPointOfInterestCategoryEVCharger: @[@"bolt.car.fill", @"EV charger", @(LSToneTravel)],
            MKPointOfInterestCategoryFireStation: @[@"flame.fill", @"Fire station", @(LSToneHealth)],
            MKPointOfInterestCategoryFitnessCenter: @[@"dumbbell.fill", @"Gym", @(LSToneLeisure)],
            MKPointOfInterestCategoryFoodMarket: @[@"cart.fill", @"Grocery", @(LSToneShop)],
            MKPointOfInterestCategoryGasStation: @[@"fuelpump.fill", @"Gas station", @(LSToneTravel)],
            MKPointOfInterestCategoryHospital: @[@"cross.case.fill", @"Hospital", @(LSToneHealth)],
            MKPointOfInterestCategoryHotel: @[@"bed.double.fill", @"Hotel", @(LSToneStay)],
            MKPointOfInterestCategoryLaundry: @[@"washer.fill", @"Laundry", @(LSToneService)],
            MKPointOfInterestCategoryLibrary: @[@"books.vertical.fill", @"Library", @(LSToneCulture)],
            MKPointOfInterestCategoryMarina: @[@"ferry.fill", @"Marina", @(LSToneNature)],
            MKPointOfInterestCategoryMovieTheater: @[@"film.fill", @"Cinema", @(LSToneCulture)],
            MKPointOfInterestCategoryMuseum: @[@"building.columns.fill", @"Museum", @(LSToneCulture)],
            MKPointOfInterestCategoryNationalPark: @[@"mountain.2.fill", @"National park", @(LSToneNature)],
            MKPointOfInterestCategoryNightlife: @[@"music.note", @"Nightlife", @(LSToneCulture)],
            MKPointOfInterestCategoryPark: @[@"leaf.fill", @"Park", @(LSToneNature)],
            MKPointOfInterestCategoryParking: @[@"parkingsign", @"Parking", @(LSToneTravel)],
            MKPointOfInterestCategoryPharmacy: @[@"pills.fill", @"Pharmacy", @(LSToneHealth)],
            MKPointOfInterestCategoryPolice: @[@"shield.lefthalf.filled", @"Police", @(LSToneService)],
            MKPointOfInterestCategoryPostOffice: @[@"envelope.fill", @"Post office", @(LSToneService)],
            MKPointOfInterestCategoryPublicTransport: @[@"tram.fill", @"Transit", @(LSToneTravel)],
            MKPointOfInterestCategoryRestaurant: @[@"fork.knife", @"Restaurant", @(LSToneFood)],
            MKPointOfInterestCategoryRestroom: @[@"toilet.fill", @"Restroom", @(LSToneService)],
            MKPointOfInterestCategorySchool: @[@"graduationcap.fill", @"School", @(LSToneCulture)],
            MKPointOfInterestCategoryStadium: @[@"sportscourt.fill", @"Stadium", @(LSToneLeisure)],
            MKPointOfInterestCategoryStore: @[@"bag.fill", @"Store", @(LSToneShop)],
            MKPointOfInterestCategoryTheater: @[@"theatermasks.fill", @"Theater", @(LSToneCulture)],
            MKPointOfInterestCategoryUniversity: @[@"graduationcap.fill", @"University", @(LSToneCulture)],
            MKPointOfInterestCategoryWinery: @[@"wineglass.fill", @"Winery", @(LSToneFood)],
            MKPointOfInterestCategoryZoo: @[@"pawprint.fill", @"Zoo", @(LSToneLeisure)],
        };
    });
    return category ? info[category] : nil;
}

// Discovery chips shown before typing: title, symbol, search text, categories, tone.
static NSArray<NSArray *> *LSCategoryChips(void) {
    static NSArray<NSArray *> *chips;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        chips = @[
            @[@"Coffee", @"cup.and.saucer.fill", @"coffee", @[MKPointOfInterestCategoryCafe, MKPointOfInterestCategoryBakery], @(LSToneFood)],
            @[@"Restaurants", @"fork.knife", @"restaurant", @[MKPointOfInterestCategoryRestaurant], @(LSToneFood)],
            @[@"Hotels", @"bed.double.fill", @"hotel", @[MKPointOfInterestCategoryHotel], @(LSToneStay)],
            @[@"Parks", @"leaf.fill", @"park", @[MKPointOfInterestCategoryPark, MKPointOfInterestCategoryNationalPark], @(LSToneNature)],
            @[@"Museums", @"building.columns.fill", @"museum", @[MKPointOfInterestCategoryMuseum], @(LSToneCulture)],
            @[@"Airports", @"airplane", @"airport", @[MKPointOfInterestCategoryAirport], @(LSToneTravel)],
            @[@"Fuel", @"fuelpump.fill", @"gas station", @[MKPointOfInterestCategoryGasStation, MKPointOfInterestCategoryEVCharger], @(LSToneTravel)],
            @[@"Groceries", @"cart.fill", @"grocery store", @[MKPointOfInterestCategoryFoodMarket], @(LSToneShop)],
            @[@"Beaches", @"beach.umbrella.fill", @"beach", @[MKPointOfInterestCategoryBeach], @(LSToneNature)],
        ];
    });
    return chips;
}

#pragma mark - Helpers

static const NSUInteger kLSMaximumSuggestions = 12;
static const NSTimeInterval kLSSuggestDelay = 0.2;  // pause in typing before asking for suggestions
static const NSTimeInterval kLSSlowDelay = 0.4;     // progress appears only when an answer is slow
static const NSTimeInterval kLSAnnounceDelay = 0.6; // VoiceOver hears counts once typing settles

static BOOL LSRegionUsable(MKCoordinateRegion region) {
    return CLLocationCoordinate2DIsValid(region.center) && region.span.latitudeDelta > 0 && region.span.longitudeDelta > 0 &&
        region.span.latitudeDelta <= 180 && region.span.longitudeDelta <= 360;
}

static BOOL LSIsNoResults(NSError *error) {
    return !error || ([error.domain isEqualToString:MKErrorDomain] && error.code == MKErrorPlacemarkNotFound);
}

static NSString *LSFailureMessage(NSError *error) {
    if ([error.domain isEqualToString:MKErrorDomain] && error.code == MKErrorLoadingThrottled) {
        return @"Too many searches in a short time. Wait a moment, then try again.";
    }
    if ([error.domain isEqualToString:NSURLErrorDomain] || ([error.domain isEqualToString:MKErrorDomain] && error.code == MKErrorServerFailure)) {
        return @"Check your internet connection. Saved places and coordinates still work offline.";
    }
    return @"Place search didn’t respond. Try again, or enter coordinates.";
}

static NSString *LSItemName(MKMapItem *item) { return item.name.length ? item.name : @"Selected place"; }

// Street and town, or town, region and country, leaving out whatever repeats the name.
static NSString *LSShortAddress(MKPlacemark *mark, NSString *name) {
    NSString *street = nil;
    if (mark.thoroughfare.length) street = mark.subThoroughfare.length ? [NSString stringWithFormat:@"%@ %@", mark.subThoroughfare, mark.thoroughfare] : mark.thoroughfare;
    NSArray<NSString *> *candidates = street ? @[street, mark.locality ?: @""] : @[mark.locality ?: @"", mark.administrativeArea ?: @"", mark.country ?: @""];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in candidates) {
        if (!part.length || [part isEqualToString:name] || [parts containsObject:part]) continue;
        [parts addObject:part];
    }
    if (parts.count) return [parts componentsJoinedByString:@", "];
    NSString *title = mark.title;
    return title.length && ![title isEqualToString:name] ? title : nil;
}

static NSString *LSDistanceText(CLLocationDistance meters, BOOL spoken) {
    static MKDistanceFormatter *brief, *full;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        brief = [[MKDistanceFormatter alloc] init];
        brief.unitStyle = MKDistanceFormatterUnitStyleAbbreviated;
        full = [[MKDistanceFormatter alloc] init];
        full.unitStyle = MKDistanceFormatterUnitStyleFull;
    });
    return [(spoken ? full : brief) stringFromDistance:meters];
}

// Initial bearing of the great circle, in radians clockwise from north.
static double LSBearing(CLLocationCoordinate2D from, CLLocationCoordinate2D to) {
    double lat1 = from.latitude * M_PI / 180.0, lat2 = to.latitude * M_PI / 180.0;
    double deltaLon = (to.longitude - from.longitude) * M_PI / 180.0;
    return atan2(sin(deltaLon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon));
}

static NSString *LSCompassName(double bearing) {
    NSArray<NSString *> *names = @[@"north", @"northeast", @"east", @"southeast", @"south", @"southwest", @"west", @"northwest"];
    long index = lround(bearing * 180.0 / M_PI / 45.0) % 8;
    return names[(NSUInteger)(index < 0 ? index + 8 : index)];
}

static NSAttributedString *LSStyledText(NSString *text, NSArray<NSValue *> *highlights, NSRange monospaced,
                                        UIFont *font, UIFont *strongFont, UIColor *color, UIColor *strongColor) {
    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:text ?: @""
                                                                               attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
    for (NSValue *value in highlights) {
        NSRange range = value.rangeValue;
        if (range.location == NSNotFound || NSMaxRange(range) > styled.length) continue;
        [styled addAttributes:@{NSFontAttributeName: strongFont, NSForegroundColorAttributeName: strongColor} range:range];
    }
    if (monospaced.location != NSNotFound && NSMaxRange(monospaced) <= styled.length) {
        [styled addAttribute:NSFontAttributeName value:LSMonospacedFont(UIFontTextStyleSubheadline) range:monospaced];
    }
    return styled;
}

#pragma mark - Rows

typedef NS_ENUM(NSInteger, LSRowKind) {
    LSRowPlace,       // a known coordinate: choosing it closes the search
    LSRowCompletion,  // a suggestion, looked up before it can be used
    LSRowQuery,       // runs a full search for the typed text
    LSRowLink,        // a pasted map link that is opening or could not be read
    LSRowCoordinates, // pushes coordinate entry
    LSRowStatus,      // progress or a hint, not selectable
    LSRowEmpty,       // a centered empty or error state, not selectable
};

@interface LSSearchRow : NSObject
@property (nonatomic) LSRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<NSValue *> *titleHighlights;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSArray<NSValue *> *detailHighlights;
@property (nonatomic) NSRange detailMonospaced;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic) LSTone tone;
@property (nonatomic) CLLocationCoordinate2D coordinate;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *address;
@property (nonatomic, strong) MKLocalSearchCompletion *completion;
@property (nonatomic, copy) NSString *spokenLabel;
@property (nonatomic, copy) NSString *spokenValue;
@property (nonatomic, copy) NSString *hint;
@property (nonatomic) BOOL busy;
@property (nonatomic, copy) NSString *actionTitle;
@property (nonatomic, copy) NSString *actionSymbol;
@property (nonatomic) SEL action;
// Radians clockwise from north, from the map center to this place; NAN when not shown.
@property (nonatomic) double bearing;
@end
@implementation LSSearchRow
- (instancetype)init {
    self = [super init];
    if (self) {
        _title = @""; _name = @""; _symbol = @"mappin"; _titleHighlights = @[]; _detailHighlights = @[];
        _detailMonospaced = NSMakeRange(NSNotFound, 0); _coordinate = kCLLocationCoordinate2DInvalid; _tone = LSTonePlace; _bearing = NAN;
    }
    return self;
}
+ (instancetype)rowWithKind:(LSRowKind)kind title:(NSString *)title {
    LSSearchRow *row = [[self alloc] init];
    row.kind = kind;
    row.title = title ?: @"";
    return row;
}
@end

@interface LSSearchSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSArray<LSSearchRow *> *rows;
@end
@implementation LSSearchSection
+ (instancetype)sectionWithTitle:(NSString *)title rows:(NSArray<LSSearchRow *> *)rows footer:(NSString *)footer {
    LSSearchSection *section = [[self alloc] init];
    section.title = title;
    section.rows = rows;
    section.footer = footer;
    return section;
}
@end

#pragma mark - Cells

// Category badge, name with the typed match in bold, and a secondary line with the distance.
// At accessibility text sizes the badge moves above the text so nothing is squeezed.
@interface LSSearchResultCell : UITableViewCell
@property (nonatomic, strong) UIView *badge;
@property (nonatomic, strong) UIImageView *glyph;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIView *arrowHolder;
@property (nonatomic, strong) UIImageView *arrow;
@property (nonatomic, strong) NSLayoutConstraint *arrowWidth;
@property (nonatomic, strong) NSLayoutConstraint *arrowHeight;
@property (nonatomic, strong) UIStackView *detailRow;
@property (nonatomic, strong) UIStackView *textStack;
@property (nonatomic, strong) UIStackView *row;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSLayoutConstraint *badgeWidth;
@property (nonatomic, strong) UIColor *tone;
@end
@implementation LSSearchResultCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    _badge = [[UIView alloc] init];
    _badge.translatesAutoresizingMaskIntoConstraints = NO;
    _badge.layer.cornerCurve = kCACornerCurveContinuous;
    _badge.isAccessibilityElement = NO;
    [_badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _glyph = [[UIImageView alloc] init];
    _glyph.translatesAutoresizingMaskIntoConstraints = NO;
    _glyph.tintColor = UIColor.whiteColor;
    _glyph.contentMode = UIViewContentModeCenter;
    [_badge addSubview:_glyph];
    // Fonts live in the attributed text, rebuilt on every reload, including text size changes.
    _titleLabel = LSLabel(@"", UIFontTextStyleBody);
    _titleLabel.adjustsFontForContentSizeCategory = NO;
    _detailLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    _detailLabel.adjustsFontForContentSizeCategory = NO;
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    // The arrow sits in a box one text line tall, so it centres on the first line as text wraps.
    _arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"location.north.fill"]];
    _arrow.translatesAutoresizingMaskIntoConstraints = NO;
    _arrow.tintColor = UIColor.secondaryLabelColor;
    _arrow.contentMode = UIViewContentModeCenter;
    _arrowHolder = [[UIView alloc] init];
    _arrowHolder.translatesAutoresizingMaskIntoConstraints = NO;
    _arrowHolder.isAccessibilityElement = NO;
    [_arrowHolder addSubview:_arrow];
    [_arrowHolder setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_arrowHolder setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _arrowWidth = [_arrowHolder.widthAnchor constraintEqualToConstant:14];
    _arrowHeight = [_arrowHolder.heightAnchor constraintEqualToConstant:18];
    _detailRow = LSRow(@[_arrowHolder, _detailLabel], 4);
    _detailRow.alignment = UIStackViewAlignmentTop;
    _textStack = LSStack(@[_titleLabel, _detailRow], 2);
    _row = LSRow(@[_badge, _textStack], 14);
    [self.contentView addSubview:_row];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _badgeWidth = [_badge.widthAnchor constraintEqualToConstant:32];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    NSLayoutConstraint *bottom = [_row.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-2];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        _badgeWidth,
        _arrowWidth,
        _arrowHeight,
        [_arrow.centerXAnchor constraintEqualToAnchor:_arrowHolder.centerXAnchor],
        [_arrow.centerYAnchor constraintEqualToAnchor:_arrowHolder.centerYAnchor],
        [_badge.heightAnchor constraintEqualToAnchor:_badge.widthAnchor],
        [_glyph.centerXAnchor constraintEqualToAnchor:_badge.centerXAnchor],
        [_glyph.centerYAnchor constraintEqualToAnchor:_badge.centerYAnchor],
        [_row.topAnchor constraintEqualToAnchor:margins.topAnchor constant:2],
        bottom,
        [_row.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_row.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor]
    ]];
    return self;
}
// Separators start under the text, not under the badge.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect text = [self.textStack convertRect:self.textStack.bounds toView:self];
    BOOL rightToLeft = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat inset = round(rightToLeft ? self.bounds.size.width - CGRectGetMaxX(text) : CGRectGetMinX(text));
    if (inset > 0 && fabs(self.separatorInset.left - inset) > 0.5) self.separatorInset = UIEdgeInsetsMake(0, inset, 0, 0);
}
- (void)configureWithRow:(LSSearchRow *)row traits:(UITraitCollection *)traits {
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory);
    self.row.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.row.alignment = large ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    self.row.spacing = large ? LSSpaceS : 14;
    CGFloat size = round(MIN(52, [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledValueForValue:32 compatibleWithTraitCollection:traits]));
    self.badgeWidth.constant = size;
    self.badge.layer.cornerRadius = size / 2;
    self.tone = LSFillColor(LSToneColor(row.tone));
    self.badge.backgroundColor = self.tone;
    self.glyph.image = [UIImage systemImageNamed:row.symbol] ?: [UIImage systemImageNamed:@"mappin"];
    self.glyph.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:round(size * 0.46) weight:UIImageSymbolWeightSemibold];
    // Typed matches are bold against a regular title; plain rows keep a semibold title.
    BOOL matched = row.titleHighlights.count > 0;
    UIFont *strongTitle = LSFont(UIFontTextStyleBody, UIFontWeightSemibold, 44);
    self.titleLabel.attributedText = LSStyledText(row.title, row.titleHighlights, NSMakeRange(NSNotFound, 0),
                                                  matched ? LSFont(UIFontTextStyleBody, UIFontWeightRegular, 44) : strongTitle, strongTitle,
                                                  UIColor.labelColor, UIColor.labelColor);
    self.detailRow.hidden = row.detail.length == 0;
    self.detailLabel.numberOfLines = large ? 0 : 3;
    UIFont *detailFont = LSFont(UIFontTextStyleSubheadline, UIFontWeightRegular, 36);
    self.detailLabel.attributedText = LSStyledText(row.detail, row.detailHighlights, row.detailMonospaced, detailFont,
                                                   LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 36),
                                                   UIColor.secondaryLabelColor, UIColor.labelColor);
    BOOL pointing = !isnan(row.bearing);
    self.arrowHolder.hidden = !pointing;
    if (pointing) {
        self.arrowWidth.constant = ceil(detailFont.pointSize * 0.85);
        self.arrowHeight.constant = ceil(detailFont.lineHeight);
        self.arrow.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:round(detailFont.pointSize * 0.7) weight:UIImageSymbolWeightSemibold];
        self.arrow.transform = CGAffineTransformMakeRotation(row.bearing);
    }
    if (row.busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    self.accessoryView = row.busy ? self.spinner : nil;
    // Only coordinate entry pushes a screen; every other row acts in place.
    self.accessoryType = row.kind == LSRowCoordinates ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = row.spokenLabel ?: (row.detail.length ? [NSString stringWithFormat:@"%@, %@", row.title, row.detail] : row.title);
    self.accessibilityValue = row.busy ? @"Loading" : row.spokenValue;
    self.accessibilityHint = row.busy ? nil : row.hint;
    self.accessibilityTraits = UIAccessibilityTraitButton;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.alpha = 1;
    self.transform = CGAffineTransformIdentity;
}
// Cell highlighting clears subview backgrounds; the badge keeps its colour.
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.badge.backgroundColor = self.tone;
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    self.badge.backgroundColor = self.tone;
}
@end

// Hosts a progress line or an empty state on a clear background.
@interface LSSearchMessageCell : UITableViewCell
@property (nonatomic, strong) UIView *hosted;
@property (nonatomic, copy) NSString *hostedKey;
@end
@implementation LSSearchMessageCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    }
    return self;
}
- (void)host:(UIView *)view {
    [self.hosted removeFromSuperview];
    self.hosted = view;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:view];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    NSLayoutConstraint *bottom = [view.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:margins.topAnchor],
        bottom,
        [view.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor]
    ]];
}
@end

static UIView *LSStatusView(NSString *text, NSString *symbol, BOOL busy) {
    UIView *lead;
    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        lead = spinner;
    } else {
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol.length ? symbol : @"info.circle"]];
        icon.tintColor = UIColor.secondaryLabelColor;
        icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleLarge];
        lead = icon;
    }
    [lead setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [lead setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *label = LSLabel(text, UIFontTextStyleSubheadline);
    label.textColor = UIColor.secondaryLabelColor;
    UIStackView *row = LSRow(@[lead, label], LSSpaceM);
    row.layoutMargins = UIEdgeInsetsMake(LSSpaceS, 0, LSSpaceS, 0);
    row.layoutMarginsRelativeArrangement = YES;
    return row;
}

#pragma mark - Controller

typedef NS_ENUM(NSInteger, LSSearchPhase) {
    LSSearchPhaseIdle,        // nothing typed: chips, saved and recent places
    LSSearchPhaseShort,       // one character: saved matches only
    LSSearchPhaseTooLong,
    LSSearchPhaseSuggesting,  // waiting for suggestions; earlier ones stay visible
    LSSearchPhaseSuggestions,
    LSSearchPhaseSmart,       // coordinates or a map link, answered without a text search
    LSSearchPhaseSearching,   // full or category search in flight
    LSSearchPhaseResults,
    LSSearchPhaseFailed,
    LSSearchPhasePaused,
};

// Phases that look alike share a group, so typing never cross-fades the list.
static NSInteger LSPhaseGroup(LSSearchPhase phase) {
    switch (phase) {
        case LSSearchPhaseShort: case LSSearchPhaseTooLong: case LSSearchPhaseSuggesting: case LSSearchPhaseSuggestions: return 1;
        default: return 10 + phase;
    }
}

typedef NS_OPTIONS(NSUInteger, LSSearchOptions) {
    LSSearchChooseSingle = 1 << 0,   // a single valid place is used at once
    LSSearchSortByDistance = 1 << 1, // nearest first, for category browsing
    LSSearchKeepList = 1 << 2,       // a tapped suggestion: the list stays, its row shows progress
};

@interface LSPlaceSearchController () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate, MKLocalSearchCompleterDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIView *searchGlyph;
@property (nonatomic, strong) UIActivityIndicatorView *fieldSpinner;
@property (nonatomic, strong) UIView *captionHolder;
@property (nonatomic, strong) UILabel *caption;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *chipsHeader;
@property (nonatomic, strong) UIView *plainHeader;
@property (nonatomic, strong) UIScrollView *chipsScroll;
@property (nonatomic, strong) NSArray<UIButton *> *chips;
@property (nonatomic) BOOL wantsChips;
@property (nonatomic) CGFloat chipsInset;
@property (nonatomic) CGFloat headerWidth;
@property (nonatomic, copy) UIContentSizeCategory headerCategory;
@property (nonatomic) NSUInteger placesSectionIndex;
@property (nonatomic, strong) MKLocalSearchCompleter *completer;
@property (nonatomic, strong) MKLocalSearch *search;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, copy) NSString *areaName;
@property (nonatomic, copy) NSString *query;
@property (nonatomic) LSSearchPhase phase;
@property (nonatomic) LSSearchPhase renderedPhase;
@property (nonatomic) LSSearchPhase pausedPhase;
@property (nonatomic) NSInteger category;
@property (nonatomic, strong) NSArray<MKLocalSearchCompletion *> *completions;
@property (nonatomic, strong) NSArray<MKMapItem *> *places;
@property (nonatomic, copy) NSString *placesTitle;
@property (nonatomic, copy) NSString *failure;
@property (nonatomic) BOOL suggestionsFailed;
@property (nonatomic) BOOL slow;
@property (nonatomic, strong) LSSearchRow *smartRow;
@property (nonatomic, strong) MKLocalSearchCompletion *resolving;
@property (nonatomic, strong) MKLocalSearchRequest *lastRequest;
@property (nonatomic) LSSearchOptions lastOptions;
// Times the last search was repeated over a wider area (each 4x the span, at most twice).
@property (nonatomic) NSUInteger widenings;
// Saved places and recents, offered before typing and matched while typing.
@property (nonatomic, strong) NSArray<NSDictionary *> *saved;
@property (nonatomic, strong) NSArray<NSDictionary *> *recents;
@property (nonatomic, strong) NSArray<LSSearchSection *> *sections;
@property (nonatomic, copy) NSString *pendingAnnouncement;
@property (nonatomic) NSUInteger announcedRevision;
@property (nonatomic) NSUInteger revision;
@property (nonatomic) BOOL closed;
@property (nonatomic) BOOL appeared;
@property (nonatomic) BOOL settingText;
@end

@implementation LSPlaceSearchController
- (instancetype)init {
    self = [super init];
    if (self) {
        _initialCoordinate = kCLLocationCoordinate2DInvalid;
        _completions = @[]; _places = @[]; _saved = @[]; _recents = @[]; _sections = @[];
        _query = @""; _category = -1; _announcedRevision = NSUIntegerMax; _placesSectionIndex = NSNotFound;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    UIBarButtonItem *coordinates = [[UIBarButtonItem alloc] initWithTitle:@"Coordinates" style:UIBarButtonItemStylePlain target:self action:@selector(enterCoordinates)];
    coordinates.accessibilityHint = @"Opens latitude and longitude fields.";
    self.navigationItem.rightBarButtonItem = coordinates;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(backgrounded:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(backgrounded:) name:UISceneWillDeactivateNotification object:nil];
    [center addObserver:self selector:@selector(foregrounded:) name:UISceneDidActivateNotification object:nil];
    [center addObserver:self selector:@selector(foregrounded:) name:UIApplicationDidBecomeActiveNotification object:nil];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = @"Place, address, coordinates or link";
    UISearchTextField *field = self.searchBar.searchTextField;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    // Offers places from Maps, Messages and Contacts above the keyboard.
    field.textContentType = UITextContentTypeLocation;
    self.searchBar.accessibilityLabel = @"Search places";
    field.accessibilityLabel = @"Search places";
    field.accessibilityHint = @"Type a place or an address, or paste coordinates or a map link.";
    self.searchGlyph = field.leftView;
    self.fieldSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.fieldSpinner.frame = CGRectMake(0, 0, 20, 20);
    self.fieldSpinner.hidesWhenStopped = NO;

    UIView *searchHolder = [[UIView alloc] init];
    searchHolder.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [searchHolder addSubview:self.searchBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:searchHolder.topAnchor],
        [self.searchBar.bottomAnchor constraintEqualToAnchor:searchHolder.bottomAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:searchHolder.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:searchHolder.trailingAnchor constant:-8]
    ]];
    [self buildCaption];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 64;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.chipsHeader = [self makeChipsHeader];
    self.plainHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, LSSpaceS)];
    self.table.tableHeaderView = self.plainHeader;

    UIStackView *stack = LSStack(@[searchHolder, self.captionHolder, self.table], 0);
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.table.heightAnchor constraintGreaterThanOrEqualToConstant:0]
    ]];
    LSAnchorAboveKeyboard(stack, self.view);
    [self loadShortcuts];
    [self rebuild];
    [self lookUpArea];
    // Saved matches, coordinates and links answer at once; suggestions start once on screen.
    if (self.initialQuery.length) {
        [self setSearchText:self.initialQuery];
        [self updateForText:self.initialQuery];
    }
}

// A quiet line under the field saying where results are ranked from.
- (void)buildCaption {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"location.magnifyingglass"]];
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote scale:UIImageSymbolScaleMedium];
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [icon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.caption = LSLabel(@"Searching near the map area", UIFontTextStyleFootnote);
    self.caption.textColor = UIColor.secondaryLabelColor;
    UIStackView *row = LSRow(@[icon, self.caption], 6);
    UIView *holder = [[UIView alloc] init];
    holder.translatesAutoresizingMaskIntoConstraints = NO;
    [holder addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:holder.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor constant:-LSSpaceXS],
        [row.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor constant:LSSpaceXL],
        [row.trailingAnchor constraintLessThanOrEqualToAnchor:holder.trailingAnchor constant:-LSSpaceXL]
    ]];
    holder.hidden = !LSRegionUsable(self.searchRegion);
    self.captionHolder = holder;
}

- (void)lookUpArea {
    MKCoordinateRegion region = self.searchRegion;
    if (!LSRegionUsable(region) || region.span.latitudeDelta > 12) return;
    CLLocation *center = [[CLLocation alloc] initWithLatitude:region.center.latitude longitude:region.center.longitude];
    CLLocationDegrees span = region.span.latitudeDelta;
    self.geocoder = [[CLGeocoder alloc] init];
    __weak typeof(self) weakSelf = self;
    [self.geocoder reverseGeocodeLocation:center completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        (void)error;
        typeof(self) self = weakSelf;
        if (!self || self.closed) return;
        CLPlacemark *mark = placemarks.firstObject;
        // A town when zoomed in, a region or country when looking at more of the map.
        NSString *name = span < 1.5 ? (mark.locality ?: mark.subAdministrativeArea ?: mark.administrativeArea) : (mark.administrativeArea ?: mark.country);
        if (!name.length) return;
        self.areaName = name;
        self.caption.text = [NSString stringWithFormat:@"Searching near %@", name];
        [self updateChips];
        [self rebuild];
    }];
}

- (void)loadShortcuts {
    NSMutableArray *saved = [NSMutableArray array];
    NSMutableArray *recents = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (LSBookmark *place in BookmarksManager.shared.allBookmarks) {
        [saved addObject:@{@"name":place.name, @"lat":@(place.coordinate.latitude), @"lon":@(place.coordinate.longitude), @"saved":@YES}];
        [seen addObject:LSCoordinateText(place.coordinate)];
    }
    for (NSDictionary *entry in PersistenceManager.shared.recentLocations) {
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
        if ([seen containsObject:LSCoordinateText(coordinate)]) continue;
        NSString *name = [entry[@"LSRecentName"] isKindOfClass:NSString.class] ? entry[@"LSRecentName"] : @"Recent location";
        [recents addObject:@{@"name":name, @"lat":@(coordinate.latitude), @"lon":@(coordinate.longitude), @"saved":@NO}];
    }
    self.saved = saved;
    self.recents = recents;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.closed = NO;
    if (self.phase == LSSearchPhasePaused) [self resumeWork];
    // Suggestions for a starting query wait for a window, so ask again now there is one.
    else if (!self.appeared && self.phase == LSSearchPhaseSuggesting && !self.completer) [self updateForText:self.searchBar.text];
    // Coming back from coordinate entry to a list of results keeps the keyboard down.
    if (!self.appeared || self.phase == LSSearchPhaseIdle) [self.searchBar becomeFirstResponder];
    self.appeared = YES;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Pushing coordinates or dismissing stops outstanding work; it resumes if the view returns.
    [self pauseWork];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self sizeChipsHeader:NO];
    // Chips start where the cards start but scroll from edge to edge.
    CGFloat leading = self.table.layoutMargins.left;
    if (fabs(leading - self.chipsInset) > 0.5) {
        self.chipsInset = leading;
        self.chipsScroll.contentInset = UIEdgeInsetsMake(0, leading, 0, self.table.layoutMargins.right);
        self.chipsScroll.contentOffset = CGPointMake(-leading, 0);
    }
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self.table reloadData];
        [self.view setNeedsLayout];
        // Chips restyle their titles on their own pass; measure again once that has run.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf sizeChipsHeader:YES]; });
    }
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _completer.delegate = nil;
    [_completer cancel];
    [_search cancel];
    [_geocoder cancelGeocode];
}

#pragma mark Chips

- (UIView *)makeChipsHeader {
    NSArray<NSArray *> *definitions = LSCategoryChips();
    NSMutableArray<UIButton *> *chips = [NSMutableArray array];
    for (NSUInteger index = 0; index < definitions.count; index++) {
        UIButton *chip = LSChipButton(definitions[index][0], definitions[index][1]);
        // The row scrolls, so a chip keeps its whole title on one line at every text size.
        LSSetChipOneLine(chip);
        chip.tag = (NSInteger)index;
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self tintChip:chip tone:(LSTone)[definitions[index][4] integerValue] symbol:definitions[index][1]];
        [chips addObject:chip];
    }
    self.chips = chips;
    [self updateChips];
    UIStackView *row = LSRow(chips, LSSpaceS);
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [scroll addSubview:row];
    self.chipsScroll = scroll;
    UIView *holder = [[UIView alloc] init];
    holder.accessibilityContainerType = UIAccessibilityContainerTypeSemanticGroup;
    holder.accessibilityLabel = @"Categories";
    holder.accessibilityValue = @"None";
    [holder addSubview:scroll];
    NSLayoutConstraint *bottom = [scroll.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor constant:-LSSpaceXS];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        [scroll.topAnchor constraintEqualToAnchor:holder.topAnchor constant:LSSpaceS],
        bottom,
        [scroll.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor]
    ]];
    return holder;
}

- (void)setChipsVisible:(BOOL)visible {
    if (visible == self.wantsChips) return;
    self.wantsChips = visible;
    if (visible) [self sizeChipsHeader:YES];
    else self.table.tableHeaderView = self.plainHeader;
    [self.view setNeedsLayout];
}

// Measuring the header is a full layout pass, so it only runs when its inputs change.
- (void)sizeChipsHeader:(BOOL)force {
    CGFloat width = self.table.bounds.size.width;
    UIContentSizeCategory category = self.traitCollection.preferredContentSizeCategory;
    if (!self.wantsChips || width <= 0) return;
    BOOL current = self.table.tableHeaderView == self.chipsHeader && fabs(width - self.headerWidth) < 0.5 &&
        [category isEqualToString:self.headerCategory];
    if (current && !force) return;
    LSSizeTableHeader(self.table, self.chipsHeader);
    self.headerWidth = width;
    self.headerCategory = category;
}

// Category colour, matching the result badges: a tone symbol on idle chips and a tone fill once
// selected, where a trailing clear mark shows that tapping again removes the category. This runs
// after the shared chip styling, so every configuration update keeps it.
- (void)tintChip:(UIButton *)chip tone:(LSTone)tone symbol:(NSString *)symbol {
    UIColor *glyph = LSToneColor(tone);
    LSSetChipIconColor(chip, glyph);
    UIButtonConfigurationUpdateHandler shared = chip.configurationUpdateHandler;
    UIColor *fill = LSFillColor(glyph);
    UIImage *idleImage = [UIImage systemImageNamed:symbol];
    UIImage *clearImage = [UIImage systemImageNamed:@"xmark.circle.fill"];
    __weak typeof(self) weakSelf = self;
    chip.configurationUpdateHandler = ^(UIButton *button) {
        if (shared) shared(button);
        typeof(self) self = weakSelf;
        BOOL selected = self && button.tag == self.category;
        UIButtonConfiguration *config = button.configuration;
        config.image = selected ? clearImage : idleImage;
        config.imagePlacement = selected ? NSDirectionalRectEdgeTrailing : NSDirectionalRectEdgeLeading;
        if (selected && button.enabled) config.baseBackgroundColor = fill;
        button.configuration = config;
    };
}

- (void)updateChips {
    NSArray<NSArray *> *definitions = LSCategoryChips();
    for (UIButton *chip in self.chips) {
        NSArray *definition = definitions[(NSUInteger)chip.tag];
        BOOL selected = chip.tag == self.category;
        LSSetChipSelected(chip, selected);
        [chip setNeedsUpdateConfiguration];
        chip.accessibilityHint = selected ? @"Clears this category." :
            [NSString stringWithFormat:@"Lists %@ %@.", [definition[0] lowercaseString], [self nearText]];
    }
    self.chipsHeader.accessibilityValue = self.category >= 0 ? [self categoryTitle] : @"None";
}

- (void)chipTapped:(UIButton *)chip {
    LSHapticSelection();
    if (chip.tag == self.category) {
        // Tapping the selected chip again goes back to the start.
        self.category = -1;
        [self setSearchText:@""];
        [self updateChips];
        [self updateForText:@""];
        return;
    }
    [self runCategory:chip.tag];
}

- (void)runCategory:(NSInteger)index {
    NSArray *definition = LSCategoryChips()[(NSUInteger)index];
    self.category = index;
    [self setSearchText:definition[0]];
    self.query = definition[0];
    self.completions = @[];
    self.smartRow = nil;
    self.resolving = nil;
    self.placesTitle = nil;
    [self.searchBar resignFirstResponder];
    [self updateChips];
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = definition[2];
    request.resultTypes = MKLocalSearchResultTypePointOfInterest;
    request.pointOfInterestFilter = [[MKPointOfInterestFilter alloc] initIncludingCategories:definition[3]];
    if (LSRegionUsable(self.searchRegion)) request.region = self.searchRegion;
    self.widenings = 0;
    [self startSearch:request options:LSSearchSortByDistance];
}

// Chips fill in the field; that must not read as the person typing.
- (void)setSearchText:(NSString *)text {
    self.settingText = YES;
    self.searchBar.text = text;
    self.settingText = NO;
}

- (NSString *)nearText { return self.areaName.length ? [NSString stringWithFormat:@"near %@", self.areaName] : @"near the map"; }
- (NSString *)categoryTitle { return self.category >= 0 ? LSCategoryChips()[(NSUInteger)self.category][0] : @""; }

#pragma mark Typing

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    (void)bar;
    if (self.settingText) return;
    // Editing the text leaves a category and becomes an ordinary search.
    if (self.category >= 0) { self.category = -1; [self updateChips]; }
    [self updateForText:text];
}

- (void)updateForText:(NSString *)text {
    BOOL hadSmartRow = self.smartRow != nil;
    BOOL stillWaiting = self.phase == LSSearchPhaseSuggesting && self.slow;
    [self invalidateRequests];
    self.slow = NO;
    self.places = @[];
    self.failure = nil;
    self.resolving = nil;
    self.smartRow = nil;
    self.suggestionsFailed = NO;
    NSString *query = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.query = query;
    if (!query.length) {
        self.completions = @[];
        self.phase = LSSearchPhaseIdle;
        [self rebuild];
        return;
    }
    CLLocationCoordinate2D pasted;
    if (LSParseCoordinatePair(query, &pasted)) {
        // A pasted pair, decimal or degrees-minutes-seconds, is offered directly instead of being searched as text.
        self.completions = @[];
        self.phase = LSSearchPhaseSmart;
        self.smartRow = [self useRow:pasted name:@"Entered coordinates" title:[NSString stringWithFormat:@"Use %@", LSCoordinateText(pasted)]
                              source:@"Coordinates" symbol:@"mappin.and.ellipse"];
        [self rebuild];
        if (!hadSmartRow) LSHapticSelection();
        [self announceLater:[NSString stringWithFormat:@"Coordinates recognized: %@. Press Search to use them.", LSCoordinateText(pasted)]];
        return;
    }
    NSURL *link = [LSMapLinks firstMapLinkInText:query];
    if (link) {
        self.completions = @[];
        [self openLink:link];
        return;
    }
    if (query.length > 256) {
        self.completions = @[];
        self.phase = LSSearchPhaseTooLong;
        [self rebuild];
        return;
    }
    if (query.length < 2) {
        self.completions = @[];
        self.phase = LSSearchPhaseShort;
        [self rebuild];
        return;
    }
    // Earlier suggestions stay on screen until new ones arrive, so the list never flashes empty.
    self.phase = LSSearchPhaseSuggesting;
    self.slow = stillWaiting;
    [self setLoading:stillWaiting];
    [self rebuild];
    [self requestSuggestions:query];
}

- (void)requestSuggestions:(NSString *)query {
    NSUInteger revision = self.revision;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLSSuggestDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision || !self.view.window) return;
        // One completer per query prevents late results from an older fragment being reused.
        MKLocalSearchCompleter *completer = [[MKLocalSearchCompleter alloc] init];
        completer.delegate = self;
        completer.resultTypes = MKLocalSearchCompleterResultTypeAddress | MKLocalSearchCompleterResultTypePointOfInterest | MKLocalSearchCompleterResultTypeQuery;
        if (LSRegionUsable(self.searchRegion)) completer.region = self.searchRegion;
        self.completer = completer;
        completer.queryFragment = query;
    });
    [self showProgressIfSlow];
}

- (void)showProgressIfSlow {
    NSUInteger revision = self.revision;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLSSlowDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision || self.phase != LSSearchPhaseSuggesting || self.slow) return;
        self.slow = YES;
        [self setLoading:YES];
        if (!self.completions.count) [self rebuild];
    });
}

- (void)completerDidUpdateResults:(MKLocalSearchCompleter *)completer {
    if (self.closed || completer != self.completer) return;
    self.completions = completer.results ?: @[];
    self.suggestionsFailed = NO;
    [self finishSuggestions];
}
- (void)completer:(MKLocalSearchCompleter *)completer didFailWithError:(NSError *)error {
    if (self.closed || completer != self.completer) return;
    self.completions = @[];
    self.suggestionsFailed = !LSIsNoResults(error);
    [self finishSuggestions];
}
- (void)finishSuggestions {
    self.phase = LSSearchPhaseSuggestions;
    self.slow = NO;
    [self setLoading:NO];
    [self rebuild];
    NSUInteger count = MIN(self.completions.count, kLSMaximumSuggestions);
    [self announceLater:count ? [NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? @"suggestion" : @"suggestions"] :
        (self.suggestionsFailed ? @"Suggestions aren’t available" : @"No suggestions")];
}

// Spoken once typing settles, with the latest text; any further edit cancels it.
- (void)announceLater:(NSString *)message {
    if (!UIAccessibilityIsVoiceOverRunning() || !message.length) return;
    self.pendingAnnouncement = message;
    NSUInteger revision = self.revision;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLSAnnounceDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision || self.announcedRevision == revision) return;
        self.announcedRevision = revision;
        LSAnnounce(self.pendingAnnouncement);
    });
}

// The field's magnifying glass turns into a spinner while an answer is pending.
- (void)setLoading:(BOOL)loading {
    UITextField *field = self.searchBar.searchTextField;
    if (loading) [self.fieldSpinner startAnimating]; else [self.fieldSpinner stopAnimating];
    if (!self.searchGlyph) return;
    UIView *left = loading ? self.fieldSpinner : self.searchGlyph;
    if (field.leftView != left) field.leftView = left;
}

- (void)invalidateRequests {
    self.revision++;
    self.completer.delegate = nil;
    [self.completer cancel];
    self.completer = nil;
    [self.search cancel];
    self.search = nil;
    [self setLoading:NO];
}

#pragma mark Map links

- (void)openLink:(NSURL *)url {
    self.phase = LSSearchPhaseSmart;
    NSUInteger revision = self.revision;
    if (![LSMapLinks needsResolving:url]) { [self useLink:[LSMapLinks parseURL:url] html:nil reached:YES revision:revision]; return; }
    self.smartRow = [self linkRow:@"Opening map link…" detail:url.host ?: @"Map link" busy:YES];
    [self rebuild];
    __weak typeof(self) weakSelf = self;
    // Typing a short link by hand would otherwise open every prefix of it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision) return;
        [self resolveLink:url revision:revision];
    });
}

- (void)resolveLink:(NSURL *)url revision:(NSUInteger)revision {
    __weak typeof(self) weakSelf = self;
    [LSMapLinks resolveURL:url completion:^(NSURL *resolved, NSString *html) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision) return;
        [self useLink:resolved ? [LSMapLinks parseURL:resolved] : nil html:html reached:resolved != nil revision:revision];
    }];
}

- (void)useLink:(LSMapLink *)link html:(NSString *)html reached:(BOOL)reached revision:(NSUInteger)revision {
    // A pin link names one place; directions end at the place that matters here.
    LSMapLinkPlace *place = link.places.lastObject;
    // Apple place links with only a place id name their coordinate in the page.
    if (!place && html) place = [LSMapLinks placeFromHTML:html];
    if (!place) {
        [self showLinkFailure:reached ? @"That link doesn’t name a place LSpoof can read." : @"The link couldn’t be opened. Check your connection, then tap to try again."];
        return;
    }
    NSString *source = link.isDirections ? @"End of the shared directions" : @"From the map link";
    if (place.hasCoordinate) {
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(place.latitude, place.longitude);
        NSString *name = place.name.length ? place.name : @"Map link place";
        [self showLinkPlace:coordinate name:name label:place.name.length ? place.name : LSCoordinateText(coordinate) source:source];
        return;
    }
    NSString *text = place.query;
    if (!text.length) { [self showLinkFailure:@"That link doesn’t name a place LSpoof can read."]; return; }
    // Text-only places are looked up near where the link's map was looking.
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = text;
    if (place.hasHint) request.region = MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2DMake(place.hintLatitude, place.hintLongitude), 30000, 30000);
    else if (LSRegionUsable(self.searchRegion)) request.region = self.searchRegion;
    self.smartRow = [self linkRow:[NSString stringWithFormat:@"Finding “%@”…", text] detail:source busy:YES];
    [self rebuild];
    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    self.search = search;
    __weak typeof(self) weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        (void)error;
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision) return;
        self.search = nil;
        MKMapItem *found = nil;
        for (MKMapItem *item in response.mapItems) if (CLLocationCoordinate2DIsValid(item.placemark.coordinate)) { found = item; break; }
        if (!found) { [self showLinkFailure:[NSString stringWithFormat:@"Couldn’t find “%@” from the link. Tap to try again.", text]]; return; }
        NSString *name = found.name.length ? found.name : text;
        [self showLinkPlace:found.placemark.coordinate name:name label:name source:source];
    }];
}

- (void)showLinkPlace:(CLLocationCoordinate2D)coordinate name:(NSString *)name label:(NSString *)label source:(NSString *)source {
    self.smartRow = [self useRow:coordinate name:name title:[NSString stringWithFormat:@"Use %@", label] source:source symbol:@"link"];
    [self rebuild];
    LSHapticSelection();
    LSAnnounce([NSString stringWithFormat:@"%@. %@. Press Search or double-tap to use it.", self.smartRow.title, source]);
}

- (void)showLinkFailure:(NSString *)message {
    self.smartRow = [self linkRow:@"Couldn’t read this link" detail:message busy:NO];
    [self rebuild];
    LSHapticWarning();
    LSAnnounce(message);
}

#pragma mark Searching

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    (void)bar;
    LSSearchRow *smart = self.smartRow;
    if (smart) {
        if (smart.kind == LSRowPlace) [self choose:smart.coordinate name:smart.name];
        else if (smart.busy) LSAnnounce(@"Still opening the link.");
        else [self updateForText:self.searchBar.text];
        return;
    }
    if (self.phase == LSSearchPhaseResults && self.places.count) {
        // Search on a list of places takes the first one, so the keyboard alone can finish.
        MKMapItem *first = self.places.firstObject;
        [self choose:first.placemark.coordinate name:LSItemName(first)];
        return;
    }
    if (self.category >= 0) return;
    [self runFullSearch];
}

- (void)runFullSearch {
    NSString *query = self.query;
    if (!query.length || query.length > 256) return;
    [self.view endEditing:YES];
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = query;
    if (LSRegionUsable(self.searchRegion)) request.region = self.searchRegion;
    self.placesTitle = @"Results";
    self.widenings = 0;
    [self startSearch:request options:LSSearchChooseSingle];
}

- (void)resolveCompletion:(MKLocalSearchCompletion *)completion {
    [self.view endEditing:YES];
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] initWithCompletion:completion];
    if (LSRegionUsable(self.searchRegion)) request.region = self.searchRegion;
    self.placesTitle = completion.title;
    [self startSearch:request options:LSSearchChooseSingle | LSSearchKeepList];
    // Set after startSearch so its rebuild is followed by one that shows the row's spinner.
    self.resolving = completion;
    self.phase = LSSearchPhaseSuggestions;
    [self rebuild];
}

- (void)retrySearch {
    if (self.lastRequest) [self startSearch:self.lastRequest options:self.lastOptions & ~LSSearchKeepList];
}

- (BOOL)canWidenSearch {
    return self.lastRequest && self.widenings < 2 && LSRegionUsable(self.searchRegion) && !(self.lastOptions & LSSearchKeepList) &&
        self.searchRegion.span.latitudeDelta * pow(4, self.widenings) < 180;
}

// Same search around the same map center, over four times the span each time.
- (void)widenSearch {
    if (![self canWidenSearch]) return;
    self.widenings++;
    double scale = pow(4, self.widenings);
    MKCoordinateRegion region = self.searchRegion;
    region.span.latitudeDelta = MIN(180.0, region.span.latitudeDelta * scale);
    region.span.longitudeDelta = MIN(360.0, region.span.longitudeDelta * scale);
    MKLocalSearchRequest *request = [self.lastRequest copy];
    request.region = region;
    LSHapticSelection();
    [self startSearch:request options:self.lastOptions];
}

- (void)startSearch:(MKLocalSearchRequest *)request options:(LSSearchOptions)options {
    [self invalidateRequests];
    self.lastRequest = request;
    self.lastOptions = options;
    self.failure = nil;
    self.resolving = nil;
    if (!(options & LSSearchKeepList)) {
        self.places = @[];
        self.phase = LSSearchPhaseSearching;
        [self rebuild];
    }
    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    self.search = search;
    NSUInteger revision = self.revision;
    __weak typeof(self) weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision) return;
        [self finishSearch:response error:error options:options];
    }];
}

- (void)finishSearch:(MKLocalSearchResponse *)response error:(NSError *)error options:(LSSearchOptions)options {
    self.search = nil;
    self.resolving = nil;
    self.slow = NO;
    [self setLoading:NO];
    NSMutableArray<MKMapItem *> *valid = [NSMutableArray array];
    for (MKMapItem *item in response.mapItems) if (CLLocationCoordinate2DIsValid(item.placemark.coordinate)) [valid addObject:item];
    BOOL failed = !valid.count && !LSIsNoResults(error);
    if (options & LSSearchKeepList && (failed || !valid.count)) {
        // A suggestion that can't be looked up leaves the list in place and says why.
        [self rebuild];
        LSShowToast(self.view, failed ? LSFailureMessage(error) : @"That suggestion has no location. Try another.", @"exclamationmark.triangle.fill");
        return;
    }
    if (failed) {
        self.failure = LSFailureMessage(error);
        self.phase = LSSearchPhaseFailed;
        [self rebuild];
        LSAnnounce([@"Search isn’t available. " stringByAppendingString:self.failure]);
        return;
    }
    if (options & LSSearchChooseSingle && valid.count == 1) {
        [self choose:valid.firstObject.placemark.coordinate name:LSItemName(valid.firstObject)];
        return;
    }
    if (options & LSSearchSortByDistance && LSRegionUsable(self.searchRegion)) {
        CLLocation *center = [[CLLocation alloc] initWithLatitude:self.searchRegion.center.latitude longitude:self.searchRegion.center.longitude];
        NSMutableArray<NSArray *> *measured = [NSMutableArray arrayWithCapacity:valid.count];
        for (MKMapItem *item in valid) {
            CLLocation *place = [[CLLocation alloc] initWithLatitude:item.placemark.coordinate.latitude longitude:item.placemark.coordinate.longitude];
            [measured addObject:@[@([center distanceFromLocation:place]), item]];
        }
        [measured sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
        [valid removeAllObjects];
        for (NSArray *pair in measured) [valid addObject:pair[1]];
    }
    self.places = valid;
    self.phase = LSSearchPhaseResults;
    [self rebuild];
    if (!valid.count) { LSAnnounce([self noResultsTitle]); return; }
    NSString *where = self.category >= 0 ? [@" " stringByAppendingString:[self nearText]] : @"";
    [self focusFirstResultSaying:[NSString stringWithFormat:@"%lu %@%@", (unsigned long)valid.count, valid.count == 1 ? @"result" : @"results", where]];
}

- (NSString *)searchingText {
    return self.category >= 0 ? [NSString stringWithFormat:@"Finding %@ %@…", [self categoryTitle].lowercaseString, [self nearText]]
                              : [NSString stringWithFormat:@"Searching for “%@”…", self.query];
}
- (NSString *)noResultsTitle {
    return self.category >= 0 ? [NSString stringWithFormat:@"No %@ found %@", [self categoryTitle].lowercaseString, [self nearText]]
                              : [NSString stringWithFormat:@"No results for “%@”", self.query];
}
- (NSString *)noResultsMessage {
    BOOL widest = ![self canWidenSearch];
    if (self.category >= 0) {
        if (!widest) return @"Search a wider area, try another category, or search by name.";
        return self.widenings ? @"Nothing turned up in the wider area either. Try another category, or search by name." : @"Try another category, or search by name.";
    }
    if (!widest) return @"Check the spelling, try a full address, or search a wider area. You can also enter coordinates.";
    return self.widenings ? @"Nothing turned up in the wider area either. Check the spelling or try a full address. You can also enter coordinates."
                          : @"Check the spelling, or try a nearby town or a full address. You can also enter coordinates.";
}

#pragma mark Background

- (BOOL)hasWorkInFlight {
    return self.search || self.resolving || self.smartRow.busy ||
        self.phase == LSSearchPhaseSuggesting || self.phase == LSSearchPhaseSearching;
}
- (void)pauseWork {
    if (self.closed || self.phase == LSSearchPhasePaused || ![self hasWorkInFlight]) return;
    self.pausedPhase = self.phase;
    [self invalidateRequests];
    self.slow = NO;
    self.resolving = nil;
    if (self.smartRow.busy) self.smartRow = nil;
    self.phase = LSSearchPhasePaused;
    [self rebuild];
}
- (void)resumeWork {
    if (self.phase != LSSearchPhasePaused || self.closed) return;
    if (self.pausedPhase == LSSearchPhaseSearching && self.lastRequest) [self startSearch:self.lastRequest options:self.lastOptions & ~LSSearchKeepList];
    else [self updateForText:self.searchBar.text];
}
- (BOOL)isOwnScene:(NSNotification *)note {
    return ![note.object isKindOfClass:UIScene.class] || note.object == self.view.window.windowScene;
}
- (void)backgrounded:(NSNotification *)note {
    if ([self isOwnScene:note]) [self pauseWork];
}
// Control Center or a notification glance pauses work; it picks up again on return.
- (void)foregrounded:(NSNotification *)note {
    if (!self.view.window || ![self isOwnScene:note]) return;
    [self resumeWork];
}

#pragma mark Rows

- (NSString *)distanceTo:(CLLocationCoordinate2D)coordinate spoken:(BOOL)spoken {
    if (!LSRegionUsable(self.searchRegion) || !CLLocationCoordinate2DIsValid(coordinate)) return nil;
    CLLocation *center = [[CLLocation alloc] initWithLatitude:self.searchRegion.center.latitude longitude:self.searchRegion.center.longitude];
    CLLocation *place = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
    CLLocationDistance meters = [center distanceFromLocation:place];
    NSString *text = LSDistanceText(meters, spoken);
    if (!spoken) return text;
    double bearing = [self bearingTo:coordinate];
    return isnan(bearing) ? [text stringByAppendingString:@" from the map center"]
                          : [NSString stringWithFormat:@"%@ %@ of the map center", text, LSCompassName(bearing)];
}

// Which way the place lies from the map center; NAN when it is practically at the center.
- (double)bearingTo:(CLLocationCoordinate2D)coordinate {
    if (!LSRegionUsable(self.searchRegion) || !CLLocationCoordinate2DIsValid(coordinate)) return NAN;
    CLLocationCoordinate2D center = self.searchRegion.center;
    CLLocation *from = [[CLLocation alloc] initWithLatitude:center.latitude longitude:center.longitude];
    CLLocation *to = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
    if ([from distanceFromLocation:to] < 25) return NAN;
    return LSBearing(center, coordinate);
}

- (LSSearchRow *)useRow:(CLLocationCoordinate2D)coordinate name:(NSString *)name title:(NSString *)title source:(NSString *)source symbol:(NSString *)symbol {
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowPlace title:title];
    row.name = name;
    row.coordinate = coordinate;
    row.symbol = symbol;
    row.tone = LSTonePlace;
    NSString *distance = [self distanceTo:coordinate spoken:NO];
    row.detail = distance ? [NSString stringWithFormat:@"%@ · %@", distance, source] : source;
    row.bearing = distance ? [self bearingTo:coordinate] : NAN;
    row.spokenLabel = [NSString stringWithFormat:@"%@, %@", title, source];
    row.spokenValue = [self distanceTo:coordinate spoken:YES];
    row.hint = @"Uses this location. Pressing Search does the same.";
    return row;
}

- (LSSearchRow *)linkRow:(NSString *)title detail:(NSString *)detail busy:(BOOL)busy {
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowLink title:title];
    row.detail = detail;
    row.busy = busy;
    row.symbol = busy ? @"link" : @"exclamationmark.triangle.fill";
    row.tone = busy ? LSTonePlace : LSToneWarning;
    row.hint = busy ? nil : @"Tries the link again.";
    return row;
}

- (LSSearchRow *)rowForItem:(MKMapItem *)item {
    NSString *name = LSItemName(item);
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowPlace title:name];
    row.name = name;
    row.coordinate = item.placemark.coordinate;
    NSArray *info = LSCategoryInfo(item.pointOfInterestCategory);
    row.symbol = info ? info[0] : @"mappin";
    row.tone = info ? (LSTone)[info[2] integerValue] : LSTonePlace;
    row.address = LSShortAddress(item.placemark, name);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *distance = [self distanceTo:row.coordinate spoken:NO];
    if (distance) [parts addObject:distance];
    if (info) [parts addObject:info[1]];
    if (row.address) [parts addObject:row.address];
    row.detail = parts.count ? [parts componentsJoinedByString:@" · "] : LSCoordinateText(row.coordinate);
    row.bearing = distance ? [self bearingTo:row.coordinate] : NAN;
    NSMutableArray<NSString *> *spoken = [NSMutableArray arrayWithObject:name];
    if (info) [spoken addObject:info[1]];
    if (row.address) [spoken addObject:row.address];
    row.spokenLabel = [spoken componentsJoinedByString:@", "];
    row.spokenValue = [self distanceTo:row.coordinate spoken:YES];
    row.hint = @"Uses this place.";
    return row;
}

- (LSSearchRow *)rowForShortcut:(NSDictionary *)shortcut match:(NSRange)match {
    BOOL saved = [shortcut[@"saved"] boolValue];
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([shortcut[@"lat"] doubleValue], [shortcut[@"lon"] doubleValue]);
    NSString *name = shortcut[@"name"];
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowPlace title:name];
    row.name = name;
    row.coordinate = coordinate;
    if (match.location != NSNotFound) row.titleHighlights = @[[NSValue valueWithRange:match]];
    row.symbol = saved ? @"bookmark.fill" : @"clock.arrow.circlepath";
    row.tone = saved ? LSTonePlace : LSToneNeutral;
    NSString *coordinates = LSCoordinateText(coordinate);
    NSString *distance = [self distanceTo:coordinate spoken:NO];
    row.detail = distance ? [NSString stringWithFormat:@"%@ · %@", distance, coordinates] : coordinates;
    row.bearing = distance ? [self bearingTo:coordinate] : NAN;
    row.detailMonospaced = NSMakeRange(row.detail.length - coordinates.length, coordinates.length);
    row.spokenLabel = name;
    NSString *kind = saved ? @"Saved place" : @"Recent";
    NSString *spokenDistance = [self distanceTo:coordinate spoken:YES];
    row.spokenValue = spokenDistance ? [NSString stringWithFormat:@"%@, %@", kind, spokenDistance] : kind;
    row.hint = @"Uses this place.";
    return row;
}

- (LSSearchRow *)rowForCompletion:(MKLocalSearchCompletion *)completion {
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowCompletion title:completion.title];
    row.completion = completion;
    row.titleHighlights = completion.titleHighlightRanges ?: @[];
    row.detail = completion.subtitle;
    row.detailHighlights = completion.subtitleHighlightRanges ?: @[];
    // Without a subtitle it reads as a search. Either way the lookup decides: one place is used
    // at once and several are listed, which works the same in every language.
    BOOL query = !completion.subtitle.length;
    row.symbol = query ? @"magnifyingglass" : @"mappin";
    row.tone = query ? LSToneNeutral : LSTonePlace;
    row.busy = completion == self.resolving;
    row.hint = query ? @"Lists matching places." : @"Looks up this suggestion.";
    return row;
}

- (LSSearchRow *)queryRow {
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowQuery title:[NSString stringWithFormat:@"Search for “%@”", self.query]];
    row.symbol = @"magnifyingglass";
    row.tone = LSToneNeutral;
    row.hint = @"Looks further for places matching this text.";
    return row;
}

- (LSSearchRow *)coordinatesRow {
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowCoordinates title:@"Enter coordinates"];
    row.detail = @"Type a latitude and longitude";
    row.symbol = @"number";
    row.tone = LSToneNeutral;
    row.hint = @"Opens latitude and longitude fields.";
    return row;
}

- (LSSearchSection *)statusSection:(NSString *)text symbol:(NSString *)symbol busy:(BOOL)busy {
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowStatus title:text];
    row.symbol = symbol ?: @"";
    row.busy = busy;
    return [LSSearchSection sectionWithTitle:nil rows:@[row] footer:nil];
}

- (LSSearchSection *)emptySection:(NSString *)symbol title:(NSString *)title message:(NSString *)message action:(NSString *)action
                     actionSymbol:(NSString *)actionSymbol selector:(SEL)selector {
    LSSearchRow *row = [LSSearchRow rowWithKind:LSRowEmpty title:title];
    row.symbol = symbol;
    row.detail = message;
    row.actionTitle = action;
    row.actionSymbol = actionSymbol;
    row.action = selector;
    return [LSSearchSection sectionWithTitle:nil rows:@[row] footer:nil];
}

- (void)addShortcutSections:(NSMutableArray<LSSearchSection *> *)sections {
    NSMutableArray<LSSearchRow *> *saved = [NSMutableArray array];
    NSMutableArray<LSSearchRow *> *recent = [NSMutableArray array];
    for (NSDictionary *shortcut in self.saved) [saved addObject:[self rowForShortcut:shortcut match:NSMakeRange(NSNotFound, 0)]];
    for (NSDictionary *shortcut in self.recents) [recent addObject:[self rowForShortcut:shortcut match:NSMakeRange(NSNotFound, 0)]];
    NSString *note = LSRegionUsable(self.searchRegion) ? @"Distances are measured from the center of the map." : nil;
    if (saved.count) [sections addObject:[LSSearchSection sectionWithTitle:@"Saved places" rows:saved footer:recent.count ? nil : note]];
    if (recent.count) [sections addObject:[LSSearchSection sectionWithTitle:@"Recent" rows:recent footer:note]];
    if (!saved.count && !recent.count) {
        [sections addObject:[self emptySection:@"map" title:@"Find any place"
                                       message:@"Search for an address, a business or a landmark. You can also paste coordinates such as 48.8584, 2.2945 or a link from Apple Maps, Google Maps or Waze."
                                        action:nil actionSymbol:nil selector:NULL]];
    }
}

// Saved and recent places whose names contain the typed text, above the suggestions.
- (void)addLocalMatches:(NSMutableArray<LSSearchSection *> *)sections {
    if (!self.query.length) return;
    NSMutableArray<LSSearchRow *> *rows = [NSMutableArray array];
    for (NSDictionary *shortcut in [self.saved arrayByAddingObjectsFromArray:self.recents]) {
        NSRange match = [shortcut[@"name"] rangeOfString:self.query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        if (match.location == NSNotFound) continue;
        [rows addObject:[self rowForShortcut:shortcut match:match]];
        if (rows.count == 3) break;
    }
    if (rows.count) [sections addObject:[LSSearchSection sectionWithTitle:@"Saved and recent" rows:rows footer:nil]];
}

- (LSSearchSection *)suggestionSection {
    NSMutableArray<LSSearchRow *> *rows = [NSMutableArray array];
    for (MKLocalSearchCompletion *completion in self.completions) {
        [rows addObject:[self rowForCompletion:completion]];
        if (rows.count == kLSMaximumSuggestions) break;
    }
    return [LSSearchSection sectionWithTitle:@"Suggestions" rows:rows footer:nil];
}

- (LSSearchSection *)placesSection {
    NSMutableArray<LSSearchRow *> *rows = [NSMutableArray array];
    for (MKMapItem *item in self.places) [rows addObject:[self rowForItem:item]];
    BOOL category = self.category >= 0;
    NSString *title = category ? [NSString stringWithFormat:@"%@ %@", [self categoryTitle], [self nearText]] : (self.placesTitle ?: @"Results");
    NSString *footer = !LSRegionUsable(self.searchRegion) ? nil :
        (category ? @"Nearest first, measured from the center of the map." : @"Distances are measured from the center of the map.");
    return [LSSearchSection sectionWithTitle:title rows:rows footer:footer];
}

- (void)rebuild {
    NSMutableArray<LSSearchSection *> *sections = [NSMutableArray array];
    LSSearchPhase phase = self.phase;
    BOOL idle = phase == LSSearchPhaseIdle;
    [self setChipsVisible:idle || self.category >= 0];
    BOOL offerCoordinates = idle;
    if (self.smartRow) [sections addObject:[LSSearchSection sectionWithTitle:nil rows:@[self.smartRow] footer:nil]];
    if (idle) [self addShortcutSections:sections];
    else if (self.category < 0 && phase != LSSearchPhaseSmart && phase != LSSearchPhaseTooLong) [self addLocalMatches:sections];
    BOOL listed = sections.count > 0;
    NSUInteger placesIndex = NSNotFound;
    switch (phase) {
        case LSSearchPhaseIdle:
        case LSSearchPhaseSmart:
            break;
        case LSSearchPhaseShort:
            if (!listed) [sections addObject:[self statusSection:@"Keep typing to see suggestions." symbol:@"character.cursor.ibeam" busy:NO]];
            break;
        case LSSearchPhaseTooLong:
            [sections addObject:[self statusSection:@"That’s too long to search. Paste just the address, the coordinates or the map link." symbol:@"exclamationmark.circle" busy:NO]];
            offerCoordinates = YES;
            break;
        case LSSearchPhaseSuggesting:
            if (self.completions.count) [sections addObject:[self suggestionSection]];
            else if (self.slow) [sections addObject:[self statusSection:@"Finding places…" symbol:nil busy:YES]];
            break;
        case LSSearchPhaseSuggestions:
            if (self.completions.count) {
                [sections addObject:[self suggestionSection]];
            } else {
                NSString *footer = self.suggestionsFailed ? @"Suggestions aren’t available right now. A full search may still work."
                                                          : @"No suggestions match yet. A full search looks further.";
                [sections addObject:[LSSearchSection sectionWithTitle:nil rows:@[[self queryRow]] footer:footer]];
                offerCoordinates = YES;
            }
            break;
        case LSSearchPhaseSearching:
            [sections addObject:[self statusSection:[self searchingText] symbol:nil busy:YES]];
            break;
        case LSSearchPhaseResults:
            if (self.places.count) {
                placesIndex = sections.count;
                [sections addObject:[self placesSection]];
            } else {
                BOOL widen = [self canWidenSearch];
                [sections addObject:[self emptySection:@"mappin.slash" title:[self noResultsTitle] message:[self noResultsMessage]
                                                action:widen ? @"Search a wider area" : nil actionSymbol:@"arrow.up.backward.and.arrow.down.forward"
                                              selector:widen ? @selector(widenSearch) : NULL]];
                offerCoordinates = YES;
            }
            break;
        case LSSearchPhaseFailed:
            [sections addObject:[self emptySection:@"wifi.exclamationmark" title:@"Search isn’t available" message:self.failure ?: @""
                                            action:@"Try again" actionSymbol:@"arrow.clockwise" selector:@selector(retrySearch)]];
            offerCoordinates = YES;
            break;
        case LSSearchPhasePaused:
            [sections addObject:[self statusSection:@"Search paused while you were away. It picks up again when you return." symbol:@"pause.circle" busy:NO]];
            break;
    }
    if (offerCoordinates) [sections addObject:[LSSearchSection sectionWithTitle:nil rows:@[[self coordinatesRow]] footer:nil]];
    self.placesSectionIndex = placesIndex;
    [self applySections:sections phase:phase];
}

// Section titles, footers and row kinds. Two lists with the same shape differ only in text.
static NSArray<NSString *> *LSSectionShape(NSArray<LSSearchSection *> *sections) {
    NSMutableArray<NSString *> *shape = [NSMutableArray arrayWithCapacity:sections.count];
    for (LSSearchSection *section in sections) {
        NSMutableString *kinds = [NSMutableString string];
        for (LSSearchRow *row in section.rows) [kinds appendFormat:@"%ld,", (long)row.kind];
        [shape addObject:[NSString stringWithFormat:@"%@|%@|%@", section.title ?: @"", section.footer ?: @"", kinds]];
    }
    return shape;
}

- (void)applySections:(NSArray<LSSearchSection *> *)sections phase:(LSSearchPhase)phase {
    BOOL onScreen = self.table.window != nil;
    BOOL sameShape = onScreen && [LSSectionShape(self.sections) isEqualToArray:LSSectionShape(sections)];
    BOOL reveal = onScreen && phase == LSSearchPhaseResults && self.renderedPhase != LSSearchPhaseResults && LSMapAnimationsEnabled();
    BOOL fade = onScreen && LSPhaseGroup(phase) != LSPhaseGroup(self.renderedPhase);
    NSArray<LSSearchSection *> *previous = self.sections;
    self.sections = sections;
    self.renderedPhase = phase;
    if (sameShape) {
        // Updating rows in place keeps VoiceOver focus and running spinners where they are.
        [self refreshVisibleRowsFrom:previous];
    } else if (reveal) {
        [self.table reloadData];
        [self revealResults];
    } else if (fade) {
        [UIView transitionWithView:self.table duration:0.2
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                        animations:^{ [self.table reloadData]; } completion:nil];
    } else {
        [self.table reloadData];
    }
}

// Everything about a row that can change its height.
static NSString *LSRowSizeKey(LSSearchRow *row) {
    return [NSString stringWithFormat:@"%ld|%@|%@|%@|%@|%d|%d|%@", (long)row.kind, row.title, row.detail ?: @"", row.titleHighlights,
            row.detailHighlights, row.busy, !isnan(row.bearing), row.actionTitle ?: @""];
}

- (void)refreshVisibleRowsFrom:(NSArray<LSSearchSection *> *)previous {
    BOOL resized = NO;
    for (NSIndexPath *path in self.table.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.table cellForRowAtIndexPath:path];
        LSSearchRow *row = [self rowAtIndexPath:path];
        if (!cell || !row) continue;
        // Same shape, so the earlier list has a row at every visible index path.
        LSSearchRow *old = previous[(NSUInteger)path.section].rows[(NSUInteger)path.row];
        if (![LSRowSizeKey(old) isEqualToString:LSRowSizeKey(row)]) resized = YES;
        [self configureCell:cell row:row];
    }
    // Rows whose text changed length settle to their new height without animating.
    if (resized) [UIView performWithoutAnimation:^{ [self.table performBatchUpdates:nil completion:nil]; }];
}

// The first time results arrive they rise 8 pt and fade in, one after another.
- (void)revealResults {
    if (self.placesSectionIndex == NSNotFound) return;
    [self.table layoutIfNeeded];
    NSUInteger order = 0;
    for (NSIndexPath *path in self.table.indexPathsForVisibleRows) {
        if ((NSUInteger)path.section != self.placesSectionIndex) continue;
        UITableViewCell *cell = [self.table cellForRowAtIndexPath:path];
        if (!cell) continue;
        cell.alpha = 0;
        cell.transform = CGAffineTransformMakeTranslation(0, 8);
        [UIView animateWithDuration:0.4 delay:0.03 * MIN(order, 10) usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            cell.alpha = 1;
            cell.transform = CGAffineTransformIdentity;
        } completion:nil];
        order++;
    }
}

// VoiceOver moves to the first result, then hears the count after reading it.
- (void)focusFirstResultSaying:(NSString *)message {
    UITableViewCell *first = nil;
    if (UIAccessibilityIsVoiceOverRunning() && self.placesSectionIndex != NSNotFound) {
        [self.table layoutIfNeeded];
        first = [self.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:(NSInteger)self.placesSectionIndex]];
    }
    if (!first) { LSAnnounce(message); return; }
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, first);
    NSAttributedString *queued = [[NSAttributedString alloc] initWithString:message attributes:@{UIAccessibilitySpeechAttributeQueueAnnouncement: @YES}];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, queued);
}

#pragma mark Table

- (LSSearchRow *)rowAtIndexPath:(NSIndexPath *)path {
    if ((NSUInteger)path.section >= self.sections.count) return nil;
    NSArray<LSSearchRow *> *rows = self.sections[(NSUInteger)path.section].rows;
    return (NSUInteger)path.row < rows.count ? rows[(NSUInteger)path.row] : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return (NSInteger)self.sections.count; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table;
    return (NSInteger)self.sections[(NSUInteger)section].rows.count;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    (void)table;
    return self.sections[(NSUInteger)section].title;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    (void)table;
    return self.sections[(NSUInteger)section].footer;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    LSSearchRow *row = [self rowAtIndexPath:path];
    UITableViewCell *cell;
    if (row.kind == LSRowStatus || row.kind == LSRowEmpty) {
        cell = [table dequeueReusableCellWithIdentifier:@"Message"] ?: [[LSSearchMessageCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Message"];
    } else {
        cell = [table dequeueReusableCellWithIdentifier:@"Result"] ?: [[LSSearchResultCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Result"];
    }
    [self configureCell:cell row:row];
    return cell;
}

- (void)configureCell:(UITableViewCell *)cell row:(LSSearchRow *)row {
    if ([cell isKindOfClass:LSSearchResultCell.class]) {
        LSSearchResultCell *result = (LSSearchResultCell *)cell;
        [result configureWithRow:row traits:self.table.traitCollection];
        result.accessibilityCustomActions = [self accessibilityActionsForRow:row];
        return;
    }
    if (![cell isKindOfClass:LSSearchMessageCell.class]) return;
    LSSearchMessageCell *message = (LSSearchMessageCell *)cell;
    NSString *key = [NSString stringWithFormat:@"%ld|%@|%@|%@|%d|%@|%@", (long)row.kind, row.symbol, row.title, row.detail ?: @"", row.busy, row.actionTitle ?: @"", row.actionSymbol ?: @""];
    if (row.kind == LSRowStatus) {
        if (![message.hostedKey isEqualToString:key]) [message host:LSStatusView(row.title, row.symbol, row.busy)];
        message.isAccessibilityElement = YES;
        message.accessibilityLabel = row.title;
        message.accessibilityTraits = UIAccessibilityTraitStaticText;
    } else {
        if (![message.hostedKey isEqualToString:key]) {
            UIButton *action = nil;
            if (row.actionTitle.length && row.action) {
                action = LSButton(row.actionTitle, row.actionSymbol, NO);
                [action addTarget:self action:row.action forControlEvents:UIControlEventTouchUpInside];
            }
            [message host:LSEmptyState(row.symbol, row.title, row.detail ?: @"", action)];
        }
        // Leave the title, message and button reachable one by one.
        message.isAccessibilityElement = NO;
        message.accessibilityLabel = nil;
    }
    message.hostedKey = key;
}

- (BOOL)rowIsSelectable:(LSSearchRow *)row {
    return row && row.kind != LSRowStatus && row.kind != LSRowEmpty && !row.busy;
}
- (BOOL)tableView:(UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    return [self rowIsSelectable:[self rowAtIndexPath:path]];
}
- (NSIndexPath *)tableView:(UITableView *)table willSelectRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    return [self rowIsSelectable:[self rowAtIndexPath:path]] ? path : nil;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    LSSearchRow *row = [self rowAtIndexPath:path];
    if (![self rowIsSelectable:row]) return;
    switch (row.kind) {
        case LSRowPlace: [self choose:row.coordinate name:row.name]; break;
        case LSRowCompletion: [self resolveCompletion:row.completion]; break;
        case LSRowQuery: [self runFullSearch]; break;
        case LSRowLink: [self updateForText:self.searchBar.text]; break;
        case LSRowCoordinates: [self enterCoordinates]; break;
        case LSRowStatus: case LSRowEmpty: break;
    }
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    (void)table; (void)point;
    LSSearchRow *row = [self rowAtIndexPath:path];
    if (row.kind != LSRowPlace || !CLLocationCoordinate2DIsValid(row.coordinate)) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        [items addObject:[UIAction actionWithTitle:@"Use this place" image:[UIImage systemImageNamed:@"mappin.and.ellipse"] identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf choose:row.coordinate name:row.name];
        }]];
        [items addObject:[UIAction actionWithTitle:@"Copy coordinates" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf copyText:LSCoordinateText(row.coordinate) message:@"Coordinates copied"];
        }]];
        if (row.address.length) {
            [items addObject:[UIAction actionWithTitle:@"Copy address" image:[UIImage systemImageNamed:@"text.quote"] identifier:nil handler:^(__unused UIAction *action) {
                [weakSelf copyText:row.address message:@"Address copied"];
            }]];
        }
        return [UIMenu menuWithTitle:row.name children:items];
    }];
}

- (NSArray<UIAccessibilityCustomAction *> *)accessibilityActionsForRow:(LSSearchRow *)row {
    if (row.kind != LSRowPlace || !CLLocationCoordinate2DIsValid(row.coordinate)) return @[];
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAccessibilityCustomAction *> *actions = [NSMutableArray array];
    [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Copy coordinates" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        [weakSelf copyText:LSCoordinateText(row.coordinate) message:@"Coordinates copied"];
        return YES;
    }]];
    if (row.address.length) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Copy address" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            [weakSelf copyText:row.address message:@"Address copied"];
            return YES;
        }]];
    }
    return actions;
}

- (void)copyText:(NSString *)text message:(NSString *)message {
    UIPasteboard.generalPasteboard.string = text;
    LSHapticSelection();
    LSShowToast(self.view, message, @"doc.on.doc.fill");
}

#pragma mark Leaving

- (void)enterCoordinates {
    [self.view endEditing:YES];
    LSCoordinateEntryController *entry = [[LSCoordinateEntryController alloc] init];
    // A pair typed into search carries over so it can be fine-tuned.
    BOOL typed = self.smartRow.kind == LSRowPlace && CLLocationCoordinate2DIsValid(self.smartRow.coordinate);
    entry.initialCoordinate = typed ? self.smartRow.coordinate : self.initialCoordinate;
    __weak typeof(self) weakSelf = self;
    entry.didChoose = ^(CLLocationCoordinate2D coordinate) { [weakSelf choose:coordinate name:@"Selected coordinates"]; };
    // Called instead of didChoose; keeps a name the entry screen found for the spot.
    entry.didChooseNamed = ^(CLLocationCoordinate2D coordinate, NSString *name) {
        [weakSelf choose:coordinate name:name.length ? name : @"Selected coordinates"];
    };
    [self.navigationController pushViewController:entry animated:LSMapAnimationsEnabled()];
}
- (void)choose:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (self.closed || !CLLocationCoordinate2DIsValid(coordinate)) return;
    self.closed = YES;
    [self invalidateRequests];
    LSHapticSelection();
    if (self.didChoose) self.didChoose(coordinate, name);
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (void)cancel {
    self.closed = YES;
    [self invalidateRequests];
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (NSArray<UIKeyCommand *> *)keyCommands { return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancel)]]; }
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }
@end
