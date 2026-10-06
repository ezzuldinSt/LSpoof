#import "LSSettings.h"
#import "PersistenceManager.h"

@implementation LSSettings
+ (instancetype)storedSettings {
    PersistenceManager *store = PersistenceManager.shared;
    LSSettings *settings = [[self alloc] init];
    settings.altitude = store.altitude;
    settings.course = store.heading;
    settings.fluctuationEnabled = store.fluctuationEnabled;
    settings.fluctuationRadius = store.fluctuationRadius;
    settings.rememberLocation = store.keepLastSpoof;
    settings.showRealLocation = store.showRealLocation;
    settings.showFloatingButton = store.showFloatingButton;
    return settings;
}
- (id)copyWithZone:(NSZone *)zone {
    LSSettings *copy = [[[self class] allocWithZone:zone] init];
    copy.altitude = self.altitude;
    copy.course = self.course;
    copy.fluctuationEnabled = self.fluctuationEnabled;
    copy.fluctuationRadius = self.fluctuationRadius;
    copy.rememberLocation = self.rememberLocation;
    copy.showRealLocation = self.showRealLocation;
    copy.showFloatingButton = self.showFloatingButton;
    return copy;
}
- (BOOL)isValid {
    return isfinite(self.altitude) && self.altitude >= -500 && self.altitude <= 10000 &&
        isfinite(self.course) && self.course >= 0 && self.course < 360 &&
        isfinite(self.fluctuationRadius) && self.fluctuationRadius >= 1 && self.fluctuationRadius <= 1000;
}
- (void)writeToStore {
    if (!self.isValid) return;
    PersistenceManager *store = PersistenceManager.shared;
    // Turning Remember off used to leave the kept coordinate behind, so the picker kept
    // offering it as the last selection. An active session's coordinate is never touched.
    BOOL forget = store.keepLastSpoof && !self.rememberLocation && !store.isSpoofingEnabled;
    store.altitude = self.altitude;
    store.heading = self.course;
    store.fluctuationEnabled = self.fluctuationEnabled;
    store.fluctuationRadius = self.fluctuationRadius;
    store.keepLastSpoof = self.rememberLocation;
    if (forget) [store clearLastSpoof];
    store.showRealLocation = self.showRealLocation;
    store.showFloatingButton = self.showFloatingButton;
}
@end
