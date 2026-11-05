#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"
#import "LSMapLinks.h"
#import "LSPlaceSearchController.h"
#import "LSTrackIO.h"

// Row identities, so list changes animate as inserts, deletes and moves instead of a reload.
// "s|" is a saved place, "t|" a saved route, "r|" a recent location, "p|" a placeholder row.
// Sections: saved places, saved routes (#20, only when there are some), recently applied.
static const NSInteger LSSavedRoutesSection = 1;
static const NSInteger LSSavedSectionCount = 3;
static NSString * const LSSavedEmptyKey = @"p|saved";
static NSString * const LSRecentsEmptyKey = @"p|recents";
static NSString * const LSSavedNoMatchKey = @"p|nomatch";
// Long lists get a filter field.
static const NSUInteger LSSavedFilterThreshold = 6;
// The first-use tip goes away once closed or once a place has been previewed from here.
static BOOL ls_savedTipDone = NO;

#pragma mark - Small helpers

static NSString *LSRecentKey(NSDictionary *entry) {
    return [NSString stringWithFormat:@"r|%.7f,%.7f", [entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]];
}
static CLLocationCoordinate2D LSRecentCoordinate(NSDictionary *entry) {
    return CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
}
static BOOL LSSameRecent(NSDictionary *a, NSDictionary *b) {
    return fabs([a[@"LSRecentLat"] doubleValue] - [b[@"LSRecentLat"] doubleValue]) < 0.000001 &&
           fabs([a[@"LSRecentLon"] doubleValue] - [b[@"LSRecentLon"] doubleValue]) < 0.000001;
}
static NSDate *LSRecentDate(NSDictionary *entry) {
    // One formatter for every row and lookup; these are main-thread only.
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [[NSISO8601DateFormatter alloc] init]; });
    id value = entry[@"LSRecentDate"];
    return [value isKindOfClass:NSString.class] ? [formatter dateFromString:value] : nil;
}
static NSString *LSSavedAgo(NSDate *date) {
    static NSRelativeDateTimeFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSRelativeDateTimeFormatter alloc] init];
        formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    });
    if (fabs(date.timeIntervalSinceNow) < 60) return @"just now";
    return [formatter localizedStringForDate:date relativeToDate:NSDate.date];
}
static NSString *LSSavedDistance(CLLocationDistance meters, BOOL spoken) {
    static MKDistanceFormatter *brief, *full;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        brief = [[MKDistanceFormatter alloc] init];
        brief.unitStyle = MKDistanceFormatterUnitStyleAbbreviated;
        full = [[MKDistanceFormatter alloc] init];
        full.unitStyle = MKDistanceFormatterUnitStyleFull;
    });
    return [spoken ? full : brief stringFromDistance:meters];
}
static NSString *LSSavedCapitalized(NSString *text) {
    return text.length ? [[text substringToIndex:1].uppercaseString stringByAppendingString:[text substringFromIndex:1]] : text;
}
static BOOL LSSavedKeysUnique(NSArray<NSArray<NSString *> *> *keys) {
    for (NSArray *section in keys) if ([NSSet setWithArray:section].count != section.count) return NO;
    return YES;
}
static BOOL LSSavedMatches(NSString *name, CLLocationCoordinate2D coordinate, NSString *filter) {
    return [name localizedStandardContainsString:filter] || [LSCoordinateText(coordinate) containsString:filter];
}
// A route matches by its name or the name of any place it runs through.
static BOOL LSSavedRouteMatches(LSRouteArchive *route, NSString *filter) {
    if ([route.name localizedStandardContainsString:filter]) return YES;
    for (LSArchivedPlace *place in route.places) if ([place.name localizedStandardContainsString:filter]) return YES;
    return NO;
}
// Where the filter matched, found the way LSSavedMatches compares (names ignore case and accents).
static NSRange LSSavedMatchRange(NSString *text, NSString *filter, BOOL localized) {
    if (!text.length || !filter.length) return NSMakeRange(NSNotFound, 0);
    if (!localized) return [text rangeOfString:filter];
    return [text rangeOfString:filter options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                         range:NSMakeRange(0, text.length) locale:NSLocale.currentLocale];
}
// The typed match in bold label colour against a quieter rest, as Search styles typed matches.
static NSAttributedString *LSSavedHighlighted(NSString *text, NSRange match, UIFont *font, UIFont *strongFont) {
    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:text ?: @""
                                                                               attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor}];
    if (match.location != NSNotFound && NSMaxRange(match) <= styled.length)
        [styled addAttributes:@{NSFontAttributeName: strongFont, NSForegroundColorAttributeName: UIColor.labelColor} range:match];
    return styled;
}
static void LSSavedTintImages(UIView *view, UIColor *color) {
    if ([view isKindOfClass:UIImageView.class]) {
        // Badge glyphs carry a hierarchical colour, which wins over tintColor.
        UIImageView *image = (UIImageView *)view;
        UIImageSymbolConfiguration *hierarchical = [UIImageSymbolConfiguration configurationWithHierarchicalColor:color];
        image.preferredSymbolConfiguration = image.preferredSymbolConfiguration ? [image.preferredSymbolConfiguration configurationByApplyingConfiguration:hierarchical] : hierarchical;
        image.tintColor = color;
    }
    for (UIView *child in view.subviews) LSSavedTintImages(child, color);
}
static double LSSavedDistanceBetween(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    CLLocation *from = [[CLLocation alloc] initWithLatitude:a.latitude longitude:a.longitude];
    CLLocation *to = [[CLLocation alloc] initWithLatitude:b.latitude longitude:b.longitude];
    return [from distanceFromLocation:to];
}
// A glyph and tint that match what the name suggests, so a long list scans at a glance.
static void LSSavedPlaceStyle(NSString *name, NSString **symbol, UIColor **color) {
    static NSArray<NSArray *> *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rules = @[
            @[@"house.fill", UIColor.systemBlueColor, @[@"home", @"house", @"apartment", @"flat", @"parents", @"mom", @"mum", @"dad"]],
            @[@"briefcase.fill", UIColor.systemBrownColor, @[@"work", @"office", @"job", @"hq", @"studio"]],
            @[@"graduationcap.fill", UIColor.systemIndigoColor, @[@"school", @"university", @"uni", @"college", @"campus", @"library"]],
            @[@"cup.and.saucer.fill", UIColor.systemOrangeColor, @[@"cafe", @"café", @"coffee", @"bakery"]],
            @[@"fork.knife", UIColor.systemOrangeColor, @[@"restaurant", @"food", @"lunch", @"dinner", @"breakfast", @"pizza", @"burger", @"sushi"]],
            @[@"wineglass.fill", UIColor.systemPurpleColor, @[@"bar", @"pub", @"club"]],
            @[@"dumbbell.fill", UIColor.systemPinkColor, @[@"gym", @"fitness", @"workout", @"yoga"]],
            @[@"leaf.fill", UIColor.systemGreenColor, @[@"park", @"garden", @"forest", @"trail", @"lake", @"beach", @"mountain", @"camp"]],
            @[@"airplane", UIColor.systemTealColor, @[@"airport", @"flight", @"terminal"]],
            @[@"bed.double.fill", UIColor.systemTealColor, @[@"hotel", @"hostel", @"motel", @"airbnb"]],
            @[@"tram.fill", UIColor.systemTealColor, @[@"station", @"train", @"metro", @"subway", @"tram", @"bus"]],
            @[@"cross.case.fill", UIColor.systemRedColor, @[@"hospital", @"clinic", @"doctor", @"dentist", @"pharmacy"]],
            @[@"bag.fill", UIColor.systemPurpleColor, @[@"shop", @"store", @"mall", @"market", @"supermarket", @"grocery"]],
            @[@"person.2.fill", UIColor.systemCyanColor, @[@"friend", @"friends"]]
        ];
    });
    NSArray<NSString *> *words = [name.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
    for (NSArray *rule in rules) {
        for (NSString *word in words) {
            if (!word.length) continue;
            NSString *singular = word.length > 3 && [word hasSuffix:@"s"] ? [word substringToIndex:word.length - 1] : word;
            if ([rule[2] containsObject:word] || [rule[2] containsObject:singular]) { *symbol = rule[0]; *color = rule[1]; return; }
        }
    }
    *symbol = @"bookmark.fill";
    *color = LSAccentColor();
}

#pragma mark - Map preview for the context menu

// One preview's pictures: the map, and the wander circle and pin drawn on their own so they
// can animate separately. `point` is the place in the map image's coordinates.
@interface LSSavedPreviewImages : NSObject
@property (nonatomic, strong) UIImage *map;
@property (nonatomic, strong, nullable) UIImage *ring;
@property (nonatomic, strong) UIImage *pin;
@property (nonatomic) CGPoint point;
@end
@implementation LSSavedPreviewImages
@end

static NSCache<NSString *, LSSavedPreviewImages *> *LSSavedSnapshotCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    // Costs are bytes: room for a dozen or so map previews.
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.totalCostLimit = 32 * 1024 * 1024; });
    return cache;
}
static NSUInteger LSSavedImageCost(UIImage *image) {
    return image ? (NSUInteger)(image.size.width * image.scale * image.size.height * image.scale * 4) : 0;
}
// The dashed wander circle, as the picker's map draws it. Safe off the main thread.
static UIImage *LSSavedRenderRing(CGFloat radius, UIColor *color, UIGraphicsImageRendererFormat *format) {
    CGFloat side = ceil(radius * 2 + 4);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(side / 2, side / 2) radius:radius startAngle:0 endAngle:2 * M_PI clockwise:YES];
        [[color colorWithAlphaComponent:0.14] setFill];
        [ring fill];
        CGFloat dash[] = {6, 4};
        [ring setLineDash:dash count:2 phase:0];
        ring.lineWidth = 1.5;
        [color setStroke];
        [ring stroke];
    }];
}
// The place's pin: a tinted disc with a white ring and the row's glyph. Safe off the main thread.
static UIImage *LSSavedRenderPin(UIImage *glyph, UIColor *color, UIGraphicsImageRendererFormat *format) {
    CGFloat diameter = 30, side = 44;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect disc = CGRectMake((side - diameter) / 2, (side - diameter) / 2, diameter, diameter);
        CGContextRef cg = context.CGContext;
        CGContextSaveGState(cg);
        CGContextSetShadowWithColor(cg, CGSizeMake(0, 2), 5, [UIColor colorWithWhite:0 alpha:0.3].CGColor);
        [UIColor.whiteColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:disc] fill];
        CGContextRestoreGState(cg);
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(disc, 2.5, 2.5)] fill];
        if (glyph) [glyph drawInRect:CGRectMake((side - glyph.size.width) / 2, (side - glyph.size.height) / 2, glyph.size.width, glyph.size.height)];
    }];
}

@interface LSSavedPreviewController : UIViewController
- (instancetype)initWithName:(NSString *)name detail:(NSString *)detail pill:(nullable NSString *)pill pillColor:(nullable UIColor *)pillColor
                  coordinate:(CLLocationCoordinate2D)coordinate radius:(double)radius
                      symbol:(NSString *)symbol tint:(UIColor *)tint traits:(UITraitCollection *)traits width:(CGFloat)width;
// A saved route: its whole path, fitted above the caption, with From and To marked.
- (instancetype)initWithName:(NSString *)name detail:(NSString *)detail route:(LSRouteArchive *)route
                      traits:(UITraitCollection *)traits width:(CGFloat)width;
