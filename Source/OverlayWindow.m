#import "OverlayWindow.h"
#import "MapPickerViewController.h"
#import "LSHooking.h"
#import "PersistenceManager.h"
#import "SessionController.h"
#import "LSUI.h"
#import <objc/runtime.h>

// An opener window never becomes key and only its actual button receives touches.
@interface LSOpenerWindow : UIWindow
@property (nonatomic, weak) UIButton *opener;
@end
@implementation LSOpenerWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self.opener || [hit isDescendantOfView:self.opener] ? hit : nil;
}
@end

// Floating opener: a round button that shows the session state, can be dragged
// anywhere, snaps to the nearest side edge, and remembers where it was left.
static NSString * const kLSOpenerSideKey = @"LSOpenerSide";
static NSString * const kLSOpenerYKey = @"LSOpenerY";
static const CGFloat kLSOpenerSize = 56;

@interface LSOpenerViewController : UIViewController
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIView *ring;
@property (nonatomic) BOOL dragging;
@property (nonatomic) CGPoint dragOrigin;
@property (nonatomic) LSSessionMode shownMode;
@end
@implementation LSOpenerViewController
+ (NSUserDefaults *)defaults { return [[NSUserDefaults alloc] initWithSuiteName:@"com.locationspoofer.dylib"]; }
- (void)loadView {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = UIColor.clearColor;
    view.accessibilityViewIsModal = NO;
    self.view = view;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.shownMode = (LSSessionMode)-1;
    UIButtonConfiguration *config = UIButtonConfiguration.filledButtonConfiguration;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.frame = CGRectMake(0, 0, kLSOpenerSize, kLSOpenerSize);
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.28;
    button.layer.shadowRadius = 10;
    button.layer.shadowOffset = CGSizeMake(0, 4);
    button.accessibilityHint = @"Opens the LSpoof picker. Drag to move. You can hide this button in Settings.";
    button.largeContentTitle = @"LSpoof";
    button.showsLargeContentViewer = YES;
    [button addInteraction:[[UILargeContentViewerInteraction alloc] init]];
    UIView *ring = [[UIView alloc] initWithFrame:CGRectInset(button.bounds, -3, -3)];
    ring.userInteractionEnabled = NO;
    ring.layer.cornerRadius = ring.bounds.size.width / 2;
    ring.layer.borderWidth = 2.5;
    ring.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [button addSubview:ring];
    self.ring = ring;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [button addGestureRecognizer:pan];
    [self.view addSubview:button];
    self.button = button;
    [self updateForSession];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionChanged:) name:LSSessionDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)sessionChanged:(NSNotification *)note {
    (void)note;
    // Route ticks arrive at 10 Hz; only a mode change alters the button.
    if (LSSessionController.shared.snapshot.mode != self.shownMode) [self updateForSession];
}
- (void)updateForSession {
    LSSessionMode mode = LSSessionController.shared.snapshot.mode;
    self.shownMode = mode;
    UIButtonConfiguration *config = self.button.configuration;
    BOOL off = mode == LSSessionModeOff;
    config.image = [UIImage systemImageNamed:off ? @"location.fill" : LSSessionSymbol(mode)];
    config.baseBackgroundColor = off ? UIColor.systemBackgroundColor : LSAccentColor();
    config.baseForegroundColor = off ? LSAccentColor() : UIColor.whiteColor;
    if (mode == LSSessionModeMoving) config.baseBackgroundColor = LSSuccessColor();
    if (mode == LSSessionModePaused) config.baseBackgroundColor = LSWarningColor();
    self.button.configuration = config;
    self.ring.layer.borderColor = (off ? [UIColor.separatorColor resolvedColorWithTraitCollection:self.traitCollection]
                                       : [UIColor.whiteColor colorWithAlphaComponent:0.85]).CGColor;
    self.button.accessibilityLabel = off ? @"Open LSpoof. Spoofing is off" : [NSString stringWithFormat:@"Open LSpoof. %@", LSSessionTitle(mode)];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateForSession];
}
- (CGRect)allowedRect {
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGRect bounds = UIEdgeInsetsInsetRect(self.view.bounds, insets);
    return CGRectInset(bounds, 10 + kLSOpenerSize / 2, 10 + kLSOpenerSize / 2);
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.dragging) return;
    CGRect allowed = [self allowedRect];
    if (CGRectIsNull(allowed) || CGRectIsEmpty(allowed)) return;
    NSUserDefaults *defaults = [self.class defaults];
    id storedSide = [defaults objectForKey:kLSOpenerSideKey], storedY = [defaults objectForKey:kLSOpenerYKey];
    BOOL right = [storedSide isKindOfClass:NSNumber.class] ? [storedSide boolValue] : YES;
    double fraction = [storedY isKindOfClass:NSNumber.class] ? [storedY doubleValue] : 0.62;
    if (!isfinite(fraction)) fraction = 0.62;
    fraction = MAX(0.0, MIN(1.0, fraction));
    self.button.center = CGPointMake(right ? CGRectGetMaxX(allowed) : CGRectGetMinX(allowed),
                                     CGRectGetMinY(allowed) + allowed.size.height * fraction);
}
- (void)panned:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    CGRect allowed = [self allowedRect];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragging = YES;
            self.dragOrigin = self.button.center;
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            [UIView animateWithDuration:0.15 animations:^{ self.button.transform = CGAffineTransformMakeScale(1.1, 1.1); }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint center = CGPointMake(self.dragOrigin.x + translation.x, self.dragOrigin.y + translation.y);
            center.x = MAX(CGRectGetMinX(allowed), MIN(CGRectGetMaxX(allowed), center.x));
            center.y = MAX(CGRectGetMinY(allowed), MIN(CGRectGetMaxY(allowed), center.y));
            self.button.center = center;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGPoint velocity = [pan velocityInView:self.view];
            CGPoint center = self.button.center;
            CGFloat projectedX = center.x + velocity.x * 0.15;
            BOOL right = projectedX > CGRectGetMidX(allowed);
            CGFloat y = MAX(CGRectGetMinY(allowed), MIN(CGRectGetMaxY(allowed), center.y + velocity.y * 0.1));
            CGPoint target = CGPointMake(right ? CGRectGetMaxX(allowed) : CGRectGetMinX(allowed), y);
            double fraction = allowed.size.height > 0 ? (y - CGRectGetMinY(allowed)) / allowed.size.height : 0.62;
            NSUserDefaults *defaults = [self.class defaults];
            [defaults setBool:right forKey:kLSOpenerSideKey];
            [defaults setDouble:fraction forKey:kLSOpenerYKey];
            BOOL animate = !UIAccessibilityIsReduceMotionEnabled();
            [UIView animateWithDuration:animate ? 0.45 : 0.1 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                self.button.center = target;
                self.button.transform = CGAffineTransformIdentity;
            } completion:^(__unused BOOL finished) { self.dragging = NO; }];
            break;
        }
        default:
            break;
    }
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
        state.openerWindow.hidden = !visible;
    }
}
- (void)createOpener:(LSOverlayState *)state {
    LSOpenerWindow *window = state.scene ? [[LSOpenerWindow alloc] initWithWindowScene:state.scene] : [[LSOpenerWindow alloc] initWithFrame:state.hostWindow.bounds];
    window.windowLevel = UIWindowLevelNormal + 1;
    window.backgroundColor = UIColor.clearColor;
    LSOpenerViewController *controller = [[LSOpenerViewController alloc] init];
    window.rootViewController = controller;
    (void)controller.view;
    UIButton *button = controller.button;
    __weak LSOverlayState *weakState = state;
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        LSOverlayState *state = weakState;
        if (state) [[LSOverlayManager shared] presentState:state];
    }] forControlEvents:UIControlEventTouchUpInside];
    window.opener = button;
    state.openerWindow = window;
    // Setting hidden does not change the host's key window or keyboard focus.
    window.hidden = NO;
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
    state.openerWindow.hidden = YES;
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
        state.openerWindow.hidden = YES;
        // Preserve the picker reference and release latch through background/foreground.
    }
}
- (void)disconnected:(NSNotification *)note {
    for (NSString *key in self.states.allKeys) {
        LSOverlayState *state = self.states[key];
        if (state.scene == note.object) {
            [state.holdTimer invalidate]; state.openerWindow.hidden = YES; state.openerWindow = nil;
            [self.states removeObjectForKey:key];
        }
    }
}
@end
