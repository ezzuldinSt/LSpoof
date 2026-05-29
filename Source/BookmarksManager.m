#import "BookmarksManager.h"

static NSString * const kSuiteName = @"com.locationspoofer.dylib";
static NSString * const kBookmarksKey = @"LSBookmarks";
static NSString * const kBookmarkNameKey = @"LSBMName";
static NSString * const kBookmarkLatitudeKey = @"LSBMLat";
static NSString * const kBookmarkLongitudeKey = @"LSBMLon";
static NSString * const kBookmarkDateKey = @"LSBMDate";
static const NSUInteger kLSMaxBookmarks = 50;

@implementation LSBookmark

- (instancetype)initWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate {
    self = [super init];
    if (self) {
        _name = [name copy];
        _coordinate = coordinate;
        _createdAt = [NSDate date];
    }
    return self;
}

+ (NSISO8601DateFormatter *)sharedFormatter {
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
    });
    return formatter;
}

- (NSDictionary *)dictionaryRepresentation {
    NSISO8601DateFormatter *formatter = [LSBookmark sharedFormatter];

    return @{
        kBookmarkNameKey: self.name ?: @"",
        kBookmarkLatitudeKey: @(self.coordinate.latitude),
        kBookmarkLongitudeKey: @(self.coordinate.longitude),
        kBookmarkDateKey: [formatter stringFromDate:self.createdAt ?: [NSDate date]]
    };
}

+ (instancetype)bookmarkFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *name = dictionary[kBookmarkNameKey];
    NSNumber *latitude = dictionary[kBookmarkLatitudeKey];
    NSNumber *longitude = dictionary[kBookmarkLongitudeKey];
    if (![name isKindOfClass:[NSString class]] || ![latitude isKindOfClass:[NSNumber class]] || ![longitude isKindOfClass:[NSNumber class]]) {
        return nil;
    }

    LSBookmark *bookmark = [[LSBookmark alloc] initWithName:name
                                                 coordinate:CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue)];

    NSString *dateString = dictionary[kBookmarkDateKey];
    if ([dateString isKindOfClass:[NSString class]]) {
        NSDate *parsedDate = [[LSBookmark sharedFormatter] dateFromString:dateString];
        if (parsedDate) {
            bookmark.createdAt = parsedDate;
        }
    }

    return bookmark;
}

@end

@interface BookmarksManager ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSMutableArray<LSBookmark *> *bookmarks;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation BookmarksManager

+ (instancetype)shared {
    static BookmarksManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BookmarksManager alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        _bookmarks = [NSMutableArray array];
    }
    return self;
}

- (void)loadIfNeeded {
    @synchronized(self) {
        if (self.loaded) {
            return;
        }

        NSArray *stored = [self.defaults arrayForKey:kBookmarksKey];
        if ([stored isKindOfClass:[NSArray class]]) {
            for (id entry in stored) {
                LSBookmark *bookmark = [LSBookmark bookmarkFromDictionary:entry];
                if (bookmark) {
                    [self.bookmarks addObject:bookmark];
                }
            }
        }
        self.loaded = YES;
    }
}

- (void)persistLocked {
    NSMutableArray *payload = [NSMutableArray arrayWithCapacity:self.bookmarks.count];
    for (LSBookmark *bookmark in self.bookmarks) {
        [payload addObject:[bookmark dictionaryRepresentation]];
    }
    [self.defaults setObject:payload forKey:kBookmarksKey];
}

- (NSArray<LSBookmark *> *)allBookmarks {
    @synchronized(self) {
        [self loadIfNeeded];
        return [self.bookmarks copy];
    }
}

- (void)addBookmarkWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate {
    @synchronized(self) {
        [self loadIfNeeded];
        LSBookmark *bookmark = [[LSBookmark alloc] initWithName:name coordinate:coordinate];
        [self.bookmarks insertObject:bookmark atIndex:0];
        while (self.bookmarks.count > kLSMaxBookmarks) {
            [self.bookmarks removeLastObject];
        }
        [self persistLocked];
    }
}

- (void)removeBookmarkAtIndex:(NSUInteger)index {
    @synchronized(self) {
        [self loadIfNeeded];
        if (index >= self.bookmarks.count) {
            return;
        }
        [self.bookmarks removeObjectAtIndex:index];
        [self persistLocked];
    }
}

- (void)renameBookmark:(NSString *)newName atIndex:(NSUInteger)index {
    @synchronized(self) {
        [self loadIfNeeded];
        if (index >= self.bookmarks.count) {
            return;
        }
        self.bookmarks[index].name = [newName copy];
        [self persistLocked];
    }
}

- (void)moveBookmarkFromIndex:(NSUInteger)from toIndex:(NSUInteger)to {
    @synchronized(self) {
        [self loadIfNeeded];
        if (from >= self.bookmarks.count || to >= self.bookmarks.count || from == to) {
            return;
        }
        LSBookmark *bookmark = self.bookmarks[from];
        [self.bookmarks removeObjectAtIndex:from];
        [self.bookmarks insertObject:bookmark atIndex:to];
        [self persistLocked];
    }
}

@end