@end
@implementation LSSavedPreviewController {
    NSData *_routePath;
    NSString *_routeKey;
    NSString *_symbol;
    CLLocationCoordinate2D _coordinate;
    double _radius;
    UIColor *_tint;
    UITraitCollection *_traits;
    UIStackView *_captionText;
    CGFloat _captionHeight;
    UIImageView *_imageView, *_ringView, *_pinView;
    LSSavedPreviewImages *_images;
    UIActivityIndicatorView *_spinner;
    UILabel *_fallback;
    MKMapSnapshotter *_snapshotter;
}
- (instancetype)initWithName:(NSString *)name detail:(NSString *)detail pill:(nullable NSString *)pill pillColor:(nullable UIColor *)pillColor
                  coordinate:(CLLocationCoordinate2D)coordinate radius:(double)radius
                      symbol:(NSString *)symbol tint:(UIColor *)tint traits:(UITraitCollection *)traits width:(CGFloat)width {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _symbol = [symbol copy];
    _coordinate = coordinate;
    _radius = radius;
    _tint = tint;
    _traits = traits;
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory);
    UILabel *title = LSLabel(name, UIFontTextStyleHeadline);
    title.font = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 28);
    title.numberOfLines = large ? 3 : 2;
    [title setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[title]];
    heading.spacing = LSSpaceS;
    // Same pills as the row: whether the place is the applied one, or already saved.
    if (pill.length) [heading addArrangedSubview:LSPillLabel(pill, pillColor ?: LSAccentTextColor())];
    heading.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    heading.alignment = large ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    if (large) [title.widthAnchor constraintEqualToAnchor:heading.widthAnchor].active = YES;
    UILabel *line = LSLabel(detail, UIFontTextStyleCaption1);
    line.font = LSMonospacedFont(UIFontTextStyleCaption1);
    line.textColor = UIColor.secondaryLabelColor;
    // At accessibility sizes the coordinates wrap instead of shrinking.
    line.numberOfLines = large ? 0 : 1;
    line.adjustsFontSizeToFitWidth = !large;
    line.minimumScaleFactor = 0.8;
    _captionText = LSStack(@[heading, line], 4);
    // Measured here: the menu sizes the preview before its view loads. The caption grows with
    // the text size and the map keeps a band above it, so the preview grows too.
    CGFloat textWidth = MAX(round(width) - 2 * LSSpaceL, 100);
    CGSize fit = [_captionText systemLayoutSizeFittingSize:CGSizeMake(textWidth, UILayoutFittingCompressedSize.height)
                             withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    _captionHeight = ceil(fit.height) + 20;
    CGFloat height = MAX(round(width * 0.66), round(width * 0.46 + _captionHeight));
    self.preferredContentSize = CGSizeMake(round(width), MIN(height, round(width * 1.3)));
    return self;
}
- (instancetype)initWithName:(NSString *)name detail:(NSString *)detail route:(LSRouteArchive *)route
                      traits:(UITraitCollection *)traits width:(CGFloat)width {
    LSArchivedPlace *first = route.places.firstObject;
    self = [self initWithName:name detail:detail pill:nil pillColor:nil coordinate:CLLocationCoordinate2DMake(first.latitude, first.longitude) radius:0
                       symbol:@"mappin" tint:LSRouteColor() traits:traits width:width];
    if (!self) return nil;
    NSMutableData *path = [NSMutableData data];
    if (route.pointCount >= 2) {
        // A few hundred points draw the same line as fifty thousand.
        NSUInteger count = route.pointCount, stride = MAX((NSUInteger)1, count / 400);
        const CLLocationCoordinate2D *points = route.coordinates.bytes;
        for (NSUInteger index = 0; index < count; index += stride) [path appendBytes:&points[index] length:sizeof(CLLocationCoordinate2D)];
        if ((count - 1) % stride) [path appendBytes:&points[count - 1] length:sizeof(CLLocationCoordinate2D)];
    } else {
        // Only its places: straight lines from one to the next.
        for (LSArchivedPlace *place in route.places) {
            CLLocationCoordinate2D point = CLLocationCoordinate2DMake(place.latitude, place.longitude);
            [path appendBytes:&point length:sizeof point];
        }
    }
    _routePath = path;
    _routeKey = [NSString stringWithFormat:@"%@|%lu", route.identifier, (unsigned long)route.pointCount];
    return self;
}
- (void)dealloc { [_snapshotter cancel]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _imageView = [[UIImageView alloc] init];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.clipsToBounds = YES;
    // The ring and pin are placed by frame over the map (placeOverlays).
    _ringView = [[UIImageView alloc] init];
    _pinView = [[UIImageView alloc] init];
    for (UIImageView *view in @[_imageView, _ringView, _pinView]) {
        view.alpha = 0;
        view.accessibilityIgnoresInvertColors = YES;
    }
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [_spinner startAnimating];
    _fallback = LSLabel(@"Map preview unavailable", UIFontTextStyleFootnote);
    _fallback.translatesAutoresizingMaskIntoConstraints = NO;
    _fallback.textColor = UIColor.secondaryLabelColor;
    _fallback.textAlignment = NSTextAlignmentCenter;
    _fallback.hidden = YES;
    UIVisualEffectView *caption = LSGlassView(0, NO);
    UIStackView *text = _captionText;
    [caption.contentView addSubview:text];
    for (UIView *view in @[_imageView, _ringView, _pinView, _spinner, _fallback, caption]) [self.view addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [_imageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_imageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_imageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_imageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:caption.topAnchor constant:-MAX(self.preferredContentSize.height - _captionHeight, 40) / 2],
        [_fallback.centerYAnchor constraintEqualToAnchor:_spinner.centerYAnchor],
        [_fallback.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:LSSpaceL],
        [_fallback.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-LSSpaceL],
        [caption.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [caption.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [caption.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [text.topAnchor constraintEqualToAnchor:caption.contentView.topAnchor constant:10],
        [text.bottomAnchor constraintEqualToAnchor:caption.contentView.bottomAnchor constant:-10],
        [text.leadingAnchor constraintEqualToAnchor:caption.contentView.leadingAnchor constant:LSSpaceL],
        [text.trailingAnchor constraintEqualToAnchor:caption.contentView.trailingAnchor constant:-LSSpaceL]
    ]];
    [self loadSnapshot];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self placeOverlays];
}
// The ring and pin sit on the place in the map image, wherever aspect fill puts that image.
- (void)placeOverlays {
    LSSavedPreviewImages *images = _images;
    CGSize bounds = self.view.bounds.size, size = images.map.size;
    if (!images || size.width <= 0 || size.height <= 0 || bounds.width <= 0 || bounds.height <= 0) return;
    CGFloat scale = MAX(bounds.width / size.width, bounds.height / size.height);
    CGPoint center = CGPointMake((bounds.width - size.width * scale) / 2 + images.point.x * scale,
                                 (bounds.height - size.height * scale) / 2 + images.point.y * scale);
    for (UIImageView *view in @[_ringView, _pinView]) {
        // Bounds and center rather than frame, so a running scale animation is left alone.
        CGSize side = view.image.size;
        view.bounds = CGRectMake(0, 0, side.width * scale, side.height * scale);
        view.center = center;
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // The menu was dismissed: nobody will see a late snapshot.
    [_snapshotter cancel];
    _snapshotter = nil;
}
- (void)loadRouteSnapshot {
    CGSize size = self.preferredContentSize;
    CGFloat scale = _traits.displayScale > 0 ? _traits.displayScale : 2;
    BOOL dark = _traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    NSString *key = [NSString stringWithFormat:@"route|%@|%d|%.0fx%.0f@%.0f", _routeKey, dark, size.width, size.height, scale];
    NSCache<NSString *, LSSavedPreviewImages *> *cache = LSSavedSnapshotCache();
    LSSavedPreviewImages *cached = [cache objectForKey:key];
    if (cached) { [self showImages:cached animated:NO]; return; }
    NSData *path = _routePath;
    NSUInteger count = path.length / sizeof(CLLocationCoordinate2D);
    if (count < 2) { [self showFallback]; return; }
    const CLLocationCoordinate2D *coordinates = path.bytes;
    MKMapRect bounds = [MKPolyline polylineWithCoordinates:coordinates count:count].boundingMapRect;
    CGFloat margin = 28;
    CGFloat width = MAX(size.width - 2 * margin, 40), height = MAX(size.height - _captionHeight - 2 * margin, 40);
    double minimum = 400 * MKMapPointsPerMeterAtLatitude(coordinates[0].latitude);
    double perPoint = MAX(MAX(bounds.size.width / width, bounds.size.height / height), minimum / width);
    MKMapPoint center = MKMapPointMake(MKMapRectGetMidX(bounds), MKMapRectGetMidY(bounds));
    MKMapSnapshotOptions *options = [[MKMapSnapshotOptions alloc] init];
    options.mapRect = MKMapRectMake(center.x - size.width / 2 * perPoint, center.y - (margin + height / 2) * perPoint, size.width * perPoint, size.height * perPoint);
    options.size = size;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithTraitsFromCollections:@[_traits, [UITraitCollection traitCollectionWithDisplayScale:scale]]];
    options.traitCollection = traits;
    UIColor *line = [LSRouteColor() resolvedColorWithTraitCollection:traits];
    UIColor *from = [LSFillColor(LSSuccessColor()) resolvedColorWithTraitCollection:traits];
    UIColor *to = [LSFillColor(LSErrorColor()) resolvedColorWithTraitCollection:traits];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    _snapshotter = [[MKMapSnapshotter alloc] initWithOptions:options];
    __weak typeof(self) weakSelf = self;
    [_snapshotter startWithCompletionHandler:^(MKMapSnapshot *snapshot, NSError *error) {
        LSSavedPreviewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_snapshotter = nil;
        if (!snapshot || error) { [strongSelf showFallback]; return; }
        UIImage *map = snapshot.image;
        UIBezierPath *trace = [UIBezierPath bezierPath];
        for (NSUInteger index = 0; index < count; index++) {
            CGPoint point = [snapshot pointForCoordinate:coordinates[index]];
            if (index == 0) [trace moveToPoint:point]; else [trace addLineToPoint:point];
        }
        CGPoint start = [snapshot pointForCoordinate:coordinates[0]], end = [snapshot pointForCoordinate:coordinates[count - 1]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:map.size format:format];
            UIImage *drawn = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                [map drawAtPoint:CGPointZero];
                trace.lineCapStyle = kCGLineCapRound;
                trace.lineJoinStyle = kCGLineJoinRound;
                trace.lineWidth = 7;
                [[UIColor colorWithWhite:1 alpha:0.85] setStroke];
                [trace stroke];
                trace.lineWidth = 4.5;
                [line setStroke];
                [trace stroke];
                for (NSUInteger end_ = 0; end_ < 2; end_++) {
                    CGPoint point = end_ ? end : start;
                    [UIColor.whiteColor setFill];
                    [[UIBezierPath bezierPathWithArcCenter:point radius:8 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
                    [end_ ? to : from setFill];
                    [[UIBezierPath bezierPathWithArcCenter:point radius:5.5 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
                }
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                LSSavedPreviewImages *images = [[LSSavedPreviewImages alloc] init];
                images.map = drawn;
                [cache setObject:images forKey:key cost:LSSavedImageCost(drawn)];
                [weakSelf showImages:images animated:YES];
            });
        });
    }];
}
- (void)loadSnapshot {
    if (_routePath) { [self loadRouteSnapshot]; return; }
    CGSize size = self.preferredContentSize;
    CGFloat scale = _traits.displayScale > 0 ? _traits.displayScale : 2;
    BOOL dark = _traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    // The pin sits in the middle of the map the caption leaves uncovered.
    CGFloat pinY = round(MAX(size.height - _captionHeight, size.height * 0.4) / 2);
    NSString *key = [NSString stringWithFormat:@"%.6f,%.6f|%.0f|%d|%.0fx%.0f@%.0f|%.0f|%@", _coordinate.latitude, _coordinate.longitude, _radius, dark, size.width, size.height, scale, pinY, _symbol];
    NSCache<NSString *, LSSavedPreviewImages *> *cache = LSSavedSnapshotCache();
    LSSavedPreviewImages *cached = [cache objectForKey:key];
    if (cached) { [self showImages:cached animated:NO]; return; }
    MKMapSnapshotOptions *options = [[MKMapSnapshotOptions alloc] init];
    double span = MAX(700, _radius * 6);
    double perPoint = span / MAX(size.width, 1) * MKMapPointsPerMeterAtLatitude(_coordinate.latitude);
    MKMapPoint pin = MKMapPointForCoordinate(_coordinate);
    options.mapRect = MKMapRectMake(pin.x - size.width / 2 * perPoint, pin.y - pinY * perPoint, size.width * perPoint, size.height * perPoint);
    options.size = size;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithTraitsFromCollections:@[_traits, [UITraitCollection traitCollectionWithDisplayScale:scale]]];
    options.traitCollection = traits;
    // Colours and the glyph are resolved here; the drawing itself runs off the main thread.
    UIColor *color = [LSFillColor(_tint) resolvedColorWithTraitCollection:traits];
    UIImage *glyph = [[UIImage systemImageNamed:_symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = NO;
    _snapshotter = [[MKMapSnapshotter alloc] initWithOptions:options];
    __weak typeof(self) weakSelf = self;
    CLLocationCoordinate2D coordinate = _coordinate;
    double radius = _radius;
    [_snapshotter startWithCompletionHandler:^(MKMapSnapshot *snapshot, NSError *error) {
        LSSavedPreviewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_snapshotter = nil;
        if (!snapshot || error) { [strongSelf showFallback]; return; }
        UIImage *map = snapshot.image;
        CGPoint point = [snapshot pointForCoordinate:coordinate];
        CGFloat ringRadius = 0;
        if (radius > 0) {
            MKMapPoint origin = MKMapPointForCoordinate(coordinate);
            MKMapPoint east = MKMapPointMake(origin.x + radius * MKMapPointsPerMeterAtLatitude(coordinate.latitude), origin.y);
            ringRadius = fabs([snapshot pointForCoordinate:MKCoordinateForMapPoint(east)].x - point.x);
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *pinImage = LSSavedRenderPin(glyph, color, format);
            UIImage *ringImage = ringRadius >= 3 ? LSSavedRenderRing(ringRadius, color, format) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                LSSavedPreviewImages *images = [[LSSavedPreviewImages alloc] init];
                images.map = map;
                images.ring = ringImage;
                images.pin = pinImage;
                images.point = point;
                [cache setObject:images forKey:key cost:LSSavedImageCost(map) + LSSavedImageCost(ringImage) + LSSavedImageCost(pinImage)];
                [weakSelf showImages:images animated:YES];
            });
        });
    }];
}
- (void)showImages:(LSSavedPreviewImages *)images animated:(BOOL)animated {
    [_spinner stopAnimating];
    _images = images;
    _imageView.image = images.map;
    _ringView.image = images.ring;
    _ringView.hidden = !images.ring;
    _pinView.image = images.pin;
    [self placeOverlays];
    UIImageView *map = _imageView, *ring = _ringView, *pin = _pinView;
    if (!LSMapAnimationsEnabled()) { map.alpha = 1; pin.alpha = 1; ring.alpha = 1; return; }
    // The map and pin come in together. The wander circle follows a moment later and settles
    // from slightly smaller, so it reads as the area the spot moves in rather than part of the map.
    NSTimeInterval fade = animated ? 0.25 : 0;
    if (animated) [UIView animateWithDuration:fade animations:^{ map.alpha = 1; pin.alpha = 1; }];
    else { map.alpha = 1; pin.alpha = 1; }
    if (!images.ring) return;
    ring.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.3 delay:fade + 0.15 options:UIViewAnimationOptionCurveEaseOut animations:^{ ring.alpha = 1; } completion:nil];
    [UIView animateWithDuration:0.55 delay:fade + 0.15 usingSpringWithDamping:0.72 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ ring.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)showFallback {
    [_spinner stopAnimating];
    _fallback.hidden = NO;
}
@end

#pragma mark - Row cell

