#import "OverlayWindow.h"
#import "MapPickerViewController.h"
#import "LSHooking.h"
#import "PersistenceManager.h"
#import "SessionController.h"
#import "LSUI.h"
#import <objc/runtime.h>

// An opener window never becomes key and only its actual button receives touches,
// plus the quick-action menu UIKit shows in this window while it is open.
@interface LSOpenerWindow : UIWindow
@property (nonatomic, weak) UIView *opener;
@end
@implementation LSOpenerWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    if (hit == self.opener || [hit isDescendantOfView:self.opener]) return hit;
    UIView *root = self.rootViewController.view;
    // The open menu lives outside the root view; everything else passes through to the app.
    if (root && hit != self && hit != root && ![hit isDescendantOfView:root]) return hit;
    return nil;
}
@end

// MARK: - Opener look and behaviour

// Floating opener: a glass disc that shows the session at a glance, can be thrown to
// either side (or pushed into the edge to tuck it away), remembers where it was left,
// and steps back to a faint ghost while it is not being used.
static NSString * const kLSOpenerSideKey = @"LSOpenerSide";
static NSString * const kLSOpenerYKey = @"LSOpenerY";
static NSString * const kLSOpenerTuckedKey = @"LSOpenerTucked";
static NSString * const kLSOpenerHintKey = @"LSOpenerHintShown";
static NSString * const kLSOpenerTuckHintKey = @"LSOpenerTuckHintShown";
static const CGFloat kLSOpenerSize = 56;
static const CGFloat kLSOpenerMargin = 10;      // from the safe area when docked
static const CGFloat kLSOpenerDiscInset = 4;    // glass rim around the state disc
static const CGFloat kLSOpenerTabWidth = 30;    // what stays on screen when tucked
static const NSTimeInterval kLSOpenerIdleDelay = 4;

static NSUserDefaults *LSOpenerDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.locationspoofer.dylib"]; });
    return defaults;
}

// Past a limit the opener follows the finger less and less, like a scroll view.
static CGFloat LSRubberBand(CGFloat value, CGFloat minimum, CGFloat maximum, CGFloat dimension) {
    if (maximum < minimum) maximum = minimum;
    CGFloat over = value < minimum ? minimum - value : (value > maximum ? value - maximum : 0);
    if (over <= 0 || dimension <= 0) return value;
    CGFloat eased = (1 - 1 / (over * 0.55 / dimension + 1)) * dimension;
    return value < minimum ? minimum - eased : maximum + eased;
}
// Where a flick would come to rest if it decelerated like a scroll view.
static CGFloat LSProjectedDistance(CGFloat velocity) {
    const CGFloat rate = 0.995;
    return velocity / 1000 * rate / (1 - rate);
}
// UIKit springs take velocity relative to the distance left to travel.
static CGFloat LSRelativeVelocity(CGFloat velocity, CGFloat distance) {
    if (fabs(distance) < 1 || !isfinite(velocity)) return 0;
    return MAX(-30, MIN(30, velocity / distance));
}

// Fill shades keep the white glyph and ring legible in both appearances.
static UIColor *LSOpenerDiscColor(LSSessionMode mode) {
    switch (mode) {
        case LSSessionModeStatic: return LSFillColor(LSAccentColor());
        case LSSessionModeMoving: return LSFillColor(LSSuccessColor());
        case LSSessionModePaused: return LSFillColor(LSWarningColor());
        case LSSessionModeOff: break;
    }
    return UIColor.clearColor;
}
static NSString *LSOpenerSymbol(LSSessionMode mode) {
    // Moving uses a plain arrow so it can turn with the route's heading.
    switch (mode) {
        case LSSessionModeOff: return @"location.fill";
        case LSSessionModeMoving: return @"location.north.fill";
        case LSSessionModeStatic:
        case LSSessionModePaused: break;
    }
    return LSSessionSymbol(mode);
}
static NSString *LSOpenerAnnouncement(LSSessionMode mode) {
    return mode == LSSessionModeOff ? @"Spoofing is off" : LSSessionTitle(mode);
}
// Two scenes can each show an opener; one spoken message is enough.
static void LSOpenerAnnounce(NSString *message) {
    static NSString *last;
    static CFTimeInterval lastTime;
    CFTimeInterval now = CACurrentMediaTime();
    if ([message isEqualToString:last] && now - lastTime < 1) return;
    last = message;
    lastTime = now;
    LSAnnounce(message);
}

static double LSOpenerRouteProgress(void) {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    double total = engine.totalDistance;
    return total > 0 && isfinite(total) ? MAX(0, MIN(1, engine.distanceCovered / total)) : 0;
}
static BOOL LSOpenerRouteComplete(void) {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    return LSSessionController.shared.retainedRoute && engine.totalDistance > 0 && engine.distanceCovered >= engine.totalDistance;
}
static NSString *LSOpenerSpeedText(void) {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    LSPlaybackOptions *options = engine.options;
    return options.recordedPace && engine.route.hasTiming
        ? [NSString stringWithFormat:@"Recorded pace ×%@", LSFormatDecimal(options.paceMultiplier, 2)]
        : [NSString stringWithFormat:@"%@ km/h", LSFormatDecimal(options.speedKmh, 0)];
}
static NSString * _Nullable LSOpenerDuration(NSTimeInterval seconds, BOOL spoken) {
    if (!isfinite(seconds) || seconds <= 0) return nil;
    if (seconds < 60) return spoken ? @"under a minute" : @"under 1 min";
    // Made once: the status is rebuilt for every menu open and VoiceOver query.
    static NSDateComponentsFormatter *shortFormatter, *spokenFormatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shortFormatter = [[NSDateComponentsFormatter alloc] init];
        spokenFormatter = [[NSDateComponentsFormatter alloc] init];
        for (NSDateComponentsFormatter *formatter in @[shortFormatter, spokenFormatter]) {
            formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
            formatter.maximumUnitCount = 2;
        }
        shortFormatter.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
        spokenFormatter.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
    });
    return [spoken ? spokenFormatter : shortFormatter stringFromTimeInterval:seconds];
}
// What is happening now: the quick menu's header, or the button's VoiceOver value.
static NSString *LSOpenerStatus(BOOL spoken) {
    LSSessionSnapshot *snapshot = LSSessionController.shared.snapshot;
    LSSessionMode mode = snapshot.mode;
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:spoken ? LSOpenerAnnouncement(mode) : LSSessionTitle(mode)];
    if (mode == LSSessionModeMoving || mode == LSSessionModePaused) {
        NSString *percent = [NSString stringWithFormat:spoken ? @"%.0f percent done" : @"%.0f%%", floor(LSOpenerRouteProgress() * 100)];
        if (mode == LSSessionModeMoving && engine.isWaitingAtStop) {
            parts[0] = @"Waiting at a stop";
            [parts addObject:percent];
            double wait = engine.waitRemaining;
            if (isfinite(wait) && wait > 0) {
                NSString *rest = wait < 60 ? [NSString stringWithFormat:spoken ? @"%.0f seconds" : @"%.0f s", ceil(wait)] : LSOpenerDuration(wait, spoken);
                if (rest) [parts addObject:[NSString stringWithFormat:@"moving on in %@", rest]];
            }
        } else {
            [parts addObject:percent];
            [parts addObject:LSOpenerSpeedText()];
            NSString *left = mode == LSSessionModeMoving ? LSOpenerDuration([engine remainingTimeEstimate], spoken) : nil;
            if (left) [parts addObject:[NSString stringWithFormat:@"%@ left", left]];
        }
    } else if (mode == LSSessionModeStatic && snapshot.location && !spoken) {
        [parts addObject:LSCoordinateText(snapshot.location.coordinate)];
    }
    return [parts componentsJoinedByString:spoken ? @", " : @" · "];
}

// The opener's own view. While tucked its touch area reaches past the visible tab, so
// the sliver left on screen is still a full-size target.
@interface LSOpenerView : UIView
@property (nonatomic) UIEdgeInsets hitInsets;
@end
@implementation LSOpenerView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(UIEdgeInsetsInsetRect(self.bounds, self.hitInsets), point);
}
@end

@interface LSOpenerViewController : UIViewController
@property (nonatomic, copy, nullable) void (^openPicker)(void);
@property (nonatomic, readonly) UIView *opener;
@property (nonatomic) BOOL leaving;
- (void)openerDidAppear;
- (void)openerWillHide;
- (void)leaveWithCompletion:(dispatch_block_t)completion;
// Called by the button.
- (void)wake;
- (void)activateFromAccessibility:(BOOL)accessibility;
- (void)menuWillShow;
- (void)menuDidEnd;
- (NSArray<UIAccessibilityCustomAction *> *)accessibilityQuickActions;
- (UIMenu *)openerMenu;
@end

