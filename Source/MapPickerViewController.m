#import "MapPickerViewController+Private.h"
#import "LocationSpoofer.h"
#import "PersistenceManager.h"
#import "LSPlaceSearchController.h"
#import "LSSettingsViewController.h"
#import "LSCoordinateEntryController.h"
#import "LSScheduler.h"
#import "LSScheduleViewController.h"

@implementation LSStartAnnotation @end
@implementation LSDestinationAnnotation @end
@implementation LSStopAnnotation @end
@implementation LSMovingAnnotation @end
@implementation LSRealAnnotation @end

// Map style survives reopening the picker for the life of the host process.
static MKMapType ls_mapType = MKMapTypeStandard;
// The one-time map hint is remembered with the library's other preferences.
static NSString * const kLSDefaultsSuite = @"com.locationspoofer.dylib";
static NSString * const kLSLocationHintKey = @"ls.hint.location";
static NSString * const kLSLocationHint = @"Tap the map to drop a pin.\nTouch and hold to save it.";
// Gap between a floating surface and what it hugs, and the widest the floating column gets,
// so the header, card and footer stay a readable column in landscape and on iPad.
static const CGFloat kLSFloatGap = 10;
static const CGFloat kLSColumnWidth = 560;

typedef NS_ENUM(NSInteger, LSMapState) { LSMapStateReady, LSMapStateLoading, LSMapStateFailed };

static UIFont *LSMonoFont(UIFontTextStyle style, UIFontWeight weight, CGFloat maximum) {
    // Capped, unlike LSMonospacedFont: uncapped coordinates wrap into a column at the largest sizes.
    UITraitCollection *standard = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    CGFloat size = [UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:standard].pointSize;
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont monospacedSystemFontOfSize:size weight:weight] maximumPointSize:maximum];
}
static NSString *LSMapTypeName(MKMapType type) {
    return type == MKMapTypeHybrid ? @"Hybrid" : (type == MKMapTypeSatellite ? @"Satellite" : @"Standard");
}
static NSString *LSMapTypeSymbol(MKMapType type) {
    return type == MKMapTypeHybrid ? @"square.2.layers.3d" : (type == MKMapTypeSatellite ? @"globe.americas.fill" : @"map");
}
// A floating surface 12 pt in from the safe area, centred and at most one column wide. The edges
// are 999 so the column cap wins on wide screens; nothing inside can pull the surface narrower.
static NSArray<NSLayoutConstraint *> *LSColumnConstraints(UIView *view, UILayoutGuide *safe) {
    NSLayoutConstraint *leading = [view.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12];
    NSLayoutConstraint *trailing = [view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12];
    leading.priority = 999;
    trailing.priority = 999;
    return @[leading, trailing,
             [view.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
             [view.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
             [view.widthAnchor constraintLessThanOrEqualToConstant:kLSColumnWidth]];
}
static void LSSetConstant(NSLayoutConstraint *constraint, CGFloat value) {
    // Layout callbacks run often; touching only changed constants keeps them from looping.
    if (constraint && fabs(constraint.constant - value) > 0.5) constraint.constant = value;
}
// Metres between two nearby points; plain arithmetic, cheap enough for every refresh.
static double LSApproximateDistance(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    double north = (a.latitude - b.latitude) * 111320.0;
    double east = (a.longitude - b.longitude) * 111320.0 * cos(a.latitude * M_PI / 180.0);
    return sqrt(north * north + east * east);
}
static NSString *LSPlacemarkName(CLPlacemark *placemark) {
    NSString *name = placemark.name.length ? placemark.name : placemark.thoroughfare;
    NSString *area = placemark.locality.length ? placemark.locality : placemark.administrativeArea;
    if (!name.length) return area;
    if (area.length && [name rangeOfString:area].location == NSNotFound) return [NSString stringWithFormat:@"%@, %@", name, area];
    return name;
}
// Round 44 pt glyph button for use inside a glass surface, which already supplies the material.
static UIButton *LSPlainIconButton(NSString *symbol, NSString *label, UIColor *tint, UIColor *fill) {
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.image = [UIImage systemImageNamed:symbol];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    config.baseForegroundColor = tint;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
    UIBackgroundConfiguration *background = UIBackgroundConfiguration.clearConfiguration;
    background.backgroundColor = fill ?: UIColor.clearColor;
    background.cornerRadius = 22;
    config.background = background;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = label;
    button.largeContentTitle = label;
    button.showsLargeContentViewer = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    // Below required: these sit in stacks, which collapse hidden views with required constraints.
    NSLayoutConstraint *width = [button.widthAnchor constraintEqualToConstant:44];
    NSLayoutConstraint *height = [button.heightAnchor constraintEqualToConstant:44];
    width.priority = 999; height.priority = 999;
    [NSLayoutConstraint activateConstraints:@[width, height]];
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}
// Place card action: a symbol over a short caption on a quiet rounded tile, like the actions on
// a place in Maps. The tiles share their row equally, so they never scroll or clip.
static UIButton *LSPlaceAction(NSString *title, NSString *symbol) {
    UIButtonConfiguration *config = UIButtonConfiguration.grayButtonConfiguration;
    config.title = title;
    config.image = [UIImage systemImageNamed:symbol];
    config.imagePlacement = NSDirectionalRectEdgeTop;
    config.imagePadding = 4;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleMedium];
    config.baseForegroundColor = LSAccentTextColor();
    config.baseBackgroundColor = UIColor.tertiarySystemFillColor;
    config.titleLineBreakMode = NSLineBreakByTruncatingTail;
    config.contentInsets = NSDirectionalEdgeInsetsMake(10, 2, 9, 2);
    config.cornerStyle = UIButtonConfigurationCornerStyleFixed;
    UIBackgroundConfiguration *background = config.background;
    background.cornerRadius = 14;
    config.background = background;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleCaption1, UIFontWeightSemibold, 24);
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.largeContentTitle = title;
    button.showsLargeContentViewer = YES;
    button.scalesLargeContentImage = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    NSLayoutConstraint *height = [button.heightAnchor constraintGreaterThanOrEqualToConstant:56];
    height.priority = 999; // A hidden tile collapses without a conflict.
    height.active = YES;
    LSAddPressFeedback(button);
    return button;
}
static UIView *LSClusterSeparator(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = UIColor.separatorColor;
    NSLayoutConstraint *height = [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale];
    height.priority = 999;
    [NSLayoutConstraint activateConstraints:@[height, [line.widthAnchor constraintEqualToConstant:26]]];
    return line;
}
// Concentric corners: a control inset inside a rounded surface uses the outer radius minus the inset.
static void LSSetButtonRadius(UIButton *button, CGFloat radius) {
    UIButtonConfiguration *config = button.configuration;
    config.cornerStyle = UIButtonConfigurationCornerStyleFixed;
    UIBackgroundConfiguration *background = config.background;
    background.cornerRadius = radius;
    config.background = background;
    button.configuration = config;
}

// Reports its layout so the map's margins can follow the floating surfaces.
@interface LSMapContainerView : UIView
@property (nonatomic, copy) dispatch_block_t didLayout;
@end
@implementation LSMapContainerView
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.didLayout) self.didLayout();
}
@end

// Context menu for a view whose actions depend on state at the moment of the long press.
@interface LSMenuInteractionHandler : NSObject <UIContextMenuInteractionDelegate>
@property (nonatomic, copy) UIMenu *(^menuProvider)(void);
@end
@implementation LSMenuInteractionHandler
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    (void)interaction; (void)location;
    UIMenu *menu = self.menuProvider ? self.menuProvider() : nil;
    if (!menu) return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
        return menu;
    }];
}
@end

// Thin capsule under the header that fills as a route plays. Each 4 Hz refresh glides the fill
// linearly to the new value, so it moves continuously instead of stepping.
@interface LSProgressCapsule : UIView
@property (nonatomic, strong) UIColor *fillColor;
@property (nonatomic, readonly) double progress;
- (void)setProgress:(double)progress animated:(BOOL)animated;
@end
@implementation LSProgressCapsule {
    CALayer *_fill;
    CGSize _laidOutSize;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
        // The faint fill nearly vanishes over light glass; Increase Contrast gets a solid track.
        self.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.accessibilityContrast == UIAccessibilityContrastHigh ? UIColor.systemGray3Color : UIColor.tertiarySystemFillColor;
        }];
        self.layer.masksToBounds = YES;
        _fill = [CALayer layer];
        _fill.anchorPoint = CGPointMake(0, 0.5);
        [self.layer addSublayer:_fill];
        _fillColor = LSAccentColor();
        [self resolveFill];
    }
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 3); }
- (void)resolveFill {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.backgroundColor = [_fillColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    [CATransaction commit];
}
- (void)setFillColor:(UIColor *)fillColor {
    _fillColor = fillColor ?: LSAccentColor();
    [self resolveFill];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self resolveFill];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    // Text beside it changes every tick; only a real size change may cut a glide short.
    if (CGSizeEqualToSize(bounds.size, _laidOutSize)) return;
    _laidOutSize = bounds.size;
    self.layer.cornerRadius = bounds.size.height / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_fill removeAnimationForKey:@"glide"];
    _fill.cornerRadius = bounds.size.height / 2;
    _fill.position = CGPointMake(0, CGRectGetMidY(bounds));
    _fill.bounds = CGRectMake(0, 0, bounds.size.width * _progress, bounds.size.height);
    [CATransaction commit];
}
- (void)setProgress:(double)progress animated:(BOOL)animated {
    progress = MIN(1, MAX(0, isfinite(progress) ? progress : 0));
    if (fabs(progress - _progress) < 0.0005) return;
    _progress = progress;
    CGRect bounds = self.bounds;
    CGFloat from = ((CALayer *)_fill.presentationLayer ?: _fill).bounds.size.width;
    CGFloat to = bounds.size.width * progress;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.bounds = CGRectMake(0, 0, to, bounds.size.height);
    // Small steps glide; a jump (seek, replay, restart) snaps.
    if (animated && self.window && LSMapAnimationsEnabled() && fabs(to - from) < bounds.size.width * 0.2) {
        CABasicAnimation *glide = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        glide.fromValue = @(from);
        glide.toValue = @(to);
        glide.duration = 0.25;
        glide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [_fill addAnimation:glide forKey:@"glide"];
    } else {
        [_fill removeAnimationForKey:@"glide"];
    }
    [CATransaction commit];
}
@end

// The applied spot and the real location are drawn as location dots rather than pins, so they
// read as "where the app thinks you are" instead of as places you picked. The applied dot keeps
// a soft pulse while a session is live, and its arrow follows the route heading.
@interface LSPuckView : MKAnnotationView
- (void)configureWithColor:(UIColor *)color symbol:(NSString *)symbol diameter:(CGFloat)diameter pulsing:(BOOL)pulsing;
- (void)setGlyphRotation:(CGFloat)radians;
- (void)ripple;
@end
@implementation LSPuckView {
    UIView *_halo;
    UIView *_dot;
    UIImageView *_glyph;
    UIColor *_color;
    NSString *_symbol;
    CGFloat _diameter;
    CGFloat _rotation;
    BOOL _pulsing;
}
- (instancetype)initWithAnnotation:(id<MKAnnotation>)annotation reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithAnnotation:annotation reuseIdentifier:reuseIdentifier])) {
        _diameter = 22;
        self.frame = CGRectMake(0, 0, _diameter, _diameter);
        _halo = [[UIView alloc] init];
        _halo.userInteractionEnabled = NO;
        _halo.alpha = 0;
        _dot = [[UIView alloc] init];
        _dot.userInteractionEnabled = NO;
        _dot.layer.borderColor = UIColor.whiteColor.CGColor;
        _dot.layer.borderWidth = 3;
        _dot.layer.shadowColor = UIColor.blackColor.CGColor;
        _dot.layer.shadowOpacity = 0.3;
        _dot.layer.shadowRadius = 3;
        _dot.layer.shadowOffset = CGSizeMake(0, 1);
        _glyph = [[UIImageView alloc] init];
        _glyph.tintColor = UIColor.whiteColor;
        _glyph.contentMode = UIViewContentModeCenter;
        [self addSubview:_halo];
        [self addSubview:_dot];
        [_dot addSubview:_glyph];
        self.isAccessibilityElement = YES;
    }
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    [_halo.layer removeAllAnimations];
    _color = nil;
    _symbol = nil;
    _rotation = 0;
    _glyph.transform = CGAffineTransformIdentity;
    _dot.transform = CGAffineTransformIdentity;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // Bounds and center, not frame: the halo and glyph carry transforms.
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGRect dot = CGRectMake(0, 0, _diameter, _diameter);
    _dot.bounds = dot;
    _dot.center = center;
    _dot.layer.cornerRadius = _diameter / 2;
    _dot.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:dot].CGPath;
    _halo.bounds = dot;
    _halo.center = center;
    _halo.layer.cornerRadius = _diameter / 2;
    _glyph.bounds = dot;
    _glyph.center = CGPointMake(_diameter / 2, _diameter / 2);
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updatePulse];
}
- (void)configureWithColor:(UIColor *)color symbol:(NSString *)symbol diameter:(CGFloat)diameter pulsing:(BOOL)pulsing {
    // Called on every playback refresh, so only changed parts are touched. Callers pass the same
    // colour object while nothing changes, which skips resolving it.
    if (color != _color && (!_color || ![[_color resolvedColorWithTraitCollection:self.traitCollection] isEqual:[color resolvedColorWithTraitCollection:self.traitCollection]])) {
        _color = color;
        _dot.backgroundColor = color;
        _halo.backgroundColor = [color colorWithAlphaComponent:0.35];
    }
    BOOL sameSymbol = (!symbol && !_symbol) || [symbol isEqualToString:_symbol];
    if (!sameSymbol || diameter != _diameter) {
        _symbol = [symbol copy];
        UIImageSymbolConfiguration *weight = [UIImageSymbolConfiguration configurationWithPointSize:round(diameter * 0.45) weight:UIImageSymbolWeightBold];
        _glyph.image = symbol ? [UIImage systemImageNamed:symbol withConfiguration:weight] : nil;
    }
    if (diameter != _diameter) {
        _diameter = diameter;
        self.bounds = CGRectMake(0, 0, diameter, diameter);
        [self setNeedsLayout];
    }
    _pulsing = pulsing;
    [self updatePulse];
}
- (void)updatePulse {
    CALayer *layer = _halo.layer;
    BOOL animate = _pulsing && self.window && LSMapAnimationsEnabled();
    if (!animate) {
        [layer removeAnimationForKey:@"pulse"];
        // With Reduce Motion a still halo keeps the "live" cue.
        _halo.alpha = _pulsing ? 1 : 0;
        _halo.transform = _pulsing ? CGAffineTransformMakeScale(1.8, 1.8) : CGAffineTransformIdentity;
        return;
    }
    _halo.alpha = 1;
    _halo.transform = CGAffineTransformIdentity;
    // Self-healing: the system drops animations in the background, and refreshes re-add them.
    if ([layer animationForKey:@"pulse"]) return;
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1.0;
    scale.toValue = @3.0;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.9;
    fade.toValue = @0.0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scale, fade];
    group.duration = 2.2;
    group.repeatCount = HUGE_VALF;
    group.removedOnCompletion = NO;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:group forKey:@"pulse"];
}
- (void)setGlyphRotation:(CGFloat)radians {
    if (fabs(radians - _rotation) < 0.01) return;
    _rotation = radians;
    UIImageView *glyph = _glyph;
    CGAffineTransform turn = CGAffineTransformMakeRotation(radians);
    if (!LSMapAnimationsEnabled()) { glyph.transform = turn; return; }
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveLinear
                     animations:^{ glyph.transform = turn; } completion:nil];
}
- (void)ripple {
    if (!self.window || !LSMapAnimationsEnabled()) return;
    CALayer *ring = [CALayer layer];
    ring.bounds = CGRectMake(0, 0, _diameter, _diameter);
    ring.position = _dot.center;
    ring.cornerRadius = _diameter / 2;
    ring.borderWidth = 2.5;
    ring.borderColor = [(_color ?: UIColor.systemBlueColor) resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    [self.layer insertSublayer:ring below:_dot.layer];
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1.0;
    scale.toValue = @5.0;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0;
    fade.toValue = @0.0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scale, fade];
    group.duration = 0.9;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [ring removeFromSuperlayer]; }];
    [ring addAnimation:group forKey:@"ripple"];
    [CATransaction commit];
    UIView *dot = _dot;
    dot.transform = CGAffineTransformMakeScale(0.6, 0.6);
    LSAnimateBouncy(^{ dot.transform = CGAffineTransformIdentity; }, nil);
}
@end