@interface LSSavedRowCell : UITableViewCell
@property (nonatomic, strong) UIView *badgeHolder;
@property (nonatomic, strong) NSLayoutConstraint *badgeWidth;
@property (nonatomic, strong) NSLayoutConstraint *badgeHeight;
@property (nonatomic, copy) NSString *badgeKey;
@property (nonatomic, strong) UIStackView *titleRow;
@property (nonatomic, strong) NSLayoutConstraint *titleFullWidth;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *appliedPill;
@property (nonatomic, strong) UILabel *savedPill;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *coordinateLabel;
@property (nonatomic, strong) UIStackView *textStack;
@property (nonatomic, strong) UIButton *moreButton;
- (NSString *)layoutShape;
- (void)revealPill:(UILabel *)pill;
- (void)setTitle:(NSString *)title color:(UIColor *)color match:(NSRange)match;
- (void)setCoordinates:(NSString *)text match:(NSRange)match;
@end
@implementation LSSavedRowCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    _badgeHolder = [[UIView alloc] init];
    _badgeHolder.translatesAutoresizingMaskIntoConstraints = NO;
    _badgeHolder.isAccessibilityElement = NO;
    [_badgeHolder setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_badgeHolder setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    // Below required: a hidden arranged subview gets a required zero width from its stack.
    _badgeWidth = [_badgeHolder.widthAnchor constraintEqualToConstant:40];
    _badgeWidth.priority = 999;
    _badgeHeight = [_badgeHolder.heightAnchor constraintEqualToConstant:40];
    _badgeHeight.priority = 999;
    _titleLabel = LSLabel(@"", UIFontTextStyleBody);
    _titleLabel.font = LSFont(UIFontTextStyleBody, UIFontWeightSemibold, 30);
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    _appliedPill = LSPillLabel(@"Applied now", LSSuccessColor());
    _savedPill = LSPillLabel(@"Saved", LSAccentTextColor());
    for (UILabel *pill in @[_appliedPill, _savedPill]) {
        [pill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [pill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        pill.isAccessibilityElement = NO;
    }
    _titleRow = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _appliedPill, _savedPill]];
    _titleRow.spacing = LSSpaceS;
    // Centred, not on the baseline: the pill draws its text inset, so baseline alignment let it
    // hang below the row into the line under it.
    _titleRow.alignment = UIStackViewAlignmentCenter;
    // Stacked at accessibility sizes: the name keeps the full width so it wraps instead of clipping.
    _titleFullWidth = [_titleLabel.widthAnchor constraintEqualToAnchor:_titleRow.widthAnchor];
    _detailLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    _detailLabel.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightRegular, 26);
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _coordinateLabel = LSLabel(@"", UIFontTextStyleCaption2);
    _coordinateLabel.font = LSMonospacedFont(UIFontTextStyleCaption2);
    _coordinateLabel.textColor = UIColor.secondaryLabelColor;
    UIStackView *text = LSStack(@[_titleRow, _detailLabel, _coordinateLabel], 2);
    [text setCustomSpacing:3 afterView:_titleRow];
    UIStackView *row = LSRow(@[_badgeHolder, text], 14);
    [self.contentView addSubview:row];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    NSLayoutConstraint *bottom = [row.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-3];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        _badgeWidth, _badgeHeight,
        [row.topAnchor constraintEqualToAnchor:margins.topAnchor constant:3],
        [row.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        bottom
    ]];
    _textStack = text;
    UIButtonConfiguration *moreStyle = UIButtonConfiguration.plainButtonConfiguration;
    moreStyle.image = [UIImage systemImageNamed:@"ellipsis.circle"];
    moreStyle.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleLarge];
    moreStyle.baseForegroundColor = UIColor.secondaryLabelColor;
    _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _moreButton.configuration = moreStyle;
    _moreButton.showsMenuAsPrimaryAction = YES;
    // A minimum 44 pt accessory for touch and Switch Control; VoiceOver uses the row's actions.
    _moreButton.frame = CGRectMake(0, 0, 44, 44);
    self.isAccessibilityElement = YES;
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.badgeHolder.transform = CGAffineTransformIdentity;
    for (UILabel *pill in @[self.appliedPill, self.savedPill]) {
        [pill.layer removeAllAnimations];
        pill.alpha = 1;
        pill.transform = CGAffineTransformIdentity;
    }
}
// Everything that decides the row's height. Only a row whose shape changed is measured again.
- (NSString *)layoutShape {
    return [NSString stringWithFormat:@"%@|%@|%@|%d%d%d%d%d", self.titleLabel.text ?: @"", self.detailLabel.text ?: @"", self.coordinateLabel.text ?: @"",
            self.detailLabel.hidden, self.coordinateLabel.hidden, self.appliedPill.hidden, self.savedPill.hidden, self.badgeHolder.hidden];
}
// A pill a row gains (Applied now, Saved) fades in and gives a small bump.
- (void)revealPill:(UILabel *)pill {
    if (!pill.window || pill.hidden) return;
    pill.alpha = 0;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ pill.alpha = 1; } completion:nil];
    LSBump(pill);
}
// Attributed text resets the label's font and colour, so both are set again on every pass.
- (void)setTitle:(NSString *)title color:(UIColor *)color match:(NSRange)match {
    UIFont *strong = LSFont(UIFontTextStyleBody, UIFontWeightSemibold, 30);
    if (match.location == NSNotFound) {
        self.titleLabel.font = strong;
        self.titleLabel.textColor = color;
        self.titleLabel.text = title;
        return;
    }
    self.titleLabel.attributedText = LSSavedHighlighted(title, match, LSFont(UIFontTextStyleBody, UIFontWeightRegular, 30), strong);
}
- (void)setCoordinates:(NSString *)text match:(NSRange)match {
    UIFont *mono = LSMonospacedFont(UIFontTextStyleCaption2);
    if (match.location == NSNotFound) {
        self.coordinateLabel.font = mono;
        self.coordinateLabel.textColor = UIColor.secondaryLabelColor;
        self.coordinateLabel.text = text;
        return;
    }
    UIFont *strong = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold]];
    self.coordinateLabel.attributedText = LSSavedHighlighted(text, match, mono, strong);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // Separators start under the text, as in Settings.
    CGFloat leading = round([self.textStack convertPoint:CGPointZero toView:self].x);
    if (leading > 0 && fabs(self.separatorInset.left - leading) > 0.5) self.separatorInset = UIEdgeInsetsMake(0, leading, 0, 0);
}
- (void)applyLarge:(BOOL)large traits:(UITraitCollection *)traits {
    // At accessibility sizes the text gets the full width; the badge is decorative.
    self.badgeHolder.hidden = large;
    self.titleRow.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.titleRow.alignment = large ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    self.titleFullWidth.active = large;
    // The badge grows a little with the text, like the icons in Settings.
    CGFloat size = MIN(48, round([[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledValueForValue:40 compatibleWithTraitCollection:traits]));
    if (fabs(self.badgeWidth.constant - size) > 0.5) { self.badgeWidth.constant = size; self.badgeHeight.constant = size; self.badgeKey = nil; }
}
// Each symbol always comes with the same tint, so the symbol identifies the badge.
- (void)setBadgeSymbol:(NSString *)symbol color:(UIColor *)color muted:(BOOL)muted {
    NSString *key = [NSString stringWithFormat:@"%@|%d|%.0f", symbol, muted, self.badgeWidth.constant];
    if ([key isEqualToString:self.badgeKey]) return;
    self.badgeKey = key;
    for (UIView *child in self.badgeHolder.subviews) [child removeFromSuperview];
    NSString *name = [UIImage systemImageNamed:symbol] ? symbol : @"bookmark.fill";
    UIView *badge = LSIconBadge(name, color, self.badgeWidth.constant);
    if (muted) {
        // Placeholders get a quiet badge: a pale fill and a secondary glyph instead of white.
        badge.backgroundColor = UIColor.tertiarySystemFillColor;
        LSSavedTintImages(badge, UIColor.secondaryLabelColor);
    }
    [self.badgeHolder addSubview:badge];
    [NSLayoutConstraint activateConstraints:@[
        [badge.centerXAnchor constraintEqualToAnchor:self.badgeHolder.centerXAnchor],
        [badge.centerYAnchor constraintEqualToAnchor:self.badgeHolder.centerYAnchor]
    ]];
}
@end

#pragma mark - Section header

// Section title in the same style as the sections in Settings, an optional count after it in
// quieter text, and an optional text button (Reorder, Clear) at the trailing edge. One label and
// one button in a plain row: nothing aligns on the baseline of a label that may be empty.
@interface LSSavedSectionHeader : UITableViewHeaderFooterView
@property (nonatomic, strong) UILabel *heading;
@property (nonatomic, strong) UIStackView *row;
@property (nonatomic, copy) NSString *lsTitle;
@property (nonatomic, copy) NSString *lsCount;
- (instancetype)initWithTitle:(NSString *)title button:(UIButton *)button;
- (void)setCountText:(NSString *)count;
- (void)applyLarge:(BOOL)large;
@end
@implementation LSSavedSectionHeader
- (instancetype)initWithTitle:(NSString *)title button:(UIButton *)button {
    self = [super initWithReuseIdentifier:nil];
    if (!self) return nil;
    _lsTitle = [title copy];
    _lsCount = @"";
    _heading = LSSectionLabel(title);
    _heading.numberOfLines = 1;
    [_heading setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_heading setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _row = LSRow(@[_heading, button], LSSpaceS);
    [self.contentView addSubview:_row];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    NSLayoutConstraint *bottom = [_row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-2];
    bottom.priority = 999;
    // The same height with or without its button, so sections line up.
    NSLayoutConstraint *height = [_row.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    height.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [_row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:LSSpaceS],
        [_row.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_row.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        bottom, height
    ]];
    [self renderHeading];
    return self;
}
// A changed count cross-dissolves instead of jumping.
- (void)setCountText:(NSString *)count {
    NSString *text = count ?: @"";
    if ([text isEqualToString:_lsCount]) return;
    BOOL animate = self.heading.window && _lsCount.length && text.length;
    _lsCount = [text copy];
    if (!animate) { [self renderHeading]; return; }
    [UIView transitionWithView:self.heading duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ [self renderHeading]; } completion:nil];
}
- (void)renderHeading {
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:self.lsTitle attributes:@{
        NSFontAttributeName: LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 28), NSForegroundColorAttributeName: UIColor.secondaryLabelColor}];
    if (self.lsCount.length) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:self.lsCount] attributes:@{
            NSFontAttributeName: LSFont(UIFontTextStyleSubheadline, UIFontWeightRegular, 28), NSForegroundColorAttributeName: UIColor.tertiaryLabelColor}]];
    }
    self.heading.attributedText = text;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // Attributed text keeps the fonts it was built with; rebuild it at the new text size.
    if (![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) [self renderHeading];
}
- (void)applyLarge:(BOOL)large {
    self.heading.numberOfLines = large ? 0 : 1;
    UILayoutConstraintAxis axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    if (self.row.axis == axis) return;
    self.row.axis = axis;
    self.row.alignment = large ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
}
@end

#pragma mark - Saved tab

