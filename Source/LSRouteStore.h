#import <Foundation/Foundation.h>
#import "LSRouteArchive.h"

NS_ASSUME_NONNULL_BEGIN

// Named routes from the Saved tab, newest first. They live in a JSON file in Application
// Support rather than in the defaults, because a recorded track can be large. Foundation only,
// so it can be tested on Linux, which is also why the instance variables are declared here.
//   { "format": "lspoof-routes", "version": 1, "routes": [ LSRouteArchive, ... ] }
@interface LSRouteStore : NSObject {
@private
    NSURL *_fileURL;
    NSMutableArray<LSRouteArchive *> *_routes;
}
@property (class, nonatomic, readonly) LSRouteStore *shared;
@property (class, nonatomic, readonly) NSUInteger capacity;
// Loads the file if it exists; unreadable entries are skipped.
- (instancetype)initWithFileURL:(NSURL *)fileURL;
- (NSArray<LSRouteArchive *> *)allRoutes;
- (NSUInteger)count;
- (nullable LSRouteArchive *)routeWithID:(NSString *)identifier;
// No eviction. NO means invalid input, an identifier already saved, or the capacity was reached.
- (BOOL)addRoute:(LSRouteArchive *)route;
// Puts a deleted route back at its old position (Undo).
- (BOOL)insertRoute:(LSRouteArchive *)route atIndex:(NSUInteger)index;
- (BOOL)removeRouteWithID:(NSString *)identifier;
- (BOOL)renameRouteWithID:(NSString *)identifier name:(NSString *)name;
// Restore: merge skips routes already saved (same identifier); replace swaps the list.
// Returns how many routes were added, never more than the capacity allows.
- (NSUInteger)importRoutes:(NSArray<LSRouteArchive *> *)routes replace:(BOOL)replace;
@end

NS_ASSUME_NONNULL_END
