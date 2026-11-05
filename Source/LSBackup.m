#import "LSBackup.h"
#import "BookmarksManager.h"
#import "PersistenceManager.h"
#import "LSSettings.h"
#import "SessionController.h"
#import "LSRouteStore.h"

static NSString * const kLSBackupFormat = @"lspoof-backup";
static const NSInteger kLSBackupVersion = 1;
// Big enough for the largest backup the caps allow, so anything exported can be restored: 50
// saved routes of up to 50,000 points with timing are about 1.6 MB each as base64 (about 80 MB),
// plus 500 places and the settings.
static const NSUInteger kLSBackupMaximumBytes = 128 * 1024 * 1024;

@implementation LSBackupSummary
@end

static id LSNumber(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? value : nil;
}

@implementation LSBackup

+ (NSUInteger)maximumBytes { return kLSBackupMaximumBytes; }

+ (NSUserDefaults *)defaults { return [[NSUserDefaults alloc] initWithSuiteName:@"com.locationspoofer.dylib"]; }

+ (NSData *)exportData {
    PersistenceManager *store = PersistenceManager.shared;
    LSSettings *settings = LSSettings.storedSettings;
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSMutableArray *places = [NSMutableArray array];
    for (LSBookmark *place in BookmarksManager.shared.allBookmarks) {
        NSMutableDictionary *entry = [@{@"id":place.identifier, @"name":place.name, @"lat":@(place.coordinate.latitude),
                                        @"lon":@(place.coordinate.longitude), @"created":[formatter stringFromDate:place.createdAt]} mutableCopy];
        if (isfinite(place.radius)) entry[@"radius"] = @(place.radius);
        [places addObject:entry];
    }
    NSMutableArray *recents = [NSMutableArray array];
    for (NSDictionary *entry in store.recentLocations) {
        [recents addObject:@{@"name":entry[@"LSRecentName"] ?: @"Recent location", @"lat":entry[@"LSRecentLat"] ?: @0,
                             @"lon":entry[@"LSRecentLon"] ?: @0, @"date":entry[@"LSRecentDate"] ?: @""}];
    }
    NSMutableDictionary *backup = [@{
        @"format":kLSBackupFormat, @"version":@(kLSBackupVersion), @"exportedAt":[formatter stringFromDate:NSDate.date],
        @"settings":@{@"altitude":@(settings.altitude), @"course":@(settings.course), @"fluctuationEnabled":@(settings.fluctuationEnabled),
                      @"fluctuationRadius":@(settings.fluctuationRadius), @"rememberLocation":@(settings.rememberLocation),
                      @"showRealLocation":@(settings.showRealLocation), @"showFloatingButton":@(settings.showFloatingButton),
                      @"continueInBackground":@(settings.continueInBackground)},
        @"playback":@{@"smoothMotion":@(store.smoothMotion), @"accelerationProfile":@(store.accelerationProfile), @"stopDwell":@(store.stopDwell)},
        @"places":places, @"recents":recents} mutableCopy];
    NSMutableArray *routes = [NSMutableArray array];
    for (LSRouteArchive *route in LSRouteStore.shared.allRoutes) [routes addObject:route.dictionaryRepresentation];
    backup[@"routes"] = routes;
    NSUserDefaults *defaults = [self defaults];
    id side = [defaults objectForKey:@"LSOpenerSide"], y = [defaults objectForKey:@"LSOpenerY"];
    if ([side isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] && isfinite([y doubleValue])) backup[@"opener"] = @{@"right":side, @"y":y};
    return [NSJSONSerialization dataWithJSONObject:backup options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil] ?: [NSData data];
}

+ (NSString *)suggestedFileName {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"LSpoof Backup %@.json", [formatter stringFromDate:NSDate.date]];
}

+ (BOOL)textLooksLikeBackup:(NSString *)text {
    if (![text isKindOfClass:NSString.class] || text.length > kLSBackupMaximumBytes) return NO;
    return [text containsString:kLSBackupFormat] && [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasPrefix:@"{"];
}