// The touch, menu and accessibility element. Its value and actions are built on demand,
// so nothing is computed for VoiceOver while it is off.
@interface LSOpenerButton : UIButton
@property (nonatomic, weak) LSOpenerViewController *owner;
@end
@implementation LSOpenerButton
- (NSString *)accessibilityValue { return LSOpenerStatus(YES); }
- (NSArray<UIAccessibilityCustomAction *> *)accessibilityCustomActions {
    NSArray<UIAccessibilityCustomAction *> *mine = [self.owner accessibilityQuickActions] ?: @[];
    NSArray<UIAccessibilityCustomAction *> *system = [super accessibilityCustomActions];
    return system.count ? [mine arrayByAddingObjectsFromArray:system] : mine;
}
- (BOOL)accessibilityActivate {
    [self.owner activateFromAccessibility:YES];
    return YES;
}
- (void)accessibilityElementDidBecomeFocused { [self.owner wake]; }
// Rebuilt at the moment UIKit asks for it (touch, pointer or keyboard), so its header is current.
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    LSOpenerViewController *owner = self.owner;
    if (owner) self.menu = [owner openerMenu];
    return [super contextMenuInteraction:interaction configurationForMenuAtLocation:location];
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
    [self.owner menuWillShow];
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    [self.owner menuDidEnd];
}
@end

@interface LSOpenerViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) LSOpenerView *container;
@property (nonatomic, strong) CALayer *halo;
@property (nonatomic, strong) UIVisualEffectView *glass;
@property (nonatomic, strong, nullable) UIVisualEffect *glassEffect;
@property (nonatomic, strong) UIView *backing;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIView *face;
@property (nonatomic, strong) UIView *disc;
@property (nonatomic, strong) CAShapeLayer *trackLayer;
@property (nonatomic, strong) CAShapeLayer *progressLayer;
@property (nonatomic, strong) UIImageView *glyph;
@property (nonatomic, strong) UIImageView *tabGlyph;
@property (nonatomic, strong) UIView *tabProgress;
@property (nonatomic, strong) CAShapeLayer *tabTrackLayer;
@property (nonatomic, strong) CAShapeLayer *tabProgressLayer;
@property (nonatomic, strong, nullable) UIVisualEffectView *hintPointer;
@property (nonatomic, strong) LSOpenerButton *button;
@property (nonatomic, strong) UITapGestureRecognizer *tabTap;
@property (nonatomic, strong, nullable) UIVisualEffectView *hint;
@property (nonatomic, strong, nullable) UILabel *hintLabel;
@property (nonatomic, strong, nullable) UIVisualEffect *hintEffect;
@property (nonatomic, strong, nullable) UIViewPropertyAnimator *snapAnimator;
@property (nonatomic, strong, nullable) NSTimer *dimTimer;
@property (nonatomic) LSSessionMode shownMode;
@property (nonatomic) BOOL hasShownMode;
@property (nonatomic) CFTimeInterval lastRingUpdate;
@property (nonatomic) CFTimeInterval lastHeadingUpdate;
@property (nonatomic) CGFloat glyphAngle;
@property (nonatomic) CGPoint dragOrigin;
@property (nonatomic) NSUInteger snapGeneration;
@property (nonatomic) NSUInteger visibilityGeneration;
@property (nonatomic) BOOL dragging, lifted, pressed, dimmed, menuOpen, tucked, right, glassOn;
@property (nonatomic) BOOL dragProjectedRight, dragInTuckZone, offFromQuickAction;
@end

@implementation LSOpenerViewController
- (void)loadView {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = UIColor.clearColor;
    view.accessibilityViewIsModal = NO;
    self.view = view;
}
- (UIView *)opener { return self.container; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.right = YES;
    self.glassOn = YES;
    CGRect bounds = CGRectMake(0, 0, kLSOpenerSize, kLSOpenerSize);
    LSOpenerView *container = [[LSOpenerView alloc] initWithFrame:bounds];
    container.layer.shadowColor = UIColor.blackColor.CGColor;
    container.layer.shadowOffset = CGSizeMake(0, 4);
    container.layer.shadowRadius = 10;
    // An explicit path keeps the always-visible shadow out of an offscreen pass while the host redraws.
    container.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:bounds].CGPath;
    [self.view addSubview:container];
    self.container = container;

    // Slow breathing ring behind the glass while a route plays.
    CALayer *halo = [CALayer layer];
    halo.frame = bounds;
    halo.cornerRadius = kLSOpenerSize / 2;
    halo.opacity = 0;
    [container.layer addSublayer:halo];
    self.halo = halo;

    UIVisualEffectView *glass = LSGlassView(kLSOpenerSize / 2, YES);
    glass.translatesAutoresizingMaskIntoConstraints = YES;
    glass.frame = bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:glass];
    self.glass = glass;
    self.glassEffect = glass.effect;

    // Shown instead of the glass while idle (a faint ghost) and under Reduce Transparency.
    UIView *backing = [[UIView alloc] initWithFrame:bounds];
    backing.userInteractionEnabled = NO;
    backing.alpha = 0;
    [glass.contentView addSubview:backing];
    self.backing = backing;

    UIView *content = [[UIView alloc] initWithFrame:bounds];
    content.userInteractionEnabled = NO;
    [glass.contentView addSubview:content];
    self.content = content;
    UIView *face = [[UIView alloc] initWithFrame:bounds];
    face.userInteractionEnabled = NO;
    [content addSubview:face];
    self.face = face;

    UIView *disc = [[UIView alloc] initWithFrame:CGRectInset(bounds, kLSOpenerDiscInset, kLSOpenerDiscInset)];
    disc.layer.cornerRadius = disc.bounds.size.width / 2;
    disc.userInteractionEnabled = NO;
    disc.alpha = 0;
    [face addSubview:disc];
    self.disc = disc;
    CGFloat discRadius = disc.bounds.size.width / 2;
    UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(discRadius, discRadius) radius:discRadius - 4
                                                    startAngle:-M_PI_2 endAngle:3 * M_PI_2 clockwise:YES];
    CAShapeLayer *track = [CAShapeLayer layer], *progress = [CAShapeLayer layer];
    for (CAShapeLayer *layer in @[track, progress]) {
        layer.frame = disc.bounds;
        layer.path = ring.CGPath;
        layer.fillColor = nil;
        layer.lineWidth = 3;
        layer.lineCap = kCALineCapRound;
        layer.hidden = YES;
        [disc.layer addSublayer:layer];
    }
    progress.strokeColor = UIColor.whiteColor.CGColor;
    progress.strokeEnd = 0;
    self.trackLayer = track;
    self.progressLayer = progress;

    UIImageView *glyph = [[UIImageView alloc] initWithFrame:bounds];
    glyph.contentMode = UIViewContentModeCenter;
    glyph.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    [face addSubview:glyph];
    self.glyph = glyph;
    UIImageView *tab = [[UIImageView alloc] initWithFrame:bounds];
    tab.contentMode = UIViewContentModeCenter;
    tab.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold];
    tab.alpha = 0;
    [content addSubview:tab];
    self.tabGlyph = tab;
    // Route progress along the exposed rim while tucked; its path follows the side.
    UIView *tabProgress = [[UIView alloc] initWithFrame:bounds];
    tabProgress.userInteractionEnabled = NO;
    tabProgress.alpha = 0;
    CAShapeLayer *tabTrack = [CAShapeLayer layer], *tabFill = [CAShapeLayer layer];
    for (CAShapeLayer *layer in @[tabTrack, tabFill]) {
        layer.frame = bounds;
        layer.fillColor = nil;
        layer.lineWidth = 3;
        layer.lineCap = kCALineCapRound;
        [tabProgress.layer addSublayer:layer];
    }
    tabFill.strokeEnd = 0;
    [content addSubview:tabProgress];
    self.tabProgress = tabProgress;
    self.tabTrackLayer = tabTrack;
    self.tabProgressLayer = tabFill;

    LSOpenerButton *button = [LSOpenerButton buttonWithType:UIButtonTypeCustom];
    button.frame = bounds;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    button.owner = self;
    button.accessibilityLabel = @"LSpoof";
    button.accessibilityHint = @"Opens the LSpoof picker. You can hide this button in Settings.";
    button.largeContentTitle = @"LSpoof";
    button.showsLargeContentViewer = YES;
    button.scalesLargeContentImage = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    button.menu = [self openerMenu];
    button.showsMenuAsPrimaryAction = NO;
    [button addTarget:self action:@selector(pressDown) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [button addTarget:self action:@selector(pressUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [glass.contentView addSubview:button];
    self.button = button;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [container addGestureRecognizer:pan];
    // Only for the stretch of touch area beside a tucked tab; taps on the glass reach the button.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tabTapped:)];
    tap.enabled = NO;
    tap.delegate = self;
    [container addGestureRecognizer:tap];
    self.tabTap = tap;

    [self updateForSessionAnimated:NO];
    [self applyAppearance];
    [self applyChromeValues];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(sessionChanged:) name:LSSessionDidChangeNotification object:nil];
    for (NSNotificationName name in @[UIAccessibilityReduceTransparencyStatusDidChangeNotification, UIAccessibilityDarkerSystemColorsStatusDidChangeNotification,
                                      UIAccessibilityVoiceOverStatusDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification,
                                      UIAccessibilityShouldDifferentiateWithoutColorDidChangeNotification]) {
        [center addObserver:self selector:@selector(accessibilityChanged:) name:name object:nil];
    }
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_dimTimer invalidate];
}

