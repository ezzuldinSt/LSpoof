#import "OverlayWindow.h"
#import "LocationSpoofer.h"
#import "MapPickerViewController.h"
#import "LSHooking.h"

#import <objc/runtime.h>
#import <os/log.h>

static const NSTimeInterval kLSThreeFingerHoldDuration = 0.8;
static const NSTimeInterval kLSPresentationWatchdogInterval = 2.0;
static NSHashTable *ls_sendEventSwizzledClasses = nil;
static dispatch_once_t ls_sendEventTablesOnceToken;
static NSTimer *ls_threeFingerHoldTimer = nil;
static BOOL ls_threeFingerTriggered = NO;
static BOOL ls_isPresentingMapPicker = NO;
static BOOL ls_mapPickerVisible = NO;
static os_log_t ls_overlayLog = NULL;

#if DEBUG
#define LSAssertMainThread() NSCAssert([NSThread isMainThread], @"LocationSpoofer overlay UI state must change on main thread")
#else
#define LSAssertMainThread()
#endif

@interface LSOverlayManager ()
+ (instancetype)shared;
@property (nonatomic, assign) BOOL installed;
@end

static void LSUpdateThreeFingerHoldForEvent(UIEvent *event);

@interface LSSendEventHookTemplate : NSObject
- (void)lsp_applicationSendEvent:(UIEvent *)event;
- (void)lsp_windowSendEvent:(UIEvent *)event;
@end

static void LSInitializeSendEventTables(void) {
    dispatch_once(&ls_sendEventTablesOnceToken, ^{
        ls_sendEventSwizzledClasses = [NSHashTable weakObjectsHashTable];
        ls_overlayLog = os_log_create("com.locationspoofer.dylib", "overlay");
    });
}

static NSInteger LSActiveTouchCountForEvent(UIEvent * _Nullable event) {
    if (!event) {
        return 0;
    }

    NSSet *touches = event.allTouches;
    if (touches.count < 3) {
        return 0;
    }

    NSInteger activeTouches = 0;
    for (UITouch *touch in touches) {
        switch (touch.phase) {
            case UITouchPhaseBegan:
            case UITouchPhaseMoved:
            case UITouchPhaseStationary:
                activeTouches += 1;
                break;
            default:
                break;
        }
    }
    return activeTouches;
}

static Class LSSendEventHookTargetClass(void) {
    Class targetClass = [UIApplication class];
    UIApplication *application = UIApplication.sharedApplication;
    if (application && LSClassDefinesInstanceMethodLocally([application class], @selector(sendEvent:))) {
        targetClass = [application class];
    }
    return targetClass;
}

static void LSSwizzleSendEventOnClass(Class cls, SEL hookSelector) {
    if (!cls) {
        return;
    }

    if (!LSClassDefinesInstanceMethodLocally(cls, @selector(sendEvent:))) {
        return;
    }

    LSInitializeSendEventTables();
    @synchronized(ls_sendEventSwizzledClasses) {
        if ([ls_sendEventSwizzledClasses containsObject:cls]) {
            return;
        }

        if (LSInstallInstanceHook(cls,
                                  @selector(sendEvent:),
                                  hookSelector,
                                  [LSSendEventHookTemplate class])) {
            [ls_sendEventSwizzledClasses addObject:cls];
        }
    }
}

static void LSCancelThreeFingerHoldTimer(void) {
    [ls_threeFingerHoldTimer invalidate];
    ls_threeFingerHoldTimer = nil;
}

static void LSHandleThreeFingerHoldTimerFired(void) {
    LSCancelThreeFingerHoldTimer();
    if (ls_mapPickerVisible || ls_isPresentingMapPicker || ls_threeFingerTriggered) {
        return;
    }

    LSAssertMainThread();
    ls_threeFingerTriggered = YES;
    [LSOverlayManager presentMapPicker];
}

@implementation LSSendEventHookTemplate

- (void)lsp_applicationSendEvent:(UIEvent *)event {
    [self lsp_applicationSendEvent:event];
    LSUpdateThreeFingerHoldForEvent(event);
}

- (void)lsp_windowSendEvent:(UIEvent *)event {
    [self lsp_windowSendEvent:event];
    LSUpdateThreeFingerHoldForEvent(event);
}