+ (NSDictionary *)parse:(NSData *)data error:(NSString **)error {
    if (![data isKindOfClass:NSData.class] || !data.length) { if (error) *error = @"The file is empty."; return nil; }
    if (data.length > kLSBackupMaximumBytes) { if (error) *error = @"The file is too large to be an LSpoof backup."; return nil; }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"format"] isEqual:kLSBackupFormat]) {
        if (error) *error = @"This isn’t an LSpoof backup file.";
        return nil;
    }
    id version = object[@"version"];
    if (![version isKindOfClass:NSNumber.class] || [version integerValue] < 1) { if (error) *error = @"The backup has no version."; return nil; }
    if ([version integerValue] > kLSBackupVersion) { if (error) *error = @"This backup was made by a newer LSpoof. Update LSpoof and try again."; return nil; }
    return object;
}

+ (NSArray<LSBookmark *> *)placesFrom:(NSDictionary *)backup {
    NSMutableArray<LSBookmark *> *places = [NSMutableArray array];
    id entries = backup[@"places"];
    for (id entry in [entries isKindOfClass:NSArray.class] ? entries : @[]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *stored = [NSMutableDictionary dictionary];
        if (entry[@"id"]) stored[@"LSBMID"] = entry[@"id"];
        if (entry[@"name"]) stored[@"LSBMName"] = entry[@"name"];
        if (entry[@"lat"]) stored[@"LSBMLat"] = entry[@"lat"];
        if (entry[@"lon"]) stored[@"LSBMLon"] = entry[@"lon"];
        if (entry[@"created"]) stored[@"LSBMDate"] = entry[@"created"];
        if (entry[@"radius"]) stored[@"LSBMRadius"] = entry[@"radius"];
        LSBookmark *place = [LSBookmark bookmarkFromDictionary:stored];
        if (place) [places addObject:place];
        if (places.count >= 500) break;
    }
    return places;
}

// Entries that don't decode, or come from a newer route format, are left out.
+ (NSArray<LSRouteArchive *> *)routesFrom:(NSDictionary *)backup {
    NSMutableArray<LSRouteArchive *> *routes = [NSMutableArray array];
    id entries = backup[@"routes"];
    for (id entry in [entries isKindOfClass:NSArray.class] ? entries : @[]) {
        LSRouteArchive *route = [LSRouteArchive archiveFromDictionary:entry error:NULL];
        if (route.isValid) [routes addObject:route];
        if (routes.count >= LSRouteStore.capacity) break;
    }
    return routes;
}

+ (NSArray<NSDictionary *> *)recentsFrom:(NSDictionary *)backup {
    NSMutableArray *recents = [NSMutableArray array];
    id entries = backup[@"recents"];
    for (id entry in [entries isKindOfClass:NSArray.class] ? entries : @[]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        id name = entry[@"name"], lat = LSNumber(entry, @"lat"), lon = LSNumber(entry, @"lon"), date = entry[@"date"];
        if (![name isKindOfClass:NSString.class] || !lat || !lon || ![date isKindOfClass:NSString.class]) continue;
        [recents addObject:@{@"LSRecentLat":lat, @"LSRecentLon":lon, @"LSRecentName":name, @"LSRecentDate":date}];
    }
    return recents;
}

+ (LSBackupSummary *)inspectData:(NSData *)data error:(NSString **)error {
    NSDictionary *backup = [self parse:data error:error];
    if (!backup) return nil;
    LSBackupSummary *summary = [[LSBackupSummary alloc] init];
    summary.placeCount = [self placesFrom:backup].count;
    summary.routeCount = [self routesFrom:backup].count;
    summary.hasRoutes = [backup[@"routes"] isKindOfClass:NSArray.class];
    summary.recentCount = [self recentsFrom:backup].count;
    summary.hasSettings = [backup[@"settings"] isKindOfClass:NSDictionary.class];
    id exported = backup[@"exportedAt"];
    if ([exported isKindOfClass:NSString.class] && [exported length] <= 64) summary.exportedAt = [[[NSISO8601DateFormatter alloc] init] dateFromString:exported];
    return summary;
}