// MARK: Session state

- (void)sessionChanged:(NSNotification *)note {
    (void)note;
    LSSessionMode mode = LSSessionController.shared.snapshot.mode;
    if (!self.hasShownMode || mode != self.shownMode) { [self updateForSessionAnimated:YES]; return; }
    if (mode != LSSessionModeMoving || ![self isOnScreen]) return;
    // Route ticks arrive at up to 10 Hz: the arrow turns at most 4 times a second and the
    // ring moves once a second, gliding linearly in between.
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastHeadingUpdate >= 0.25) {
        self.lastHeadingUpdate = now;
        [self turnGlyphToHeading:LSRouteSimulator.shared.currentHeading animated:YES];
    }
    if (now - self.lastRingUpdate >= 1) {
        self.lastRingUpdate = now;
        [self setRingProgress:LSOpenerRouteProgress() duration:1];
    }
}
- (BOOL)isOnScreen {
    UIWindow *window = self.view.window;
    return window && !window.hidden && !self.leaving;
}
- (void)updateForSessionAnimated:(BOOL)animated {
    LSSessionMode previous = self.shownMode, mode = LSSessionController.shared.snapshot.mode;
    BOOL changed = self.hasShownMode && previous != mode;
    self.shownMode = mode;
    self.hasShownMode = YES;
    animated = animated && [self isOnScreen];
    BOOL off = mode == LSSessionModeOff, route = mode == LSSessionModeMoving || mode == LSSessionModePaused;
    BOOL arrived = changed && previous == LSSessionModeMoving && mode == LSSessionModeStatic && LSOpenerRouteComplete();
    UIImage *image = [UIImage systemImageNamed:LSOpenerSymbol(mode)];
    UIColor *disc = LSOpenerDiscColor(mode);
    void (^colours)(void) = ^{
        self.disc.backgroundColor = disc;
        self.disc.alpha = off ? 0 : 1;
        self.glyph.tintColor = off ? LSSessionColor(LSSessionModeStatic) : UIColor.whiteColor;
    };
    if (mode != LSSessionModeMoving) [self resetGlyphRotation];
    if (animated) {
        [UIView transitionWithView:self.glyph duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:^{ self.glyph.image = image; } completion:nil];
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:colours completion:nil];
    } else {
        self.glyph.image = image;
        colours();
    }
    self.glyph.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:off ? 22 : 20 weight:UIImageSymbolWeightSemibold];
    self.button.largeContentImage = image;

    // Progress ring: solid while playing, dotted while paused, completed on arrival.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.progressLayer.lineDashPattern = mode == LSSessionModePaused ? @[@0, @6] : nil;
    self.tabProgressLayer.lineDashPattern = self.progressLayer.lineDashPattern;
    [CATransaction commit];
    self.button.accessibilityTraits = mode == LSSessionModeMoving ? UIAccessibilityTraitButton | UIAccessibilityTraitUpdatesFrequently : UIAccessibilityTraitButton;
    if (route) {
        [self setRingHidden:NO];
        [self setRingProgress:LSOpenerRouteProgress() duration:animated ? 0.3 : 0];
        self.lastRingUpdate = CACurrentMediaTime();
        if (mode == LSSessionModeMoving) [self turnGlyphToHeading:LSRouteSimulator.shared.currentHeading animated:NO];
    } else if (arrived && animated && !self.progressLayer.hidden) {
        [self setRingProgress:1 duration:0.3];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LSOpenerViewController *strongSelf = weakSelf;
            LSSessionMode now = strongSelf.shownMode;
            if (strongSelf && now != LSSessionModeMoving && now != LSSessionModePaused) [strongSelf setRingHidden:YES];
        });
    } else {
        [self setRingHidden:YES];
    }
    [self updateTab];
    [self applyAppearance];
    [self updateHalo];
    BOOL offerLast = self.offFromQuickAction && off && PersistenceManager.shared.hasStoredCoordinate;
    if (changed) self.offFromQuickAction = NO;
    if (changed && animated) {
        [self wake];
        [self pop];
        if (arrived) LSHapticSuccess();
        NSString *message = arrived ? @"Arrived. Holding location" : LSOpenerAnnouncement(mode);
        if (offerLast) message = @"Spoofing is off. Apply last location is in quick actions";
        LSOpenerAnnounce(message);
    }
}
- (void)setRingHidden:(BOOL)hidden {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.trackLayer.hidden = hidden;
    self.progressLayer.hidden = hidden;
    if (hidden) self.progressLayer.strokeEnd = self.tabProgressLayer.strokeEnd = 0;
    [CATransaction commit];
}
- (void)setRingProgress:(double)progress duration:(NSTimeInterval)duration {
    [CATransaction begin];
    [CATransaction setDisableActions:duration <= 0 || !LSMapAnimationsEnabled()];
    [CATransaction setAnimationDuration:duration];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    CGFloat value = MAX(0, MIN(1, progress));
    self.progressLayer.strokeEnd = value;
    self.tabProgressLayer.strokeEnd = value;
    [CATransaction commit];
}
// Turns the arrow by the short way round; the layer's angle keeps accumulating so a
// heading crossing north or south never spins the glyph a full turn.
- (void)turnGlyphToHeading:(CLLocationDirection)heading animated:(BOOL)animated {
    if (!isfinite(heading) || heading < 0) return;
    CGFloat from = self.glyphAngle;
    CGFloat delta = remainder(heading * M_PI / 180.0 - from, 2 * M_PI);
    if (fabs(delta) < 0.01) return;
    CGFloat to = from + delta;
    self.glyphAngle = to;
    CALayer *layer = self.glyph.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = CATransform3DMakeRotation(to, 0, 0, 1);
    [CATransaction commit];
    if (!animated || !LSMapAnimationsEnabled()) return;
    CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    turn.fromValue = @(from);
    turn.toValue = @(to);
    turn.duration = 0.25;
    [layer addAnimation:turn forKey:@"heading"];
}
- (void)resetGlyphRotation {
    [self.glyph.layer removeAnimationForKey:@"heading"];
    self.glyph.layer.transform = CATransform3DIdentity;
    self.glyphAngle = 0;
}
// A small bounce of the glyph, only for a real change of state.
- (void)pop {
    if (!LSMapAnimationsEnabled() || self.dragging || self.snapAnimator) return;
    self.content.transform = CGAffineTransformMakeScale(0.88, 0.88);
    LSAnimateBouncy(^{ self.content.transform = CGAffineTransformIdentity; }, nil);
}
- (void)updateHalo {
    CALayer *halo = self.halo;
    BOOL wanted = self.shownMode == LSSessionModeMoving && ![self ghosted] && !self.tucked && LSMapAnimationsEnabled() && [self isOnScreen];
    if (!wanted) {
        [halo removeAnimationForKey:@"breathe"];
        return;
    }
    if ([halo animationForKey:@"breathe"]) return;
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @1.0;
    grow.toValue = @1.32;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.35;
    fade.toValue = @0.0;
    CAAnimationGroup *breathe = [CAAnimationGroup animation];
    breathe.animations = @[grow, fade];
    breathe.duration = 2.6;
    breathe.repeatCount = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [halo addAnimation:breathe forKey:@"breathe"];
}
- (void)updateTab {
    LSSessionMode mode = self.shownMode;
    // A chevron says "pull me out"; with Differentiate Without Color it shows the state glyph instead.
    NSString *name = LSDifferentiateWithoutColor() ? LSOpenerSymbol(mode) : (self.right ? @"chevron.compact.left" : @"chevron.compact.right");
    self.tabGlyph.image = [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:self.right ? @"chevron.left" : @"chevron.right"];
    self.tabGlyph.tintColor = mode == LSSessionModeOff ? UIColor.secondaryLabelColor : LSSessionColor(mode);
    // Top to bottom along whichever half of the rim stays on screen.
    CGFloat c = kLSOpenerSize / 2, spread = 80 * M_PI / 180;
    UIBezierPath *arc = self.right
        ? [UIBezierPath bezierPathWithArcCenter:CGPointMake(c, c) radius:c - 4 startAngle:M_PI + M_PI_2 - (M_PI_2 - spread) endAngle:M_PI_2 + (M_PI_2 - spread) clockwise:NO]
        : [UIBezierPath bezierPathWithArcCenter:CGPointMake(c, c) radius:c - 4 startAngle:-spread endAngle:spread clockwise:YES];
    UITraitCollection *traits = self.traitCollection;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.tabTrackLayer.path = arc.CGPath;
    self.tabProgressLayer.path = arc.CGPath;
    self.tabTrackLayer.strokeColor = [[UIColor.labelColor colorWithAlphaComponent:LSIncreaseContrast() ? 0.3 : 0.15] resolvedColorWithTraitCollection:traits].CGColor;
    self.tabProgressLayer.strokeColor = [LSSessionColor(mode) resolvedColorWithTraitCollection:traits].CGColor;
    [CATransaction commit];
}