@implementation MapPickerViewController (LSBookmarksUI)
- (void)buildSavedUI {
    self.savedTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.savedTable.dataSource = self;
    self.savedTable.delegate = self;
    self.savedTable.rowHeight = UITableViewAutomaticDimension;
    self.savedTable.estimatedRowHeight = 76;
    self.savedTable.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.savedTable.estimatedSectionHeaderHeight = 48;
    self.savedTable.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.savedTable.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.savedHeldCoordinate = kCLLocationCoordinate2DInvalid;
    self.savedReferenceCoordinate = kCLLocationCoordinate2DInvalid;
    self.savedSessionMode = -1;

    self.editSavedButton = LSTextButton(@"Reorder", @"arrow.up.arrow.down");
    self.editSavedButton.accessibilityUserInputLabels = @[@"Reorder", @"Reorder places"];
    [self.editSavedButton addTarget:self action:@selector(toggleSavedEditing) forControlEvents:UIControlEventTouchUpInside];
    self.savedClearButton = LSTextButton(@"Clear", nil);
    self.savedClearButton.accessibilityLabel = @"Clear recent locations";
    self.savedClearButton.accessibilityUserInputLabels = @[@"Clear recents", @"Clear"];
    [self.savedClearButton addTarget:self action:@selector(clearRecents) forControlEvents:UIControlEventTouchUpInside];
    // Saved routes have no header button; a hidden one keeps the header the same height.
    UIButton *noButton = LSTextButton(@"", nil);
    noButton.hidden = YES;
    self.savedSectionHeaders = @[[[LSSavedSectionHeader alloc] initWithTitle:@"Saved places" button:self.editSavedButton],
                                 [[LSSavedSectionHeader alloc] initWithTitle:@"Saved routes" button:noButton],
                                 [[LSSavedSectionHeader alloc] initWithTitle:@"Recently applied" button:self.savedClearButton]];

    self.savedEmptyHolder = [[UIView alloc] init];
    self.savedEmptyHolder.hidden = YES;
    __weak typeof(self) weakSelf = self;
    self.savedTip = LSTipView(@"hand.tap.fill", @"Tap a place to preview it",
                              @"Swipe right to apply it now. Touch and hold for a map preview, sharing and more.", ^{
        ls_savedTipDone = YES;
        [weakSelf savedHeaderChangedAnimated:YES];
    });
    self.savedTip.hidden = YES;
    UISearchTextField *filter = [[UISearchTextField alloc] init];
    filter.translatesAutoresizingMaskIntoConstraints = NO;
    filter.placeholder = @"Filter places";
    filter.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    filter.adjustsFontForContentSizeCategory = YES;
    filter.returnKeyType = UIReturnKeyDone;
    filter.autocorrectionType = UITextAutocorrectionTypeNo;
    filter.accessibilityLabel = @"Filter saved places and recents";
    filter.hidden = YES;
    [filter addTarget:self action:@selector(savedFilterChanged) forControlEvents:UIControlEventEditingChanged];
    [filter addTarget:filter action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    NSLayoutConstraint *filterHeight = [filter.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    filterHeight.priority = 999;
    filterHeight.active = YES;
    self.savedFilterField = filter;
    self.savedHint = LSLabel(@"", UIFontTextStyleFootnote);
    self.savedHint.textColor = UIColor.secondaryLabelColor;
    self.savedHint.hidden = YES;
    UIStackView *content = LSStack(@[self.savedEmptyHolder, self.savedTip, filter, self.savedHint], LSSpaceM);
    // Inset to line up with the inset-grouped sections below.
    UIView *header = [[UIView alloc] init];
    [header addSubview:content];
    NSLayoutConstraint *bottom = [content.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [content.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor constant:4],
        [content.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor constant:-4],
        bottom
    ]];
    header.preservesSuperviewLayoutMargins = YES;
    self.savedToolbar = header;
    self.savedTable.tableHeaderView = self.savedToolbar;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(savedSessionChanged:) name:LSSessionDidChangeNotification object:LSSessionController.shared];
    [self reloadSavedPlaces];
}
- (BOOL)savedUsesLargeText {
    return UIContentSizeCategoryIsAccessibilityCategory(self.savedTable.traitCollection.preferredContentSizeCategory);
}
- (void)layoutSavedHeader {
    BOOL large = [self savedUsesLargeText];
    for (UITableViewHeaderFooterView *header in self.savedSectionHeaders) [(LSSavedSectionHeader *)header applyLarge:large];
    LSSizeTableHeader(self.savedTable, self.savedToolbar);
}
- (void)savedHeaderChangedAnimated:(BOOL)animated {
    if (!animated || !self.savedTable.window || !LSMapAnimationsEnabled()) { [self layoutSavedHeader]; return; }
    LSAnimate(^{
        [self layoutSavedHeader];
        [self.savedTable layoutIfNeeded];
    }, nil);
}
- (void)updateEditButton {
    BOOL editing = self.savedTable.editing;
    UIButtonConfiguration *configuration = self.editSavedButton.configuration;
    configuration.title = editing ? @"Done" : @"Reorder";
    configuration.image = editing ? nil : [UIImage systemImageNamed:@"arrow.up.arrow.down"];
    self.editSavedButton.configuration = configuration;
    self.editSavedButton.accessibilityLabel = editing ? @"Done reordering" : @"Reorder saved places";
    self.editSavedButton.accessibilityUserInputLabels = editing ? @[@"Done"] : @[@"Reorder", @"Reorder places"];
}
- (NSString *)savedFilterText {
    return [self.savedFilterField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

#pragma mark - Model and animated updates

- (void)reloadSavedPlaces { [self reloadSavedPlacesAnimated:NO]; }
- (void)reloadSavedPlacesAnimated:(BOOL)animated {
    NSArray<LSBookmark *> *all = BookmarksManager.shared.allBookmarks;
    NSArray<LSRouteArchive *> *allRoutes = LSRouteStore.shared.allRoutes;
    NSArray<NSDictionary *> *allRecents = PersistenceManager.shared.recentLocations;
    NSString *filter = [self savedFilterText];
    BOOL filtering = filter.length > 0;
    NSArray<LSBookmark *> *places = all;
    NSArray<LSRouteArchive *> *routes = allRoutes;
    NSArray<NSDictionary *> *recents = allRecents;
    if (filtering) {
        routes = [allRoutes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LSRouteArchive *route, __unused NSDictionary *bindings) {
            return LSSavedRouteMatches(route, filter);
        }]];
        places = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LSBookmark *place, __unused NSDictionary *bindings) {
            return LSSavedMatches(place.name, place.coordinate, filter);
        }]];
        recents = [allRecents filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, __unused NSDictionary *bindings) {
            return LSSavedMatches(entry[@"LSRecentName"], LSRecentCoordinate(entry), filter);
        }]];
    }
    // With nothing at all, the empty state above the sections does the teaching.
    BOOL nothing = !all.count && !allRecents.count && !allRoutes.count;
    NSMutableArray<NSString *> *savedKeys = [NSMutableArray array], *routeKeys = [NSMutableArray array], *recentKeys = [NSMutableArray array];
    if (!nothing) {
        for (LSBookmark *place in places) [savedKeys addObject:[@"s|" stringByAppendingString:place.identifier]];
        // No placeholder: the section only shows once a route is saved.
        for (LSRouteArchive *route in routes) [routeKeys addObject:[@"t|" stringByAppendingString:route.identifier]];
        for (NSDictionary *entry in recents) [recentKeys addObject:LSRecentKey(entry)];
        if (filtering) { if (!savedKeys.count && !routeKeys.count && !recentKeys.count) [savedKeys addObject:LSSavedNoMatchKey]; }
        else {
            if (!savedKeys.count) [savedKeys addObject:LSSavedEmptyKey];
            if (!recentKeys.count) [recentKeys addObject:LSRecentsEmptyKey];
        }
    }
    NSArray<NSArray<NSString *> *> *keys = @[[savedKeys copy], [routeKeys copy], [recentKeys copy]];
    NSArray<NSArray<NSString *> *> *old = self.savedRowKeys;
    // Reordering only makes sense on the whole list.
    if (self.savedTable.editing && (places.count < 2 || filtering)) [self.savedTable setEditing:NO animated:NO];
    // Make the table read its counts while the model is unchanged, so a batch update is
    // compared with what is on screen rather than with a reload still pending.
    BOOL synced = animated && old.count == LSSavedSectionCount && self.savedTable.window && !self.savedTable.hidden &&
        LSSavedKeysUnique(old) && LSSavedKeysUnique(keys) && [self.savedTable numberOfSections] == LSSavedSectionCount;
    for (NSInteger section = 0; synced && section < LSSavedSectionCount; section++) {
        synced = [self.savedTable numberOfRowsInSection:section] == (NSInteger)old[section].count;
    }
    self.allSavedPlaces = all;
    self.allRecentCount = allRecents.count;
    self.allSavedRouteCount = allRoutes.count;
    self.savedPlaces = places;
    self.savedRoutes = routes;
    self.recents = recents;
    self.savedRowKeys = keys;
    [self updateSavedSessionState];
    [self updateSavedChromeFiltering:filtering nothing:nothing];
    NSString *pulse = self.savedPulseKey;
    self.savedPulseKey = nil;
    if (!synced) {
        [self.savedTable reloadData];
        [self layoutSavedHeader];
        return;
    }
    UITableView *table = self.savedTable;
    UITableViewRowAnimation animation = LSMapAnimationsEnabled() ? UITableViewRowAnimationAutomatic : UITableViewRowAnimationFade;
    __weak typeof(self) weakSelf = self;
    [table performBatchUpdates:^{
        for (NSInteger section = 0; section < LSSavedSectionCount; section++) {
            NSArray<NSString *> *from = old[section], *to = keys[section];
            NSMutableArray<NSIndexPath *> *deleted = [NSMutableArray array], *inserted = [NSMutableArray array];
            [from enumerateObjectsUsingBlock:^(NSString *key, NSUInteger index, __unused BOOL *stop) {
                NSUInteger target = [to indexOfObject:key];
                NSIndexPath *source = [NSIndexPath indexPathForRow:(NSInteger)index inSection:section];
                if (target == NSNotFound) [deleted addObject:source];
                else if (target != index) [table moveRowAtIndexPath:source toIndexPath:[NSIndexPath indexPathForRow:(NSInteger)target inSection:section]];
            }];
            [to enumerateObjectsUsingBlock:^(NSString *key, NSUInteger index, __unused BOOL *stop) {
                if (![from containsObject:key]) [inserted addObject:[NSIndexPath indexPathForRow:(NSInteger)index inSection:section]];
            }];
            [table deleteRowsAtIndexPaths:deleted withRowAnimation:animation];
            [table insertRowsAtIndexPaths:inserted withRowAnimation:animation];
        }
    } completion:^(__unused BOOL finished) {
        MapPickerViewController *strongSelf = weakSelf;
        // Rows that stayed or moved still show their old text, menus and actions.
        [strongSelf reconfigureVisibleSavedRows];
        if (pulse) [strongSelf pulseSavedKey:pulse];
    }];
    [self layoutSavedHeader];
}
- (void)reconfigureVisibleSavedRows {
    UITableView *table = self.savedTable;
    if (table.hidden) return;
    BOOL resize = NO;
    for (NSIndexPath *path in table.indexPathsForVisibleRows) {
        LSSavedRowCell *cell = (LSSavedRowCell *)[table cellForRowAtIndexPath:path];
        if (![cell isKindOfClass:LSSavedRowCell.class] || ![self savedKeyAtPath:path]) continue;
        NSString *shape = [cell layoutShape];
        BOOL wasApplied = !cell.appliedPill.hidden, wasSaved = !cell.savedPill.hidden;
        [self configureSavedCell:cell path:path];
        if (!wasApplied) [cell revealPill:cell.appliedPill];
        if (!wasSaved) [cell revealPill:cell.savedPill];
        if (![shape isEqualToString:[cell layoutShape]]) resize = YES;
    }
    // New text or a line shown or hidden can change a row's height. Let the table measure the
    // rows again: measuring a cell by hand reads back the height the table already gave it, so a
    // row that gained a line kept its old height and its lines overlapped.
    if (resize && !table.editing) {
        [UIView performWithoutAnimation:^{ [table performBatchUpdates:nil completion:nil]; }];
    }
}
- (void)pulseSavedKey:(NSString *)key {
    NSIndexPath *path = [self savedPathForKey:key];
    LSSavedRowCell *cell = path ? (LSSavedRowCell *)[self.savedTable cellForRowAtIndexPath:path] : nil;
    if ([cell isKindOfClass:LSSavedRowCell.class] && !cell.badgeHolder.hidden) LSBump(cell.badgeHolder);
}
- (nullable NSString *)savedKeyAtPath:(NSIndexPath *)path {
    NSArray<NSArray<NSString *> *> *keys = self.savedRowKeys;
    if (path.section < 0 || path.section >= (NSInteger)keys.count) return nil;
    NSArray<NSString *> *rows = keys[path.section];
    return path.row >= 0 && path.row < (NSInteger)rows.count ? rows[path.row] : nil;
}
- (nullable NSIndexPath *)savedPathForKey:(NSString *)key {
    NSArray<NSArray<NSString *> *> *keys = self.savedRowKeys;
    for (NSUInteger section = 0; section < keys.count; section++) {
        NSUInteger row = [keys[section] indexOfObject:key];
        if (row != NSNotFound) return [NSIndexPath indexPathForRow:(NSInteger)row inSection:(NSInteger)section];
    }
    return nil;
}
- (NSUInteger)savedFullIndexOfID:(NSString *)identifier {
    return [self.allSavedPlaces indexOfObjectPassingTest:^BOOL(LSBookmark *place, __unused NSUInteger i, __unused BOOL *stop) { return [place.identifier isEqualToString:identifier]; }];
}

#pragma mark - Session state on rows

// Returns YES when the applied spot or the distance reference moved.
- (BOOL)updateSavedSessionState {
    LSSessionSnapshot *snapshot = LSSessionController.shared.snapshot;
    CLLocationCoordinate2D held = kCLLocationCoordinate2DInvalid, reference = kCLLocationCoordinate2DInvalid;
    // Distances only while the spoofed spot stands still; during playback they would go stale.
    if (snapshot.mode == LSSessionModeStatic && PersistenceManager.shared.hasStoredCoordinate) held = reference = PersistenceManager.shared.spoofCoordinate;
    else if (snapshot.mode == LSSessionModePaused && snapshot.location) reference = snapshot.location.coordinate;
    CLLocationCoordinate2D oldHeld = self.savedHeldCoordinate, oldReference = self.savedReferenceCoordinate;
    BOOL changed = self.savedSessionMode != snapshot.mode ||
        fabs(oldHeld.latitude - held.latitude) > 1e-7 || fabs(oldHeld.longitude - held.longitude) > 1e-7 ||
        fabs(oldReference.latitude - reference.latitude) > 1e-7 || fabs(oldReference.longitude - reference.longitude) > 1e-7;
    self.savedSessionMode = snapshot.mode;
    self.savedHeldCoordinate = held;
    self.savedReferenceCoordinate = reference;
    return changed;
}
- (void)savedSessionChanged:(NSNotification *)note {
    (void)note;
    // Fires up to 10 Hz during playback; only a new mode or spot does any work.
    if (self.closed || self.savedTable.hidden || ![self updateSavedSessionState]) return;
    if (!self.savedTable.editing) [self reconfigureVisibleSavedRows];
    [self updateSavedHint];
    [self layoutSavedHeader];
}
- (BOOL)savedIsHeld:(CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DIsValid(self.savedHeldCoordinate) && LSSavedDistanceBetween(self.savedHeldCoordinate, coordinate) < 5;
}

#pragma mark - Chrome: headers, empty state, tip, filter

- (void)updateSavedChromeFiltering:(BOOL)filtering nothing:(BOOL)nothing {
    LSSavedSectionHeader *savedHeader = (LSSavedSectionHeader *)self.savedSectionHeaders.firstObject;
    LSSavedSectionHeader *routeHeader = (LSSavedSectionHeader *)self.savedSectionHeaders[LSSavedRoutesSection];
    LSSavedSectionHeader *recentHeader = (LSSavedSectionHeader *)self.savedSectionHeaders.lastObject;
    unsigned long routes = self.allSavedRouteCount, routeCapacity = LSRouteStore.capacity;
    NSString *routeCount = filtering ? [NSString stringWithFormat:@"%lu of %lu", (unsigned long)self.savedRoutes.count, routes]
        : (routes >= routeCapacity * 4 / 5 ? [NSString stringWithFormat:@"%lu of %lu", routes, routeCapacity] : [NSString stringWithFormat:@"%lu", routes]);
    [routeHeader setCountText:routes ? routeCount : @""];
    routeHeader.heading.accessibilityLabel = routes ? [NSString stringWithFormat:@"Saved routes, %@%@", routeCount, filtering ? @" match" : @""] : @"Saved routes";
    unsigned long total = self.allSavedPlaces.count, visible = self.savedPlaces.count, capacity = BookmarksManager.capacity;
    // The limit only matters once it is near.
    BOOL nearLimit = total >= capacity * 4 / 5;
    if (filtering) {
        [savedHeader setCountText:[NSString stringWithFormat:@"%lu of %lu", visible, total]];
        savedHeader.heading.accessibilityLabel = [NSString stringWithFormat:@"Saved places, %lu of %lu match", visible, total];
    } else {
        [savedHeader setCountText:total == 0 ? @"" : (nearLimit ? [NSString stringWithFormat:@"%lu of %lu", total, capacity] : [NSString stringWithFormat:@"%lu", total])];
        savedHeader.heading.accessibilityLabel = total == 0 ? @"Saved places" : (nearLimit ? [NSString stringWithFormat:@"Saved places, %lu of %lu", total, capacity]
                                                                                       : [NSString stringWithFormat:@"Saved places, %lu", total]);
    }
    NSString *recentCount = filtering && self.allRecentCount ? [NSString stringWithFormat:@"%lu of %lu", (unsigned long)self.recents.count, (unsigned long)self.allRecentCount] : @"";
    [recentHeader setCountText:recentCount];
    recentHeader.heading.accessibilityLabel = recentCount.length ? [NSString stringWithFormat:@"Recently applied, %@ match", recentCount] : @"Recently applied";
    self.editSavedButton.hidden = total < 2;
    self.editSavedButton.enabled = visible > 1 && !filtering;
    // Nothing to clear means no Clear button, rather than one that explains itself after a tap.
    self.savedClearButton.hidden = self.allRecentCount == 0 || filtering;
    [self updateEditButton];
    BOOL showFilter = total + routes >= LSSavedFilterThreshold || filtering;
    self.savedFilterField.placeholder = routes ? @"Filter places and routes" : @"Filter places";
    if (!showFilter && self.savedFilterField.isFirstResponder) [self.savedFilterField resignFirstResponder];
    self.savedFilterField.hidden = !showFilter;
    self.savedTip.hidden = nothing || ls_savedTipDone;
    [self updateSavedEmptyState:nothing];
    [self updateSavedHint];
}
- (void)updateSavedEmptyState:(BOOL)nothing {
    NSString *variant = !nothing ? @"" : (self.hasSelection ? @"save" : @"pick");
    self.savedEmptyHolder.hidden = !nothing;
    if ([variant isEqualToString:self.savedEmptyVariant]) return;
    self.savedEmptyVariant = variant;
    for (UIView *child in self.savedEmptyHolder.subviews) [child removeFromSuperview];
    if (!nothing) return;
    BOOL save = self.hasSelection;
    UIButton *action = LSButton(save ? @"Save current spot" : @"Pick a place on the map", save ? @"bookmark.fill" : @"map.fill", YES);
    action.accessibilityHint = save ? @"Names the spot selected on the Location tab and saves it." : @"Opens the Location tab, where you can drop a pin.";
    [action addTarget:self action:save ? @selector(saveSelectedPlace) : @selector(showLocationTabFromSaved) forControlEvents:UIControlEventTouchUpInside];
    UIView *empty = LSEmptyState(@"bookmark", @"No saved places yet",
                                 @"Save spots you use often and apply them in one tap. Drop a pin and tap Save, or touch and hold anywhere on the map. Routes you save on the Route tab show up here too.", action);
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    [self.savedEmptyHolder addSubview:empty];
    NSLayoutConstraint *bottom = [empty.bottomAnchor constraintEqualToAnchor:self.savedEmptyHolder.bottomAnchor];
    bottom.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [empty.topAnchor constraintEqualToAnchor:self.savedEmptyHolder.topAnchor constant:LSSpaceXL],
        [empty.leadingAnchor constraintEqualToAnchor:self.savedEmptyHolder.leadingAnchor],
        [empty.trailingAnchor constraintEqualToAnchor:self.savedEmptyHolder.trailingAnchor],
        bottom
    ]];
}
- (void)updateSavedHint {
    NSString *text = nil, *spoken = nil;
    if (self.savedTable.editing) {
        text = @"Drag the handles to reorder, then tap Done.";
        spoken = @"Reordering. Use the Move up and Move down actions on each place, then Done.";
    } else if ([self savedShowsDistances]) {
        text = @"Distances are from the applied location.";
    }
    self.savedHint.text = text;
    self.savedHint.accessibilityLabel = spoken ?: text;
    self.savedHint.hidden = text.length == 0;
}
// Only when some row shows a distance: the applied spot's own row shows none.
- (BOOL)savedShowsDistances {
    if (!CLLocationCoordinate2DIsValid(self.savedReferenceCoordinate)) return NO;
    for (LSBookmark *place in self.savedPlaces) if (![self savedIsHeld:place.coordinate]) return YES;
    for (NSDictionary *entry in self.recents) if (![self savedIsHeld:LSRecentCoordinate(entry)]) return YES;
    return NO;
}
- (void)savedFilterChanged {
    [self reloadSavedPlacesAnimated:YES];
    // VoiceOver hears how many places match once typing pauses, not after every letter.
    NSUInteger revision = ++self.savedFilterRevision;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MapPickerViewController *strongSelf = weakSelf;
        if (!strongSelf || revision != strongSelf.savedFilterRevision || strongSelf.closed || strongSelf.tab != LSPickerTabSaved) return;
        if (![strongSelf savedFilterText].length) {
            // Cleared: everything is back.
            unsigned long all = strongSelf.allSavedPlaces.count + strongSelf.allSavedRouteCount + strongSelf.allRecentCount;
            if (all) LSAnnounce(all == 1 ? @"Showing 1 place." : [NSString stringWithFormat:@"Showing all %lu places.", all]);
            return;
        }
        unsigned long count = strongSelf.savedPlaces.count + strongSelf.savedRoutes.count + strongSelf.recents.count;
        LSAnnounce(count == 0 ? @"No matches." : (count == 1 ? @"1 place matches." : [NSString stringWithFormat:@"%lu places match.", count]));
    });
}
- (void)showLocationTabFromSaved {
    [self.savedFilterField resignFirstResponder];
    [self showTab:LSPickerTabLocation animated:YES];
    LSHapticSelection();
}
- (void)toggleSavedEditing {
    [self.savedFilterField resignFirstResponder];
    [self.savedTable setEditing:!self.savedTable.editing animated:LSMapAnimationsEnabled()];
    LSHapticSelection();
    [self updateEditButton];
    [self updateSavedHint];
    [self savedHeaderChangedAnimated:YES];
    if (!self.savedTable.editing) [self reconfigureVisibleSavedRows];
    LSAnnounce(self.savedTable.editing ? @"Reordering saved places." : @"Done reordering.");
}

