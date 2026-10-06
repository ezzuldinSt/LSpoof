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
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.accessibilityViewIsModal = NO;
    window.rootViewController = controller;
    UIButton *button = LSButton(@"Location", @"mappin.and.ellipse", YES);
    button.accessibilityLabel = @"Open LSpoof location picker";
    button.accessibilityHint = @"Choose a location, route, or saved place. You can hide this button in Settings.";
    __weak LSOverlayState *weakState = state;
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        LSOverlayState *state = weakState;
        if (state) [[LSOverlayManager shared] presentState:state];
    }] forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [button.centerYAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.centerYAnchor]
    ]];
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
