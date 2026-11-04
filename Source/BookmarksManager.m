#import "BookmarksManager.h"

static NSString * const kSuiteName = @"com.locationspoofer.dylib";
static NSString * const kBookmarksKey = @"LSBookmarks";
static NSString *LSValidBookmarkName(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *name = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length && name.length <= 120 ? name : nil;
}
static BOOL LSValidBookmarkCoordinate(CLLocationCoordinate2D coordinate) {
    return isfinite(coordinate.latitude) && isfinite(coordinate.longitude) && CLLocationCoordinate2DIsValid(coordinate);
}
@interface LSBookmark ()
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) CLLocationCoordinate2D coordinate;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic) double radius;
@end
@implementation LSBookmark
- (instancetype)initWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate {
    self = [super init];
    if (self) {
        _identifier = NSUUID.UUID.UUIDString;
        _name = [name copy];
        _coordinate = coordinate;
        _createdAt = NSDate.date;
        _radius = NAN;
    }
    return self;
}
- (NSDictionary *)dictionaryRepresentation {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSMutableDictionary *dictionary = [@{@"LSBMID":self.identifier, @"LSBMName":self.name,
             @"LSBMLat":@(self.coordinate.latitude), @"LSBMLon":@(self.coordinate.longitude),
             @"LSBMDate":[formatter stringFromDate:self.createdAt]} mutableCopy];
    if (isfinite(self.radius)) dictionary[@"LSBMRadius"] = @(self.radius);
    return dictionary;
}
+ (instancetype)bookmarkFromDictionary:(id)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    NSString *name = LSValidBookmarkName(dictionary[@"LSBMName"]);
    id lat = dictionary[@"LSBMLat"], lon = dictionary[@"LSBMLon"];
    if (!name || ![lat isKindOfClass:NSNumber.class] || ![lon isKindOfClass:NSNumber.class]) return nil;
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]);
    if (!LSValidBookmarkCoordinate(coordinate)) return nil;
    LSBookmark *bookmark = [[self alloc] initWithName:name coordinate:coordinate];
    id date = dictionary[@"LSBMDate"];
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *parsed = [date isKindOfClass:NSString.class] && [date length] <= 64 ? [formatter dateFromString:date] : nil;
    // An unreadable date used to drop the whole place, and the load-time rewrite then
    // deleted it from storage. Keep the place; its date falls back to now.
    if (parsed) bookmark.createdAt = parsed;
    id radius = dictionary[@"LSBMRadius"];
    if ([radius isKindOfClass:NSNumber.class] && isfinite([radius doubleValue]) && [radius doubleValue] >= 0 && [radius doubleValue] <= 1000) bookmark.radius = [radius doubleValue];
    id identifier = dictionary[@"LSBMID"];
    if ([identifier isKindOfClass:NSString.class] && [identifier length] <= 64 && [[NSUUID alloc] initWithUUIDString:identifier]) bookmark.identifier = [[NSUUID alloc] initWithUUIDString:identifier].UUIDString;
    return bookmark;
}
@end