// MARK: Chrome (glass, ghost, lift, tuck)

- (BOOL)ghosted { return self.dimmed && !self.lifted && !self.pressed && !self.menuOpen; }
- (BOOL)canDim {
    return !UIAccessibilityIsVoiceOverRunning() && !self.dragging && !self.pressed && !self.menuOpen && !self.snapAnimator && !self.hint && !self.leaving;
}
// Colours that are not animatable or need resolving for the current traits.
- (void)applyAppearance {
    BOOL contrast = LSIncreaseContrast(), off = self.shownMode == LSSessionModeOff;
    UIColor *base = UIColor.systemBackgroundColor;
    self.backing.backgroundColor = LSReduceTransparency() ? base : [base colorWithAlphaComponent:contrast ? 0.85 : 0.6];
    UIColor *border = contrast ? [UIColor.labelColor colorWithAlphaComponent:off ? 0.75 : 0.45] : UIColor.separatorColor;
    self.glass.layer.borderColor = [border resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.trackLayer.strokeColor = [UIColor colorWithWhite:1 alpha:contrast ? 0.5 : 0.3].CGColor;
    self.halo.backgroundColor = [LSOpenerDiscColor(LSSessionModeMoving) resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    [CATransaction commit];
    [self applyChromeValues];
}
// Every flag-driven value; callers choose the animation around it.
- (void)applyChromeValues {
    BOOL ghost = [self ghosted], contrast = LSIncreaseContrast(), motion = LSMapAnimationsEnabled();
    // Visual effect views must not sit under a translucent ancestor, so idling swaps the
    // glass for a faint backing instead of fading the whole opener.
    BOOL glassOn = !ghost && !self.leaving;
    if (glassOn != self.glassOn) {
        self.glass.effect = glassOn ? self.glassEffect : nil;
        self.glassOn = glassOn;
    }
    self.backing.alpha = !self.leaving && (ghost || LSReduceTransparency()) ? 1 : 0;
    CGFloat alpha = ghost ? (contrast ? 0.85 : 0.6) : 1;
    // Under Reduce Motion a held opener dips instead of growing.
    if (self.lifted && !motion) alpha = 0.7;
    self.content.alpha = self.leaving ? 0 : alpha;
    CGFloat scale = 1;
    // Leaving, it swells a touch as it fades, as if lifting into the rising sheet.
    if (self.leaving) scale = motion ? 1.08 : 1;
    else if (self.lifted) scale = motion ? 1.1 : 1;
    else if (self.pressed) scale = LSLiquidGlassAvailable() ? 1 : 0.92; // Liquid Glass answers presses itself.
    else if (ghost) scale = 0.88;
    self.container.transform = CGAffineTransformMakeScale(scale, scale);
    BOOL off = self.shownMode == LSSessionModeOff;
    self.glass.layer.borderWidth = contrast ? (off ? 2 : 1) : (ghost || !LSLiquidGlassAvailable() ? 0.5 : 0);

    self.face.alpha = self.tucked ? 0 : 1;
    self.tabGlyph.alpha = self.tucked ? 1 : 0;
    BOOL route = self.shownMode == LSSessionModeMoving || self.shownMode == LSSessionModePaused;
    self.tabProgress.alpha = self.tucked && route ? 1 : 0;
    CGFloat offset = (kLSOpenerSize - kLSOpenerTabWidth) / 2;
    self.tabGlyph.center = CGPointMake(kLSOpenerSize / 2 + (self.right ? -offset : offset), kLSOpenerSize / 2);
    CGFloat reach = 44 - kLSOpenerTabWidth;
    self.container.hitInsets = !self.tucked ? UIEdgeInsetsZero
        : (self.right ? UIEdgeInsetsMake(-8, -reach, -8, 0) : UIEdgeInsetsMake(-8, 0, -8, -reach));
    self.tabTap.enabled = self.tucked;
}
- (void)updateShadowAnimated:(BOOL)animated {
    // Liquid Glass draws its own depth; the blur fallback needs a soft shadow over the map.
    float opacity = LSLiquidGlassAvailable() || [self ghosted] || self.leaving ? 0 : (self.lifted ? 0.3f : 0.2f);
    CALayer *layer = self.container.layer;
    if (animated && fabsf(layer.shadowOpacity - opacity) > 0.001f) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
        fade.fromValue = @((layer.presentationLayer ?: layer).shadowOpacity);
        fade.toValue = @(opacity);
        fade.duration = 0.3;
        [layer addAnimation:fade forKey:@"shadow"];
    }
    layer.shadowOpacity = opacity;
    layer.shadowRadius = self.lifted ? 16 : 10;
    layer.shadowOffset = CGSizeMake(0, self.lifted ? 9 : 4);
}
- (void)animateChrome {
    [self updateShadowAnimated:YES];
    LSAnimate(^{ [self applyChromeValues]; }, nil);
    [self updateHalo];
}
- (void)wake {
    [self.dimTimer invalidate];
    self.dimTimer = nil;
    if (self.dimmed) {
        self.dimmed = NO;
        [self animateChrome];
    }
    [self scheduleDim];
}
- (void)scheduleDim {
    [self.dimTimer invalidate];
    self.dimTimer = nil;
    if (![self canDim]) return;
    __weak typeof(self) weakSelf = self;
    self.dimTimer = [NSTimer scheduledTimerWithTimeInterval:kLSOpenerIdleDelay repeats:NO block:^(__unused NSTimer *timer) {
        [weakSelf dimIfIdle];
    }];
}
- (void)dimIfIdle {
    self.dimTimer = nil;
    if (self.dimmed || ![self canDim] || ![self isOnScreen]) return;
    self.dimmed = YES;
    [self updateShadowAnimated:YES];
    [self updateHalo];
    [UIView animateWithDuration:LSMapAnimationsEnabled() ? 0.9 : 0.3 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self applyChromeValues]; } completion:nil];
}
- (void)accessibilityChanged:(NSNotification *)note {
    (void)note;
    [self applyAppearance];
    [self updateTab];
    [self wake];
    [self updateHalo];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyAppearance];
    [self updateTab];
}

// MARK: Showing and hiding

- (void)openerDidAppear {
    self.visibilityGeneration++;
    self.leaving = NO;
    self.view.userInteractionEnabled = YES;
    self.dimmed = self.pressed = self.lifted = self.menuOpen = NO;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self updateForSessionAnimated:NO];
    [self applyAppearance];
    // Materialises from the spot it sits on: glass and glyph grow in together.
    self.glass.effect = nil;
    self.glassOn = NO;
    self.content.alpha = 0;
    if (LSMapAnimationsEnabled()) self.container.transform = CGAffineTransformMakeScale(0.5, 0.5);
    self.container.layer.shadowOpacity = 0;
    [self updateShadowAnimated:YES];
    LSAnimateBouncy(^{ [self applyChromeValues]; }, nil);
    [self updateHalo];
    [self scheduleDim];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LSOpenerViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.tucked) return;
        [strongSelf showHintOnce:kLSOpenerHintKey title:@"Tap to open LSpoof" message:@"Touch and hold for quick controls. Drag to move it."];
    });
}
- (void)openerWillHide {
    self.visibilityGeneration++;
    self.leaving = NO;
    [self dismissHint];
    [self.dimTimer invalidate];
    self.dimTimer = nil;
    [self.halo removeAnimationForKey:@"breathe"];
}
// Fades out just before the picker sheet rises, then the window hides.
- (void)leaveWithCompletion:(dispatch_block_t)completion {
    [self openerWillHide];
    self.leaving = YES;
    self.view.userInteractionEnabled = NO;
    NSUInteger generation = self.visibilityGeneration;
    [self updateShadowAnimated:YES];
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:^{
        [self applyChromeValues];
    } completion:^(__unused BOOL finished) {
        if (self.visibilityGeneration == generation && self.leaving && completion) completion();
    }];
}

// MARK: Touch

- (void)pressDown {
    [self dismissHint];
    self.pressed = YES;
    [self.dimTimer invalidate];
    self.dimTimer = nil;
    self.dimmed = NO;
    [self animateChrome];
}
- (void)pressUp {
    if (!self.pressed) return;
    self.pressed = NO;
    [self animateChrome];
    [self scheduleDim];
}
- (void)tapped { [self activateFromAccessibility:NO]; }
- (void)activateFromAccessibility:(BOOL)accessibility {
    [self dismissHint];
    // A tap on the tucked tab brings the opener back; VoiceOver goes straight to the picker.
    if (self.tucked && !accessibility) { [self setTuckedAway:NO]; return; }
    LSHapticImpact(UIImpactFeedbackStyleLight);
    if (self.openPicker) self.openPicker();
}
- (void)tabTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded && self.tucked) [self setTuckedAway:NO];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    // The button handles its own taps; one tap must never both bring it back and open the picker.
    return recognizer != self.tabTap || ![touch.view isDescendantOfView:self.button];
}
- (void)menuWillShow {
    self.menuOpen = YES;
    [self dismissHint];
    [self.dimTimer invalidate];
    self.dimTimer = nil;
    self.dimmed = NO;
    [self animateChrome];
}
- (void)menuDidEnd {
    self.menuOpen = NO;
    [self animateChrome];
    [self scheduleDim];
}

