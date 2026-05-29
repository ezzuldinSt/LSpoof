#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSBookmark : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;
@property (nonatomic, strong) NSDate *createdAt;

- (instancetype)initWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)bookmarkFromDictionary:(NSDictionary *)dictionary;

@end

@interface BookmarksManager : NSObject

@property (class, nonatomic, readonly) BookmarksManager *shared;

- (NSArray<LSBookmark *> *)allBookmarks;
- (void)addBookmarkWithName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate;
- (void)removeBookmarkAtIndex:(NSUInteger)index;
- (void)renameBookmark:(NSString *)newName atIndex:(NSUInteger)index;
- (void)moveBookmarkFromIndex:(NSUInteger)from toIndex:(NSUInteger)to;

@end

NS_ASSUME_NONNULL_END