@interface BookmarksManager ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSMutableArray<LSBookmark *> *bookmarks;
@end
@implementation BookmarksManager
+ (instancetype)shared {
    static BookmarksManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:kSuiteName]]; });
    return instance;
}
+ (NSUInteger)capacity { return 50; }
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (self) {
        _defaults = defaults;
        _bookmarks = [NSMutableArray array];
        id stored = [defaults objectForKey:kBookmarksKey];
        NSMutableSet *ids = [NSMutableSet set];
        if ([stored isKindOfClass:NSArray.class]) {
            for (id entry in stored) {
                LSBookmark *bookmark = [LSBookmark bookmarkFromDictionary:entry];
                if (!bookmark) continue;
                if ([ids containsObject:bookmark.identifier]) bookmark.identifier = NSUUID.UUID.UUIDString;
                [ids addObject:bookmark.identifier];
                [_bookmarks addObject:bookmark];
                // Preserve valid legacy entries above capacity; block additions until under 50.
            }
            [self persistLocked];
        }
    }
    return self;
}
- (void)persistLocked {
    NSMutableArray *payload = [NSMutableArray array];
    for (LSBookmark *bookmark in self.bookmarks) [payload addObject:bookmark.dictionaryRepresentation];
    [self.defaults setObject:payload forKey:kBookmarksKey];
}
- (NSArray<LSBookmark *> *)allBookmarks {
    @synchronized(self) { return [self.bookmarks copy]; }
}
- (NSUInteger)indexForID:(NSString *)identifier {
    return [self.bookmarks indexOfObjectPassingTest:^BOOL(LSBookmark *bookmark, __unused NSUInteger index, __unused BOOL *stop) {
        return [bookmark.identifier isEqualToString:identifier];
    }];
}
- (BOOL)addBookmarkWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate {
    NSString *validName = LSValidBookmarkName(name);
    if (!validName || !LSValidBookmarkCoordinate(coordinate)) return NO;
    @synchronized(self) {
        if (self.bookmarks.count >= self.class.capacity) return NO;
        [self.bookmarks insertObject:[[LSBookmark alloc] initWithName:validName coordinate:coordinate] atIndex:0];
        [self persistLocked];
        return YES;
    }
}
- (BOOL)removeBookmarkWithID:(NSString *)identifier {
    @synchronized(self) {
        NSUInteger index = [self indexForID:identifier];
        if (index == NSNotFound) return NO;
        [self.bookmarks removeObjectAtIndex:index];
        [self persistLocked];
        return YES;
    }
}
- (BOOL)renameBookmarkWithID:(NSString *)identifier name:(NSString *)name {
    NSString *validName = LSValidBookmarkName(name);
    if (!validName) return NO;
    @synchronized(self) {
        NSUInteger index = [self indexForID:identifier];
        if (index == NSNotFound) return NO;
        LSBookmark *old = self.bookmarks[index];
        LSBookmark *replacement = [[LSBookmark alloc] initWithName:validName coordinate:old.coordinate];
        replacement.identifier = old.identifier;
        replacement.createdAt = old.createdAt;
        replacement.radius = old.radius;
        self.bookmarks[index] = replacement;
        [self persistLocked];
        return YES;
    }
}
- (BOOL)moveBookmarkWithID:(NSString *)identifier toIndex:(NSUInteger)index {
    @synchronized(self) {
        NSUInteger from = [self indexForID:identifier];
        if (from == NSNotFound || index >= self.bookmarks.count) return NO;
        LSBookmark *bookmark = self.bookmarks[from];
        [self.bookmarks removeObjectAtIndex:from];
        [self.bookmarks insertObject:bookmark atIndex:index];
        [self persistLocked];
        return YES;
    }
}
- (BOOL)setRadius:(double)radius forBookmarkWithID:(NSString *)identifier {
    if (isfinite(radius) && (radius < 0 || radius > 1000)) return NO;
    @synchronized(self) {
        NSUInteger index = [self indexForID:identifier];
        if (index == NSNotFound) return NO;
        LSBookmark *old = self.bookmarks[index];
        LSBookmark *replacement = [[LSBookmark alloc] initWithName:old.name coordinate:old.coordinate];
        replacement.identifier = old.identifier;
        replacement.createdAt = old.createdAt;
        replacement.radius = isfinite(radius) ? radius : NAN;
        self.bookmarks[index] = replacement;
        [self persistLocked];
        return YES;
    }
}
- (NSUInteger)importBookmarks:(NSArray<LSBookmark *> *)bookmarks replace:(BOOL)replace {
    if (![bookmarks isKindOfClass:NSArray.class]) return 0;
    @synchronized(self) {
        NSMutableArray<LSBookmark *> *result = replace ? [NSMutableArray array] : [self.bookmarks mutableCopy];
        NSMutableSet<NSString *> *ids = [NSMutableSet set];
        for (LSBookmark *existing in result) [ids addObject:existing.identifier];
        NSUInteger added = 0;
        // A restore may bring back a list above the add limit; it is capped well above it.
        NSUInteger limit = MAX(self.class.capacity, MIN((NSUInteger)500, bookmarks.count + (replace ? 0 : result.count)));
        for (LSBookmark *candidate in bookmarks) {
            if (![candidate isKindOfClass:LSBookmark.class] || result.count >= limit) continue;
            CLLocation *target = [[CLLocation alloc] initWithLatitude:candidate.coordinate.latitude longitude:candidate.coordinate.longitude];
            BOOL duplicate = NO;
            for (LSBookmark *existing in result) {
                CLLocation *other = [[CLLocation alloc] initWithLatitude:existing.coordinate.latitude longitude:existing.coordinate.longitude];
                if ([existing.identifier isEqualToString:candidate.identifier] || [other distanceFromLocation:target] < 5.0) { duplicate = YES; break; }
            }
            if (duplicate) continue;
            if ([ids containsObject:candidate.identifier]) candidate.identifier = NSUUID.UUID.UUIDString;
            [ids addObject:candidate.identifier];
            [result addObject:candidate];
            added++;
        }
        self.bookmarks = result;
        [self persistLocked];
        return added;
    }
}
- (LSBookmark *)bookmarkNearCoordinate:(CLLocationCoordinate2D)coordinate {
    if (!LSValidBookmarkCoordinate(coordinate)) return nil;
    CLLocation *target = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
    @synchronized(self) {
        for (LSBookmark *bookmark in self.bookmarks) {
            CLLocation *candidate = [[CLLocation alloc] initWithLatitude:bookmark.coordinate.latitude longitude:bookmark.coordinate.longitude];
            if ([candidate distanceFromLocation:target] < 5.0) return bookmark;
        }
    }
    return nil;
}
@end
