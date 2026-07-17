#import "LocationSpoofer.h"
#import "PersistenceManager.h"
#import "OverlayWindow.h"
#import "LSTimeZoneSync.h"

__attribute__((constructor(101)))
static void LSDylibInit(void) {
    [PersistenceManager loadEarly];
    [LocationSpoofer installHooks];
    [LSTimeZoneSync install];
    [LSTimeZoneSync applyFromPersistenceIfNeeded];

    dispatch_async(dispatch_get_main_queue(), ^{
        [LSOverlayManager install];
    });
}