@end

static void LSUpdateThreeFingerHoldForEvent(UIEvent *event) {
    if (event.type != UIEventTypeTouches || ls_mapPickerVisible || ls_isPresentingMapPicker) {
        LSCancelThreeFingerHoldTimer();
        return;
    }

    NSInteger activeTouches = LSActiveTouchCountForEvent(event);
    if (activeTouches >= 3) {
        if (ls_threeFingerHoldTimer || ls_threeFingerTriggered) {
            return;
        }

        ls_threeFingerHoldTimer = [NSTimer timerWithTimeInterval:kLSThreeFingerHoldDuration
                                                         repeats:NO
                                                           block:^(__unused NSTimer *timer) {
            LSHandleThreeFingerHoldTimerFired();
        }];
        [[NSRunLoop mainRunLoop] addTimer:ls_threeFingerHoldTimer forMode:NSRunLoopCommonModes];
    } else {
        ls_threeFingerTriggered = NO;
        LSCancelThreeFingerHoldTimer();
    }
}

static UIViewController *LSHostTopViewController(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *keyWindow = nil;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }

        if (!keyWindow) {
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden && window.alpha > 0.01) {
                    keyWindow = window;
                    break;
                }
            }
        }

        if (keyWindow) {
            break;
        }
    }

    if (!keyWindow) {
        if (ls_overlayLog) {
            os_log_error(ls_overlayLog, "No key window found for map picker presentation");
        }
        return nil;
    }

    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }

    return controller;
}

@implementation LSOverlayManager

+ (instancetype)shared {
    static LSOverlayManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LSOverlayManager alloc] init];
    });
    return instance;
}

+ (void)install {
    [[self shared] installIfNeeded];
}

+ (void)presentMapPicker {
    [[self shared] presentMapPickerIfNeeded];
}

+ (void)resetGestureTriggerState {
    LSAssertMainThread();
    ls_threeFingerTriggered = NO;
    LSCancelThreeFingerHoldTimer();
}

+ (void)setMapPickerVisible:(BOOL)visible {
    LSAssertMainThread();
    ls_mapPickerVisible = visible;
    LSCancelThreeFingerHoldTimer();
}

+ (void)restoreMapPickerSessionState {
    LSAssertMainThread();
    LSSetHooksBypassed(NO);
    ls_isPresentingMapPicker = NO;
    [self setMapPickerVisible:NO];
    [self resetGestureTriggerState];
}

+ (void)installSendEventHooks {
    LSSwizzleSendEventOnClass(LSSendEventHookTargetClass(), @selector(lsp_applicationSendEvent:));
}

- (void)installIfNeeded {
    if (self.installed) {
        return;
    }

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self installIfNeeded];
        });
        return;
    }

    [LSOverlayManager installSendEventHooks];

    // Singleton retains observers for process lifetime.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidFinishLaunching:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    self.installed = YES;
}

- (void)handleApplicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [LSOverlayManager installSendEventHooks];
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [LSOverlayManager installSendEventHooks];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [LSOverlayManager restoreMapPickerSessionState];
}

- (void)presentMapPickerIfNeeded {
    if (ls_isPresentingMapPicker || ls_mapPickerVisible) {
        return;
    }

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentMapPickerIfNeeded];
        });
        return;
    }

    UIViewController *hostController = LSHostTopViewController();
    if (!hostController || hostController.presentedViewController) {
        ls_threeFingerTriggered = NO;
        return;
    }

    LSAssertMainThread();
    ls_isPresentingMapPicker = YES;

    MapPickerViewController *mapPicker = [[MapPickerViewController alloc] init];
    mapPicker.modalPresentationStyle = UIModalPresentationPageSheet;

    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = mapPicker.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[[UISheetPresentationControllerDetent largeDetent]];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 24.0;
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLSPresentationWatchdogInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LSAssertMainThread();
        if (ls_isPresentingMapPicker) {
            ls_isPresentingMapPicker = NO;
        }
    });

    [hostController presentViewController:mapPicker animated:YES completion:^{
        LSAssertMainThread();
        ls_isPresentingMapPicker = NO;
    }];
}

@end