@interface MapPickerViewController () <MKMapViewDelegate, CLLocationManagerDelegate, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *chromeView;
@property (nonatomic, strong) UIStackView *statusStack;
@property (nonatomic, strong) UIView *footerView;
@property (nonatomic, strong) UIStackView *panelsStack;
@property (nonatomic, strong) UIView *mapControls;
@property (nonatomic, strong) UIView *realSeparator;
@property (nonatomic, strong) MKCompassButton *compassButton;
@property (nonatomic, strong) UIView *mapHintView;
@property (nonatomic, strong) UIView *mapStateView;
@property (nonatomic, strong) UIImageView *mapStateIcon;
@property (nonatomic, strong) UILabel *mapStateTitle;
@property (nonatomic, strong) UIActivityIndicatorView *mapStateSpinner;
@property (nonatomic, strong) NSLayoutConstraint *mapGuideTop;
@property (nonatomic, strong) NSLayoutConstraint *mapGuideToCard;
@property (nonatomic, strong) NSLayoutConstraint *mapGuideToBottom;
@property (nonatomic, strong) NSLayoutConstraint *mapMinimumVisible;
@property (nonatomic, strong) NSLayoutConstraint *cardBottom;
@property (nonatomic, strong) NSLayoutConstraint *savedBottom;
@property (nonatomic, strong) NSLayoutConstraint *scrollTop;
@property (nonatomic, strong) NSLayoutConstraint *scrollBottom;
// Landscape on a phone: the header, the place card, the planner and Saved share a side panel on
// the leading edge, the map fills the rest and the footer floats at its bottom.
@property (nonatomic) BOOL sideLayout;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *columnLayout;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *sideConstraints;
@property (nonatomic, strong) NSLayoutConstraint *sideWidth;
@property (nonatomic, strong) NSLayoutConstraint *sideGuideBottom;
@property (nonatomic, strong) UILayoutGuide *sideGuide;
@property (nonatomic, strong) UIScrollView *sideScroll;
@property (nonatomic, strong) UIStackView *sideStack;
@property (nonatomic, strong) UIStackView *statusLine;
@property (nonatomic, strong) UIStackView *placeStatusRow;
@property (nonatomic, strong) UIImageView *placeStatusIcon;
@property (nonatomic, strong) UILabel *placeStatusLabel;
@property (nonatomic, weak) UITapGestureRecognizer *mapDoubleTap;
@property (nonatomic, strong) NSHashTable<MKOverlayRenderer *> *defaultRenderers;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, copy) NSString *appliedName;
@property (nonatomic) CLLocationCoordinate2D appliedNameCoordinate;
@property (nonatomic, copy) NSString *footerKey;
@property (nonatomic) NSInteger statusMode;
@property (nonatomic) BOOL locationHintDone;
@property (nonatomic) BOOL didInitialMapFit;
@property (nonatomic) BOOL placeApplied;
@property (nonatomic) BOOL pendingApplyRipple;
@property (nonatomic) BOOL savedHeaderDirty;
@property (nonatomic) CGFloat savedHeaderWidth;
@property (nonatomic) NSUInteger copyRevision;
@property (nonatomic, strong) UIStackView *footerPrimaryRow;
@property (nonatomic, weak) NSLayoutConstraint *scheduleButtonHeight;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIColor *> *puckColors;
@property (nonatomic, copy) NSString *geocodedName;
@property (nonatomic, strong) LSProgressCapsule *statusProgress;
@property (nonatomic) NSInteger statusDetailKind;
@property (nonatomic) BOOL footerShown;
@property (nonatomic) BOOL scheduleDotShown;
@property (nonatomic) NSInteger scheduleActiveState;
@property (nonatomic, strong) LSMenuInteractionHandler *heldMenu;
@property (nonatomic) CLLocationCoordinate2D geocodedCoordinate;
@end