// MARK: Position

- (CGRect)safeRect { return UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets); }
- (CGRect)dockRect {
    CGFloat inset = kLSOpenerMargin + kLSOpenerSize / 2;
    return CGRectInset([self safeRect], inset, inset);
}
- (BOOL)usableDock:(CGRect)dock { return !CGRectIsNull(dock) && !CGRectIsEmpty(dock); }
- (CGFloat)xOnRight:(BOOL)right tucked:(BOOL)tucked dock:(CGRect)dock {
    if (!tucked) return right ? CGRectGetMaxX(dock) : CGRectGetMinX(dock);
    // Measured from the safe area so a tab is never lost behind the sensor housing.
    CGRect safe = [self safeRect];
    return right ? CGRectGetMaxX(safe) - kLSOpenerTabWidth + kLSOpenerSize / 2 : CGRectGetMinX(safe) + kLSOpenerTabWidth - kLSOpenerSize / 2;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.dragging || self.snapAnimator) return;
    CGRect dock = [self dockRect];
    if (![self usableDock:dock]) return;
    NSUserDefaults *defaults = LSOpenerDefaults();
    id storedSide = [defaults objectForKey:kLSOpenerSideKey], storedY = [defaults objectForKey:kLSOpenerYKey];
    BOOL right = [storedSide isKindOfClass:NSNumber.class] ? [storedSide boolValue] : YES;
    BOOL tucked = [defaults boolForKey:kLSOpenerTuckedKey];
    double fraction = [storedY isKindOfClass:NSNumber.class] ? [storedY doubleValue] : 0.62;
    if (!isfinite(fraction)) fraction = 0.62;
    fraction = MAX(0.0, MIN(1.0, fraction));
    if (right != self.right || tucked != self.tucked) {
        self.right = right;
        self.tucked = tucked;
        [self updateTab];
        [self applyChromeValues];
        [self updateHalo];
    }
    self.container.center = CGPointMake([self xOnRight:right tucked:tucked dock:dock], CGRectGetMinY(dock) + dock.size.height * fraction);
    [self layoutHint];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self dismissHint];
    [self stopSnap];
}
- (void)stopSnap {
    UIViewPropertyAnimator *animator = self.snapAnimator;
    if (!animator) return;
    self.snapAnimator = nil;
    self.snapGeneration++;
    if (animator.state == UIViewAnimatingStateActive) [animator stopAnimation:YES];
    [self applyChromeValues];
    [self.view setNeedsLayout];
}
- (void)panned:(UIPanGestureRecognizer *)pan {
    CGRect dock = [self dockRect];
    BOOL usable = [self usableDock:dock];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            [self dismissHint];
            // Catching it mid-flight continues from where it is on screen.
            [self stopSnap];
            self.dragging = YES;
            self.dragOrigin = self.container.center;
            [self.dimTimer invalidate];
            self.dimTimer = nil;
            self.dimmed = NO;
            self.lifted = YES;
            self.dragProjectedRight = self.right;
            self.dragInTuckZone = self.tucked;
            // The face shows while held, even when it was tucked.
            self.tucked = NO;
            LSHapticPrepare();
            LSHapticImpact(UIImpactFeedbackStyleLight);
            [self animateChrome];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!usable) break;
            CGPoint translation = [pan translationInView:self.view];
            CGFloat minX = [self xOnRight:NO tucked:YES dock:dock], maxX = [self xOnRight:YES tucked:YES dock:dock];
            self.container.center = CGPointMake(LSRubberBand(self.dragOrigin.x + translation.x, minX, maxX, kLSOpenerSize),
                                                LSRubberBand(self.dragOrigin.y + translation.y, CGRectGetMinY(dock), CGRectGetMaxY(dock), 2 * kLSOpenerSize));
            [self dragFeedbackInDock:dock velocity:[pan velocityInView:self.view]];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.dragging = NO;
            if (!usable) {
                self.lifted = NO;
                [self animateChrome];
                [self.view setNeedsLayout];
                break;
            }
            CGPoint velocity = [pan velocityInView:self.view];
            CGPoint center = self.container.center;
            CGFloat leftDock = CGRectGetMinX(dock), rightDock = CGRectGetMaxX(dock);
            CGFloat leftTuck = [self xOnRight:NO tucked:YES dock:dock], rightTuck = [self xOnRight:YES tucked:YES dock:dock];
            BOOL right, tuck = YES;
            // Pushed into an edge, or flicked hard at the edge it is already next to, it tucks away.
            if (center.x < (leftDock + leftTuck) / 2 && velocity.x < 300) right = NO;
            else if (center.x > (rightDock + rightTuck) / 2 && velocity.x > -300) right = YES;
            else if (center.x < leftDock + kLSOpenerSize && velocity.x < -1200) right = NO;
            else if (center.x > rightDock - kLSOpenerSize && velocity.x > 1200) right = YES;
            else {
                tuck = NO;
                right = center.x + LSProjectedDistance(velocity.x) > CGRectGetMidX(dock);
            }
            [self settleOnRight:right tucked:tuck y:center.y + LSProjectedDistance(velocity.y) velocity:velocity];
            break;
        }
        default:
            break;
    }
}
// Felt while dragging: a soft bump on entering or leaving the tuck zone at either edge, and
// a tick each time the side it would land on flips (with a little hysteresis at the middle).
- (void)dragFeedbackInDock:(CGRect)dock velocity:(CGPoint)velocity {
    CGFloat x = self.container.center.x, mid = CGRectGetMidX(dock);
    CGFloat leftZone = (CGRectGetMinX(dock) + [self xOnRight:NO tucked:YES dock:dock]) / 2;
    CGFloat rightZone = (CGRectGetMaxX(dock) + [self xOnRight:YES tucked:YES dock:dock]) / 2;
    BOOL zone = x < leftZone || x > rightZone;
    if (zone != self.dragInTuckZone) {
        self.dragInTuckZone = zone;
        LSHapticImpact(UIImpactFeedbackStyleSoft);
    }
    if (zone) { self.dragProjectedRight = x > mid; return; }
    CGFloat projected = x + LSProjectedDistance(velocity.x);
    if (self.dragProjectedRight ? projected < mid - 12 : projected > mid + 12) {
        self.dragProjectedRight = !self.dragProjectedRight;
        LSHapticSelection();
    }
}
// Springs to a docked or tucked spot, carrying the throw's velocity, and remembers it.
- (void)settleOnRight:(BOOL)right tucked:(BOOL)tucked y:(CGFloat)y velocity:(CGPoint)velocity {
    CGRect dock = [self dockRect];
    if (![self usableDock:dock]) return;
    [self stopSnap];
    NSUserDefaults *defaults = LSOpenerDefaults();
    BOOL newlyTucked = tucked && ![defaults boolForKey:kLSOpenerTuckedKey];
    y = MAX(CGRectGetMinY(dock), MIN(CGRectGetMaxY(dock), isfinite(y) ? y : CGRectGetMidY(dock)));
    [defaults setBool:right forKey:kLSOpenerSideKey];
    [defaults setDouble:dock.size.height > 0 ? (y - CGRectGetMinY(dock)) / dock.size.height : 0.62 forKey:kLSOpenerYKey];
    [defaults setBool:tucked forKey:kLSOpenerTuckedKey];
    self.right = right;
    self.tucked = tucked;
    self.lifted = NO;
    [self updateTab];
    [self updateHalo];
    [self updateShadowAnimated:YES];

    CGPoint from = self.container.center, target = CGPointMake([self xOnRight:right tucked:tucked dock:dock], y);
    BOOL motion = LSMapAnimationsEnabled();
    UIViewPropertyAnimator *animator;
    if (motion) {
        CGVector relative = CGVectorMake(LSRelativeVelocity(velocity.x, target.x - from.x), LSRelativeVelocity(velocity.y, target.y - from.y));
        UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithDampingRatio:0.8 initialVelocity:relative];
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.55 timingParameters:spring];
    } else {
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.2 curve:UIViewAnimationCurveEaseOut animations:nil];
    }
    __weak typeof(self) weakSelf = self;
    __weak UIViewPropertyAnimator *weakAnimator = animator;
    [animator addAnimations:^{
        LSOpenerViewController *strongSelf = weakSelf;
        strongSelf.container.center = target;
        [strongSelf applyChromeValues];
    }];
    [animator addCompletion:^(__unused UIViewAnimatingPosition position) {
        LSOpenerViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.snapAnimator != weakAnimator) return;
        strongSelf.snapAnimator = nil;
        [strongSelf.view setNeedsLayout];
        [strongSelf scheduleDim];
        if (newlyTucked && strongSelf.tucked) [strongSelf showHintOnce:kLSOpenerTuckHintKey title:@"Tucked away" message:@"Tap the tab to bring it back."];
    }];
    self.snapAnimator = animator;
    [animator startAnimation];
    // A light tap as it lands, unless it is picked up again first.
    NSUInteger generation = ++self.snapGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((motion ? 0.2 : 0.12) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.snapGeneration == generation) LSHapticImpact(tucked ? UIImpactFeedbackStyleSoft : UIImpactFeedbackStyleLight);
    });
}
- (void)setTuckedAway:(BOOL)tucked {
    [self settleOnRight:self.right tucked:tucked y:self.container.center.y velocity:CGPointZero];
    LSOpenerAnnounce(tucked ? @"Tucked into the edge" : @"Opener back in place");
}
- (void)moveToRight:(BOOL)right {
    [self settleOnRight:right tucked:NO y:self.container.center.y velocity:CGPointZero];
    LSOpenerAnnounce(right ? @"Moved to the right side" : @"Moved to the left side");
}
- (void)moveVertically:(NSInteger)direction {
    CGRect dock = [self dockRect];
    if (![self usableDock:dock]) return;
    CGFloat y = self.container.center.y + direction * MAX(44, dock.size.height / 5);
    [self settleOnRight:self.right tucked:self.tucked y:y velocity:CGPointZero];
    LSOpenerAnnounce(direction < 0 ? @"Moved up" : @"Moved down");
}

