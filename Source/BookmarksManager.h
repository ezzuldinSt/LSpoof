#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
NS_ASSUME_NONNULL_BEGIN
@interface LSBookmark : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
@property (nonatomic, strong, readonly) NSDate *createdAt;
// Wander radius for this place: NAN follows Settings, 0 turns wandering off here, else meters.
@property (nonatomic, readonly) double radius;
- (instancetype)initWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate;
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)bookmarkFromDictionary:(id)dictionary;
@end

@interface BookmarksManager : NSObject
@property (class, nonatomic, readonly) BookmarksManager *shared;
@property (class, nonatomic, readonly) NSUInteger capacity;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSArray<LSBookmark *> *)allBookmarks;
// No eviction. NO means invalid input or the capacity has been reached.
- (BOOL)addBookmarkWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate;
- (BOOL)removeBookmarkWithID:(NSString *)identifier;
- (BOOL)renameBookmarkWithID:(NSString *)identifier name:(NSString *)name;
- (BOOL)moveBookmarkWithID:(NSString *)identifier toIndex:(NSUInteger)index;
- (BOOL)setRadius:(double)radius forBookmarkWithID:(NSString *)identifier;
// Restore: merge skips places already saved within a few meters; replace swaps the list.
// Returns how many places were added.
- (NSUInteger)importBookmarks:(NSArray<LSBookmark *> *)bookmarks replace:(BOOL)replace;
// The saved place within a few meters of a coordinate, used to avoid duplicates.
- (nullable LSBookmark *)bookmarkNearCoordinate:(CLLocationCoordinate2D)coordinate;
@end
NS_ASSUME_NONNULL_END