@implementation MapPickerViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.view.tintColor = LSAccentColor();
    self.title = @"LSpoof";
    self.statusMode = -1;
    self.defaultRenderers = [NSHashTable weakObjectsHashTable];
    self.puckColors = [NSMutableDictionary dictionary];
    self.scheduleActiveState = -1;
    self.geocodedCoordinate = kCLLocationCoordinate2DInvalid;
    self.locationHintDone = [[[NSUserDefaults alloc] initWithSuiteName:kLSDefaultsSuite] boolForKey:kLSLocationHintKey];
    self.selectedCoordinate = kCLLocationCoordinate2DInvalid;
    self.selectedName = @"Selected location";
    self.tab = LSPickerTabLocation;
    self.previousMode = LSSessionController.shared.snapshot.mode;
    PersistenceManager *store = PersistenceManager.shared;
    if (store.hasStoredCoordinate) {
        self.selectedCoordinate = store.spoofCoordinate;
        self.hasSelection = YES;
        // The spot's own name (a saved place or a recent), so the card and the header agree.
        NSString *known = [self appliedPlaceName];
        BOOL named = known.length && ![known isEqualToString:@"Applied location"];
        self.selectedName = named ? known : (store.isSpoofingEnabled ? @"Applied location" : @"Last selection");
    }
    [self buildInterface];
    [self restoreRoute];
    [self updateWorkspace];
    [self refreshSession];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionChanged:) name:LSSessionDidChangeNotification object:LSSessionController.shared];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(activated:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentSizeChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneDeactivated:) name:UISceneWillDeactivateNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneActivated:) name:UISceneDidActivateNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleChanged:) name:LSSchedulerDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(differentiateWithoutColorChanged:) name:UIAccessibilityShouldDifferentiateWithoutColorDidChangeNotification object:nil];
    [self updateScheduleBanner];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Fit the map before the sheet slides in; restoreRoute ran while the map had no size.
    [self.view layoutIfNeeded];
    [self performInitialMapFit];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self performInitialMapFit];
    [self refreshSession];
    [self updateRealLocation];
    [self showScheduleNotice];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed || !self.presentingViewController) {
        [self endPickerLifetime];
        if (self.didDismiss) { self.didDismiss(); self.didDismiss = nil; }
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Measuring the Saved header sizes its text; skip it while that tab is off screen.
    CGFloat width = self.savedTable.bounds.size.width;
    if (fabs(width - self.savedHeaderWidth) > 0.5 || (self.savedHeaderDirty && self.tab == LSPickerTabSaved)) {
        self.savedHeaderWidth = width;
        self.savedHeaderDirty = NO;
        [self layoutSavedHeader];
    }
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    UILayoutConstraintAxis playback = self.view.bounds.size.height >= 600 && large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    if (self.playbackRow.axis != playback) self.playbackRow.axis = playback;
    UILayoutConstraintAxis speeds = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    if (self.speedRow.axis != speeds) self.speedRow.axis = speeds;
    [self layoutPlaceActions:large];
    [self layoutFloatingSurfaces];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_directions cancel];
    [_geocoder cancelGeocode];
    [_realManager stopUpdatingLocation];
    _mapView.delegate = nil;
}
- (void)endPickerLifetime {
    if (self.closed) return;
    self.closed = YES;
    self.selectionRevision++;
    [self cancelDirections];
    [self.geocoder cancelGeocode];
    self.realRevision++;
    [self.realManager stopUpdatingLocation];
}
- (void)backgrounded:(NSNotification *)note {
    (void)note;
    // The selection revision is deliberately left alone: a brief interruption such as
    // Control Center used to make the next search or coordinate choice silently vanish.
    BOOL fetching = self.directions != nil;
    [self cancelDirections];
    if (fetching) { self.routeFeedback.text = @"Route lookup paused. Tap Build route to try again."; [self updateRouteUI]; }
    self.realRevision++;
    [self.realManager stopUpdatingLocation];
}
- (void)activated:(NSNotification *)note {
    (void)note;
    if (!self.closed && self.view.window) { [self refreshSession]; [self updateRealLocation]; [self updateScheduleBanner]; [self showScheduleNotice]; }
}
- (void)sceneDeactivated:(NSNotification *)note { if (note.object == self.view.window.windowScene) [self backgrounded:note]; }
- (void)sceneActivated:(NSNotification *)note { if (note.object == self.view.window.windowScene) [self activated:note]; }
- (void)contentSizeChanged:(NSNotification *)note {
    (void)note;
    UIFont *font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 20);
    NSMutableArray<UISegmentedControl *> *segments = [NSMutableArray arrayWithObject:self.tabs];
    if (self.profileSegment) [segments addObject:self.profileSegment];
    if (self.endpointSegment) [segments addObject:self.endpointSegment];
    for (UISegmentedControl *segment in segments) {
        [segment setTitleTextAttributes:@{NSFontAttributeName:font} forState:UIControlStateNormal];
    }
    [self.savedTable reloadData];
    [self refreshButtonFonts:self.view];
    [self applyTextSizeLayout];
    self.savedHeaderDirty = YES;
    [self.view setNeedsLayout];
}
- (void)applyTextSizeLayout {
    // At accessibility sizes text wraps instead of shrinking or truncating.
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.brandLabel.numberOfLines = large ? 0 : 1;
    [self applyStatusLineLayout];
    self.appliedLabel.numberOfLines = large ? 0 : 1;
    self.appliedLabel.adjustsFontSizeToFitWidth = !large;
    self.placeLabel.numberOfLines = large ? 0 : 3;
    // The schedule button gets its word back and its own full-width row, so Apply keeps its width.
    UIStackView *row = self.footerPrimaryRow;
    row.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    row.alignment = large ? UIStackViewAlignmentFill : UIStackViewAlignmentCenter;
    // Required hugging would fight the full-width fill.
    [self.scheduleButton setContentHuggingPriority:large ? UILayoutPriorityDefaultLow : UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.scheduleButtonHeight.priority = large ? UILayoutPriorityDefaultLow : 999;
    UIButtonConfiguration *clock = self.scheduleButton.configuration;
    clock.title = large ? @"Schedule" : nil;
    self.scheduleButton.configuration = clock;
}
- (void)refreshButtonFonts:(UIView *)view {
    if ([view isKindOfClass:UIButton.class]) [(UIButton *)view setNeedsUpdateConfiguration];
    for (UIView *child in view.subviews) [self refreshButtonFonts:child];
}

#pragma mark - Layout

- (UIView *)buildChrome {
    // What is happening now leads: status capsule and the applied place in large type. A playing
    // route adds its progress line and bar. No branding competes with it.
    self.statusChip = [[LSStatusChip alloc] init];
    [self.statusChip setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.statusChip setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.brandLabel = LSLabel(@"", UIFontTextStyleTitle3);
    self.brandLabel.font = LSFont(UIFontTextStyleTitle3, UIFontWeightBold, 30);
    self.brandLabel.numberOfLines = 1;
    self.appliedLabel = LSLabel(@"", UIFontTextStyleFootnote);
    self.appliedLabel.font = LSNumberFont(UIFontTextStyleFootnote, UIFontWeightMedium, 22);
    self.appliedLabel.textColor = UIColor.secondaryLabelColor;
    self.appliedLabel.numberOfLines = 1;
    self.appliedLabel.adjustsFontSizeToFitWidth = YES;
    self.appliedLabel.minimumScaleFactor = 0.75;
    self.appliedLabel.hidden = YES;
    // The held spot's name copies its coordinates with a long press (VoiceOver: a custom action).
    self.heldMenu = [[LSMenuInteractionHandler alloc] init];
    __weak typeof(self) weakSelf = self;
    self.heldMenu.menuProvider = ^UIMenu *{
        typeof(self) self = weakSelf;
        if (!self || LSSessionController.shared.snapshot.mode != LSSessionModeStatic || !PersistenceManager.shared.hasStoredCoordinate) return nil;
        UIAction *copy = [UIAction actionWithTitle:@"Copy coordinates" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf copyHeldCoordinates];
        }];
        return [UIMenu menuWithTitle:@"" children:@[copy]];
    };
    self.brandLabel.userInteractionEnabled = YES;
    [self.brandLabel addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self.heldMenu]];
    self.statusProgress = [[LSProgressCapsule alloc] initWithFrame:CGRectZero];
    self.statusProgress.hidden = YES;
    [self.brandLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    // Capsule above the name; side by side in the landscape side panel (applyStatusLineLayout).
    self.statusLine = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusChip, self.brandLabel]];
    self.statusLine.axis = UILayoutConstraintAxisVertical;
    self.statusLine.alignment = UIStackViewAlignmentLeading;
    self.statusLine.spacing = 6;
    self.statusStack = LSStack(@[self.statusLine, self.appliedLabel, self.statusProgress], 2);
    [self.statusStack setCustomSpacing:6 afterView:self.appliedLabel];
    self.statusStack.isAccessibilityElement = YES;
    [self.statusStack setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.statusStack setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIButton *settings = LSPlainIconButton(@"gearshape.fill", @"Settings", UIColor.secondaryLabelColor, UIColor.tertiarySystemFillColor);
    settings.accessibilityUserInputLabels = @[@"Settings"];
    LSAddPressFeedback(settings);
    [settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    UIButton *close = LSPlainIconButton(@"xmark", @"Close picker", UIColor.secondaryLabelColor, UIColor.tertiarySystemFillColor);
    close.accessibilityUserInputLabels = @[@"Close", @"Close picker"];
    close.accessibilityHint = @"Discards unapplied location or route edits. An applied session continues.";
    LSAddPressFeedback(close);
    [close addTarget:self action:@selector(dismissPicker) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = LSRow(@[settings, close], 8);
    UIStackView *header = LSRow(@[self.statusStack, buttons], 10);
    header.alignment = UIStackViewAlignmentTop;
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"Location", @"Route", @"Saved"]];
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabs.selectedSegmentIndex = 0;
    self.tabs.accessibilityLabel = @"Workspace";
    [self.tabs.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *stack = LSStack(@[header, self.tabs], 12);
    UIView *chrome = LSGlassPanel(stack, LSRadiusL, 14);
    chrome.translatesAutoresizingMaskIntoConstraints = NO;
    self.chromeView = chrome;
    return chrome;
}
- (void)buildInterface {
    self.columnLayout = [NSMutableArray array];
    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // The map runs under the floating header and footer; insets follow them by hand.
    self.scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:self.scroll];
    [self buildRouteUI];
    [self buildMap];
    [self buildLocationDetails];
    self.panelsStack = LSStack(@[self.routeEndpointsPanel, self.routeDetailsPanel], 14);
    self.panelsStack.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14, 0, 24, 0);
    self.panelsStack.layoutMarginsRelativeArrangement = YES;
    // Fill, not centre: every card spans the column. The column's side margins (zero on
    // Location, where the map runs edge to edge) are set in layoutFloatingSurfaces. A centred
    // stack sized the cards by their content and squeezed them into a narrow strip.
    self.contentStack = LSStack(@[self.mapContainer, self.panelsStack], 0);
    self.contentStack.layoutMarginsRelativeArrangement = YES;
    self.contentStack.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
    [self.scroll addSubview:self.contentStack];
    [self buildSavedUI];
    self.savedTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.savedTable];
    UIView *chrome = [self buildChrome];
    [self.view addSubview:chrome];
    [self buildFooter];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.savedBottom = [self.savedTable.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    // Location: the map runs under the floating header and footer. Route: the content scrolls
    // between them and never shows behind or around them (constants set with the layout).
    self.scrollTop = [self.scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    self.scrollBottom = [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    NSArray<NSLayoutConstraint *> *savedColumn = @[
        [self.savedTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.savedTable.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor]
    ];
    [self.columnLayout addObjectsFromArray:LSColumnConstraints(chrome, safe)];
    [self.columnLayout addObjectsFromArray:savedColumn];
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:self.columnLayout];
    [constraints addObjectsFromArray:@[
        [chrome.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        self.scrollTop, self.scrollBottom,
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor],
        [self.savedTable.topAnchor constraintEqualToAnchor:chrome.bottomAnchor constant:6],
        self.savedBottom
    ]];
    [NSLayoutConstraint activateConstraints:constraints];
    // The overlays pin to the view's safe area, so the map has to be in the hierarchy first.
    [self installMapOverlays];
    [self installSideLayout];
    [self contentSizeChanged:nil];
}
// The landscape side panel: a guide under the header, a scroll view for the planner, and the
// constraints that replace the centred column. They are only active in that layout.
- (void)installSideLayout {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UIView *chrome = self.chromeView;
    UILayoutGuide *side = [[UILayoutGuide alloc] init];
    [self.view addLayoutGuide:side];
    self.sideGuide = side;
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hidden = YES;
    scroll.alwaysBounceVertical = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // A solid sheet behind the planner cards, as on the Route tab in portrait.
    scroll.backgroundColor = UIColor.systemGroupedBackgroundColor;
    scroll.layer.cornerRadius = LSRadiusL;
    scroll.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view insertSubview:scroll aboveSubview:self.scroll];
    UIStackView *stack = LSStack(@[], 0);
    [scroll addSubview:stack];
    self.sideScroll = scroll;
    self.sideStack = stack;
    self.sideGuideBottom = [side.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12];
    [NSLayoutConstraint activateConstraints:@[
        [side.topAnchor constraintEqualToAnchor:chrome.bottomAnchor constant:kLSFloatGap],
        [side.leadingAnchor constraintEqualToAnchor:chrome.leadingAnchor],
        [side.trailingAnchor constraintEqualToAnchor:chrome.trailingAnchor],
        self.sideGuideBottom,
        [scroll.topAnchor constraintEqualToAnchor:side.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:side.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    self.sideWidth = [chrome.widthAnchor constraintEqualToConstant:360];
    self.sideConstraints = @[
        [chrome.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        self.sideWidth,
        // The footer floats over the map at the bottom, beside the panel.
        [self.footerView.leadingAnchor constraintEqualToAnchor:chrome.trailingAnchor constant:12],
        [self.footerView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        // The place card sits under the header and scrolls inside itself when it is taller.
        [self.locationDetails.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [self.locationDetails.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [self.locationDetails.topAnchor constraintEqualToAnchor:side.topAnchor],
        [self.locationDetails.bottomAnchor constraintLessThanOrEqualToAnchor:side.bottomAnchor],
        [self.savedTable.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [self.savedTable.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        // Map controls, hints and centring use the map beside the panel.
        [self.mapVisibleGuide.leadingAnchor constraintGreaterThanOrEqualToAnchor:chrome.trailingAnchor constant:12]
    ];
}
- (void)applySideLayout:(BOOL)side {
    if (!self.sideConstraints) return;
    self.sideLayout = side;
    // Off first, so the two layouts never fight for a moment. The map stops ending at the place
    // card before the card moves into the panel.
    if (side) [self setMapGuideForLocation:NO];
    if (side) {
        [NSLayoutConstraint deactivateConstraints:self.columnLayout];
        [NSLayoutConstraint activateConstraints:self.sideConstraints];
    } else {
        [NSLayoutConstraint deactivateConstraints:self.sideConstraints];
        [NSLayoutConstraint activateConstraints:self.columnLayout];
    }
    // The planner moves into the panel and back; the map stays where it is.
    UIStackView *home = side ? self.sideStack : self.contentStack;
    if (self.panelsStack.superview != home) {
        [self.panelsStack removeFromSuperview];
        [home addArrangedSubview:self.panelsStack];
    }
    self.panelsStack.directionalLayoutMargins = side ? NSDirectionalEdgeInsetsMake(12, 12, 12, 12) : NSDirectionalEdgeInsetsMake(14, 0, 24, 0);
    [self applyStatusLineLayout];
    [self applyWorkspaceLayout];
}
- (void)applyStatusLineLayout {
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    BOOL inlined = self.sideLayout && !large;
    self.statusLine.axis = inlined ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    self.statusLine.alignment = inlined ? UIStackViewAlignmentCenter : UIStackViewAlignmentLeading;
    self.statusLine.spacing = inlined ? 8 : 6;
}
- (void)buildFooter {
    self.primaryButton = LSButton(@"Apply location", @"checkmark.circle.fill", YES);
    [self.primaryButton addTarget:self action:@selector(primaryAction) forControlEvents:UIControlEventTouchUpInside];
    self.holdButton = LSButton(@"Hold here", @"stop.fill", NO);
    self.holdButton.accessibilityHint = @"Stops route movement and holds its current point.";
    [self.holdButton addTarget:self action:@selector(routeControlTapped) forControlEvents:UIControlEventTouchUpInside];
    self.offButton = LSButton(@"Turn off", @"power", NO);
    self.offButton.accessibilityLabel = @"Turn off spoofing";
    self.offButton.accessibilityUserInputLabels = @[@"Turn off", @"Turn off spoofing"];
    self.offButton.accessibilityHint = @"The app gets its real location again.";
    UIButtonConfiguration *off = self.offButton.configuration;
    off.baseForegroundColor = LSErrorColor();
    off.baseBackgroundColor = LSErrorColor();
    self.offButton.configuration = off;
    [self.offButton addTarget:self action:@selector(turnOff) forControlEvents:UIControlEventTouchUpInside];
    // Footer buttons keep the system capsule shape (Liquid Glass buttons are capsules); the
    // footer's corner is the 26 pt capsule radius plus its 12 pt inset, so the shapes nest.
    self.playbackRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.holdButton, self.offButton]];
    self.playbackRow.distribution = UIStackViewDistributionFillEqually;
    self.playbackRow.spacing = 10;
    self.scheduleButton = LSPlainIconButton(@"clock", @"Schedule", LSAccentTextColor(), UIColor.tertiarySystemFillColor);
    self.scheduleButton.accessibilityUserInputLabels = @[@"Schedule"];
    UIButtonConfiguration *clock = self.scheduleButton.configuration;
    clock.imagePadding = 8;
    clock.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 26);
        return result;
    };
    self.scheduleButton.configuration = clock;
    for (NSLayoutConstraint *constraint in self.scheduleButton.constraints) {
        // The 44 pt size from LSPlainIconButton, not UIKit's own content-size constraints.
        if (constraint.firstItem == self.scheduleButton && constraint.firstAttribute == NSLayoutAttributeHeight && !constraint.secondItem && constraint.priority == 999) self.scheduleButtonHeight = constraint;
    }
    [self buildScheduleBadge];
    self.scheduleButton.accessibilityHint = @"Start this location or route later, and turn it off at a set time.";
    LSAddPressFeedback(self.scheduleButton);
    [self.scheduleButton addTarget:self action:@selector(openSchedule) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *primaryRow = LSRow(@[self.primaryButton, self.scheduleButton], 10);
    primaryRow.alignment = UIStackViewAlignmentCenter;
    self.footerPrimaryRow = primaryRow;
    UIStackView *stack = LSStack(@[primaryRow, self.playbackRow], 10);
    UIView *footer = LSGlassPanel(stack, 26 + 12, 12);
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:footer];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    // Floats just into the home indicator area, but never closer than 12 pt to the edge.
    NSLayoutConstraint *bottom = [footer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:10];
    bottom.priority = 999;
    NSArray<NSLayoutConstraint *> *column = LSColumnConstraints(footer, safe);
    [self.columnLayout addObjectsFromArray:column];
    [NSLayoutConstraint activateConstraints:column];
    [NSLayoutConstraint activateConstraints:@[
        [footer.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-12],
        bottom
    ]];
    self.footerView = footer;
    self.footerShown = YES;
}
- (void)buildLocationDetails {
    UIButtonConfiguration *searchStyle = UIButtonConfiguration.grayButtonConfiguration;
    searchStyle.title = @"Search places or addresses";
    searchStyle.image = [UIImage systemImageNamed:@"magnifyingglass"];
    searchStyle.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody scale:UIImageSymbolScaleMedium];
    searchStyle.imagePadding = 10;
    searchStyle.baseForegroundColor = UIColor.secondaryLabelColor;
    searchStyle.baseBackgroundColor = UIColor.tertiarySystemFillColor;
    searchStyle.contentInsets = NSDirectionalEdgeInsetsMake(13, 14, 13, 14);
    searchStyle.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleBody, UIFontWeightRegular, 28);
        return result;
    };
    UIButton *search = [UIButton buttonWithType:UIButtonTypeSystem];
    search.configuration = searchStyle;
    search.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    search.translatesAutoresizingMaskIntoConstraints = NO;
    search.accessibilityLabel = @"Search places";
    search.accessibilityUserInputLabels = @[@"Search", @"Search places"];
    search.accessibilityHint = @"Search for a place or address, paste a map link or coordinates, or pick a saved place.";
    [search.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    LSAddPressFeedback(search);
    [search addTarget:self action:@selector(searchLocation) forControlEvents:UIControlEventTouchUpInside];
    LSSetButtonRadius(search, LSRadiusL - 16);
    self.locationIntro = search;

    // Preview or applied: an icon and words, never colour alone.
    self.placeStatusIcon = [[UIImageView alloc] init];
    self.placeStatusIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote scale:UIImageSymbolScaleMedium];
    [self.placeStatusIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.placeStatusIcon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.placeStatusLabel = LSLabel(@"", UIFontTextStyleFootnote);
    self.placeStatusLabel.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
    self.placeStatusRow = LSRow(@[self.placeStatusIcon, self.placeStatusLabel], 5);
    self.placeStatusRow.hidden = YES;
    self.placeLabel = LSLabel(@"Choose a location", UIFontTextStyleTitle2);
    self.placeLabel.font = LSFont(UIFontTextStyleTitle2, UIFontWeightBold, 36);
    self.placeLabel.numberOfLines = 3;
    self.placeLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    self.coordinateLabel = LSLabel(@"Search, tap the map, or enter coordinates.", UIFontTextStyleSubheadline);
    self.coordinateLabel.textColor = UIColor.secondaryLabelColor;
    [self.coordinateLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.coordinateCopyButton = LSPlainIconButton(@"doc.on.doc", @"Copy coordinates", UIColor.secondaryLabelColor, nil);
    self.coordinateCopyButton.accessibilityUserInputLabels = @[@"Copy", @"Copy coordinates"];
    LSAddPressFeedback(self.coordinateCopyButton);
    [self.coordinateCopyButton addTarget:self action:@selector(copyCoordinates) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *coordinateRow = LSRow(@[self.coordinateLabel, self.coordinateCopyButton], 4);
    UIStackView *info = LSStack(@[self.placeStatusRow, self.placeLabel, coordinateRow], 2);
    [info setCustomSpacing:4 afterView:self.placeStatusRow];

    UIButton *coordinates = LSPlaceAction(@"Coordinates", @"number");
    coordinates.accessibilityLabel = @"Edit coordinates";
    coordinates.accessibilityUserInputLabels = @[@"Coordinates", @"Edit coordinates"];
    [coordinates addTarget:self action:@selector(editCoordinates) forControlEvents:UIControlEventTouchUpInside];
    self.savePlaceButton = LSPlaceAction(@"Save", @"bookmark");
    self.savePlaceButton.accessibilityLabel = @"Save place";
    self.savePlaceButton.accessibilityUserInputLabels = @[@"Save", @"Save place"];
    [self.savePlaceButton addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *link = LSPlaceAction(@"Link", @"link");
    link.accessibilityLabel = @"Import a map link or route file";
    link.accessibilityUserInputLabels = @[@"Link", @"Import"];
    link.showsMenuAsPrimaryAction = YES;
    link.menu = [self importMenu];
    self.useRealButton = LSPlaceAction(@"My location", @"location.fill");
    self.useRealButton.accessibilityLabel = @"Use my real location";
    self.useRealButton.accessibilityUserInputLabels = @[@"My location", @"Use my real location"];
    self.useRealButton.hidden = YES;
    [self.useRealButton addTarget:self action:@selector(useRealLocation) forControlEvents:UIControlEventTouchUpInside];
    // Equal tiles that always fit the card: no scrolling strip, nothing cut at the edges. A
    // saved spot's wander radius lives in the Saved tile's menu. At accessibility sizes the
    // tiles stack into full-width rows (layoutPlaceActions).
    self.locationActions = [[UIStackView alloc] initWithArrangedSubviews:@[coordinates, self.savePlaceButton, link, self.useRealButton]];
    self.locationActions.translatesAutoresizingMaskIntoConstraints = NO;
    self.locationActions.axis = UILayoutConstraintAxisHorizontal;
    self.locationActions.distribution = UIStackViewDistributionFillEqually;
    self.locationActions.spacing = 8;
    self.realNoticeLabel = LSLabel(@"", UIFontTextStyleFootnote);
    self.realNoticeLabel.textColor = UIColor.secondaryLabelColor;
    self.realNoticeLabel.hidden = YES;
    UIStackView *stack = LSStack(@[search, info, self.locationActions, self.realNoticeLabel], 14);
    [stack setCustomSpacing:16 afterView:search];
    stack.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(16, 16, 16, 16);
    stack.layoutMarginsRelativeArrangement = YES;
    // The card is as tall as its content and scrolls inside itself when there is less room
    // (landscape, very large text), instead of squeezing its rows into a sliver.
    UIScrollView *cardScroll = [[UIScrollView alloc] init];
    cardScroll.translatesAutoresizingMaskIntoConstraints = NO;
    cardScroll.showsHorizontalScrollIndicator = NO;
    cardScroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [cardScroll addSubview:stack];
    NSLayoutConstraint *fit = [cardScroll.heightAnchor constraintEqualToAnchor:stack.heightAnchor];
    fit.priority = 998;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:cardScroll.contentLayoutGuide.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:cardScroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cardScroll.contentLayoutGuide.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:cardScroll.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:cardScroll.frameLayoutGuide.widthAnchor],
        fit
    ]];
    UIView *card = LSGlassPanel(cardScroll, LSRadiusL, 0);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    self.locationDetails = card;
    [self installPlaceActions];
}
- (void)installPlaceActions {
    __weak typeof(self) weakSelf = self;
    self.placeLabel.accessibilityCustomActions = @[
        [[UIAccessibilityCustomAction alloc] initWithName:@"Drop a pin at the map center" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            return [weakSelf dropPinAtMapCenter];
        }],
        [[UIAccessibilityCustomAction alloc] initWithName:@"Copy coordinates" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            typeof(self) self = weakSelf;
            if (!self.hasSelection) return NO;
            [self copyCoordinates];
            return YES;
        }],
        [[UIAccessibilityCustomAction alloc] initWithName:@"Save place" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            typeof(self) self = weakSelf;
            if (!self.hasSelection) return NO;
            [self saveSelectedPlace];
            return YES;
        }],
        [[UIAccessibilityCustomAction alloc] initWithName:@"Edit coordinates" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            [weakSelf editCoordinates];
            return YES;
        }]
    ];
}
- (void)buildMap {
    LSMapContainerView *container = [[LSMapContainerView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.clipsToBounds = YES;
    container.backgroundColor = UIColor.secondarySystemBackgroundColor;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    __weak typeof(self) weakSelf = self;
    container.didLayout = ^{ [weakSelf mapContainerDidLayout]; };
    self.mapContainer = container;
    self.mapHeight = [container.heightAnchor constraintEqualToConstant:300];
    self.mapHeight.priority = 999;
    self.mapHeight.active = YES;
    self.mapVisibleGuide = [[UILayoutGuide alloc] init];
    self.mapVisibleGuide.identifier = @"LSMapVisibleArea";
    [container addLayoutGuide:self.mapVisibleGuide];
    [self replaceMap:nil];
    // One floating glass cluster: style, center, real location (compass appears under it when rotated).
    self.mapStyleButton = LSPlainIconButton(@"map", @"Map style", LSAccentTextColor(), nil);
    self.mapStyleButton.showsMenuAsPrimaryAction = YES;
    self.mapStyleButton.accessibilityUserInputLabels = @[@"Map style"];
    UIButton *center = LSPlainIconButton(@"scope", @"Center on applied location or selection", LSAccentTextColor(), nil);
    center.accessibilityUserInputLabels = @[@"Center", @"Center map"];
    LSAddPressFeedback(center);
    [center addTarget:self action:@selector(centerMap) forControlEvents:UIControlEventTouchUpInside];
    self.realCenterButton = LSPlainIconButton(@"location.fill", @"Center on real location", LSAccentTextColor(), nil);
    self.realCenterButton.accessibilityUserInputLabels = @[@"Real location", @"Center on real location"];
    self.realCenterButton.hidden = YES;
    LSAddPressFeedback(self.realCenterButton);
    [self.realCenterButton addTarget:self action:@selector(centerReal) forControlEvents:UIControlEventTouchUpInside];
    self.realSeparator = LSClusterSeparator();
    self.realSeparator.hidden = YES;
    UIStackView *buttons = LSStack(@[self.mapStyleButton, LSClusterSeparator(), center, self.realSeparator, self.realCenterButton], 0);
    buttons.alignment = UIStackViewAlignmentCenter;
    self.mapControls = LSGlassPanel(buttons, 22, 0);
    self.mapControls.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapHintView = [self buildMapHint];
    self.mapStateView = [self buildMapState];
    [self updateMapStyleButton];
}
- (UIView *)buildMapHint {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hand.tap.fill"]];
    icon.tintColor = LSAccentTextColor();
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline scale:UIImageSymbolScaleMedium];
    icon.isAccessibilityElement = NO;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [icon setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.mapHintLabel = LSLabel(kLSLocationHint, UIFontTextStyleFootnote);
    self.mapHintLabel.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
    UIStackView *row = LSRow(@[icon, self.mapHintLabel], 8);
    UIView *pill = LSGlassPanel(row, 18, 10);
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    // Taps go straight through to the map underneath.
    pill.userInteractionEnabled = NO;
    return pill;
}
- (UIView *)buildMapState {
    self.mapStateIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wifi.exclamationmark"]];
    self.mapStateIcon.tintColor = UIColor.secondaryLabelColor;
    self.mapStateIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2 scale:UIImageSymbolScaleLarge];
    self.mapStateIcon.isAccessibilityElement = NO;
    self.mapStateSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.mapStateSpinner.hidesWhenStopped = YES;
    self.mapStateTitle = LSLabel(@"Map unavailable", UIFontTextStyleHeadline);
    self.mapStateTitle.font = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 28);
    self.mapStateTitle.textAlignment = NSTextAlignmentCenter;
    self.mapStateTitle.accessibilityTraits = UIAccessibilityTraitHeader;
    self.mapErrorLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    self.mapErrorLabel.textColor = UIColor.secondaryLabelColor;
    self.mapErrorLabel.textAlignment = NSTextAlignmentCenter;
    self.mapRetryButton = LSButton(@"Try again", @"arrow.clockwise", NO);
    self.mapRetryButton.accessibilityLabel = @"Retry map";
    self.mapRetryButton.accessibilityUserInputLabels = @[@"Try again", @"Retry map"];
    [self.mapRetryButton addTarget:self action:@selector(retryMap) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = LSStack(@[self.mapStateIcon, self.mapStateSpinner, self.mapStateTitle, self.mapErrorLabel, self.mapRetryButton], 6);
    stack.alignment = UIStackViewAlignmentCenter;
    [stack setCustomSpacing:14 afterView:self.mapErrorLabel];
    UIView *panel = LSGlassPanel(stack, LSRadiusM, 20);
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.hidden = YES;
    return panel;
}
- (void)installMapOverlays {
    UIView *container = self.mapContainer;
    UILayoutGuide *guide = self.mapVisibleGuide;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    for (UIView *overlay in @[self.mapControls, self.mapHintView, self.mapStateView, self.locationDetails]) [container addSubview:overlay];
    self.mapGuideTop = [guide.topAnchor constraintEqualToAnchor:container.topAnchor constant:150];
    self.mapGuideToBottom = [guide.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12];
    self.mapGuideToCard = [guide.bottomAnchor constraintEqualToAnchor:self.locationDetails.topAnchor constant:-kLSFloatGap];
    // The place card floats over the map; with very large text the map grows (and scrolls)
    // rather than shrinking to nothing behind it.
    self.mapMinimumVisible = [guide.heightAnchor constraintGreaterThanOrEqualToConstant:150];
    self.cardBottom = [self.locationDetails.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-120];
    // Clear of the Maps logo and legal link in the bottom corners.
    NSLayoutConstraint *hintWidth = [self.mapHintView.widthAnchor constraintLessThanOrEqualToAnchor:guide.widthAnchor constant:-128];
    hintWidth.priority = 999;
    NSLayoutConstraint *stateWidth = [self.mapStateView.widthAnchor constraintLessThanOrEqualToAnchor:guide.widthAnchor constant:-24];
    stateWidth.priority = 999;
    NSLayoutConstraint *guideLeading = [guide.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12];
    NSLayoutConstraint *guideTrailing = [guide.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12];
    guideLeading.priority = UILayoutPriorityDefaultLow;
    guideTrailing.priority = UILayoutPriorityDefaultLow;
    NSLayoutConstraint *stateCenter = [self.mapStateView.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor];
    stateCenter.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        // 12 pt inside the map and the safe area, whichever is tighter: on Route the map is an
        // inset card, and its controls must not hang over its rounded edge.
        guideLeading, guideTrailing,
        [guide.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
        [guide.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:12],
        [guide.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        [guide.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-12],
        self.mapGuideTop, self.mapGuideToBottom,
        [self.mapControls.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.mapControls.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.mapHintView.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [self.mapHintView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [self.mapHintView.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor],
        hintWidth,
        [self.mapStateView.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [self.mapStateView.topAnchor constraintGreaterThanOrEqualToAnchor:guide.topAnchor],
        [self.mapStateView.widthAnchor constraintLessThanOrEqualToConstant:340],
        stateWidth, stateCenter,
        self.cardBottom
    ]];
    NSArray<NSLayoutConstraint *> *cardColumn = LSColumnConstraints(self.locationDetails, safe);
    [self.columnLayout addObjectsFromArray:cardColumn];
    [self.columnLayout addObject:self.cardBottom];
    [NSLayoutConstraint activateConstraints:cardColumn];
    [self installCompass];
}
- (void)installCompass {
    [self.compassButton removeFromSuperview];
    if (!self.mapControls.superview) return;
    MKCompassButton *compass = [MKCompassButton compassButtonWithMapView:self.mapView];
    compass.compassVisibility = MKFeatureVisibilityAdaptive;
    compass.translatesAutoresizingMaskIntoConstraints = NO;
    [self.mapContainer insertSubview:compass aboveSubview:self.mapView];
    [NSLayoutConstraint activateConstraints:@[
        [compass.topAnchor constraintEqualToAnchor:self.mapControls.bottomAnchor constant:10],
        [compass.centerXAnchor constraintEqualToAnchor:self.mapControls.centerXAnchor]
    ]];
    self.compassButton = compass;
}
- (void)replaceMap:(MKCoordinateRegion *)savedRegion {
    self.mapView.delegate = nil;
    [self.mapView removeFromSuperview];
    self.mapView = [[MKMapView alloc] init];
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.delegate = self;
    self.mapView.mapType = ls_mapType;
    self.mapView.showsUserLocation = NO;
    self.mapView.showsCompass = NO;
    // The Route tab keeps its top-leading corner for its own badge.
    self.mapView.showsScale = self.tab != LSPickerTabRoute;
    self.mapView.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAllCategories];
    // Margins follow the floating surfaces, so the legal notice and scale stay uncovered.
    self.mapView.insetsLayoutMarginsFromSafeArea = NO;
    self.mapView.layoutMargins = [self mapObscuredInsets];
    self.mapView.accessibilityLabel = @"Location preview map";
    __weak typeof(self) weakSelf = self;
    self.mapView.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc] initWithName:@"Drop a pin at the map center" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        return [weakSelf dropPinAtMapCenter];
    }]];
    [self.mapContainer insertSubview:self.mapView atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.mapView.topAnchor constraintEqualToAnchor:self.mapContainer.topAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.mapContainer.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor],
        [self.mapView.bottomAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor]
    ]];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
    tap.delegate = self;
    tap.cancelsTouchesInView = NO;
    [self.mapView addGestureRecognizer:tap];
    // A double tap zooms; without this its first tap dropped a pin (or set From on Route).
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapDoubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.delegate = self;
    doubleTap.cancelsTouchesInView = NO;
    doubleTap.delaysTouchesEnded = NO;
    [self.mapView addGestureRecognizer:doubleTap];
    self.mapDoubleTap = doubleTap;
    [tap requireGestureRecognizerToFail:doubleTap];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(mapHeld:)];
    hold.delegate = self;
    [tap requireGestureRecognizerToFail:hold];
    [self.mapView addGestureRecognizer:hold];
    for (MKPointAnnotation *pin in @[self.pin ?: NSNull.null, self.startPin ?: NSNull.null, self.endPin ?: NSNull.null, self.appliedPin ?: NSNull.null, self.realPin ?: NSNull.null]) {
        if ([pin isKindOfClass:MKPointAnnotation.class]) [self.mapView addAnnotation:pin];
    }
    if (self.routeStops.count) [self.mapView addAnnotations:self.routeStops];
    if (self.routePolyline) [self.mapView addOverlay:self.routePolyline];
    if (self.radiusCircle) [self.mapView addOverlay:self.radiusCircle];
    if (savedRegion) [self.mapView setRegion:*savedRegion animated:NO];
    else if (self.hasSelection) [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.selectedCoordinate, 2000, 2000) animated:NO];
    [self installCompass];
}
- (void)layoutFloatingSurfaces {
    CGSize size = self.view.bounds.size;
    CGFloat height = size.height;
    if (height <= 0 || !self.chromeView.superview || !self.mapGuideTop) return;
    BOOL location = self.tab == LSPickerTabLocation;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    // A phone on its side has no room for a header, a card and a footer stacked over the map,
    // so they move into a side panel and the map fills the rest.
    BOOL side = size.width > height && height < 500;
    if (side != self.sideLayout) [self applySideLayout:side];
    CGFloat top = CGRectGetMaxY(self.chromeView.frame) + kLSFloatGap;
    CGFloat bottom = !self.footerShown ? 0 : MAX(0, height - CGRectGetMinY(self.footerView.frame)) + kLSFloatGap;
    // The footer's own rule: just into the home indicator area, never closer than 12 pt.
    CGFloat edge = MAX(12, safe.bottom - 10);
    if (side) {
        CGFloat usable = size.width - safe.left - safe.right;
        LSSetConstant(self.sideWidth, MIN(380, MAX(330, floor((usable - 36) / 2))));
    }
    LSSetConstant(self.sideGuideBottom, -edge);
    LSSetConstant(self.cardBottom, -MAX(bottom, safe.bottom + 12));
    LSSetConstant(self.savedBottom, side ? -edge : -bottom);
    LSSetConstant(self.mapMinimumVisible, height < 500 ? 90 : 150);
    // Location (and the side layout): the map is the whole sheet, under the floating surfaces.
    // Route: the scroll view sits between the header and the footer, so nothing scrolls behind
    // the header, peeks out around it or shows below the footer buttons.
    BOOL fullMap = location || side;
    LSSetConstant(self.scrollTop, fullMap ? 0 : top);
    LSSetConstant(self.scrollBottom, fullMap ? 0 : -bottom);
    LSSetConstant(self.mapGuideTop, side ? safe.top + 12 : (location ? top : 12));
    LSSetConstant(self.mapGuideToBottom, side ? -MAX(bottom, edge) : -12);
    // Route: the map is a card in the same column as the planner below it.
    CGFloat column = MAX(16, (size.width - kLSColumnWidth) / 2);
    CGFloat leading = fullMap ? 0 : MAX(column, safe.left + 16), trailing = fullMap ? 0 : MAX(column, safe.right + 16);
    NSDirectionalEdgeInsets margins = NSDirectionalEdgeInsetsMake(0, leading, 0, trailing);
    NSDirectionalEdgeInsets current = self.contentStack.directionalLayoutMargins;
    if (current.leading != margins.leading || current.trailing != margins.trailing) self.contentStack.directionalLayoutMargins = margins;
    CGFloat available = height - (fullMap ? 0 : top + bottom);
    LSSetConstant(self.mapHeight, fullMap ? height : MIN(400, MAX(220, available * 0.45)));
    // With the footer hidden the content still clears the home indicator.
    UIEdgeInsets inset = UIEdgeInsetsMake(0, 0, fullMap || bottom > 0 ? 0 : safe.bottom, 0);
    if (!UIEdgeInsetsEqualToEdgeInsets(self.scroll.contentInset, inset)) self.scroll.contentInset = inset;
    UIEdgeInsets indicators = location && !side ? UIEdgeInsetsMake(top, 0, bottom, 0) : UIEdgeInsetsZero;
    if (!UIEdgeInsetsEqualToEdgeInsets(self.scroll.verticalScrollIndicatorInsets, indicators)) self.scroll.verticalScrollIndicatorInsets = indicators;
}
- (void)mapContainerDidLayout {
    UIEdgeInsets margins = [self mapObscuredInsets];
    if (!UIEdgeInsetsEqualToEdgeInsets(self.mapView.layoutMargins, margins)) self.mapView.layoutMargins = margins;
    [self performInitialMapFit];
}
- (UIEdgeInsets)mapObscuredInsets {
    CGRect bounds = self.mapContainer.bounds;
    CGRect visible = self.mapVisibleGuide.layoutFrame;
    if (CGRectIsEmpty(bounds) || CGRectIsEmpty(visible)) return UIEdgeInsetsZero;
    return UIEdgeInsetsMake(MAX(0, CGRectGetMinY(visible)), MAX(0, CGRectGetMinX(visible)),
                            MAX(0, CGRectGetMaxY(bounds) - CGRectGetMaxY(visible)), MAX(0, CGRectGetMaxX(bounds) - CGRectGetMaxX(visible)));
}
- (void)focusMapOnRect:(MKMapRect)rect animated:(BOOL)animated {
    if (MKMapRectIsNull(rect)) return;
    BOOL motion = animated && LSMapAnimationsEnabled();
    CGSize size = self.mapView.bounds.size;
    UIEdgeInsets padding = [self mapObscuredInsets];
    padding.top += 28; padding.bottom += 28; padding.left += 24;
    padding.right += 24 + (self.mapControls.hidden ? 0 : CGRectGetWidth(self.mapControls.bounds));
    // A tiny map (landscape, huge text) cannot take the full padding; MapKit would zoom out to the world.
    if (size.width < 1 || padding.left + padding.right > size.width - 60 || padding.top + padding.bottom > size.height - 60) padding = UIEdgeInsetsMake(24, 24, 24, 24);
    [self.mapView setVisibleMapRect:rect edgePadding:padding animated:motion];
}
- (void)focusMapOnCoordinate:(CLLocationCoordinate2D)coordinate meters:(double)meters animated:(BOOL)animated {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    if (CGRectIsEmpty(self.mapView.bounds)) {
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, meters, meters) animated:NO];
        return;
    }
    MKMapPoint point = MKMapPointForCoordinate(coordinate);
    double span = MKMapPointsPerMeterAtLatitude(coordinate.latitude) * (meters > 0 ? meters : 2000);
    [self focusMapOnRect:MKMapRectMake(point.x - span / 2, point.y - span / 2, span, span) animated:animated];
}
// Moves the map so coordinate sits in the middle of the uncovered area, keeping the zoom.
- (void)centerMapOn:(CLLocationCoordinate2D)coordinate animated:(BOOL)animated {
    CGRect bounds = self.mapView.bounds;
    CGRect visible = UIEdgeInsetsInsetRect(bounds, [self mapObscuredInsets]);
    CLLocationCoordinate2D center = coordinate;
    if (!CGRectIsEmpty(visible)) {
        CGPoint point = [self.mapView convertCoordinate:coordinate toPointToView:self.mapView];
        CGPoint shifted = CGPointMake(point.x + CGRectGetMidX(bounds) - CGRectGetMidX(visible), point.y + CGRectGetMidY(bounds) - CGRectGetMidY(visible));
        CLLocationCoordinate2D converted = [self.mapView convertPoint:shifted toCoordinateFromView:self.mapView];
        if (CLLocationCoordinate2DIsValid(converted)) center = converted;
    }
    [self.mapView setCenterCoordinate:center animated:animated && LSMapAnimationsEnabled()];
}
- (void)performInitialMapFit {
    if (self.didInitialMapFit || self.tab == LSPickerTabSaved) return;
    if (CGRectGetWidth(self.mapView.bounds) < 1 || CGRectGetHeight(self.mapVisibleGuide.layoutFrame) < 1) return;
    self.didInitialMapFit = YES;
    CLLocation *applied = LSSessionController.shared.snapshot.location;
    if (self.tab == LSPickerTabRoute && self.routePolyline) [self focusMapOnRect:self.routePolyline.boundingMapRect animated:NO];
    else if (self.hasSelection) [self focusMapOnCoordinate:self.selectedCoordinate meters:2000 animated:NO];
    else if (applied) [self focusMapOnCoordinate:applied.coordinate meters:2000 animated:NO];
}
- (void)layoutPlaceActions:(BOOL)large {
    UILayoutConstraintAxis axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    if (self.locationActions.axis == axis) return;
    self.locationActions.axis = axis;
    self.locationActions.distribution = large ? UIStackViewDistributionFill : UIStackViewDistributionFillEqually;
    // Full-width rows read left to right, with titles that wrap instead of truncating.
    for (UIButton *button in self.locationActions.arrangedSubviews) {
        UIButtonConfiguration *config = button.configuration;
        config.imagePlacement = large ? NSDirectionalRectEdgeLeading : NSDirectionalRectEdgeTop;
        config.imagePadding = large ? 10 : 4;
        config.titleLineBreakMode = large ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
        config.contentInsets = large ? NSDirectionalEdgeInsetsMake(12, 16, 12, 16) : NSDirectionalEdgeInsetsMake(10, 2, 9, 2);
        button.configuration = config;
        button.contentHorizontalAlignment = large ? UIControlContentHorizontalAlignmentLeading : UIControlContentHorizontalAlignmentCenter;
    }
}
- (void)updateMapStyleButton {
    UIButtonConfiguration *config = self.mapStyleButton.configuration;
    config.image = [UIImage systemImageNamed:LSMapTypeSymbol(ls_mapType)];
    self.mapStyleButton.configuration = config;
    self.mapStyleButton.accessibilityValue = LSMapTypeName(ls_mapType);
    self.mapStyleButton.accessibilityHint = @"Choose a standard, hybrid or satellite map.";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    for (NSNumber *value in @[@(MKMapTypeStandard), @(MKMapTypeHybrid), @(MKMapTypeSatellite)]) {
        MKMapType type = (MKMapType)value.unsignedIntegerValue;
        UIAction *action = [UIAction actionWithTitle:LSMapTypeName(type) image:[UIImage systemImageNamed:LSMapTypeSymbol(type)] identifier:nil handler:^(__unused UIAction *item) {
            [weakSelf setMapStyle:type];
        }];
        action.state = type == ls_mapType ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    self.mapStyleButton.menu = [UIMenu menuWithTitle:@"Map style" children:items];
}
- (void)setMapStyle:(MKMapType)type {
    if (type == ls_mapType) return;
    ls_mapType = type;
    self.mapView.mapType = type;
    [self updateMapStyleButton];
    LSHapticSelection();
    LSAnnounce([NSString stringWithFormat:@"%@ map", LSMapTypeName(type)]);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    (void)gesture;
    UIView *view = touch.view;
    while (view && view != self.mapView) {
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:MKAnnotationView.class]) return NO;
        view = view.superview;
    }
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)other;
    // Our double tap only holds back pin drops; MapKit's own double-tap zoom still runs.
    return gesture == self.mapDoubleTap;
}
- (void)mapDoubleTapped:(UITapGestureRecognizer *)gesture { (void)gesture; }
- (void)mapTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:[gesture locationInView:self.mapView] toCoordinateFromView:self.mapView];
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    if (self.tab == LSPickerTabRoute) { LSHapticSelection(); [self assignMapEndpoint:coordinate]; return; }
    // Beside the landscape side panel the map shows on Saved too; a tap there picks a spot.
    if (self.tab == LSPickerTabSaved) [self showTab:LSPickerTabLocation animated:YES];
    [self dropPinAt:coordinate save:NO];
}
- (void)mapHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:[gesture locationInView:self.mapView] toCoordinateFromView:self.mapView];
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    if (self.tab == LSPickerTabRoute) { LSHapticSelection(); [self assignMapEndpoint:coordinate]; return; }
    if (self.tab == LSPickerTabSaved) [self showTab:LSPickerTabLocation animated:YES];
    [self dropPinAt:coordinate save:YES];
}
- (void)dropPinAt:(CLLocationCoordinate2D)coordinate save:(BOOL)save {
    LSHapticPinDrop();
    [self setSelection:coordinate name:@"Dropped pin"];
    [self popPin];
    [self finishLocationHint];
    __weak typeof(self) weakSelf = self;
    // A held pin is saved once it has a street name (or after a short wait without one).
    [self nameDroppedPinThen:save ? ^{ [weakSelf saveSelectedPlace]; } : nil];
    BOOL named = ![self.selectedName isEqualToString:@"Dropped pin"];
    NSString *dropped = named ? [NSString stringWithFormat:@"Pin dropped at %@.", self.selectedName] : @"Pin dropped.";
    LSAnnounce([dropped stringByAppendingString:save ? @" Saving it." : @" Apply location when you’re ready."]);
}
- (BOOL)dropPinAtMapCenter {
    CGRect visible = UIEdgeInsetsInsetRect(self.mapView.bounds, [self mapObscuredInsets]);
    if (CGRectIsEmpty(visible)) visible = self.mapView.bounds;
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:CGPointMake(CGRectGetMidX(visible), CGRectGetMidY(visible)) toCoordinateFromView:self.mapView];
    if (!CLLocationCoordinate2DIsValid(coordinate) || self.tab == LSPickerTabSaved) return NO;
    if (self.tab == LSPickerTabRoute) [self assignMapEndpoint:coordinate];
    else [self dropPinAt:coordinate save:NO];
    return YES;
}
// Springs the selected marker in. New markers already drop in through MapKit.
- (void)popPin {
    if (!LSMapAnimationsEnabled() || !self.pin) return;
    MKAnnotationView *view = [self.mapView viewForAnnotation:self.pin];
    if (!view) return;
    view.transform = CGAffineTransformMakeScale(0.5, 0.5);
    LSAnimateBouncy(^{ view.transform = CGAffineTransformIdentity; }, nil);
}
- (void)nameDroppedPinThen:(dispatch_block_t)then {
    CLLocationCoordinate2D coordinate = self.selectedCoordinate;
    NSUInteger revision = self.selectionRevision;
    // A new drop replaces any lookup still running for the previous one.
    [self.geocoder cancelGeocode];
    __weak typeof(self) weakSelf = self;
    __block BOOL handedOff = NO;
    dispatch_block_t handOff = ^{
        if (handedOff) return;
        handedOff = YES;
        typeof(self) self = weakSelf;
        if (then && self && !self.closed && self.selectionRevision == revision) then();
    };
    // Nudging a pin a few doors along keeps the name just looked up, without another lookup.
    if (self.geocodedName.length && CLLocationCoordinate2DIsValid(self.geocodedCoordinate) && LSApproximateDistance(self.geocodedCoordinate, coordinate) < 25) {
        self.selectedName = self.geocodedName;
        if (self.tab == LSPickerTabLocation) [self renderSelectedLocation];
        dispatch_async(dispatch_get_main_queue(), handOff);
        return;
    }
    if (!self.geocoder) self.geocoder = [[CLGeocoder alloc] init];
    CLLocation *location = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
    [self.geocoder reverseGeocodeLocation:location completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        typeof(self) self = weakSelf;
        if (self && !self.closed && !error && self.selectionRevision == revision) {
            NSString *name = LSPlacemarkName(placemarks.firstObject);
            if (name.length) {
                self.geocodedName = name;
                self.geocodedCoordinate = coordinate;
                self.selectedName = name;
                if (self.tab == LSPickerTabLocation) [self renderSelectedLocation];
                LSAnnounce(name);
            }
        }
        handOff();
    }];
    if (then) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), handOff);
}
- (void)assignMapEndpoint:(CLLocationCoordinate2D)coordinate {
    LSEndpoint endpoint = self.endpoint;
    [self assignEndpoint:endpoint coordinate:coordinate name:@"Map point"];
    // Tapping From and then To is the common flow; without this every tap kept moving From.
    if (endpoint == LSEndpointFrom && !self.endPin) {
        self.endpointSegment.selectedSegmentIndex = LSEndpointTo;
        self.endpoint = LSEndpointTo;
        self.mapHintLabel.text = @"From is set. Tap the map again to set To.";
        LSAnnounce(self.mapHintLabel.text);
    }
}
- (void)setSelection:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    self.selectionRevision++;
    self.selectedCoordinate = coordinate;
    self.hasSelection = YES;
    self.selectedName = name.length ? name : @"Selected location";
    [self renderSelectedLocation];
}
- (void)renderSelectedLocation {
    CLLocationCoordinate2D coordinate = self.selectedCoordinate;
    if (!self.pin) {
        self.pin = [[MKPointAnnotation alloc] init];
        self.pin.coordinate = coordinate;
        [self.mapView addAnnotation:self.pin];
    }
    self.pin.coordinate = coordinate;
    self.pin.title = @"Selected location";
    [self syncMapWorkspace];
    self.pin.subtitle = self.selectedName;
    if (![self.placeLabel.text isEqualToString:self.selectedName]) self.placeLabel.text = self.selectedName;
    self.coordinateLabel.font = LSMonoFont(UIFontTextStyleSubheadline, UIFontWeightRegular, 26);
    self.coordinateLabel.text = LSCoordinateText(coordinate);
    self.coordinateLabel.accessibilityLabel = [NSString stringWithFormat:@"Coordinates %@", self.coordinateLabel.text];
    self.coordinateCopyButton.hidden = NO;
    self.coordinateCopyButton.enabled = YES;
    [self updateSaveAction:[BookmarksManager.shared bookmarkNearCoordinate:coordinate]];
    [self updatePlaceStatus];
    [self updateRadiusPreview];
    [self updateFooter];
}
- (void)renderEmptyPlace {
    self.placeLabel.text = @"Choose a location";
    self.coordinateLabel.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightRegular, 26);
    self.coordinateLabel.text = @"Search, tap the map, or enter coordinates.";
    self.coordinateLabel.accessibilityLabel = nil;
    self.coordinateCopyButton.enabled = NO;
    self.coordinateCopyButton.hidden = YES;
    self.placeStatusRow.hidden = YES;
}
// The preview is the spot the app already sees (held, not moving).
- (BOOL)selectionIsApplied {
    if (!self.hasSelection || LSSessionController.shared.snapshot.mode != LSSessionModeStatic) return NO;
    PersistenceManager *store = PersistenceManager.shared;
    if (!store.hasStoredCoordinate) return NO;
    // Runs on every refresh, so no CLLocation objects.
    return LSApproximateDistance(store.spoofCoordinate, self.selectedCoordinate) < 1;
}
- (void)updatePlaceStatus {
    BOOL show = self.hasSelection && self.tab == LSPickerTabLocation;
    if (self.placeStatusRow.hidden == show) self.placeStatusRow.hidden = !show;
    BOOL applied = [self selectionIsApplied];
    if (applied == self.placeApplied && self.placeStatusLabel.text.length) return;
    self.placeApplied = applied;
    UIColor *color = applied ? LSSuccessColor() : UIColor.secondaryLabelColor;
    self.placeStatusLabel.text = applied ? @"Applied now" : @"Preview · not applied yet";
    self.placeStatusLabel.textColor = color;
    self.placeStatusIcon.image = [UIImage systemImageNamed:applied ? @"checkmark.circle.fill" : @"eye"];
    self.placeStatusIcon.tintColor = color;
    MKMarkerAnnotationView *marker = (id)[self.mapView viewForAnnotation:self.pin];
    if ([marker isKindOfClass:MKMarkerAnnotationView.class]) marker.glyphImage = [UIImage systemImageNamed:applied ? @"checkmark" : @"mappin"];
}
- (void)syncMapWorkspace {
    BOOL location = self.tab == LSPickerTabLocation, route = self.tab == LSPickerTabRoute;
    NSMutableArray *pins = [NSMutableArray arrayWithArray:@[self.pin ?: NSNull.null, self.startPin ?: NSNull.null, self.endPin ?: NSNull.null]];
    [pins addObjectsFromArray:self.routeStops ?: @[]];
    for (MKPointAnnotation *pin in pins) {
        if (![pin isKindOfClass:MKPointAnnotation.class]) continue;
        BOOL visible = pin == self.pin ? location : route;
        if (visible && ![self.mapView.annotations containsObject:pin]) [self.mapView addAnnotation:pin];
        else if (!visible) [self.mapView removeAnnotation:pin];
    }
    if (self.routePolyline) {
        if (route && ![self.mapView.overlays containsObject:self.routePolyline]) [self.mapView addOverlay:self.routePolyline];
        else if (!route) [self.mapView removeOverlay:self.routePolyline];
    }
}
- (void)setMapGuideForLocation:(BOOL)location {
    if (self.mapGuideToCard.active == location && self.mapGuideToBottom.active == !location) return;
    // Off first, so the two never fight for a moment.
    self.mapGuideToCard.active = NO;
    self.mapGuideToBottom.active = NO;
    self.mapMinimumVisible.active = location;
    if (location) self.mapGuideToCard.active = YES;
    else self.mapGuideToBottom.active = YES;
}
- (void)updateWorkspace {
    BOOL location = self.tab == LSPickerTabLocation, route = self.tab == LSPickerTabRoute, saved = self.tab == LSPickerTabSaved;
    self.tabs.selectedSegmentIndex = self.tab;
    self.locationIntro.hidden = !location;
    self.locationDetails.hidden = !location;
    self.routeEndpointsPanel.hidden = !route;
    self.routeDetailsPanel.hidden = !route;
    self.panelsStack.hidden = !route;
    self.savedTable.hidden = !saved;
    self.mapView.showsScale = !route;
    [self applyWorkspaceLayout];
    // A renamed saved place shows its new name in the header.
    self.appliedName = nil;
    [self syncMapWorkspace];
    self.pin.title = @"Selected location";
    if (route) [self endpointChanged];
    [self updateMapHint];
    if (location && self.hasSelection) [self renderSelectedLocation];
    else if (location) [self renderEmptyPlace];
    [self updateRouteUI];
    [self reloadSavedPlaces];
    [self updateRadiusPreview];
    self.footerKey = nil;
    [self updateFooter];
    // The header shows held coordinates only off the Location tab.
    [self updateStatusForSnapshot:LSSessionController.shared.snapshot];
    if (saved) self.savedHeaderDirty = YES;
    [self.view setNeedsLayout];
}
// What depends on both the tab and the layout (portrait column or landscape side panel).
- (void)applyWorkspaceLayout {
    BOOL location = self.tab == LSPickerTabLocation, route = self.tab == LSPickerTabRoute, saved = self.tab == LSPickerTabSaved;
    BOOL side = self.sideLayout;
    // Beside the side panel the map stays in view on every tab, Saved included.
    self.mapContainer.hidden = saved && !side;
    self.scroll.hidden = saved && !side;
    self.scroll.alwaysBounceVertical = !location && !side;
    self.sideScroll.hidden = !(side && route);
    // On Route in portrait the map is a card like the planner below it; otherwise it runs edge
    // to edge. In the side panel, Saved is a rounded sheet like the planner.
    self.mapContainer.layer.cornerRadius = route && !side ? LSRadiusM : 0;
    self.savedTable.layer.cornerRadius = side ? LSRadiusL : 0;
    self.savedTable.layer.cornerCurve = kCACornerCurveContinuous;
    [self setMapGuideForLocation:location && !side];
}
- (void)updateMapHint {
    BOOL location = self.tab == LSPickerTabLocation;
    // Route always shows what the next tap sets; Location teaches once and then gets out of the way.
    BOOL show = self.tab == LSPickerTabRoute || (location && !self.locationHintDone);
    if (location && ![self.mapHintLabel.text isEqualToString:kLSLocationHint]) self.mapHintLabel.text = kLSLocationHint;
    self.mapHintView.hidden = !show;
    if (show) { self.mapHintView.alpha = 1; self.mapHintView.transform = CGAffineTransformIdentity; }
}
- (void)finishLocationHint {
    if (self.locationHintDone) return;
    self.locationHintDone = YES;
    [[[NSUserDefaults alloc] initWithSuiteName:kLSDefaultsSuite] setBool:YES forKey:kLSLocationHintKey];
    if (self.tab != LSPickerTabLocation) return;
    UIView *hint = self.mapHintView;
    BOOL motion = LSMapAnimationsEnabled();
    __weak typeof(self) weakSelf = self;
    LSAnimate(^{
        hint.alpha = 0;
        if (motion) hint.transform = CGAffineTransformMakeTranslation(0, 8);
    }, ^{ [weakSelf updateMapHint]; });
}
- (void)tabChanged {
    LSHapticSelection();
    [self showTab:self.tabs.selectedSegmentIndex animated:YES];
}
- (void)showTab:(LSPickerTab)tab animated:(BOOL)animated {
    if (tab < LSPickerTabLocation || tab > LSPickerTabSaved) return;
    LSPickerTab previous = self.tab;
    self.selectionRevision++;
    [self cancelDirections];
    self.tab = tab;
    if (self.tabs.selectedSegmentIndex != tab) self.tabs.selectedSegmentIndex = tab;
    [self updateWorkspace];
    [self updateRealLocation];
    [self.scroll setContentOffset:CGPointZero animated:NO];
    [self.sideScroll setContentOffset:CGPointZero animated:NO];
    [self revealWorkspaceFrom:animated ? previous : tab];
}
- (void)revealWorkspaceFrom:(LSPickerTab)previous {
    UIView *first = self.tab == LSPickerTabSaved ? self.savedTable : (self.tab == LSPickerTabRoute ? self.routeEndpointsPanel : self.locationIntro);
    if (previous != self.tab) {
        NSArray<UIView *> *incoming = self.tab == LSPickerTabSaved ? @[self.savedTable] : (self.tab == LSPickerTabRoute ? @[self.panelsStack] : @[self.locationDetails]);
        BOOL motion = LSMapAnimationsEnabled();
        for (UIView *view in incoming) {
            view.alpha = 0;
            if (motion) view.transform = CGAffineTransformMakeTranslation(0, 14);
        }
        // New map height and insets are set now so the spring below carries them.
        [self layoutFloatingSurfaces];
        LSAnimate(^{
            for (UIView *view in incoming) { view.alpha = 1; view.transform = CGAffineTransformIdentity; }
            [self.view layoutIfNeeded];
        }, nil);
    }
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, first);
}
- (void)keyTab:(UIKeyCommand *)command {
    NSInteger index = command.input.integerValue - 1;
    if (index < LSPickerTabLocation || index > LSPickerTabSaved || index == self.tab) return;
    [self showTab:index animated:YES];
}
- (void)keySearch {
    if (self.tab != LSPickerTabLocation) [self showTab:LSPickerTabLocation animated:YES];
    [self searchLocation];
}
- (void)showMessage:(NSString *)message { [self showMessage:message symbol:nil]; }
- (void)showMessage:(NSString *)message symbol:(NSString *)symbol {
    // Above the footer, so the status header stays readable.
    LSShowToastAbove(self.view, [self toastAnchorView], message, symbol);
}