// MARK: First-use hint

- (void)showHintOnce:(NSString *)key title:(NSString *)title message:(NSString *)message {
    NSUserDefaults *defaults = LSOpenerDefaults();
    if (self.hint || [defaults boolForKey:key] || UIAccessibilityIsVoiceOverRunning() || ![self isOnScreen] || self.dragging || self.menuOpen) return;
    [defaults setBool:YES forKey:key];
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 24), NSForegroundColorAttributeName: UIColor.labelColor}];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:message] attributes:@{
        NSFontAttributeName: LSFont(UIFontTextStyleFootnote, UIFontWeightRegular, 22), NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    label.attributedText = text;
    UIVisualEffectView *hint = LSGlassView(LSRadiusM, NO);
    hint.translatesAutoresizingMaskIntoConstraints = YES;
    hint.userInteractionEnabled = NO;
    // The same words are in the button's hint; VoiceOver users are not shown this at all.
    hint.accessibilityElementsHidden = YES;
    [hint.contentView addSubview:label];
    self.hintEffect = hint.effect;
    self.hint = hint;
    self.hintLabel = label;
    // A small glass dot in the gap, level with the opener's centre, points the bubble at it.
    // It is separate rather than joined so two glass layers never overlap.
    UIVisualEffectView *pointer = LSGlassView(4, NO);
    pointer.translatesAutoresizingMaskIntoConstraints = YES;
    pointer.userInteractionEnabled = NO;
    pointer.accessibilityElementsHidden = YES;
    pointer.bounds = CGRectMake(0, 0, 8, 8);
    self.hintPointer = pointer;
    [self.view insertSubview:hint belowSubview:self.container];
    [self.view insertSubview:pointer belowSubview:self.container];
    [self layoutHint];
    if (!self.hint) return;
    hint.effect = nil;
    pointer.effect = nil;
    label.alpha = 0;
    CGFloat shift = self.right ? 12 : -12;
    if (LSMapAnimationsEnabled()) hint.transform = CGAffineTransformMakeTranslation(shift, 0);
    UIVisualEffect *effect = self.hintEffect, *pointerEffect = self.hintEffect;
    LSAnimate(^{
        hint.effect = effect;
        pointer.effect = pointerEffect;
        hint.transform = CGAffineTransformIdentity;
        label.alpha = 1;
    }, nil);
    [self.dimTimer invalidate];
    self.dimTimer = nil;
    __weak typeof(self) weakSelf = self;
    __weak UIVisualEffectView *weakHint = hint;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LSOpenerViewController *strongSelf = weakSelf;
        if (strongSelf && weakHint && strongSelf.hint == weakHint) [strongSelf dismissHint];
    });
}
- (void)layoutHint {
    UIVisualEffectView *hint = self.hint;
    UILabel *label = self.hintLabel;
    if (!hint || !label) return;
    CGRect safe = [self safeRect];
    CGPoint center = self.container.center;
    CGFloat gap = 18, padX = 14, padY = 10;
    // Beside the opener, on the side facing the screen.
    CGFloat edge = self.right ? center.x - kLSOpenerSize / 2 - gap : center.x + kLSOpenerSize / 2 + gap;
    CGFloat available = self.right ? edge - CGRectGetMinX(safe) - 12 : CGRectGetMaxX(safe) - 12 - edge;
    CGFloat maxWidth = MIN(260, available);
    if (maxWidth < 120) { [self dismissHint]; return; }
    CGSize fit = [label sizeThatFits:CGSizeMake(maxWidth - 2 * padX, CGFLOAT_MAX)];
    CGFloat width = MIN(maxWidth, ceil(fit.width) + 2 * padX), height = ceil(fit.height) + 2 * padY;
    CGFloat x = self.right ? edge - width : edge;
    CGFloat y = MAX(CGRectGetMinY(safe) + 8, MIN(CGRectGetMaxY(safe) - 8 - height, center.y - height / 2));
    hint.bounds = CGRectMake(0, 0, width, height);
    hint.center = CGPointMake(x + width / 2, y + height / 2);
    CGFloat radius = MIN(LSRadiusM, height / 2);
    hint.layer.cornerRadius = radius;
    label.frame = CGRectMake(padX, padY, width - 2 * padX, height - 2 * padY);
    CGFloat inner = self.right ? center.x - kLSOpenerSize / 2 : center.x + kLSOpenerSize / 2;
    self.hintPointer.center = CGPointMake((inner + edge) / 2, MAX(y + radius, MIN(y + height - radius, center.y)));
}
- (void)dismissHint {
    UIVisualEffectView *hint = self.hint, *pointer = self.hintPointer;
    UILabel *label = self.hintLabel;
    if (!hint) return;
    self.hint = nil;
    self.hintLabel = nil;
    self.hintPointer = nil;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        hint.effect = nil;
        pointer.effect = nil;
        label.alpha = 0;
    } completion:^(__unused BOOL finished) {
        [hint removeFromSuperview];
        [pointer removeFromSuperview];
    }];
    [self scheduleDim];
}

// MARK: Quick actions