#pragma mark - Rows

- (NSInteger)savedRowsInSection:(NSInteger)section {
    NSArray<NSArray<NSString *> *> *keys = self.savedRowKeys;
    return section >= 0 && section < (NSInteger)keys.count ? (NSInteger)keys[section].count : 0;
}
- (BOOL)entryAtPath:(NSIndexPath *)path name:(NSString **)name coordinate:(CLLocationCoordinate2D *)coordinate date:(NSDate **)date {
    NSString *key = [self savedKeyAtPath:path];
    if ([key hasPrefix:@"s|"] && path.row < (NSInteger)self.savedPlaces.count) {
        LSBookmark *place = self.savedPlaces[path.row];
        *name = place.name; *coordinate = place.coordinate; *date = place.createdAt;
        return YES;
    }
    if ([key hasPrefix:@"r|"] && path.row < (NSInteger)self.recents.count) {
        NSDictionary *entry = self.recents[path.row];
        *name = entry[@"LSRecentName"];
        *coordinate = LSRecentCoordinate(entry);
        *date = LSRecentDate(entry);
        return YES;
    }
    return NO;
}
- (void)savedStyleForName:(NSString *)name saved:(BOOL)saved coordinate:(CLLocationCoordinate2D)coordinate symbol:(NSString **)symbol color:(UIColor **)color {
    if ([self savedIsHeld:coordinate]) { *symbol = @"location.fill"; *color = LSSuccessColor(); return; }
    if (saved) { LSSavedPlaceStyle(name, symbol, color); return; }
    *symbol = @"clock.arrow.circlepath";
    *color = UIColor.systemGrayColor;
}
- (UITableViewCell *)savedCell:(NSIndexPath *)path {
    LSSavedRowCell *cell = (LSSavedRowCell *)[self.savedTable dequeueReusableCellWithIdentifier:@"LSSavedRow"];
    if (![cell isKindOfClass:LSSavedRowCell.class]) cell = [[LSSavedRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LSSavedRow"];
    [self configureSavedCell:cell path:path];
    return cell;
}
- (void)configureSavedCell:(LSSavedRowCell *)cell path:(NSIndexPath *)path {
    NSString *key = [self savedKeyAtPath:path] ?: LSSavedEmptyKey;
    BOOL large = [self savedUsesLargeText];
    [cell applyLarge:large traits:self.savedTable.traitCollection];
    LSRouteArchive *route = [self savedRouteAtPath:path];
    if (route) { [self configureSavedRouteCell:cell route:route key:key]; return; }
    NSString *name = nil;
    CLLocationCoordinate2D coordinate = kCLLocationCoordinate2DInvalid;
    NSDate *date = nil;
    if (![self entryAtPath:path name:&name coordinate:&coordinate date:&date]) {
        NSString *title, *message, *symbol;
        // No saved match can still be a place: the row opens place search with the same text.
        BOOL search = [key isEqualToString:LSSavedNoMatchKey];
        if (search) {
            title = [NSString stringWithFormat:@"No matches for “%@”", [self savedFilterText]];
            message = [NSString stringWithFormat:@"Search places for “%@”", [self savedFilterText]];
            symbol = @"magnifyingglass";
        } else if ([key isEqualToString:LSSavedEmptyKey]) {
            title = @"No saved places yet";
            message = self.recents.count ? @"Swipe left on a recent location to save it, or touch and hold the map." : @"Drop a pin and tap Save, or touch and hold the map.";
            symbol = @"bookmark";
        } else {
            title = @"Nothing applied yet";
            message = @"Places you apply show up here, newest first.";
            symbol = @"clock";
        }
        [cell setBadgeSymbol:symbol color:UIColor.systemGrayColor muted:YES];
        [cell setTitle:title color:UIColor.secondaryLabelColor match:NSMakeRange(NSNotFound, 0)];
        cell.detailLabel.text = message;
        cell.detailLabel.textColor = search ? LSAccentTextColor() : UIColor.secondaryLabelColor;
        cell.detailLabel.hidden = NO;
        cell.coordinateLabel.hidden = YES;
        cell.appliedPill.hidden = YES;
        cell.savedPill.hidden = YES;
        cell.accessoryView = nil;
        cell.accessoryType = search ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.showsReorderControl = NO;
        cell.selectionStyle = search ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.accessibilityLabel = title;
        cell.accessibilityValue = message;
        cell.accessibilityHint = search ? @"Opens place search with this text." : nil;
        cell.accessibilityTraits = search ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
        cell.accessibilityCustomActions = nil;
        return;
    }
    BOOL saved = [key hasPrefix:@"s|"];
    LSBookmark *place = saved ? self.savedPlaces[path.row] : nil;
    LSBookmark *match = saved ? nil : [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
    BOOL active = [self savedIsHeld:coordinate];
    NSString *symbol = nil;
    UIColor *color = nil;
    [self savedStyleForName:name saved:saved coordinate:coordinate symbol:&symbol color:&color];
    [cell setBadgeSymbol:symbol color:color muted:NO];
    NSString *filter = [self savedFilterText];
    NSString *coordinates = LSCoordinateText(coordinate);
    [cell setTitle:name color:UIColor.labelColor match:LSSavedMatchRange(name, filter, YES)];
    // One calm secondary line: distance, age, wander.
    NSMutableArray<NSString *> *line = [NSMutableArray array], *spoken = [NSMutableArray array];
    if (active) [spoken addObject:@"Applied now"];
    if (!active && CLLocationCoordinate2DIsValid(self.savedReferenceCoordinate)) {
        CLLocationDistance meters = LSSavedDistanceBetween(self.savedReferenceCoordinate, coordinate);
        [line addObject:[NSString stringWithFormat:@"%@ away", LSSavedDistance(meters, NO)]];
        [spoken addObject:[NSString stringWithFormat:@"%@ from the applied location", LSSavedDistance(meters, YES)]];
    }
    if (date) {
        NSString *ago = LSSavedAgo(date);
        [line addObject:line.count ? ago : LSSavedCapitalized(ago)];
        [spoken addObject:[NSString stringWithFormat:@"%@ %@", saved ? @"Saved" : @"Applied", ago]];
    }
    if (place && isfinite(place.radius)) {
        NSString *wander = place.radius > 0 ? [NSString stringWithFormat:@"wanders %@ m", LSFormatDecimal(place.radius, 0)] : @"stays put";
        [line addObject:line.count ? wander : LSSavedCapitalized(wander)];
        [spoken addObject:place.radius > 0 ? [NSString stringWithFormat:@"Wanders within %@ meters", LSFormatDecimal(place.radius, 0)] : @"Doesn’t wander"];
    }
    if (match) [spoken addObject:[NSString stringWithFormat:@"Saved as %@", match.name]];
    cell.detailLabel.text = [line componentsJoinedByString:@" · "];
    cell.detailLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailLabel.hidden = line.count == 0;
    // Kept at accessibility sizes too, wrapping onto a second line when it must.
    [cell setCoordinates:coordinates match:LSSavedMatchRange(coordinates, filter, NO)];
    cell.coordinateLabel.hidden = NO;
    cell.appliedPill.hidden = !active;
    cell.savedPill.hidden = active || !match;
    cell.moreButton.menu = [self menuForPath:path];
    cell.moreButton.accessibilityLabel = [NSString stringWithFormat:@"Actions for %@", name];
    cell.accessoryView = cell.moreButton;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.showsReorderControl = saved;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityLabel = name;
    cell.accessibilityValue = [spoken componentsJoinedByString:@", "];
    cell.accessibilityHint = @"Shows it on the map.";
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    cell.accessibilityCustomActions = [self savedAccessibilityActionsForPath:path key:key name:name coordinate:coordinate cell:cell];
}
- (NSArray<UIAccessibilityCustomAction *> *)savedAccessibilityActionsForPath:(NSIndexPath *)path key:(NSString *)key name:(NSString *)name
                                                               coordinate:(CLLocationCoordinate2D)coordinate cell:(UITableViewCell *)cell {
    __weak typeof(self) weakSelf = self;
    __weak UITableViewCell *weakCell = cell;
    UIAccessibilityCustomAction *(^make)(NSString *, dispatch_block_t) = ^UIAccessibilityCustomAction *(NSString *title, dispatch_block_t block) {
        return [[UIAccessibilityCustomAction alloc] initWithName:title actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) { block(); return YES; }];
    };
    NSMutableArray<UIAccessibilityCustomAction *> *actions = [NSMutableArray array];
    [actions addObject:make(@"Apply now", ^{ [weakSelf applySavedKey:key coordinate:coordinate name:name]; })];
    if ([key hasPrefix:@"r|"]) {
        NSDictionary *entry = self.recents[path.row];
        [actions addObject:make(@"Save place", ^{ [weakSelf namePlace:name coordinate:coordinate identifier:nil]; })];
        [actions addObject:make(@"Copy coordinates", ^{ [weakSelf copySavedCoordinate:coordinate]; })];
        [actions addObject:make(@"Share", ^{ [weakSelf shareSavedName:name coordinate:coordinate key:key]; })];
        [actions addObject:make(@"Remove from recents", ^{ [weakSelf removeRecent:entry]; })];
        return actions;
    }
    LSBookmark *place = self.savedPlaces[path.row];
    NSString *identifier = place.identifier;
    NSUInteger index = [self savedFullIndexOfID:identifier];
    [actions addObject:make(@"Rename", ^{ [weakSelf namePlace:place.name coordinate:place.coordinate identifier:identifier]; })];
    [actions addObject:make(@"Wander radius", ^{ [weakSelf presentRadiusChoicesForPlace:place from:weakCell]; })];
    [actions addObject:make(@"Copy coordinates", ^{ [weakSelf copySavedCoordinate:coordinate]; })];
    [actions addObject:make(@"Share", ^{ [weakSelf shareSavedName:name coordinate:coordinate key:key]; })];
    if (index != NSNotFound && index > 0) [actions addObject:make(@"Move up", ^{ [weakSelf moveID:identifier offset:-1]; })];
    if (index != NSNotFound && index + 1 < self.allSavedPlaces.count) [actions addObject:make(@"Move down", ^{ [weakSelf moveID:identifier offset:1]; })];
    [actions addObject:make(@"Delete", ^{ [weakSelf deleteBookmark:place]; })];
    return actions;
}

#pragma mark - Table delegate additions (the shell forwards the rest)

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    if (table != self.savedTable || section < 0 || section >= (NSInteger)self.savedSectionHeaders.count) return nil;
    if ([self savedRowsInSection:section] == 0) return [[UIView alloc] init];
    LSSavedSectionHeader *header = (LSSavedSectionHeader *)self.savedSectionHeaders[section];
    [header applyLarge:[self savedUsesLargeText]];
    return header;
}
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    if (table != self.savedTable) return UITableViewAutomaticDimension;
    return [self savedRowsInSection:section] > 0 ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}
// An empty section takes no room at all: its footer gap left a blank band above Recently applied.
- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    if (table != self.savedTable) return UITableViewAutomaticDimension;
    return [self savedRowsInSection:section] > 0 ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}