#pragma mark - Session

- (void)refreshSession {
    LSSessionSnapshot *snapshot = LSSessionController.shared.snapshot;
    LSSessionMode mode = snapshot.mode;
    [self.statusChip setSessionMode:mode];
    [self updateStatusForSnapshot:snapshot];
    if (snapshot.location) {
        BOOL added = !self.appliedPin;
        if (added) self.appliedPin = [[LSMovingAnnotation alloc] init];
        self.appliedPin.title = mode == LSSessionModeMoving ? @"Moving location" : (mode == LSSessionModePaused ? @"Paused location" : @"Applied location");
        self.appliedPin.coordinate = snapshot.location.coordinate;
        if (added) [self.mapView addAnnotation:self.appliedPin];
        LSPuckView *puck = (id)[self.mapView viewForAnnotation:self.appliedPin];
        if ([puck isKindOfClass:LSPuckView.class]) {
            [self stylePuck:puck mode:mode];
            NSString *label = [NSString stringWithFormat:@"%@. %@", self.appliedPin.title, LSCoordinateText(snapshot.location.coordinate)];
            if (![puck.accessibilityLabel isEqualToString:label]) puck.accessibilityLabel = label;
        }
        // Keep the moving point in the uncovered part of the map while watching a route play.
        if (mode == LSSessionModeMoving && self.tab == LSPickerTabRoute && !self.mapContainer.isHidden) {
            CGRect visible = UIEdgeInsetsInsetRect(self.mapView.bounds, [self mapObscuredInsets]);
            CGRect comfortable = CGRectInset(visible, visible.size.width * 0.1, visible.size.height * 0.1);
            CGPoint point = [self.mapView convertCoordinate:snapshot.location.coordinate toPointToView:self.mapView];
            if (!CGRectIsEmpty(comfortable) && !CGRectContainsPoint(comfortable, point)) [self centerMapOn:snapshot.location.coordinate animated:YES];
        }
    } else if (self.appliedPin) {
        [self.mapView removeAnnotation:self.appliedPin]; self.appliedPin = nil;
    }
    if (self.previousMode != mode) {
        LSAnnounce(LSSessionTitle(mode));
        self.previousMode = mode;
    }
    [self updatePlaceStatus];
    [self updatePlayback];
    [self updateFooter];
}
- (void)updateStatusForSnapshot:(LSSessionSnapshot *)snapshot {
    LSSessionMode mode = snapshot.mode;
    CLLocation *location = snapshot.location;
    BOOL playing = location && (mode == LSSessionModeMoving || mode == LSSessionModePaused);
    NSString *title, *detail = nil, *spoken;
    double progress = 0;
    if (mode == LSSessionModeOff || !location) {
        title = @"Nothing applied";
        spoken = @"Your app sees its real location";
    } else if (mode == LSSessionModeStatic) {
        title = [self appliedPlaceName];
        // The held spot, not the wandering sample, so the line stays calm.
        // Coordinates stay out of the header: the place card and the Saved rows show them, and
        // a long press on the name copies them.
        PersistenceManager *store = PersistenceManager.shared;
        NSString *coordinates = LSCoordinateText(store.hasStoredCoordinate ? store.spoofCoordinate : location.coordinate);
        spoken = [NSString stringWithFormat:@"Coordinates %@", coordinates];
    } else {
        LSRouteSimulator *engine = LSRouteSimulator.shared;
        double total = engine.totalDistance;
        progress = total > 0 ? MIN(1, engine.distanceCovered / total) : 0;
        NSString *name = LSSessionController.shared.retainedRoute.name;
        title = name.length ? name : @"Route";
        detail = [NSString stringWithFormat:@"%@ done", [self percentText:floor(progress * 100) / 100]];
        if (total > 0) detail = [detail stringByAppendingFormat:@" · %@ to go", [self distanceText:MAX(0, total - engine.distanceCovered)]];
        spoken = detail;
    }
    BOOL animated = self.view.window != nil;
    if (mode != self.statusMode) {
        self.statusMode = mode;
        self.statusStack.accessibilityCustomActions = [self statusActionsForMode:mode];
        self.statusStack.accessibilityTraits = mode == LSSessionModeMoving ? UIAccessibilityTraitUpdatesFrequently : UIAccessibilityTraitNone;
        self.statusProgress.fillColor = LSSessionColor(mode);
    }
    // 0: no line, 1: route progress (rounded digits).
    NSInteger kind = detail ? 1 : 0;
    if (kind != self.statusDetailKind) {
        self.statusDetailKind = kind;
        if (kind) self.appliedLabel.text = detail;
        LSSetHidden(self.appliedLabel, kind == 0, animated);
        [self.view setNeedsLayout];
    }
    if (self.statusProgress.hidden == playing) {
        // Starts from where the route is, not with a sweep from zero.
        if (playing) [self.statusProgress setProgress:progress animated:NO];
        LSSetHidden(self.statusProgress, !playing, animated);
        [self.view setNeedsLayout];
    }
    if (playing) [self.statusProgress setProgress:progress animated:YES];
    if (![self.brandLabel.text isEqualToString:title]) self.brandLabel.text = title;
    if (detail && ![self.appliedLabel.text isEqualToString:detail]) self.appliedLabel.text = detail;
    NSString *label = [NSString stringWithFormat:@"Status: %@. %@", LSSessionTitle(mode), title];
    if (![self.statusStack.accessibilityLabel isEqualToString:label]) self.statusStack.accessibilityLabel = label;
    if (![self.statusStack.accessibilityValue isEqualToString:spoken]) self.statusStack.accessibilityValue = spoken;
}
- (NSString *)percentText:(double)fraction {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterPercentStyle;
        formatter.maximumFractionDigits = 0;
    });
    return [formatter stringFromNumber:@(fraction)] ?: @"";
}
- (NSString *)distanceText:(CLLocationDistance)meters {
    static MKDistanceFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[MKDistanceFormatter alloc] init];
        formatter.unitStyle = MKDistanceFormatterUnitStyleAbbreviated;
    });
    return [formatter stringFromDistance:meters];
}
- (NSString *)appliedPlaceName {
    PersistenceManager *store = PersistenceManager.shared;
    if (!store.hasStoredCoordinate) return @"Applied location";
    CLLocationCoordinate2D base = store.spoofCoordinate;
    if (self.appliedName && fabs(base.latitude - self.appliedNameCoordinate.latitude) < 1e-7 && fabs(base.longitude - self.appliedNameCoordinate.longitude) < 1e-7) return self.appliedName;
    // Cached per spot: this runs on every refresh and the recents list is read from disk.
    NSString *name = [BookmarksManager.shared bookmarkNearCoordinate:base].name;
    if (!name.length) {
        for (NSDictionary *entry in store.recentLocations) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            double latitude = [entry[@"LSRecentLat"] doubleValue], longitude = [entry[@"LSRecentLon"] doubleValue];
            if (fabs(latitude - base.latitude) < 1e-6 && fabs(longitude - base.longitude) < 1e-6) { name = entry[@"LSRecentName"]; break; }
        }
    }
    if (![name isKindOfClass:NSString.class] || !name.length) name = @"Applied location";
    self.appliedName = name;
    self.appliedNameCoordinate = base;
    return name;
}
- (NSArray<UIAccessibilityCustomAction *> *)statusActionsForMode:(LSSessionMode)mode {
    if (mode == LSSessionModeOff) return @[];
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAccessibilityCustomAction *> *actions = [NSMutableArray array];
    [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Show on map" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        return [weakSelf showAppliedOnMap];
    }]];
    if (mode == LSSessionModeStatic) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Copy coordinates" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            return [weakSelf copyHeldCoordinates];
        }]];
    }
    if (mode == LSSessionModeMoving || mode == LSSessionModePaused) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:mode == LSSessionModePaused ? @"Resume route" : @"Pause route" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            [weakSelf togglePause];
            return YES;
        }]];
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Stop route and hold here" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
            [weakSelf holdHere];
            return YES;
        }]];
    }
    [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Turn off spoofing" actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) {
        [weakSelf turnOff];
        return YES;
    }]];
    return actions;
}
- (BOOL)copyHeldCoordinates {
    PersistenceManager *store = PersistenceManager.shared;
    if (LSSessionController.shared.snapshot.mode != LSSessionModeStatic || !store.hasStoredCoordinate) return NO;
    UIPasteboard.generalPasteboard.string = LSCoordinateText(store.spoofCoordinate);
    LSHapticSuccess();
    [self showMessage:@"Coordinates copied." symbol:@"doc.on.doc.fill"];
    return YES;
}
- (BOOL)showAppliedOnMap {
    CLLocation *applied = LSSessionController.shared.snapshot.location;
    if (!applied) return NO;
    if (self.tab == LSPickerTabSaved) [self showTab:LSPickerTabLocation animated:YES];
    [self.view layoutIfNeeded];
    [self focusMapOnCoordinate:applied.coordinate meters:2000 animated:YES];
    return YES;
}
- (void)stylePuck:(LSPuckView *)puck mode:(LSSessionMode)mode {
    NSString *symbol = mode == LSSessionModeMoving ? @"location.north.fill" : (mode == LSSessionModePaused ? @"pause.fill" : nil);
    // One dynamic colour per mode, so the puck can skip re-resolving it on every tick.
    UIColor *color = self.puckColors[@(mode)];
    if (!color) { color = LSFillColor(LSSessionColor(mode)); self.puckColors[@(mode)] = color; }
    [puck configureWithColor:color symbol:symbol diameter:22 pulsing:mode != LSSessionModePaused];
    CLLocationDirection heading = LSRouteSimulator.shared.currentHeading;
    BOOL turn = mode == LSSessionModeMoving && heading >= 0;
    [puck setGlyphRotation:turn ? (CGFloat)((heading - self.mapView.camera.heading) * M_PI / 180.0) : 0];
}
- (void)sessionChanged:(NSNotification *)note {
    (void)note;
    if (self.closed) return;
    // Host samples continue at 10 Hz; human-readable map/progress refreshes at at most 4 Hz.
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    LSSessionMode mode = LSSessionController.shared.snapshot.mode;
    if (mode == self.previousMode && now - self.lastUIUpdate < 0.25) return;
    self.lastUIUpdate = now;
    [self refreshSession];
}
- (void)updateFooter {
    LSSessionController *session = LSSessionController.shared;
    LSSessionMode mode = session.snapshot.mode;
    BOOL moving = mode == LSSessionModeMoving || mode == LSSessionModePaused;
    BOOL controlsCurrentRoute = self.tab == LSPickerTabRoute && moving && self.fetchedRoute == session.retainedRoute && !self.routeDraftChanged;
    BOOL replay = self.tab == LSPickerTabRoute && mode == LSSessionModeStatic && self.fetchedRoute && self.fetchedRoute == session.retainedRoute && !self.routeDraftChanged;
    BOOL applied = self.tab == LSPickerTabLocation && [self selectionIsApplied];
    BOOL routeReady = self.fetchedRoute && !self.directions;
    // This runs on every playback refresh; rebuilding configurations and menus each time
    // relaid out the whole sheet.
    NSString *key = [NSString stringWithFormat:@"%ld|%ld|%d%d%d%d%d", (long)mode, (long)self.tab, controlsCurrentRoute, replay, applied, routeReady, self.hasSelection];
    if ([key isEqualToString:self.footerKey]) return;
    self.footerKey = key;
    NSString *title, *symbol;
    if (controlsCurrentRoute) {
        title = mode == LSSessionModePaused ? @"Resume route" : @"Pause route";
        symbol = mode == LSSessionModePaused ? @"play.fill" : @"pause.fill";
    } else if (self.tab == LSPickerTabRoute) {
        title = replay ? @"Replay route" : (mode == LSSessionModeOff ? @"Start route" : @"Replace with this route");
        symbol = replay ? @"arrow.counterclockwise" : (mode == LSSessionModeOff ? @"play.fill" : @"arrow.triangle.2.circlepath");
    } else if (applied) {
        title = @"Applied";
        symbol = @"checkmark.circle.fill";
    } else {
        title = mode == LSSessionModeOff ? @"Apply location" : @"Replace location";
        symbol = mode == LSSessionModeOff ? @"checkmark.circle.fill" : @"arrow.triangle.2.circlepath";
    }
    UIButtonConfiguration *primary = self.primaryButton.configuration;
    primary.title = title;
    primary.image = [UIImage systemImageNamed:symbol];
    self.primaryButton.configuration = primary;
    self.primaryButton.accessibilityLabel = title;
    self.primaryButton.accessibilityHint = applied ? @"This spot is already applied. Pick another place to replace it." : nil;
    // LSSetButtonEnabled fades the fallback glow too; Liquid Glass never gets one.
    LSSetButtonEnabled(self.primaryButton, self.tab == LSPickerTabRoute ? (controlsCurrentRoute || routeReady) : (self.hasSelection && !applied));
    UIButtonConfiguration *hold = self.holdButton.configuration;
    hold.title = controlsCurrentRoute ? @"Hold here" : @"Route controls";
    hold.image = [UIImage systemImageNamed:controlsCurrentRoute ? @"stop.fill" : @"playpause.fill"];
    self.holdButton.configuration = hold;
    self.holdButton.accessibilityLabel = hold.title;
    self.holdButton.accessibilityHint = controlsCurrentRoute ? @"Stops movement and holds the current point." : @"Pause, resume, or stop movement and hold here.";
    self.holdButton.showsMenuAsPrimaryAction = !controlsCurrentRoute;
    __weak typeof(self) weakSelf = self;
    UIAction *pause = [UIAction actionWithTitle:mode == LSSessionModePaused ? @"Resume route" : @"Pause route" image:[UIImage systemImageNamed:mode == LSSessionModePaused ? @"play.fill" : @"pause.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf togglePause]; }];
    UIAction *stop = [UIAction actionWithTitle:@"Stop route and hold here" image:[UIImage systemImageNamed:@"stop.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf holdHere]; }];
    self.holdButton.menu = controlsCurrentRoute ? nil : [UIMenu menuWithTitle:@"Applied route" children:@[pause, stop]];
    self.savePlaceButton.enabled = self.hasSelection;
    // Rows spring in and out, so the footer glass grows and shrinks instead of jumping.
    BOOL animated = self.view.window != nil;
    BOOL saved = self.tab == LSPickerTabSaved, off = mode == LSSessionModeOff;
    LSSetHidden(self.holdButton, !moving, animated);
    LSSetHidden(self.offButton, off, animated);
    LSSetHidden(self.playbackRow, off, animated);
    LSSetHidden(self.footerPrimaryRow, saved, animated);
    // Nothing to show on Saved while off: no empty glass bar.
    BOOL shown = !(saved && off);
    if (shown != self.footerShown) {
        self.footerShown = shown;
        LSSetHidden(self.footerView, !shown, animated);
        [self.view setNeedsLayout];
    }
}
- (UIView *)toastAnchorView { return self.footerShown ? self.footerView : nil; }
- (void)primaryAction {
    if (self.tab == LSPickerTabRoute) {
        LSSessionMode mode = LSSessionController.shared.snapshot.mode;
        if ((mode == LSSessionModeMoving || mode == LSSessionModePaused) && self.fetchedRoute == LSSessionController.shared.retainedRoute && !self.routeDraftChanged) [self togglePause];
        else [self startDraftRoute];
        return;
    }
    if (!self.hasSelection) return;
    // The visible Replace location action explicitly commits this reversible change.
    [self applyCoordinate:self.selectedCoordinate name:self.selectedName];
}
- (void)applyCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    // A saved place can carry its own wander radius (#19).
    LSBookmark *saved = [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
    if ([LSSessionController.shared applyStaticCoordinate:coordinate radiusOverride:saved ? saved.radius : NAN]) {
        [PersistenceManager.shared recordRecentCoordinate:coordinate name:name];
        self.appliedName = name.length ? name : nil;
        self.appliedNameCoordinate = coordinate;
        LSHapticApplied();
        self.pendingApplyRipple = LSMapAnimationsEnabled();
        [self refreshSession];
        [self celebrateApply];
        NSString *place = name.length ? [NSString stringWithFormat:@"“%@” applied.", name] : @"Location applied.";
        [self showMessage:[place stringByAppendingString:@" Close the picker to return to your app."] symbol:@"checkmark.circle.fill"];
    } else {
        [self showMessage:@"This location could not be applied." symbol:@"exclamationmark.triangle.fill"];
        LSHapticWarning();
    }
}
// The small moment when a spot goes live: the dot ripples, the pin and the radius pulse once,
// and the status capsules bump. Reduce Motion keeps only the state change and haptic.
- (void)celebrateApply {
    LSPuckView *puck = (id)[self.mapView viewForAnnotation:self.appliedPin];
    if ([puck isKindOfClass:LSPuckView.class]) { self.pendingApplyRipple = NO; [puck ripple]; }
    [self pulseRadius];
    if (!LSMapAnimationsEnabled()) return;
    if (self.tab == LSPickerTabLocation) { [self popPin]; LSBump(self.placeStatusRow); }
    LSBump(self.statusChip);
}
- (void)pulseRadius {
    if (!self.radiusCircle) return;
    MKCircleRenderer *renderer = (id)[self.mapView rendererForOverlay:self.radiusCircle];
    if (![renderer isKindOfClass:MKCircleRenderer.class]) return;
    renderer.fillColor = [LSAccentColor() colorWithAlphaComponent:0.3];
    renderer.lineWidth = 3;
    [renderer setNeedsDisplay];
    __weak MKCircleRenderer *weakRenderer = renderer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MKCircleRenderer *strong = weakRenderer;
        strong.fillColor = [LSAccentColor() colorWithAlphaComponent:0.12];
        strong.lineWidth = 1.5;
        [strong setNeedsDisplay];
    });
}
- (void)togglePause {
    if (LSSessionController.shared.snapshot.mode == LSSessionModePaused) [LSSessionController.shared resume];
    else [LSSessionController.shared pause];
    LSHapticSelection();
    [self refreshSession];
}
- (void)routeControlTapped { if (!self.holdButton.showsMenuAsPrimaryAction) [self holdHere]; }
- (void)holdHere {
    [LSSessionController.shared stopAndHold];
    [self refreshSession];
    [self showMessage:@"Route stopped. Holding its current location." symbol:@"stop.circle.fill"];
}
- (void)turnOff {
    // A held spot can come straight back from the toast; a route would restart, so it can't.
    PersistenceManager *store = PersistenceManager.shared;
    BOOL held = LSSessionController.shared.snapshot.mode == LSSessionModeStatic && store.hasStoredCoordinate;
    CLLocationCoordinate2D previous = held ? store.spoofCoordinate : kCLLocationCoordinate2DInvalid;
    NSString *name = held ? [self appliedPlaceName] : @"";
    [self cancelDirections];
    self.selectionRevision++;
    [LSSessionController.shared disable];
    LSHapticSuccess();
    [self refreshSession];
    NSString *message = @"Spoofing is off. Your app sees its real location.";
    if (!held) { [self showMessage:message symbol:@"location.slash.fill"]; return; }
    __weak typeof(self) weakSelf = self;
    LSShowActionToast(self.view, [self toastAnchorView], message, @"location.slash.fill", @"Apply again", ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed || LSSessionController.shared.snapshot.mode != LSSessionModeOff) return;
        [self applyCoordinate:previous name:name];
    });
}
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button action:(dispatch_block_t)action {
    [self confirmAction:title message:message button:button destructive:NO action:action];
}
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button destructive:(BOOL)destructive action:(dispatch_block_t)action {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:button style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(__unused UIAlertAction *item) { action(); }];
    [alert addAction:confirm];
    if (!destructive) alert.preferredAction = confirm;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