// Long-press menu: route controls without opening the picker. Its header says what is
// happening now; the items are built when it opens.
- (UIMenu *)openerMenu {
    __weak typeof(self) weakSelf = self;
    return [UIMenu menuWithTitle:LSOpenerStatus(NO) children:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        LSOpenerViewController *strongSelf = weakSelf;
        completion(strongSelf ? [strongSelf quickActions] : @[]);
    }]]];
}
- (NSArray<UIMenuElement *> *)quickActions {
    __weak typeof(self) weakSelf = self;
    LSSessionMode mode = LSSessionController.shared.snapshot.mode;
    NSMutableArray<UIMenuElement *> *sections = [NSMutableArray array];
    UIMenu *(^section)(NSString *, NSArray<UIMenuElement *> *) = ^UIMenu *(NSString *title, NSArray<UIMenuElement *> *children) {
        return [UIMenu menuWithTitle:title image:nil identifier:nil options:UIMenuOptionsDisplayInline children:children];
    };
    UIAction *open = [UIAction actionWithTitle:@"Open LSpoof" image:[UIImage systemImageNamed:@"map"] identifier:nil handler:^(__unused UIAction *action) {
        LSOpenerViewController *strongSelf = weakSelf;
        if (strongSelf.openPicker) strongSelf.openPicker();
    }];
    NSString *tuckSymbol = self.tucked ? (self.right ? @"arrow.uturn.left" : @"arrow.uturn.right") : (self.right ? @"arrow.right.to.line" : @"arrow.left.to.line");
    UIAction *tuck = [UIAction actionWithTitle:self.tucked ? @"Bring back" : @"Tuck into edge" image:[UIImage systemImageNamed:tuckSymbol] identifier:nil handler:^(__unused UIAction *action) {
        LSOpenerViewController *strongSelf = weakSelf;
        [strongSelf setTuckedAway:!strongSelf.tucked];
    }];
    if (mode == LSSessionModeMoving || mode == LSSessionModePaused) {
        BOOL paused = mode == LSSessionModePaused;
        UIAction *slower = [UIAction actionWithTitle:@"Slower" image:[UIImage systemImageNamed:@"tortoise.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf nudge:-1]; }];
        UIAction *toggle = [UIAction actionWithTitle:paused ? @"Resume" : @"Pause" image:[UIImage systemImageNamed:paused ? @"play.fill" : @"pause.fill"] identifier:nil
                                             handler:^(__unused UIAction *action) { [weakSelf togglePause]; }];
        UIAction *faster = [UIAction actionWithTitle:@"Faster" image:[UIImage systemImageNamed:@"hare.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf nudge:1]; }];
        // Speed steps keep the menu open; the header is refreshed after each one.
        slower.attributes = UIMenuElementAttributesKeepsMenuPresented;
        faster.attributes = UIMenuElementAttributesKeepsMenuPresented;
        UIMenu *controls = section(@"", @[slower, toggle, faster]);
        controls.preferredElementSize = UIMenuElementSizeMedium;
        [sections addObject:controls];
        UIAction *hold = [UIAction actionWithTitle:@"Stop and hold here" image:[UIImage systemImageNamed:@"stop.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf stopAndHold]; }];
        [sections addObject:section(@"", @[hold])];
        [sections addObject:section(@"", @[open, tuck])];
    } else {
        NSMutableArray<UIMenuElement *> *first = [NSMutableArray array];
        if (mode == LSSessionModeOff && PersistenceManager.shared.hasStoredCoordinate) {
            UIAction *apply = [UIAction actionWithTitle:@"Apply last location" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf applyLastLocation]; }];
            apply.subtitle = LSCoordinateText(PersistenceManager.shared.spoofCoordinate);
            [first addObject:apply];
        }
        [first addObject:open];
        [first addObject:tuck];
        [sections addObject:section(@"", first)];
    }
    if (mode != LSSessionModeOff) {
        UIAction *off = [UIAction actionWithTitle:@"Turn off" image:[UIImage systemImageNamed:@"power"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf turnOff]; }];
        off.attributes = UIMenuElementAttributesDestructive;
        [sections addObject:section(@"", @[off])];
    }
    return sections;
}
- (void)refreshVisibleMenu {
    UIContextMenuInteraction *interaction = self.button.contextMenuInteraction;
    if (!self.menuOpen || !interaction) return;
    NSArray<UIMenuElement *> *children = [self quickActions];
    NSString *status = LSOpenerStatus(NO);
    // The header shows the new speed straight away.
    [interaction updateVisibleMenuWithBlock:^UIMenu *(UIMenu *visible) {
        return [UIMenu menuWithTitle:status image:visible.image identifier:visible.identifier options:visible.options children:children];
    }];
}
// Each action confirms itself with a haptic; the spoken result comes from the state change
// (or, for speed, right here), since the picker is not open to show it.
- (void)togglePause {
    LSSessionController *session = LSSessionController.shared;
    if (session.snapshot.mode == LSSessionModePaused) [session resume];
    else [session pause];
    LSHapticSelection();
}
- (void)nudge:(NSInteger)direction {
    if ([LSSessionController.shared nudgeSpeed:direction]) {
        LSHapticSelection();
        LSOpenerAnnounce([NSString stringWithFormat:@"Speed %@", LSOpenerSpeedText()]);
    } else {
        LSHapticWarning();
        LSOpenerAnnounce(direction > 0 ? @"Already at the fastest speed" : @"Already at the slowest speed");
    }
    [self refreshVisibleMenu];
}
- (void)stopAndHold {
    [LSSessionController.shared stopAndHold];
    LSHapticSuccess();
}
- (void)applyLastLocation {
    if (!PersistenceManager.shared.hasStoredCoordinate) return;
    if ([LSSessionController.shared applyStaticCoordinate:PersistenceManager.shared.spoofCoordinate]) LSHapticSuccess();
    else { LSHapticError(); LSOpenerAnnounce(@"Couldn't apply the last location"); }
}
- (void)turnOff {
    // The state change then says that Apply last location can bring it back.
    self.offFromQuickAction = YES;
    [LSSessionController.shared disable];
    LSHapticImpact(UIImpactFeedbackStyleMedium);
}
- (NSArray<UIAccessibilityCustomAction *> *)accessibilityQuickActions {
    __weak typeof(self) weakSelf = self;
    LSSessionMode mode = LSSessionController.shared.snapshot.mode;
    NSMutableArray<UIAccessibilityCustomAction *> *actions = [NSMutableArray array];
    void (^add)(NSString *, NSString *, dispatch_block_t) = ^(NSString *name, NSString *symbol, dispatch_block_t block) {
        [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:name image:[UIImage systemImageNamed:symbol]
                                                               actionHandler:^BOOL(__unused UIAccessibilityCustomAction *action) { block(); return YES; }]];
    };
    if (mode == LSSessionModeMoving || mode == LSSessionModePaused) {
        BOOL paused = mode == LSSessionModePaused;
        add(paused ? @"Resume route" : @"Pause route", paused ? @"play.fill" : @"pause.fill", ^{ [weakSelf togglePause]; });
        add(@"Faster", @"hare.fill", ^{ [weakSelf nudge:1]; });
        add(@"Slower", @"tortoise.fill", ^{ [weakSelf nudge:-1]; });
        add(@"Stop and hold here", @"stop.fill", ^{ [weakSelf stopAndHold]; });
    } else if (mode == LSSessionModeOff && PersistenceManager.shared.hasStoredCoordinate) {
        add(@"Apply last location", @"clock.arrow.circlepath", ^{ [weakSelf applyLastLocation]; });
    }
    if (mode != LSSessionModeOff) add(@"Turn off", @"power", ^{ [weakSelf turnOff]; });
    BOOL right = self.right;
    add(right ? @"Move to the left side" : @"Move to the right side", right ? @"arrow.left" : @"arrow.right", ^{ [weakSelf moveToRight:!right]; });
    add(@"Move up", @"arrow.up", ^{ [weakSelf moveVertically:-1]; });
    add(@"Move down", @"arrow.down", ^{ [weakSelf moveVertically:1]; });
    BOOL tucked = self.tucked;
    add(tucked ? @"Bring back" : @"Tuck into edge", tucked ? @"arrow.uturn.left" : @"arrow.right.to.line", ^{ [weakSelf setTuckedAway:!tucked]; });
    return actions;
}
@end

@class LSOverlayManager;
@interface LSOverlayState : NSObject <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, weak, nullable) UIWindowScene *scene;
@property (nonatomic, weak, nullable) UIWindow *hostWindow;
@property (nonatomic, strong, nullable) LSOpenerWindow *openerWindow;
@property (nonatomic, weak, nullable) MapPickerViewController *picker;
@property (nonatomic, strong, nullable) NSTimer *holdTimer;
@property (nonatomic) BOOL triggered;
@property (nonatomic) BOOL presenting;
@property (nonatomic) NSInteger activeTouches;
@end
@implementation LSOverlayState
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
    (void)controller;
    self.picker = nil;
    self.presenting = NO;
    // The gesture latch is cleared only by an observed touch release.
    [LSOverlayManager refreshOpeners];
}
@end

@interface LSOverlayManager ()
@property (nonatomic) BOOL installed;
@property (nonatomic, strong) NSMutableDictionary<NSString *, LSOverlayState *> *states;
+ (instancetype)shared;
- (LSOverlayState *)stateForWindow:(UIWindow *)window;
- (void)presentState:(LSOverlayState *)state;
- (void)updateTouches:(UIEvent *)event;
- (void)refresh;
@end

static __thread NSUInteger ls_eventHookDepth;
static void LSInstallEventHook(void) {
    UIApplication *application = UIApplication.sharedApplication;
    Class cls = [application class];
    if (!LSClassDefinesInstanceMethodLocally(cls, @selector(sendEvent:))) cls = UIApplication.class;
    SEL selector = @selector(sendEvent:);
    LSInstallInstanceHook(cls, selector, ^IMP(IMP implementation) {
        void (*original)(id, SEL, UIEvent *) = (void *)implementation;
        return imp_implementationWithBlock(^(id receiver, UIEvent *event) {
            ls_eventHookDepth++;
            @try { original(receiver, selector, event); }
            @finally { ls_eventHookDepth--; }
            if (ls_eventHookDepth == 0 && event.type == UIEventTypeTouches) [[LSOverlayManager shared] updateTouches:event];
        });
    });
}