- (void)tableView:(UITableView *)table willPerformPreviewActionForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionCommitAnimating>)animator {
    if (table != self.savedTable || ![(id)configuration.identifier isKindOfClass:NSString.class]) return;
    NSString *key = (NSString *)configuration.identifier;
    // Tapping the map preview shows the place on the picker's map.
    animator.preferredCommitStyle = UIContextMenuInteractionCommitStyleDismiss;
    __weak typeof(self) weakSelf = self;
    [animator addCompletion:^{
        NSIndexPath *path = [weakSelf savedPathForKey:key];
        if (path) [weakSelf previewSavedPlace:path];
    }];
}

#pragma mark - Actions

- (void)previewCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    [self.savedFilterField resignFirstResponder];
    if (self.tab == LSPickerTabSaved && !ls_savedTipDone) ls_savedTipDone = YES;
    // The switch drops pending lookups and older selections, so the selection comes after it.
    [self showTab:LSPickerTabLocation animated:YES];
    [self setSelection:coordinate name:name];
    [self focusMapOnCoordinate:coordinate meters:2000 animated:LSMapAnimationsEnabled()];
    LSHapticSelection();
    LSAnnounce(@"Place previewed. Apply location when you’re ready.");
}
- (void)previewSavedPlace:(NSIndexPath *)path {
    if ([[self savedKeyAtPath:path] isEqualToString:LSSavedNoMatchKey]) { [self searchPlacesForSavedFilter]; return; }
    LSRouteArchive *route = [self savedRouteAtPath:path];
    if (route) { [self openSavedRoute:route start:NO]; return; }
    NSString *name = nil;
    CLLocationCoordinate2D coordinate;
    NSDate *date = nil;
    if ([self entryAtPath:path name:&name coordinate:&coordinate date:&date]) [self previewCoordinate:coordinate name:name];
}
// Place search, already running the filter's text. A choice previews on the Location tab.
- (void)searchPlacesForSavedFilter {
    NSString *query = [self savedFilterText];
    if (!query.length || self.closed) return;
    [self.savedFilterField resignFirstResponder];
    LSHapticSelection();
    LSPlaceSearchController *search = [[LSPlaceSearchController alloc] init];
    search.title = @"Search places";
    search.initialQuery = query;
    search.initialCoordinate = self.selectedCoordinate;
    search.searchRegion = self.mapView.region;
    // As openPlaceChooser does: a choice that arrives after another selection is dropped.
    NSUInteger revision = ++self.selectionRevision;
    __weak typeof(self) weakSelf = self;
    search.didChoose = ^(CLLocationCoordinate2D coordinate, NSString *name) {
        MapPickerViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.closed || strongSelf.selectionRevision != revision) return;
        [strongSelf previewCoordinate:coordinate name:name];
    };
    [self presentEditor:search];
}
- (void)applySavedKey:(NSString *)key coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    [self applyCoordinate:coordinate name:name];
    self.savedPulseKey = key;
    // Recents and the Applied badge change with it; once the rows settle, the Applied now pill
    // fades in on the row (reconfigureVisibleSavedRows). applyCoordinate already plays the haptic.
    [self reloadSavedPlacesAnimated:YES];
}
// Undo toasts sit just above the list's bottom edge, which stays clear of the floating footer.
// Created on first use: the table only joins the view hierarchy after buildSavedUI.
- (nullable UIView *)savedToastAnchorView {
    UIView *host = self.savedTable.superview;
    if (!host || ![host isDescendantOfView:self.view]) return nil;
    if (self.savedToastAnchor.superview != host) {
        [self.savedToastAnchor removeFromSuperview];
        UIView *anchor = [[UIView alloc] init];
        anchor.translatesAutoresizingMaskIntoConstraints = NO;
        anchor.hidden = YES;
        anchor.userInteractionEnabled = NO;
        [host addSubview:anchor];
        // The list runs to the screen edge when the footer is hidden; stay above the home indicator.
        NSLayoutConstraint *atList = [anchor.topAnchor constraintEqualToAnchor:self.savedTable.bottomAnchor];
        atList.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            atList,
            [anchor.topAnchor constraintLessThanOrEqualToAnchor:self.savedTable.bottomAnchor],
            [anchor.topAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
            [anchor.leadingAnchor constraintEqualToAnchor:self.savedTable.leadingAnchor],
            [anchor.trailingAnchor constraintEqualToAnchor:self.savedTable.trailingAnchor],
            [anchor.heightAnchor constraintEqualToConstant:0]
        ]];
        self.savedToastAnchor = anchor;
    }
    return self.savedToastAnchor;
}
- (void)copySavedCoordinate:(CLLocationCoordinate2D)coordinate {
    UIPasteboard.generalPasteboard.string = LSCoordinateText(coordinate);
    LSHapticSelection();
    [self showMessage:@"Coordinates copied." symbol:@"doc.on.doc.fill"];
}
- (void)shareSavedName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate key:(nullable NSString *)key {
    LSMapLinkPlace *place = [LSMapLinkPlace placeWithLatitude:coordinate.latitude longitude:coordinate.longitude name:name];
    // @available needs a compiler-rt helper the Linux toolchain doesn't ship.
    BOOL legacyApple = ![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){18, 4, 0}];
    NSURL *url = [LSMapLinks URLForApp:LSMapAppApple places:@[place] mode:nil legacyApple:legacyApple];
    NSString *text = [NSString stringWithFormat:@"%@ (%@)", name, LSCoordinateText(coordinate)];
    NSIndexPath *path = key ? [self savedPathForKey:key] : nil;
    UIView *source = path ? [self.savedTable cellForRowAtIndexPath:path] : nil;
    [self presentShareItems:url ? @[text, url] : @[text] from:source ?: self.savedTable];
}
- (void)deleteBookmark:(LSBookmark *)place {
    NSArray<LSBookmark *> *before = BookmarksManager.shared.allBookmarks;
    NSUInteger index = [before indexOfObjectPassingTest:^BOOL(LSBookmark *item, __unused NSUInteger i, __unused BOOL *stop) { return [item.identifier isEqualToString:place.identifier]; }];
    if (index == NSNotFound || ![BookmarksManager.shared removeBookmarkWithID:place.identifier]) { [self reloadSavedPlacesAnimated:YES]; return; }
    // Immediate, with Undo, instead of a confirmation in the way of every delete.
    LSHapticImpact(UIImpactFeedbackStyleMedium);
    [self reloadSavedPlacesAnimated:YES];
    __weak typeof(self) weakSelf = self;
    LSShowActionToast(self.view, [self savedToastAnchorView], [NSString stringWithFormat:@"Deleted “%@”", place.name], @"trash.fill", @"Undo", ^{
        [weakSelf restoreBookmark:place index:index];
    });
}
- (void)restoreBookmark:(LSBookmark *)place index:(NSUInteger)index {
    BookmarksManager *manager = BookmarksManager.shared;
    NSString *identifier = nil;
    // Merging keeps its id, date and radius; it then lands last and is moved back.
    if ([manager importBookmarks:@[place] replace:NO] > 0) identifier = place.identifier;
    else if ([manager addBookmarkWithName:place.name coordinate:place.coordinate]) {
        // A copy saved within a few meters blocks the merge; bring it back as its own entry.
        identifier = manager.allBookmarks.firstObject.identifier;
        if (isfinite(place.radius)) [manager setRadius:place.radius forBookmarkWithID:identifier];
    }
    if (!identifier) {
        LSHapticWarning();
        [self showMessage:@"The place could not be restored." symbol:@"exclamationmark.triangle.fill"];
        return;
    }
    NSUInteger count = manager.allBookmarks.count;
    if (count) [manager moveBookmarkWithID:identifier toIndex:MIN(index, count - 1)];
    LSHapticSuccess();
    self.savedPulseKey = [@"s|" stringByAppendingString:identifier];
    [self reloadSavedPlacesAnimated:YES];
    if (self.hasSelection && self.tab == LSPickerTabLocation) [self renderSelectedLocation];
    LSAnnounce([NSString stringWithFormat:@"Restored %@.", place.name]);
}
- (void)removeRecent:(NSDictionary *)entry {
    NSMutableArray<NSDictionary *> *list = [PersistenceManager.shared.recentLocations mutableCopy];
    NSUInteger index = [list indexOfObjectPassingTest:^BOOL(NSDictionary *item, __unused NSUInteger i, __unused BOOL *stop) { return LSSameRecent(item, entry); }];
    if (index == NSNotFound) { [self reloadSavedPlacesAnimated:YES]; return; }
    [list removeObjectAtIndex:index];
    [PersistenceManager.shared replaceRecentLocations:list];
    LSHapticImpact(UIImpactFeedbackStyleMedium);
    [self reloadSavedPlacesAnimated:YES];
    __weak typeof(self) weakSelf = self;
    NSString *name = entry[@"LSRecentName"] ?: @"Location";
    LSShowActionToast(self.view, [self savedToastAnchorView], [NSString stringWithFormat:@"Removed “%@” from recents", name], @"clock.arrow.circlepath", @"Undo", ^{
        NSMutableArray<NSDictionary *> *current = [PersistenceManager.shared.recentLocations mutableCopy];
        BOOL present = [current indexOfObjectPassingTest:^BOOL(NSDictionary *item, __unused NSUInteger i, __unused BOOL *stop) { return LSSameRecent(item, entry); }] != NSNotFound;
        if (!present) [current insertObject:entry atIndex:MIN(index, current.count)];
        [PersistenceManager.shared replaceRecentLocations:current];
        LSHapticSuccess();
        [weakSelf reloadSavedPlacesAnimated:YES];
        LSAnnounce(@"Recent location restored.");
    });
}
- (void)clearRecents {
    NSArray<NSDictionary *> *previous = PersistenceManager.shared.recentLocations;
    if (!previous.count) { [self reloadSavedPlacesAnimated:YES]; return; }
    [PersistenceManager.shared clearRecentLocations];
    LSHapticImpact(UIImpactFeedbackStyleMedium);
    [self reloadSavedPlacesAnimated:YES];
    __weak typeof(self) weakSelf = self;
    NSString *message = previous.count == 1 ? @"Cleared 1 recent location" : [NSString stringWithFormat:@"Cleared %lu recent locations", (unsigned long)previous.count];
    LSShowActionToast(self.view, [self savedToastAnchorView], message, @"clock.arrow.circlepath", @"Undo", ^{
        // Anything applied since stays on top; the cleared ones come back after it.
        NSMutableArray<NSDictionary *> *merged = [PersistenceManager.shared.recentLocations mutableCopy];
        for (NSDictionary *entry in previous) {
            BOOL present = [merged indexOfObjectPassingTest:^BOOL(NSDictionary *item, __unused NSUInteger i, __unused BOOL *stop) { return LSSameRecent(item, entry); }] != NSNotFound;
            if (!present) [merged addObject:entry];
        }
        [PersistenceManager.shared replaceRecentLocations:merged];
        LSHapticSuccess();
        [weakSelf reloadSavedPlacesAnimated:YES];
        LSAnnounce(@"Recent locations restored.");
    });
}
- (UIMenu *)menuForPath:(NSIndexPath *)path {
    __weak typeof(self) weakSelf = self;
    NSString *key = [self savedKeyAtPath:path];
    LSRouteArchive *route = [self savedRouteAtPath:path];
    if (route) return [self menuForSavedRoute:route];
    NSString *name = nil;
    CLLocationCoordinate2D coordinate = kCLLocationCoordinate2DInvalid;
    NSDate *date = nil;
    if (!key || ![self entryAtPath:path name:&name coordinate:&coordinate date:&date]) return [UIMenu menuWithTitle:@"" children:@[]];
    UIAction *apply = [UIAction actionWithTitle:@"Apply now" image:[UIImage systemImageNamed:@"location.fill"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf applySavedKey:key coordinate:coordinate name:name];
    }];
    if ([self savedIsHeld:coordinate]) apply.subtitle = @"Applied right now";
    UIAction *preview = [UIAction actionWithTitle:@"Show on map" image:[UIImage systemImageNamed:@"map"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf previewCoordinate:coordinate name:name];
    }];
    UIAction *copy = [UIAction actionWithTitle:@"Copy coordinates" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf copySavedCoordinate:coordinate];
    }];
    UIAction *share = [UIAction actionWithTitle:@"Share…" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf shareSavedName:name coordinate:coordinate key:key];
    }];
    UIMenu *primary = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[apply, preview]];
    if ([key hasPrefix:@"r|"]) {
        NSDictionary *entry = self.recents[path.row];
        LSBookmark *match = [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
        UIAction *save = [UIAction actionWithTitle:@"Save place" image:[UIImage systemImageNamed:@"bookmark"] identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf namePlace:name coordinate:coordinate identifier:nil];
        }];
        if (match) save.subtitle = [NSString stringWithFormat:@"Already saved as “%@”", match.name];
        UIAction *remove = [UIAction actionWithTitle:@"Remove from recents" image:[UIImage systemImageNamed:@"minus.circle"] identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf removeRecent:entry];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;
        UIMenu *more = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[save, copy, share]];
        UIMenu *danger = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[remove]];
        return [UIMenu menuWithTitle:name children:@[primary, more, danger]];
    }
    LSBookmark *place = self.savedPlaces[path.row];
    NSString *identifier = place.identifier;
    UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf namePlace:place.name coordinate:place.coordinate identifier:identifier];
    }];
    // Positions refer to the whole list, also while it is filtered.
    NSUInteger index = [self savedFullIndexOfID:identifier];
    NSUInteger count = self.allSavedPlaces.count;
    UIAction *first = [UIAction actionWithTitle:@"Move to top" image:[UIImage systemImageNamed:@"arrow.up.to.line"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf moveID:identifier toIndex:0];
    }];
    UIAction *up = [UIAction actionWithTitle:@"Move up" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveID:identifier offset:-1]; }];
    UIAction *down = [UIAction actionWithTitle:@"Move down" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveID:identifier offset:1]; }];
    if (index == NSNotFound || index == 0) { first.attributes = UIMenuElementAttributesDisabled; up.attributes = UIMenuElementAttributesDisabled; }
    if (index == NSNotFound || index + 1 >= count) down.attributes = UIMenuElementAttributesDisabled;
    UIAction *remove = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf deleteBookmark:place]; }];
    remove.attributes = UIMenuElementAttributesDestructive;
    UIMenu *edit = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[rename, copy, share]];
    UIMenu *order = [UIMenu menuWithTitle:@"Move" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0 children:@[first, up, down]];
    UIMenu *danger = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[remove]];
    return [UIMenu menuWithTitle:place.name children:@[primary, edit, [self radiusMenuForBookmark:place], order, danger]];
}
- (UIContextMenuConfiguration *)savedMenu:(NSIndexPath *)path {
    NSString *key = [self savedKeyAtPath:path];
    LSRouteArchive *route = [self savedRouteAtPath:path];
    if (route) {
        if (self.savedTable.editing) return nil;
        UIMenu *menu = [self menuForSavedRoute:route];
        UITraitCollection *traits = self.savedTable.traitCollection;
        CGFloat width = MIN(MAX(self.savedTable.bounds.size.width - 40, 260), 420);
        NSString *detail = [self savedRouteSummary:route spoken:NO];
        return [UIContextMenuConfiguration configurationWithIdentifier:key previewProvider:^UIViewController *{
            return [[LSSavedPreviewController alloc] initWithName:route.name detail:detail route:route traits:traits width:width];
        } actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) { return menu; }];
    }
    NSString *name = nil;
    CLLocationCoordinate2D coordinate = kCLLocationCoordinate2DInvalid;
    NSDate *date = nil;
    if (!key || self.savedTable.editing || ![self entryAtPath:path name:&name coordinate:&coordinate date:&date]) return nil;
    UIMenu *menu = [self menuForPath:path];
    BOOL saved = [key hasPrefix:@"s|"];
    LSBookmark *match = saved ? self.savedPlaces[path.row] : [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
    PersistenceManager *store = PersistenceManager.shared;
    // The circle the spot would wander in once applied.
    double radius = match && isfinite(match.radius) ? match.radius : (store.fluctuationEnabled ? store.fluctuationRadius : 0);
    NSString *symbol = nil;
    UIColor *tint = nil;
    [self savedStyleForName:name saved:saved coordinate:coordinate symbol:&symbol color:&tint];
    UITraitCollection *traits = self.savedTable.traitCollection;
    CGFloat width = MIN(MAX(self.savedTable.bounds.size.width - 40, 260), 420);
    NSString *detail = radius > 0 ? [NSString stringWithFormat:@"%@ · wanders %@ m", LSCoordinateText(coordinate), LSFormatDecimal(radius, 0)] : LSCoordinateText(coordinate);
    BOOL held = [self savedIsHeld:coordinate];
    NSString *pill = held ? @"Applied now" : (match ? @"Saved" : nil);
    UIColor *pillColor = held ? LSSuccessColor() : LSAccentTextColor();
    return [UIContextMenuConfiguration configurationWithIdentifier:key previewProvider:^UIViewController *{
        return [[LSSavedPreviewController alloc] initWithName:name detail:detail pill:pill pillColor:pillColor coordinate:coordinate radius:radius
                                                       symbol:symbol tint:tint traits:traits width:width];
    } actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) { return menu; }];
}
- (UISwipeActionsConfiguration *)savedSwipeActions:(NSIndexPath *)path leading:(BOOL)leading {
    NSString *key = [self savedKeyAtPath:path];
    LSRouteArchive *route = [self savedRouteAtPath:path];
    if (route) return self.savedTable.editing ? nil : [self savedRouteSwipeActions:route leading:leading];
    NSString *name = nil;
    CLLocationCoordinate2D coordinate;
    NSDate *date = nil;
    if (!key || self.savedTable.editing || ![self entryAtPath:path name:&name coordinate:&coordinate date:&date]) return nil;
    __weak typeof(self) weakSelf = self;
    if (leading) {
        UIContextualAction *apply = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Apply now" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            done(YES);
            // After the swipe settles, so the recents update animates on its own.
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applySavedKey:key coordinate:coordinate name:name]; });
        }];
        apply.image = [UIImage systemImageNamed:@"location.fill"];
        // Green, like the Applied now pill and badge the row gets once it is applied.
        apply.backgroundColor = LSFillColor(LSSuccessColor());
        UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[apply]];
        configuration.performsFirstActionWithFullSwipe = YES;
        return configuration;
    }
    if ([key hasPrefix:@"r|"]) {
        NSDictionary *entry = self.recents[path.row];
        UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            [weakSelf removeRecent:entry];
            done(YES);
        }];
        remove.image = [UIImage systemImageNamed:@"minus.circle.fill"];
        remove.backgroundColor = LSFillColor(LSErrorColor());
        UIContextualAction *save = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Save" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            done(YES);
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf namePlace:name coordinate:coordinate identifier:nil]; });
        }];
        save.image = [UIImage systemImageNamed:@"bookmark.fill"];
        save.backgroundColor = LSFillColor(UIColor.systemIndigoColor);
        UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove, save]];
        configuration.performsFirstActionWithFullSwipe = YES;
        return configuration;
    }
    LSBookmark *place = self.savedPlaces[path.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
        [weakSelf deleteBookmark:place];
        done(YES);
    }];
    remove.image = [UIImage systemImageNamed:@"trash.fill"];
    remove.backgroundColor = LSFillColor(LSErrorColor());
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
        done(YES);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf namePlace:place.name coordinate:place.coordinate identifier:place.identifier]; });
    }];
    rename.image = [UIImage systemImageNamed:@"pencil"];
    rename.backgroundColor = LSFillColor(UIColor.systemGrayColor);
    // Full swipe deletes: Undo makes that safe.
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove, rename]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