#pragma mark - Schedule

- (void)buildScheduleBadge {
    // A pending or running schedule shows as a dot on the clock instead of a row in the header,
    // so the map keeps the room. Tapping the clock then opens a menu headed by the schedule's
    // summary, with Change and Cancel; the summary is also the button's spoken value.
    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.userInteractionEnabled = NO;
    dot.isAccessibilityElement = NO;
    dot.backgroundColor = UIColor.systemIndigoColor;
    dot.layer.cornerRadius = 4.5;
    dot.hidden = YES;
    [self.scheduleButton addSubview:dot];
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:9],
        [dot.heightAnchor constraintEqualToConstant:9],
        [dot.centerXAnchor constraintEqualToAnchor:self.scheduleButton.trailingAnchor constant:-11],
        [dot.centerYAnchor constraintEqualToAnchor:self.scheduleButton.topAnchor constant:11]
    ]];
    self.scheduleBanner = dot;
}
- (void)setScheduleDotShown:(BOOL)shown animated:(BOOL)animated {
    if (shown == self.scheduleDotShown) return;
    self.scheduleDotShown = shown;
    UIView *dot = self.scheduleBanner;
    if (!animated || !LSMapAnimationsEnabled()) {
        [dot.layer removeAllAnimations];
        dot.hidden = !shown;
        dot.alpha = 1;
        dot.transform = CGAffineTransformIdentity;
        return;
    }
    __weak typeof(self) weakSelf = self;
    if (shown) {
        dot.hidden = NO;
        dot.alpha = 0;
        dot.transform = CGAffineTransformMakeScale(0.3, 0.3);
        LSAnimateBouncy(^{ dot.alpha = 1; dot.transform = CGAffineTransformIdentity; }, nil);
    } else {
        LSAnimate(^{ dot.alpha = 0; dot.transform = CGAffineTransformMakeScale(0.3, 0.3); }, ^{
            if (weakSelf.scheduleDotShown) return;
            dot.hidden = YES;
            dot.alpha = 1;
            dot.transform = CGAffineTransformIdentity;
        });
    }
}
- (void)updateScheduleBanner {
    LSSchedule *schedule = LSScheduler.shared.schedule;
    BOOL scheduled = schedule != nil;
    NSString *summary = schedule.summary;
    // Under Differentiate Without Color the symbol itself carries the state.
    BOOL glyph = UIAccessibilityShouldDifferentiateWithoutColor();
    [self setScheduleDotShown:scheduled && !glyph animated:self.view.window != nil];
    // One pulse when the scheduled start actually happens (not when the picker opens on it).
    NSInteger active = scheduled && schedule.isActive ? 1 : 0;
    if (self.scheduleActiveState == 0 && active == 1) [self pulseScheduleDot];
    self.scheduleActiveState = active;
    UIButtonConfiguration *clock = self.scheduleButton.configuration;
    UIImage *image = [UIImage systemImageNamed:!scheduled ? @"clock" : (glyph ? @"clock.badge.checkmark.fill" : @"clock.fill")];
    if (![clock.image isEqual:image]) {
        clock.image = image;
        self.scheduleButton.configuration = clock;
    }
    self.scheduleButton.accessibilityValue = scheduled ? summary : nil;
    self.scheduleButton.accessibilityHint = scheduled ? @"Shows the schedule, with Change and Cancel." : @"Start this location or route later, and turn it off at a set time.";
    self.scheduleButton.showsMenuAsPrimaryAction = scheduled;
    self.scheduleButton.menu = scheduled ? [self scheduleMenuWithSummary:summary] : nil;
    [self updateFooter];
}
- (void)pulseScheduleDot {
    if (!self.view.window || !LSMapAnimationsEnabled()) return;
    UIView *dot = self.scheduleBanner;
    if (!self.scheduleDotShown) { LSBump(self.scheduleButton); return; }
    LSAnimate(^{ dot.transform = CGAffineTransformMakeScale(1.35, 1.35); }, ^{
        LSAnimateBouncy(^{ dot.transform = CGAffineTransformIdentity; }, nil);
    });
}
- (UIMenu *)scheduleMenuWithSummary:(NSString *)summary {
    __weak typeof(self) weakSelf = self;
    UIAction *change = [UIAction actionWithTitle:@"Change schedule" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf openSchedule];
    }];
    UIAction *cancel = [UIAction actionWithTitle:@"Cancel schedule" image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf cancelScheduleWithUndo];
    }];
    cancel.attributes = UIMenuElementAttributesDestructive;
    // The destructive choice sits in its own group, apart from Change.
    UIMenu *danger = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[cancel]];
    return [UIMenu menuWithTitle:summary ?: @"Schedule" children:@[change, danger]];
}
- (void)cancelScheduleWithUndo {
    if (self.closed) return;
    BOOL (^restore)(void) = [self restorerForCurrentSchedule];
    LSSchedule *current = LSScheduler.shared.schedule;
    BOOL active = current.isActive, activeRoute = active && current.isRoute;
    [LSScheduler.shared cancel];
    LSHapticSuccess();
    [self updateScheduleBanner];
    if (!restore) {
        NSString *message = activeRoute ? @"Schedule cancelled. The route keeps playing."
                          : active ? @"Schedule cancelled. The location stays on." : @"Schedule cancelled.";
        [self showMessage:message symbol:@"clock.badge.xmark"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    LSShowActionToast(self.view, [self toastAnchorView], @"Schedule cancelled.", @"clock.badge.xmark", @"Undo", ^{
        typeof(self) self = weakSelf;
        // Something scheduled since wins over the old one.
        if (!self || self.closed) return;
        if (LSScheduler.shared.schedule) {
            [self showMessage:@"A newer schedule is already set." symbol:@"clock"];
            return;
        }
        if (restore()) { LSHapticSuccess(); [self updateScheduleBanner]; }
        else [self showMessage:@"The schedule could not be restored." symbol:@"exclamationmark.triangle.fill"];
    });
}
// Rebuilds the current schedule through the scheduler's public calls, from its saved form
// (read only). A schedule that already started has no restorer: scheduling it again would
// apply it a second time (a route from its first point, a location as a late start).
- (BOOL (^)(void))restorerForCurrentSchedule {
    LSSchedule *schedule = LSScheduler.shared.schedule;
    NSDictionary *stored = [[[NSUserDefaults alloc] initWithSuiteName:kLSDefaultsSuite] dictionaryForKey:@"LSSchedule"];
    if (!schedule || !stored) return nil;
    NSString *name = schedule.name;
    NSDate *start = schedule.startDate, *end = schedule.endDate;
    BOOL daily = schedule.repeatsDaily;
    if (schedule.isActive) return nil;
    if (schedule.isRoute) {
        LSRoute *route = [LSRoute routeFromDictionary:stored[@"route"] ?: @{}];
        LSPlaybackOptions *options = [LSPlaybackOptions optionsFromDictionary:stored[@"options"]];
        if (!route || !options) return nil;
        return ^BOOL(void) {
            return [LSScheduler.shared scheduleRoute:route options:options name:name start:start end:end repeatsDaily:daily];
        };
    }
    id latitude = stored[@"lat"], longitude = stored[@"lon"];
    if (![latitude isKindOfClass:NSNumber.class] || ![longitude isKindOfClass:NSNumber.class]) return nil;
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([latitude doubleValue], [longitude doubleValue]);
    double radius = [stored[@"radius"] isKindOfClass:NSNumber.class] ? [stored[@"radius"] doubleValue] : NAN;
    return ^BOOL(void) {
        return [LSScheduler.shared scheduleLocation:coordinate name:name radiusOverride:radius start:start end:end repeatsDaily:daily];
    };
}
- (void)differentiateWithoutColorChanged:(NSNotification *)note {
    (void)note;
    if (!self.closed) [self updateScheduleBanner];
}
- (void)scheduleChanged:(NSNotification *)note {
    (void)note;
    if (!self.closed) [self updateScheduleBanner];
}
- (void)showScheduleNotice {
    NSString *notice = [LSScheduler.shared takeNotice];
    if (notice) [self showMessage:notice symbol:@"clock.badge.exclamationmark.fill"];
}
- (void)openSchedule {
    LSScheduleViewController *controller = [[LSScheduleViewController alloc] init];
    if (self.tab == LSPickerTabRoute && self.fetchedRoute && !self.directions) {
        LSRoute *route = self.fetchedRoute;
        LSPlaybackOptions *options = [self draftOptions];
        controller.subject = [NSString stringWithFormat:@"Play the route “%@”", route.name];
        controller.subjectIsRoute = YES;
        controller.schedule = ^BOOL(NSDate *start, NSDate *end, BOOL daily) {
            return [LSScheduler.shared scheduleRoute:route options:options name:route.name start:start end:end repeatsDaily:daily];
        };
    } else if (self.tab == LSPickerTabLocation && self.hasSelection) {
        CLLocationCoordinate2D coordinate = self.selectedCoordinate;
        LSBookmark *saved = [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
        NSString *name = saved.name ?: self.selectedName;
        double radius = saved ? saved.radius : NAN;
        controller.subject = [NSString stringWithFormat:@"Hold “%@”", name];
        controller.schedule = ^BOOL(NSDate *start, NSDate *end, BOOL daily) {
            return [LSScheduler.shared scheduleLocation:coordinate name:name radiusOverride:radius start:start end:end repeatsDaily:daily];
        };
    }
    __weak typeof(self) weakSelf = self;
    controller.didFinish = ^(NSString *message) {
        [weakSelf updateScheduleBanner];
        [weakSelf showMessage:message symbol:@"clock.fill"];
    };
    [self presentEditor:controller];
}
- (void)presentShareItems:(NSArray *)items from:(UIView *)source {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    UIView *anchor = source.window ? source : self.view;
    share.popoverPresentationController.sourceView = anchor;
    share.popoverPresentationController.sourceRect = anchor == source ? source.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:share animated:LSMapAnimationsEnabled() completion:nil];
}
// A saved spot's tile reads Saved and opens a menu: its wander radius, or another copy.
- (void)updateSaveAction:(LSBookmark *)saved {
    UIButton *button = self.savePlaceButton;
    UIButtonConfiguration *config = button.configuration;
    config.title = saved ? @"Saved" : @"Save";
    config.image = [UIImage systemImageNamed:saved ? @"bookmark.fill" : @"bookmark"];
    button.configuration = config;
    button.largeContentTitle = config.title;
    button.showsMenuAsPrimaryAction = saved != nil;
    if (!saved) {
        button.menu = nil;
        button.accessibilityLabel = @"Save place";
        button.accessibilityHint = nil;
        return;
    }
    NSString *wander = !isfinite(saved.radius) ? @"default wander" : (saved.radius > 0 ? [NSString stringWithFormat:@"wanders %@ m", LSFormatDecimal(saved.radius, 0)] : @"stays put");
    button.accessibilityLabel = [NSString stringWithFormat:@"Saved as %@, %@", saved.name, wander];
    button.accessibilityHint = @"Shows the wander radius and save options.";
    __weak typeof(self) weakSelf = self;
    UIAction *copy = [UIAction actionWithTitle:@"Save another copy" image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf saveSelectedPlace];
    }];
    button.menu = [UIMenu menuWithTitle:saved.name children:@[[self radiusMenuForBookmark:saved], copy]];
}
- (void)saveTapped {
    // A saved spot's tile opens its menu instead.
    if (!self.savePlaceButton.showsMenuAsPrimaryAction) [self saveSelectedPlace];
}