+ (LSBackupSummary *)restoreData:(NSData *)data replace:(BOOL)replace error:(NSString **)error {
    NSDictionary *backup = [self parse:data error:error];
    if (!backup) return nil;
    LSBackupSummary *summary = [[LSBackupSummary alloc] init];
    PersistenceManager *store = PersistenceManager.shared;
    id settingsEntry = backup[@"settings"];
    if ([settingsEntry isKindOfClass:NSDictionary.class]) {
        // Each value is checked on its own; a bad one keeps the current setting.
        LSSettings *settings = [LSSettings.storedSettings copy];
        LSSettings *candidate;
        NSDictionary *values = settingsEntry;
        if (LSNumber(values, @"altitude")) { candidate = [settings copy]; candidate.altitude = [values[@"altitude"] doubleValue]; if (candidate.isValid) settings = candidate; }
        if (LSNumber(values, @"course")) { candidate = [settings copy]; candidate.course = [values[@"course"] doubleValue]; if (candidate.isValid) settings = candidate; }
        if (LSNumber(values, @"fluctuationRadius")) { candidate = [settings copy]; candidate.fluctuationRadius = [values[@"fluctuationRadius"] doubleValue]; if (candidate.isValid) settings = candidate; }
        if (LSNumber(values, @"fluctuationEnabled")) settings.fluctuationEnabled = [values[@"fluctuationEnabled"] boolValue];
        if (LSNumber(values, @"rememberLocation")) settings.rememberLocation = [values[@"rememberLocation"] boolValue];
        if (LSNumber(values, @"showRealLocation")) settings.showRealLocation = [values[@"showRealLocation"] boolValue];
        if (LSNumber(values, @"showFloatingButton")) settings.showFloatingButton = [values[@"showFloatingButton"] boolValue];
        if (LSNumber(values, @"continueInBackground")) settings.continueInBackground = [values[@"continueInBackground"] boolValue];
        summary.hasSettings = [LSSessionController.shared saveSettings:settings];
    }
    id playback = backup[@"playback"];
    if ([playback isKindOfClass:NSDictionary.class]) {
        if (LSNumber(playback, @"smoothMotion")) store.smoothMotion = [playback[@"smoothMotion"] boolValue];
        if (LSNumber(playback, @"accelerationProfile")) store.accelerationProfile = [playback[@"accelerationProfile"] integerValue];
        if (LSNumber(playback, @"stopDwell")) store.stopDwell = [playback[@"stopDwell"] doubleValue];
    }
    summary.placeCount = [BookmarksManager.shared importBookmarks:[self placesFrom:backup] replace:replace];
    // A backup from before saved routes has no list, and leaves them as they are.
    summary.hasRoutes = [backup[@"routes"] isKindOfClass:NSArray.class];
    if (summary.hasRoutes) summary.routeCount = [LSRouteStore.shared importRoutes:[self routesFrom:backup] replace:replace];
    NSArray *recents = [self recentsFrom:backup];
    if (recents.count || replace) {
        NSMutableArray *merged = [recents mutableCopy];
        if (!replace) [merged addObjectsFromArray:store.recentLocations];
        NSUInteger before = replace ? 0 : store.recentLocations.count;
        [store replaceRecentLocations:merged];
        summary.recentCount = store.recentLocations.count > before ? store.recentLocations.count - before : 0;
        if (replace) summary.recentCount = store.recentLocations.count;
    }
    id opener = backup[@"opener"];
    if ([opener isKindOfClass:NSDictionary.class] && LSNumber(opener, @"right") && LSNumber(opener, @"y")) {
        double y = [opener[@"y"] doubleValue];
        if (y >= 0 && y <= 1) {
            NSUserDefaults *defaults = [self defaults];
            [defaults setBool:[opener[@"right"] boolValue] forKey:@"LSOpenerSide"];
            [defaults setDouble:y forKey:@"LSOpenerY"];
        }
    }
    return summary;
}

@end
