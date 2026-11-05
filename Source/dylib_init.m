#import "LocationSpoofer.h"
#import "PersistenceManager.h"
#import "OverlayWindow.h"
#import "SessionController.h"
#import "LSScheduler.h"

__attribute__((constructor(101)))
static void LSDylibInit(void) {
    [PersistenceManager loadEarly];
    (void)[LSSessionController shared];
    [LocationSpoofer installHooks];

    dispatch_async(dispatch_get_main_queue(), ^{
        [LSOverlayManager install];
        // Before the scheduler, which may start a route of its own.
        [LSSessionController.shared restorePersistedRoute];
        [LSScheduler.shared activate];
    });
}