#pragma mark - Editors

- (void)searchLocation {
    __weak typeof(self) weakSelf = self;
    [self openPlaceChooser:@"Choose a location" coordinate:self.selectedCoordinate completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
        typeof(self) self = weakSelf;
        [self setSelection:coordinate name:name];
        [self focusMapOnCoordinate:coordinate meters:2000 animated:YES];
        [self popPin];
    }];
}
- (void)openPlaceChooser:(NSString *)title coordinate:(CLLocationCoordinate2D)coordinate completion:(void (^)(CLLocationCoordinate2D, NSString *))completion {
    LSPlaceSearchController *search = [[LSPlaceSearchController alloc] init];
    search.title = title;
    search.initialCoordinate = coordinate;
    search.searchRegion = self.mapView.region;
    NSUInteger revision = ++self.selectionRevision;
    __weak typeof(self) weakSelf = self;
    search.didChoose = ^(CLLocationCoordinate2D result, NSString *name) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || self.selectionRevision != revision) return;
        completion(result, name);
    };
    [self presentEditor:search];
}
- (void)editCoordinates {
    LSCoordinateEntryController *entry = [[LSCoordinateEntryController alloc] init];
    entry.initialCoordinate = self.selectedCoordinate;
    entry.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(closeEditor)];
    NSUInteger revision = ++self.selectionRevision;
    __weak typeof(self) weakSelf = self;
    // The entry screen names pasted map links and looked-up spots; keep that name.
    entry.didChooseNamed = ^(CLLocationCoordinate2D coordinate, NSString *name) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.selectionRevision) return;
        [self setSelection:coordinate name:name.length ? name : @"Entered coordinates"];
        [self focusMapOnCoordinate:coordinate meters:2000 animated:YES];
        [self closeEditor];
    };
    [self presentEditor:entry];
}
- (void)closeEditor { self.selectionRevision++; [self.presentedViewController dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil]; }
- (void)presentEditor:(UIViewController *)editor {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.view.tintColor = LSAccentColor();
    nav.navigationBar.prefersLargeTitles = NO;
    nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
    nav.sheetPresentationController.prefersGrabberVisible = YES;
    nav.sheetPresentationController.preferredCornerRadius = 24;
    [self presentViewController:nav animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)openSettings {
    LSSettingsViewController *settings = [[LSSettingsViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    settings.didSave = ^{
        typeof(self) self = weakSelf;
        [self updateRadiusPreview]; [self updateRealLocation]; [self refreshSession];
        [self showMessage:@"Settings saved." symbol:@"checkmark.circle.fill"];
    };
    settings.didRestore = ^(NSString *message) {
        typeof(self) self = weakSelf;
        self.appliedName = nil;
        [self reloadSavedPlaces]; [self updateRadiusPreview]; [self updateRealLocation]; [self refreshSession];
        if (self.hasSelection && self.tab == LSPickerTabLocation) [self renderSelectedLocation];
        [self showMessage:message symbol:@"arrow.counterclockwise.circle.fill"];
    };
    [self presentEditor:settings];
}
- (void)dismissPicker {
    [self endPickerLifetime];
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:^{
        if (self.didDismiss) { self.didDismiss(); self.didDismiss = nil; }
    }];
}
- (BOOL)accessibilityPerformEscape { [self dismissPicker]; return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *close = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(dismissPicker)];
    close.discoverabilityTitle = @"Close location picker";
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray arrayWithObject:close];
    NSArray<NSString *> *names = @[@"Location", @"Route", @"Saved"];
    for (NSUInteger index = 0; index < names.count; index++) {
        UIKeyCommand *tab = [UIKeyCommand keyCommandWithInput:[NSString stringWithFormat:@"%lu", (unsigned long)index + 1] modifierFlags:UIKeyModifierCommand action:@selector(keyTab:)];
        tab.discoverabilityTitle = [NSString stringWithFormat:@"Show %@", names[index]];
        [commands addObject:tab];
    }
    UIKeyCommand *search = [UIKeyCommand keyCommandWithInput:@"f" modifierFlags:UIKeyModifierCommand action:@selector(keySearch)];
    search.discoverabilityTitle = @"Search places";
    [commands addObject:search];
    return commands;
}
- (void)copyCoordinates {
    if (!self.hasSelection) return;
    UIPasteboard.generalPasteboard.string = LSCoordinateText(self.selectedCoordinate);
    LSHapticSelection();
    [self showMessage:@"Coordinates copied." symbol:@"doc.on.doc.fill"];
    // The button itself confirms with a checkmark for a moment.
    [self setCopyButtonConfirmed:YES];
    NSUInteger revision = ++self.copyRevision;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && self.copyRevision == revision) [self setCopyButtonConfirmed:NO];
    });
}
- (void)setCopyButtonConfirmed:(BOOL)confirmed {
    UIButtonConfiguration *config = self.coordinateCopyButton.configuration;
    config.image = [UIImage systemImageNamed:confirmed ? @"checkmark" : @"doc.on.doc"];
    config.baseForegroundColor = confirmed ? LSSuccessColor() : UIColor.secondaryLabelColor;
    self.coordinateCopyButton.configuration = config;
    if (confirmed) LSBump(self.coordinateCopyButton);
}
- (void)useRealLocation {
    if (!self.realPin) return;
    [self setSelection:self.realPin.coordinate name:@"My real location"];
    [self focusMapOnCoordinate:self.realPin.coordinate meters:2000 animated:YES];
    [self popPin];
}