#pragma mark - Reordering

- (void)moveID:(NSString *)identifier toIndex:(NSUInteger)target {
    NSArray<LSBookmark *> *current = BookmarksManager.shared.allBookmarks;
    NSUInteger index = [current indexOfObjectPassingTest:^BOOL(LSBookmark *place, __unused NSUInteger i, __unused BOOL *stop) { return [place.identifier isEqualToString:identifier]; }];
    if (index == NSNotFound || target >= current.count || index == target || ![BookmarksManager.shared moveBookmarkWithID:identifier toIndex:target]) {
        [self reloadSavedPlacesAnimated:YES];
        return;
    }
    LSHapticSelection();
    [self reloadSavedPlacesAnimated:YES];
    LSAnnounce([NSString stringWithFormat:@"Moved %@ to position %lu of %lu.", current[index].name, (unsigned long)target + 1, (unsigned long)current.count]);
}
- (void)moveID:(NSString *)identifier offset:(NSInteger)offset {
    NSUInteger index = [BookmarksManager.shared.allBookmarks indexOfObjectPassingTest:^BOOL(LSBookmark *place, __unused NSUInteger i, __unused BOOL *stop) { return [place.identifier isEqualToString:identifier]; }];
    NSInteger target = index == NSNotFound ? -1 : (NSInteger)index + offset;
    if (target < 0) { [self reloadSavedPlacesAnimated:YES]; return; }
    [self moveID:identifier toIndex:(NSUInteger)target];
}
- (void)moveSavedPlace:(NSIndexPath *)source to:(NSIndexPath *)destination {
    __weak typeof(self) weakSelf = self;
    NSArray<NSArray<NSString *> *> *keys = self.savedRowKeys;
    BOOL valid = source.section == 0 && destination.section == 0 && keys.count == LSSavedSectionCount &&
        source.row < (NSInteger)self.savedPlaces.count && destination.row < (NSInteger)self.savedPlaces.count &&
        (NSInteger)keys[0].count == (NSInteger)self.savedPlaces.count;
    if (!valid) {
        // Never reload while the table finishes the drop; do it on the next turn.
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadSavedPlaces]; });
        return;
    }
    if (source.row == destination.row) return;
    NSString *sourceID = self.savedPlaces[source.row].identifier;
    NSString *targetID = self.savedPlaces[destination.row].identifier;
    NSUInteger targetIndex = [self savedFullIndexOfID:targetID];
    // The table already shows the new order: mirror it in the model without moving rows again.
    NSMutableArray<LSBookmark *> *places = [self.savedPlaces mutableCopy];
    LSBookmark *moved = places[source.row];
    [places removeObjectAtIndex:source.row];
    [places insertObject:moved atIndex:destination.row];
    NSMutableArray<NSString *> *rowKeys = [keys[0] mutableCopy];
    NSString *movedKey = rowKeys[source.row];
    [rowKeys removeObjectAtIndex:source.row];
    [rowKeys insertObject:movedKey atIndex:destination.row];
    self.savedPlaces = places;
    NSMutableArray<NSArray<NSString *> *> *allKeys = [keys mutableCopy];
    allKeys[0] = rowKeys;
    self.savedRowKeys = allKeys;
    if (targetIndex != NSNotFound) [BookmarksManager.shared moveBookmarkWithID:sourceID toIndex:targetIndex];
    LSHapticImpact(UIImpactFeedbackStyleLight);
    // Next turn: picks up the stored order (normally identical) and refreshes Move menus.
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadSavedPlacesAnimated:YES]; });
}

#pragma mark - Wander radius (#19)

// Same choices for the menu and for the VoiceOver sheet: title, meters (NAN follows Settings), selected.
- (NSArray<NSDictionary *> *)radiusChoicesForPlace:(LSBookmark *)place matched:(BOOL *)matched {
    double radius = place.radius;
    PersistenceManager *store = PersistenceManager.shared;
    NSString *defaultTitle = store.fluctuationEnabled ? [NSString stringWithFormat:@"Same as Settings (%@ m)", LSFormatDecimal(store.fluctuationRadius, 0)] : @"Same as Settings (off)";
    NSMutableArray<NSDictionary *> *choices = [NSMutableArray array];
    [choices addObject:@{@"title":defaultTitle, @"value":@(NAN), @"on":@(!isfinite(radius))}];
    [choices addObject:@{@"title":@"Don’t wander here", @"value":@0, @"on":@(isfinite(radius) && radius == 0)}];
    BOOL found = !isfinite(radius) || radius == 0;
    for (NSNumber *meters in @[@10, @25, @50, @100, @250]) {
        BOOL on = isfinite(radius) && fabs(radius - meters.doubleValue) < 0.5;
        found = found || on;
        [choices addObject:@{@"title":[NSString stringWithFormat:@"%@ m", meters], @"value":meters, @"on":@(on)}];
    }
    if (matched) *matched = found;
    return choices;
}
- (UIMenu *)radiusMenuForBookmark:(LSBookmark *)place {
    __weak typeof(self) weakSelf = self;
    BOOL matched = NO;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    for (NSDictionary *choice in [self radiusChoicesForPlace:place matched:&matched]) {
        double value = [choice[@"value"] doubleValue];
        UIAction *action = [UIAction actionWithTitle:choice[@"title"] image:nil identifier:nil handler:^(__unused UIAction *item) { [weakSelf setRadius:value forPlace:place]; }];
        action.state = [choice[@"on"] boolValue] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    UIAction *custom = [UIAction actionWithTitle:matched ? @"Custom…" : [NSString stringWithFormat:@"Custom (%@ m)…", LSFormatDecimal(place.radius, 0)] image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf enterRadiusForPlace:place];
    }];
    if (!matched) custom.state = UIMenuElementStateOn;
    [items addObject:custom];
    return [UIMenu menuWithTitle:@"Wander radius" image:[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"] identifier:nil options:0 children:items];
}
- (void)presentRadiusChoicesForPlace:(LSBookmark *)place from:(nullable UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Wander radius" message:[NSString stringWithFormat:@"How far “%@” may drift while it’s applied.", place.name] preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    BOOL matched = NO;
    for (NSDictionary *choice in [self radiusChoicesForPlace:place matched:&matched]) {
        double value = [choice[@"value"] doubleValue];
        NSString *title = [choice[@"on"] boolValue] ? [NSString stringWithFormat:@"%@ (current)", choice[@"title"]] : choice[@"title"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf setRadius:value forPlace:place]; }]];
    }
    NSString *customTitle = matched ? @"Custom…" : [NSString stringWithFormat:@"Custom (%@ m, current)…", LSFormatDecimal(place.radius, 0)];
    [sheet addAction:[UIAlertAction actionWithTitle:customTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf enterRadiusForPlace:place]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = source.window ? source : self.savedTable;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)enterRadiusForPlace:(LSBookmark *)place {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Wander radius" message:[NSString stringWithFormat:@"How far “%@” may drift, from 1 to 1,000 meters.", place.name] preferredStyle:UIAlertControllerStyleAlert];
    double current = isfinite(place.radius) && place.radius > 0 ? place.radius : PersistenceManager.shared.fluctuationRadius;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = LSFormatDecimal(current, 0);
        field.placeholder = @"meters";
        field.accessibilityLabel = @"Radius in meters";
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Set radius" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        if (number && number.doubleValue >= 1 && number.doubleValue <= 1000) [weakSelf setRadius:number.doubleValue forPlace:place];
        else [weakSelf showMessage:@"Enter a radius from 1 to 1,000 meters." symbol:@"exclamationmark.triangle.fill"];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)setRadius:(double)radius forPlace:(LSBookmark *)place {
    if (![BookmarksManager.shared setRadius:radius forBookmarkWithID:place.identifier]) {
        [self showMessage:@"The radius could not be saved." symbol:@"exclamationmark.triangle.fill"];
        return;
    }
    LSHapticSelection();
    self.savedPulseKey = [@"s|" stringByAppendingString:place.identifier];
    [self reloadSavedPlacesAnimated:YES];
    // Held right now: the new radius applies straight away.
    LSSessionSnapshot *snapshot = LSSessionController.shared.snapshot;
    if (snapshot.mode == LSSessionModeStatic && PersistenceManager.shared.hasStoredCoordinate) {
        CLLocationCoordinate2D held = PersistenceManager.shared.spoofCoordinate;
        if (LSSavedDistanceBetween(held, place.coordinate) < 5) [LSSessionController.shared applyStaticCoordinate:held radiusOverride:radius];
    }
    if (self.tab == LSPickerTabLocation && self.hasSelection) [self renderSelectedLocation];
    [self updateRadiusPreview];
    NSString *message = !isfinite(radius) ? @"This place now follows the Settings radius." : (radius > 0 ? [NSString stringWithFormat:@"This place now wanders within %@ m.", LSFormatDecimal(radius, 0)] : @"This place no longer wanders.");
    [self showMessage:message symbol:@"dot.radiowaves.left.and.right"];
}

#pragma mark - Saving and renaming