@implementation LSOverlayManager
+ (instancetype)shared {
    static LSOverlayManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [[self alloc] init]; manager.states = [NSMutableDictionary dictionary]; });
    return manager;
}
+ (void)install {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self install]; }); return; }
    LSOverlayManager *manager = self.shared;
    LSInstallEventHook();
    if (manager.installed) { [manager refresh]; return; }
    manager.installed = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification, UIApplicationDidBecomeActiveNotification, UISceneDidActivateNotification]) {
        [center addObserver:manager selector:@selector(activated:) name:name object:nil];
    }
    for (NSNotificationName name in @[UIApplicationDidEnterBackgroundNotification, UISceneWillDeactivateNotification]) {
        [center addObserver:manager selector:@selector(deactivated:) name:name object:nil];
    }
    [center addObserver:manager selector:@selector(disconnected:) name:UISceneDidDisconnectNotification object:nil];
    [manager refresh];
}
+ (void)refreshOpeners {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refreshOpeners]; }); return; }
    [self.shared refresh];
}
+ (void)presentMapPickerInWindow:(UIWindow *)window {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self presentMapPickerInWindow:window]; }); return; }
    if (!window || [window isKindOfClass:LSOpenerWindow.class]) return;
    [self.shared presentState:[self.shared stateForWindow:window]];
}
+ (void)presentMapPicker {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self presentMapPicker]; }); return; }
    NSArray<UIWindow *> *windows = [self.shared foregroundHostWindows];
    // Without a source window, an ambiguous multi-scene request does not guess a scene.
    if (windows.count == 1) [self presentMapPickerInWindow:windows.firstObject];
}
- (NSString *)keyForWindow:(UIWindow *)window {
    return window.windowScene ? window.windowScene.session.persistentIdentifier : [NSString stringWithFormat:@"legacy-%p", window];
}
- (LSOverlayState *)stateForWindow:(UIWindow *)window {
    NSString *key = [self keyForWindow:window];
    LSOverlayState *state = self.states[key];
    if (!state) { state = [[LSOverlayState alloc] init]; self.states[key] = state; }
    state.scene = window.windowScene;
    state.hostWindow = window;
    return state;
}
- (NSArray<UIWindow *> *)foregroundHostWindows {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindow *candidate = nil;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window isKindOfClass:LSOpenerWindow.class] || window.hidden || window.alpha <= 0.01 || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (!candidate || window.isKeyWindow) candidate = window;
        }
        if (candidate) [windows addObject:candidate];
    }
    if (!windows.count && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
        UIWindow *legacy = [delegate respondsToSelector:@selector(window)] ? delegate.window : nil;
        if (legacy && !legacy.windowScene && !legacy.hidden && legacy.rootViewController) [windows addObject:legacy];
    }
    return windows;
}
- (BOOL)isForeground:(LSOverlayState *)state {
    return state.hostWindow && !state.hostWindow.hidden &&
        (state.scene ? state.scene.activationState == UISceneActivationStateForegroundActive : UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
}
- (void)refresh {
    for (UIWindow *window in [self foregroundHostWindows]) [self stateForWindow:window];
    for (LSOverlayState *state in self.states.allValues) {
        BOOL visible = [self isForeground:state] && PersistenceManager.shared.showFloatingButton && !state.picker && !state.presenting;
        if (visible && !state.openerWindow) [self createOpener:state];
        [self setOpener:state visible:visible animated:YES];
    }
}
// animated: the opener shrinks away first (and a fade already under way is left to finish);
// otherwise it hides at once, as for backgrounding.
- (void)setOpener:(LSOverlayState *)state visible:(BOOL)visible animated:(BOOL)animated {
    LSOpenerWindow *window = state.openerWindow;
    if (!window) return;
    LSOpenerViewController *controller = [window.rootViewController isKindOfClass:LSOpenerViewController.class] ? (LSOpenerViewController *)window.rootViewController : nil;
    if (visible) {
        if (!window.hidden && !controller.leaving) return;
        // Setting hidden does not change the host's key window or keyboard focus.
        window.hidden = NO;
        [controller openerDidAppear];
        return;
    }
    if (window.hidden) return;
    if (animated && controller) {
        if (controller.leaving) return;
        __weak LSOpenerWindow *weakWindow = window;
        __weak LSOpenerViewController *weakController = controller;
        [controller leaveWithCompletion:^{
            weakController.leaving = NO;
            weakWindow.hidden = YES;
        }];
        return;
    }
    [controller openerWillHide];
    window.hidden = YES;
}
- (void)createOpener:(LSOverlayState *)state {
    LSOpenerWindow *window = state.scene ? [[LSOpenerWindow alloc] initWithWindowScene:state.scene] : [[LSOpenerWindow alloc] initWithFrame:state.hostWindow.bounds];
    window.windowLevel = UIWindowLevelNormal + 1;
    window.backgroundColor = UIColor.clearColor;
    LSOpenerViewController *controller = [[LSOpenerViewController alloc] init];
    __weak LSOverlayState *weakState = state;
    controller.openPicker = ^{
        LSOverlayState *state = weakState;
        if (state) [[LSOverlayManager shared] presentState:state];
    };
    window.rootViewController = controller;
    (void)controller.view;
    window.opener = controller.opener;
    state.openerWindow = window;
    // Stays hidden until refresh shows it, so it can animate in.
}
- (void)presentState:(LSOverlayState *)state {
    if (![self isForeground:state] || state.presenting || state.picker) return;
    UIViewController *host = state.hostWindow.rootViewController;
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host || host.isBeingDismissed || host.isBeingPresented || !host.view.window) return;
    MapPickerViewController *picker = [[MapPickerViewController alloc] init];
    picker.modalPresentationStyle = UIModalPresentationPageSheet;
    picker.preferredContentSize = CGSizeMake(620, 760);
    picker.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
    picker.sheetPresentationController.prefersGrabberVisible = YES;
    picker.sheetPresentationController.preferredCornerRadius = 24;
    picker.presentationController.delegate = state;
    state.picker = picker;
    state.presenting = YES;
    [state.holdTimer invalidate]; state.holdTimer = nil;
    [self setOpener:state visible:NO animated:YES];
    __weak LSOverlayState *weakState = state;
    picker.didDismiss = ^{
        LSOverlayState *state = weakState;
        if (!state) return;
        state.picker = nil; state.presenting = NO;
        [LSOverlayManager refreshOpeners];
    };
    [host presentViewController:picker animated:LSMapAnimationsEnabled() completion:^{
        LSOverlayState *state = weakState;
        state.presenting = NO;
        [LSOverlayManager refreshOpeners];
    }];
    __weak MapPickerViewController *weakPicker = picker;
    // Recover from a refused host presentation by inspecting the actual presentation relationship.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LSOverlayState *state = weakState;
        MapPickerViewController *picker = weakPicker;
        if (state.picker == picker && !picker.presentingViewController && !picker.view.window) {
            state.picker = nil; state.presenting = NO; [LSOverlayManager refreshOpeners];
        }
    });
}
- (void)updateTouches:(UIEvent *)event {
    if (!NSThread.isMainThread) return;
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, LSOverlayState *> *touchedStates = [NSMutableDictionary dictionary];
    for (UITouch *touch in event.allTouches) {
        UIWindow *window = touch.window;
        if (!window || [window isKindOfClass:LSOpenerWindow.class] || window.windowLevel != UIWindowLevelNormal) continue;
        LSOverlayState *state = [self stateForWindow:window];
        NSString *key = [self keyForWindow:window];
        BOOL active = touch.phase == UITouchPhaseBegan || touch.phase == UITouchPhaseMoved || touch.phase == UITouchPhaseStationary;
        counts[key] = @([counts[key] integerValue] + (active ? 1 : 0));
        touchedStates[key] = state;
    }
    for (NSString *key in touchedStates) {
        LSOverlayState *state = touchedStates[key];
        state.activeTouches = [counts[key] integerValue];
        if (state.activeTouches < 3) {
            state.triggered = NO;
            [state.holdTimer invalidate]; state.holdTimer = nil;
            continue;
        }
        if (state.picker || state.presenting || ![self isForeground:state]) {
            [state.holdTimer invalidate]; state.holdTimer = nil; continue;
        }
        if (state.triggered || state.holdTimer) continue;
        __weak LSOverlayState *weakState = state;
        state.holdTimer = [NSTimer timerWithTimeInterval:0.8 repeats:NO block:^(__unused NSTimer *timer) {
            LSOverlayState *state = weakState;
            state.holdTimer = nil;
            if (!state || state.triggered || state.activeTouches < 3 || state.picker || state.presenting) return;
            state.triggered = YES;
            [[LSOverlayManager shared] presentState:state];
        }];
        [NSRunLoop.mainRunLoop addTimer:state.holdTimer forMode:NSRunLoopCommonModes];
    }
}
- (void)activated:(NSNotification *)note { (void)note; LSInstallEventHook(); [self refresh]; }
- (void)deactivated:(NSNotification *)note {
    for (LSOverlayState *state in self.states.allValues) {
        if ([note.object isKindOfClass:UIScene.class] && state.scene != note.object) continue;
        [state.holdTimer invalidate]; state.holdTimer = nil;
        if (state.activeTouches >= 3) state.triggered = YES;
        [self setOpener:state visible:NO animated:NO];
        // Preserve the picker reference and release latch through background/foreground.
    }
}
- (void)disconnected:(NSNotification *)note {
    for (NSString *key in self.states.allKeys) {
        LSOverlayState *state = self.states[key];
        if (state.scene == note.object) {
            [state.holdTimer invalidate];
            [self setOpener:state visible:NO animated:NO];
            state.openerWindow = nil;
            [self.states removeObjectForKey:key];
        }
    }
}
@end