#pragma mark - Map

- (void)centerMap {
    CLLocation *applied = LSSessionController.shared.snapshot.location;
    CLLocationCoordinate2D coordinate = applied ? applied.coordinate : self.selectedCoordinate;
    if (self.tab == LSPickerTabRoute && self.routePolyline && !applied) {
        [self focusMapOnRect:self.routePolyline.boundingMapRect animated:YES];
        return;
    }
    if (!CLLocationCoordinate2DIsValid(coordinate) && self.startPin) coordinate = self.startPin.coordinate;
    if (CLLocationCoordinate2DIsValid(coordinate)) [self focusMapOnCoordinate:coordinate meters:2000 animated:YES];
    else [self showMessage:@"Choose a place or enter coordinates to center the map." symbol:@"scope"];
}
- (void)centerReal {
    if (self.realPin) [self focusMapOnCoordinate:self.realPin.coordinate meters:2000 animated:YES];
}
- (void)retryMap {
    MKCoordinateRegion region = self.mapView.region;
    [self replaceMap:&region];
    [self syncMapWorkspace];
    // The route screen owns its extra overlays (casing, travelled part); let it put them back.
    if (self.tab == LSPickerTabRoute) [self updateRouteUI];
    [self setMapState:LSMapStateLoading];
}
- (void)setMapState:(LSMapState)state {
    BOOL failed = state == LSMapStateFailed, loading = state == LSMapStateLoading;
    self.mapFailed = failed;
    self.mapStateView.hidden = state == LSMapStateReady;
    self.mapStateIcon.hidden = !failed;
    if (loading) [self.mapStateSpinner startAnimating];
    else [self.mapStateSpinner stopAnimating];
    self.mapRetryButton.hidden = !failed;
    self.mapStateTitle.text = failed ? @"Map unavailable" : @"Loading map…";
    self.mapErrorLabel.text = failed ? @"Check your connection and try again. Search, saved places and coordinates still work." : @"You can still search or enter coordinates.";
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) {
        // Only the renderers made here; the route screen re-resolves its own.
        for (MKOverlayRenderer *renderer in self.defaultRenderers) {
            if (![renderer isKindOfClass:MKOverlayPathRenderer.class]) continue;
            MKOverlayPathRenderer *path = (MKOverlayPathRenderer *)renderer;
            BOOL circle = [path isKindOfClass:MKCircleRenderer.class];
            path.strokeColor = circle ? LSAccentColor() : LSRouteColor();
            if (circle) path.fillColor = [LSAccentColor() colorWithAlphaComponent:0.12];
            [path setNeedsDisplay];
        }
    }
    if (![self.traitCollection.preferredContentSizeCategory isEqualToString:previous.preferredContentSizeCategory]) [self applyTextSizeLayout];
}
- (void)mapViewDidFailLoadingMap:(MKMapView *)map withError:(NSError *)error {
    (void)error;
    if (map != self.mapView || self.closed) return;
    [self setMapState:LSMapStateFailed];
    LSAnnounce(@"Map unavailable. Retry the map, search for a place, or enter coordinates.");
}
- (void)mapViewDidFinishLoadingMap:(MKMapView *)map {
    if (map == self.mapView && !self.mapFailed) [self setMapState:LSMapStateReady];
}
- (void)mapViewDidFinishRenderingMap:(MKMapView *)map fullyRendered:(BOOL)fullyRendered {
    if (map == self.mapView && fullyRendered) [self setMapState:LSMapStateReady];
}
- (MKAnnotationView *)mapView:(MKMapView *)map viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:MKUserLocation.class]) return nil;
    if ([annotation isKindOfClass:LSMovingAnnotation.class] || [annotation isKindOfClass:LSRealAnnotation.class]) {
        BOOL real = [annotation isKindOfClass:LSRealAnnotation.class];
        NSString *identifier = real ? @"LSRealPuck" : @"LSAppliedPuck";
        LSPuckView *puck = (id)[map dequeueReusableAnnotationViewWithIdentifier:identifier];
        if (!puck) puck = [[LSPuckView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
        puck.annotation = annotation;
        puck.canShowCallout = YES;
        puck.draggable = NO;
        puck.displayPriority = MKFeatureDisplayPriorityRequired;
        // The applied dot rides above route markers; the real dot stays underneath everything.
        puck.zPriority = real ? MKAnnotationViewZPriorityMin : MKAnnotationViewZPriorityMax;
        if (real) [puck configureWithColor:UIColor.systemGrayColor symbol:@"person.fill" diameter:20 pulsing:NO];
        else [self stylePuck:puck mode:LSSessionController.shared.snapshot.mode];
        puck.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", annotation.title ?: @"Location", LSCoordinateText(annotation.coordinate)];
        return puck;
    }
    BOOL routeMarker = [annotation isKindOfClass:LSStartAnnotation.class] || [annotation isKindOfClass:LSDestinationAnnotation.class] || [annotation isKindOfClass:LSStopAnnotation.class];
    // Separate reuse pools, so route styling never leaks into the preview pin.
    NSString *identifier = routeMarker ? @"LSRouteMarker" : @"LSMarker";
    MKMarkerAnnotationView *view = (id)[map dequeueReusableAnnotationViewWithIdentifier:identifier];
    if (!view) view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
    view.annotation = annotation;
    view.transform = CGAffineTransformIdentity;
    view.canShowCallout = YES;
    view.animatesWhenAdded = LSMapAnimationsEnabled();
    view.displayPriority = MKFeatureDisplayPriorityRequired;
    view.draggable = annotation == self.pin || annotation == self.startPin || annotation == self.endPin || [annotation isKindOfClass:LSStopAnnotation.class];
    view.markerTintColor = LSFillColor(LSErrorColor());
    view.glyphText = nil;
    view.glyphImage = [UIImage systemImageNamed:annotation == self.pin && self.placeApplied ? @"checkmark" : @"mappin"];
    // The place card names the pin; a caption under it only crowded the map.
    if (annotation == self.pin) view.titleVisibility = MKFeatureVisibilityHidden;
    if ([annotation isKindOfClass:LSStartAnnotation.class]) { view.markerTintColor = LSSuccessColor(); view.glyphImage = [UIImage systemImageNamed:@"figure.walk"]; }
    if ([annotation isKindOfClass:LSDestinationAnnotation.class]) { view.markerTintColor = LSErrorColor(); view.glyphImage = [UIImage systemImageNamed:@"flag.checkered"]; }
    if ([annotation isKindOfClass:LSStopAnnotation.class]) {
        NSUInteger index = [self.routeStops indexOfObject:(LSStopAnnotation *)annotation];
        view.markerTintColor = LSWarningColor();
        view.glyphImage = nil;
        view.glyphText = index == NSNotFound ? nil : [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
    }
    view.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", annotation.title ?: @"Location", LSCoordinateText(annotation.coordinate)];
    view.accessibilityHint = view.draggable ? @"Drag to edit, or use the search and coordinate buttons." : nil;
    // Last, so the route screen's own labels and colours win.
    if (routeMarker) [self styleRouteAnnotationView:view];
    return view;
}
- (void)mapView:(MKMapView *)map didAddAnnotationViews:(NSArray<MKAnnotationView *> *)views {
    if (map != self.mapView || !self.pendingApplyRipple) return;
    // The applied dot is created lazily, so its first ripple waits for the view to exist.
    for (MKAnnotationView *view in views) {
        if (view.annotation != self.appliedPin || ![view isKindOfClass:LSPuckView.class]) continue;
        self.pendingApplyRipple = NO;
        [(LSPuckView *)view ripple];
    }
}
- (void)mapView:(MKMapView *)map annotationView:(MKAnnotationView *)view didChangeDragState:(MKAnnotationViewDragState)newState fromOldState:(MKAnnotationViewDragState)oldState {
    (void)map; (void)oldState;
    if (newState == MKAnnotationViewDragStateStarting) { LSHapticPrepare(); return; }
    if (newState != MKAnnotationViewDragStateEnding) return;
    if (view.annotation == self.startPin) [self assignEndpoint:LSEndpointFrom coordinate:view.annotation.coordinate name:@"Map point"];
    else if (view.annotation == self.endPin) [self assignEndpoint:LSEndpointTo coordinate:view.annotation.coordinate name:@"Map point"];
    else if (view.annotation == self.pin) {
        [self setSelection:view.annotation.coordinate name:@"Dropped pin"];
        [self finishLocationHint];
        [self nameDroppedPinThen:nil];
    }
    else if ([view.annotation isKindOfClass:LSStopAnnotation.class]) [self moveStop:(LSStopAnnotation *)view.annotation to:view.annotation.coordinate name:@"Map point"];
    LSHapticPinDrop();
    [view setDragState:MKAnnotationViewDragStateNone animated:LSMapAnimationsEnabled()];
}
- (MKOverlayRenderer *)mapView:(MKMapView *)map rendererForOverlay:(id<MKOverlay>)overlay {
    (void)map;
    MKOverlayRenderer *routeRenderer = [self routeRendererForOverlay:overlay];
    if (routeRenderer) return routeRenderer;
    if ([overlay isKindOfClass:MKCircle.class]) {
        MKCircleRenderer *renderer = [[MKCircleRenderer alloc] initWithCircle:(MKCircle *)overlay];
        renderer.strokeColor = LSAccentColor(); renderer.fillColor = [LSAccentColor() colorWithAlphaComponent:0.12]; renderer.lineWidth = 1.5;
        renderer.lineDashPattern = @[@6, @4];
        [self.defaultRenderers addObject:renderer];
        return renderer;
    }
    MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
    renderer.strokeColor = LSRouteColor(); renderer.lineWidth = 6;
    renderer.lineCap = kCGLineCapRound; renderer.lineJoin = kCGLineJoinRound;
    [self.defaultRenderers addObject:renderer];
    return renderer;
}
- (void)updateRadiusPreview {
    if (self.radiusCircle) [self.mapView removeOverlay:self.radiusCircle];
    self.radiusCircle = nil;
    if (self.tab != LSPickerTabLocation || !self.hasSelection) return;
    LSBookmark *saved = [BookmarksManager.shared bookmarkNearCoordinate:self.selectedCoordinate];
    double radius = saved && isfinite(saved.radius) ? saved.radius
                  : (PersistenceManager.shared.fluctuationEnabled ? PersistenceManager.shared.fluctuationRadius : 0);
    if (radius > 0) {
        self.radiusCircle = [MKCircle circleWithCenterCoordinate:self.selectedCoordinate radius:radius];
        [self.mapView addOverlay:self.radiusCircle];
    }
}
- (void)setRealControlsVisible:(BOOL)visible {
    self.realCenterButton.hidden = !visible;
    self.realSeparator.hidden = !visible;
    self.useRealButton.hidden = !visible || self.tab != LSPickerTabLocation;
}
- (void)hideRealLocation {
    if (self.realPin) [self.mapView removeAnnotation:self.realPin];
    self.realPin = nil;
    [self setRealControlsVisible:NO];
}
- (void)updateRealLocation {
    NSUInteger revision = ++self.realRevision;
    [self.realManager stopUpdatingLocation];
    BOOL foreground = self.view.window && (self.view.window.windowScene ? self.view.window.windowScene.activationState == UISceneActivationStateForegroundActive : UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    BOOL enabled = PersistenceManager.shared.showRealLocation && !self.closed && foreground && self.tab != LSPickerTabSaved;
    self.realNoticeLabel.hidden = !enabled;
    if (!enabled) { [self hideRealLocation]; return; }
    if (!self.realManager) {
        self.realManager = [[CLLocationManager alloc] init];
        LSMarkLibraryLocationManager(self.realManager);
        self.realManager.delegate = self;
        self.realManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        self.realManager.distanceFilter = 50;
    }
    CLAuthorizationStatus status = self.realManager.authorizationStatus;
    if (status != kCLAuthorizationStatusAuthorizedAlways && status != kCLAuthorizationStatusAuthorizedWhenInUse) {
        [self hideRealLocation];
        self.realNoticeLabel.text = @"Real location is unavailable with the app’s current permission. You can still select a location.";
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.realNoticeLabel.text = @"Updating real location…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL available = CLLocationManager.locationServicesEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.closed || revision != self.realRevision || !self.view.window ||
                (self.view.window.windowScene && self.view.window.windowScene.activationState != UISceneActivationStateForegroundActive)) return;
            if (available) [self.realManager startUpdatingLocation];
            else self.realNoticeLabel.text = @"Location Services are off. You can still select a location manually.";
        });
    });
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager { if (manager == self.realManager) [self updateRealLocation]; }
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    if (manager != self.realManager || !location || location.horizontalAccuracy < 0 || !CLLocationCoordinate2DIsValid(location.coordinate) || self.closed || !self.view.window || !PersistenceManager.shared.showRealLocation || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        (self.view.window.windowScene && self.view.window.windowScene.activationState != UISceneActivationStateForegroundActive)) return;
    BOOL added = !self.realPin;
    if (added) { self.realPin = [[LSRealAnnotation alloc] init]; self.realPin.title = @"Real location"; }
    self.realPin.coordinate = location.coordinate;
    if (added) [self.mapView addAnnotation:self.realPin];
    [self setRealControlsVisible:YES];
    self.realNoticeLabel.text = @"The gray dot is your real location. The app never receives it while spoofing.";
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)error;
    if (manager == self.realManager && !self.closed) self.realNoticeLabel.text = @"Real location could not be updated. Your selected location still works.";
}

#pragma mark - Saved table

// Saved places, saved routes, recently applied.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; return [self savedRowsInSection:section]; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path { (void)table; return [self savedCell:path]; }
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path { [table deselectRowAtIndexPath:path animated:NO]; [self previewSavedPlace:path]; }
- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    return path.section == 0 ? self.savedPlaces.count > 0 : (path.section == 1 ? self.savedRoutes.count > 0 : self.recents.count > 0);
}
- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path { (void)table; return path.section == 0 && self.savedPlaces.count > 1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path { (void)table; (void)path; return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path { (void)table; (void)path; return NO; }
- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)destination {
    (void)table; (void)source;
    NSInteger last = (NSInteger)self.savedPlaces.count - 1;
    // Dropping into the Recents section used to land the place at the top of the list.
    if (destination.section > 0) return [NSIndexPath indexPathForRow:last inSection:0];
    return [NSIndexPath indexPathForRow:MIN(MAX(destination.row, 0), last) inSection:0];
}
- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination { (void)table; [self moveSavedPlace:source to:destination]; }
- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point { (void)table; (void)point; return [self savedMenu:path]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path { (void)table; return [self savedSwipeActions:path leading:NO]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path { (void)table; return [self savedSwipeActions:path leading:YES]; }
@end