- (void)saveSelectedPlace { if (self.hasSelection) [self namePlace:self.selectedName coordinate:self.selectedCoordinate identifier:nil]; }
- (void)namePlace:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate identifier:(NSString *)identifier {
    [self namePlace:name coordinate:coordinate identifier:identifier allowDuplicate:NO];
}
- (void)namePlace:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate identifier:(NSString *)identifier allowDuplicate:(BOOL)allowDuplicate {
    if (!identifier && BookmarksManager.shared.allBookmarks.count >= BookmarksManager.capacity) {
        UIAlertController *limit = [UIAlertController alertControllerWithTitle:@"50 saved places maximum" message:@"Delete a saved place before adding another." preferredStyle:UIAlertControllerStyleAlert];
        [limit addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:limit animated:LSMapAnimationsEnabled() completion:nil];
        LSHapticWarning();
        return;
    }
    __weak typeof(self) weakSelf = self;
    LSBookmark *existing = identifier ? nil : [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
    if (existing && !allowDuplicate) {
        // Touch-and-hold twice on the same spot used to create silent duplicates.
        [self confirmAction:@"Already saved" message:[NSString stringWithFormat:@"This spot is saved as “%@”.", existing.name] button:@"Save another copy" action:^{
            [weakSelf namePlace:name coordinate:coordinate identifier:nil allowDuplicate:YES];
        }];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:identifier ? @"Rename place" : @"Save place" message:@"Choose a name from 1 to 120 characters." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = name;
        field.placeholder = @"Place name";
        field.accessibilityLabel = @"Place name";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        NSString *entered = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL saved = identifier ? [BookmarksManager.shared renameBookmarkWithID:identifier name:entered] : [BookmarksManager.shared addBookmarkWithName:entered coordinate:coordinate];
        if (saved) LSHapticSuccess(); else LSHapticWarning();
        [self showMessage:saved ? (identifier ? @"Place renamed." : @"Place saved.") : @"Could not save. Check the name and the 50-place limit."
                   symbol:saved ? @"bookmark.fill" : @"exclamationmark.triangle.fill"];
        NSString *savedID = identifier ?: BookmarksManager.shared.allBookmarks.firstObject.identifier;
        if (saved && savedID) self.savedPulseKey = [@"s|" stringByAppendingString:savedID];
        [self reloadSavedPlacesAnimated:YES];
        if (self.hasSelection && self.tab == LSPickerTabLocation) [self renderSelectedLocation];
    }];
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    save.enabled = trimmed.length > 0 && trimmed.length <= 120;
    __weak UIAlertAction *weakSave = save;
    [alert.textFields.firstObject addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        NSString *entered = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        weakSave.enabled = entered.length > 0 && entered.length <= 120;
        weakAlert.message = weakSave.enabled ? @"This name identifies your saved place." : @"Enter a name from 1 to 120 characters.";
    }] forControlEvents:UIControlEventEditingChanged];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

#pragma mark - Saved routes (#20)

- (nullable LSRouteArchive *)savedRouteAtPath:(NSIndexPath *)path {
    if (path.section != LSSavedRoutesSection || ![[self savedKeyAtPath:path] hasPrefix:@"t|"]) return nil;
    return path.row >= 0 && path.row < (NSInteger)self.savedRoutes.count ? self.savedRoutes[path.row] : nil;
}
- (NSString *)savedRouteKey:(LSRouteArchive *)route { return [@"t|" stringByAppendingString:route.identifier]; }
- (NSUInteger)savedRouteIndexOfID:(NSString *)identifier {
    NSArray<LSRouteArchive *> *routes = LSRouteStore.shared.allRoutes;
    return [routes indexOfObjectPassingTest:^BOOL(LSRouteArchive *route, __unused NSUInteger i, __unused BOOL *stop) { return [route.identifier isEqualToString:identifier]; }];
}
// "8.5 km · 2 stops · saved 3 days ago"
- (NSString *)savedRouteSummary:(LSRouteArchive *)route spoken:(BOOL)spoken {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (route.distance > 0) [parts addObject:LSSavedDistance(route.distance, spoken)];
    NSUInteger stops = route.plannedStopCount;
    if (stops) [parts addObject:stops == 1 ? @"1 stop" : [NSString stringWithFormat:@"%lu stops", (unsigned long)stops]];
    if (route.fromTrack) [parts addObject:spoken ? @"recorded track" : @"track"];
    else [parts addObject:[route.path isEqualToString:@"driving"] ? @"driving path" : @"walking path"];
    NSString *ago = LSSavedAgo(route.createdAt);
    [parts addObject:spoken ? [NSString stringWithFormat:@"saved %@", ago] : ago];
    NSString *text = [parts componentsJoinedByString:spoken ? @", " : @" · "];
    return LSSavedCapitalized(text);
}
- (NSString *)savedRouteEnds:(LSRouteArchive *)route rtl:(BOOL)rtl {
    return [NSString stringWithFormat:@"%@ %@ %@", route.places.firstObject.name, rtl ? @"←" : @"→", route.places.lastObject.name];
}
- (void)configureSavedRouteCell:(LSSavedRowCell *)cell route:(LSRouteArchive *)route key:(NSString *)key {
    NSString *symbol = route.fromTrack ? @"point.topleft.down.to.point.bottomright.curvepath" : ([route.path isEqualToString:@"driving"] ? @"car.fill" : @"figure.walk");
    [cell setBadgeSymbol:symbol color:LSRouteColor() muted:NO];
    NSString *filter = [self savedFilterText];
    [cell setTitle:route.name color:UIColor.labelColor match:LSSavedMatchRange(route.name, filter, YES)];
    cell.detailLabel.text = [self savedRouteSummary:route spoken:NO];
    cell.detailLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailLabel.hidden = NO;
    // Where it runs, in place of a place's coordinates.
    BOOL rtl = cell.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSString *ends = [self savedRouteEnds:route rtl:rtl];
    UIFont *font = LSFont(UIFontTextStyleCaption1, UIFontWeightRegular, 24);
    NSRange match = LSSavedMatchRange(ends, filter, YES);
    if (match.location == NSNotFound) {
        cell.coordinateLabel.font = font;
        cell.coordinateLabel.textColor = UIColor.secondaryLabelColor;
        cell.coordinateLabel.text = ends;
    } else {
        cell.coordinateLabel.attributedText = LSSavedHighlighted(ends, match, font, LSFont(UIFontTextStyleCaption1, UIFontWeightSemibold, 24));
    }
    cell.coordinateLabel.hidden = NO;
    cell.appliedPill.hidden = YES;
    cell.savedPill.hidden = YES;
    cell.moreButton.menu = [self menuForSavedRoute:route];
    cell.moreButton.accessibilityLabel = [NSString stringWithFormat:@"Actions for %@", route.name];
    cell.accessoryView = cell.moreButton;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.showsReorderControl = NO;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityLabel = route.name;
    cell.accessibilityValue = [NSString stringWithFormat:@"Route from %@ to %@. %@", route.places.firstObject.name, route.places.lastObject.name,
                               [self savedRouteSummary:route spoken:YES]];
    cell.accessibilityHint = @"Opens it in the Route planner.";
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    __weak typeof(self) weakSelf = self;
    UIAccessibilityCustomAction *(^make)(NSString *, dispatch_block_t) = ^UIAccessibilityCustomAction *(NSString *title, dispatch_block_t block) {
        return [[UIAccessibilityCustomAction alloc] initWithName:title actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) { block(); return YES; }];
    };
    cell.accessibilityCustomActions = @[
        make(@"Start route", ^{ [weakSelf openSavedRoute:route start:YES]; }),
        make(@"Rename", ^{ [weakSelf renameSavedRoute:route]; }),
        make(@"Share", ^{ [weakSelf shareSavedRoute:route]; }),
        make(@"Delete", ^{ [weakSelf deleteSavedRoute:route]; })
    ];
    (void)key;
}
- (UIMenu *)menuForSavedRoute:(LSRouteArchive *)route {
    __weak typeof(self) weakSelf = self;
    UIAction *start = [UIAction actionWithTitle:@"Start route" image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf openSavedRoute:route start:YES];
    }];
    UIAction *open = [UIAction actionWithTitle:@"Open in Route planner" image:[UIImage systemImageNamed:@"map"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf openSavedRoute:route start:NO];
    }];
    open.subtitle = @"As a draft, without starting it";
    UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf renameSavedRoute:route];
    }];
    UIAction *share = [UIAction actionWithTitle:@"Share…" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf shareSavedRoute:route];
    }];
    share.subtitle = route.fromTrack ? @"As a GPX file" : @"As an Apple Maps link";
    UIAction *remove = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf deleteSavedRoute:route];
    }];
    remove.attributes = UIMenuElementAttributesDestructive;
    UIMenu *primary = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[start, open]];
    UIMenu *edit = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[rename, share]];
    UIMenu *danger = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[remove]];
    return [UIMenu menuWithTitle:route.name children:@[primary, edit, danger]];
}
- (UISwipeActionsConfiguration *)savedRouteSwipeActions:(LSRouteArchive *)route leading:(BOOL)leading {
    __weak typeof(self) weakSelf = self;
    if (leading) {
        UIContextualAction *start = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Start" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            done(YES);
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openSavedRoute:route start:YES]; });
        }];
        start.image = [UIImage systemImageNamed:@"play.fill"];
        // Green, like Apply now on a place.
        start.backgroundColor = LSFillColor(LSSuccessColor());
        UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[start]];
        configuration.performsFirstActionWithFullSwipe = YES;
        return configuration;
    }
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
        [weakSelf deleteSavedRoute:route];
        done(YES);
    }];
    remove.image = [UIImage systemImageNamed:@"trash.fill"];
    remove.backgroundColor = LSFillColor(LSErrorColor());
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
        done(YES);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf renameSavedRoute:route]; });
    }];
    rename.image = [UIImage systemImageNamed:@"pencil"];
    rename.backgroundColor = LSFillColor(UIColor.systemGrayColor);
    // Full swipe deletes: Undo makes that safe.
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove, rename]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}
// The stored copy, which a rename may have changed since the row was built.
- (void)openSavedRoute:(LSRouteArchive *)route start:(BOOL)start {
    LSRouteArchive *current = [LSRouteStore.shared routeWithID:route.identifier] ?: route;
    [self.savedFilterField resignFirstResponder];
    if (!ls_savedTipDone) ls_savedTipDone = YES;
    LSHapticSelection();
    [self loadSavedRoute:current start:start];
}
- (void)renameSavedRoute:(LSRouteArchive *)route {
    LSRouteArchive *current = [LSRouteStore.shared routeWithID:route.identifier];
    if (!current) { [self reloadSavedPlacesAnimated:YES]; return; }
    __weak typeof(self) weakSelf = self;
    [self promptRouteName:current.name title:@"Rename route" button:@"Save" save:^BOOL(NSString *name) {
        typeof(self) self = weakSelf;
        BOOL renamed = [LSRouteStore.shared renameRouteWithID:current.identifier name:name];
        if (renamed) LSHapticSuccess(); else LSHapticWarning();
        [self showMessage:renamed ? @"Route renamed." : @"The route could not be renamed." symbol:renamed ? @"bookmark.fill" : @"exclamationmark.triangle.fill"];
        if (renamed) self.savedPulseKey = [self savedRouteKey:current];
        [self reloadSavedPlacesAnimated:YES];
        return renamed;
    }];
}
- (void)deleteSavedRoute:(LSRouteArchive *)route {
    NSUInteger index = [self savedRouteIndexOfID:route.identifier];
    LSRouteArchive *stored = [LSRouteStore.shared routeWithID:route.identifier];
    if (index == NSNotFound || !stored || ![LSRouteStore.shared removeRouteWithID:route.identifier]) { [self reloadSavedPlacesAnimated:YES]; return; }
    // Immediate, with Undo, as for places.
    LSHapticImpact(UIImpactFeedbackStyleMedium);
    [self reloadSavedPlacesAnimated:YES];
    __weak typeof(self) weakSelf = self;
    LSShowActionToast(self.view, [self savedToastAnchorView], [NSString stringWithFormat:@"Deleted “%@”", stored.name], @"trash.fill", @"Undo", ^{
        typeof(self) self = weakSelf;
        if (![LSRouteStore.shared insertRoute:stored atIndex:index]) {
            LSHapticWarning();
            [self showMessage:@"The route could not be restored." symbol:@"exclamationmark.triangle.fill"];
            return;
        }
        LSHapticSuccess();
        self.savedPulseKey = [self savedRouteKey:stored];
        [self reloadSavedPlacesAnimated:YES];
        if (self.tab == LSPickerTabRoute) [self updateRouteUI];
        LSAnnounce([NSString stringWithFormat:@"Restored %@.", stored.name]);
    });
    if (self.tab == LSPickerTabRoute) [self updateRouteUI];
}
// A planned route shares as an Apple Maps link through its places; a recorded track as GPX.
- (void)shareSavedRoute:(LSRouteArchive *)route {
    NSIndexPath *path = [self savedPathForKey:[self savedRouteKey:route]];
    UIView *source = (path ? [self.savedTable cellForRowAtIndexPath:path] : nil) ?: self.savedTable;
    if (!route.fromTrack) {
        NSMutableArray<LSMapLinkPlace *> *places = [NSMutableArray array];
        for (LSArchivedPlace *place in route.places) [places addObject:[LSMapLinkPlace placeWithLatitude:place.latitude longitude:place.longitude name:place.name]];
        // @available needs a compiler-rt helper the Linux toolchain doesn't ship.
        BOOL modernApple = [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){18, 4, 0}];
        NSURL *url = [LSMapLinks URLForApp:LSMapAppApple places:places mode:[route.path isEqualToString:@"driving"] ? @"driving" : @"walking"
                               legacyApple:!modernApple && places.count <= 2];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (LSArchivedPlace *place in route.places) [names addObject:place.name];
        NSString *text = [NSString stringWithFormat:@"%@: %@", route.name, [names componentsJoinedByString:@" → "]];
        [self presentShareItems:url ? @[text, url] : @[text] from:source];
        return;
    }
    LSRouteArchive *copy = [route copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger count = copy.pointCount;
        const double *values = copy.coordinates.bytes, *times = copy.times.bytes;
        double start = copy.recordedStartDate ? copy.recordedStartDate.timeIntervalSince1970 : NAN;
        NSMutableData *points = [NSMutableData dataWithLength:count * sizeof(LSTrackPoint)];
        LSTrackPoint *point = points.mutableBytes;
        for (NSUInteger index = 0; index < count; index++) {
            double time = times && isfinite(start) ? start + times[index] : NAN;
            point[index] = (LSTrackPoint){ time, values[2 * index], values[2 * index + 1], NAN, NAN, NAN };
        }
        NSString *activity = [copy.path isEqualToString:@"driving"] ? @"driving" : nil;
        NSData *data = count >= 2 ? [LSTrackIO GPXDataForPoints:points.bytes count:count name:copy.name activity:activity] : nil;
        NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"LSpoof Export"] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *file = [folder URLByAppendingPathComponent:[LSTrackIO safeFileName:copy.name extension:@"gpx"]];
        BOOL written = data && [data writeToURL:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.closed) return;
            if (!written) { LSHapticWarning(); [self showMessage:@"The route could not be exported." symbol:@"exclamationmark.triangle.fill"]; return; }
            [self presentShareItems:@[file] from:source];
        });
    });
}
@end
