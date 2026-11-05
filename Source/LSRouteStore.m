#import "LSRouteStore.h"

static NSString * const kLSRouteStoreFormat = @"lspoof-routes";
static const NSInteger kLSRouteStoreVersion = 1;

@implementation LSRouteStore

+ (instancetype)shared {
    static LSRouteStore *instance;
    // Not dispatch_once: the Linux test build has no libdispatch.
    @synchronized(LSRouteStore.class) {
        if (!instance) {
            NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
            NSString *path = [[support stringByAppendingPathComponent:@"LSpoof"] stringByAppendingPathComponent:@"SavedRoutes.json"];
            instance = [[self alloc] initWithFileURL:[NSURL fileURLWithPath:path]];
        }
    }
    return instance;
}

+ (NSUInteger)capacity { return 50; }

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (self) {
        _fileURL = [fileURL copy];
        _routes = [[NSMutableArray alloc] init];
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        id entries = [object isKindOfClass:NSDictionary.class] && [[object objectForKey:@"format"] isEqual:kLSRouteStoreFormat] ? [object objectForKey:@"routes"] : nil;
        NSMutableSet<NSString *> *ids = [NSMutableSet set];
        for (id entry in [entries isKindOfClass:NSArray.class] ? entries : @[]) {
            LSRouteArchive *route = [LSRouteArchive archiveFromDictionary:entry error:NULL];
            if (!route || !route.isValid) continue;
            if ([ids containsObject:route.identifier]) route.identifier = NSUUID.UUID.UUIDString;
            [ids addObject:route.identifier];
            [_routes addObject:route];
        }
    }
    return self;
}

- (BOOL)persistLocked {
    NSMutableArray *payload = [NSMutableArray arrayWithCapacity:_routes.count];
    for (LSRouteArchive *route in _routes) [payload addObject:[route dictionaryRepresentation]];
    NSDictionary *file = @{ @"format": kLSRouteStoreFormat, @"version": @(kLSRouteStoreVersion), @"routes": payload };
    NSData *data = [NSJSONSerialization dataWithJSONObject:file options:0 error:NULL];
    if (!data) return NO;
    [NSFileManager.defaultManager createDirectoryAtURL:[_fileURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
    return [data writeToURL:_fileURL atomically:YES];
}

- (NSUInteger)indexForIDLocked:(NSString *)identifier {
    NSUInteger count = _routes.count;
    for (NSUInteger index = 0; index < count; index++) {
        if ([[[_routes objectAtIndex:index] identifier] isEqualToString:identifier]) return index;
    }
    return NSNotFound;
}

- (NSArray<LSRouteArchive *> *)allRoutes {
    @synchronized(self) {
        NSMutableArray *copies = [NSMutableArray arrayWithCapacity:_routes.count];
        for (LSRouteArchive *route in _routes) [copies addObject:[route copy]];
        return copies;
    }
}

- (NSUInteger)count {
    @synchronized(self) { return _routes.count; }
}

- (LSRouteArchive *)routeWithID:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    @synchronized(self) {
        NSUInteger index = [self indexForIDLocked:identifier];
        return index == NSNotFound ? nil : [[_routes objectAtIndex:index] copy];
    }
}

- (BOOL)addRoute:(LSRouteArchive *)route {
    return [self insertRoute:route atIndex:0];
}

- (BOOL)insertRoute:(LSRouteArchive *)route atIndex:(NSUInteger)index {
    if (![route isKindOfClass:LSRouteArchive.class] || !route.isValid) return NO;
    @synchronized(self) {
        if (_routes.count >= LSRouteStore.capacity || [self indexForIDLocked:route.identifier] != NSNotFound) return NO;
        [_routes insertObject:[route copy] atIndex:MIN(index, _routes.count)];
        if ([self persistLocked]) return YES;
        [_routes removeObjectAtIndex:MIN(index, _routes.count - 1)];
        return NO;
    }
}

- (BOOL)removeRouteWithID:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class]) return NO;
    @synchronized(self) {
        NSUInteger index = [self indexForIDLocked:identifier];
        if (index == NSNotFound) return NO;
        [_routes removeObjectAtIndex:index];
        [self persistLocked];
        return YES;
    }
}

- (BOOL)renameRouteWithID:(NSString *)identifier name:(NSString *)name {
    NSString *valid = [LSRouteArchive validName:name];
    if (!valid || ![identifier isKindOfClass:NSString.class]) return NO;
    @synchronized(self) {
        NSUInteger index = [self indexForIDLocked:identifier];
        if (index == NSNotFound) return NO;
        LSRouteArchive *renamed = [[_routes objectAtIndex:index] copy];
        renamed.name = valid;
        [_routes replaceObjectAtIndex:index withObject:renamed];
        [self persistLocked];
        return YES;
    }
}

- (NSUInteger)importRoutes:(NSArray<LSRouteArchive *> *)routes replace:(BOOL)replace {
    if (![routes isKindOfClass:NSArray.class]) return 0;
    @synchronized(self) {
        NSMutableArray<LSRouteArchive *> *result = replace ? [[NSMutableArray alloc] init] : [_routes mutableCopy];
        NSMutableSet<NSString *> *ids = [NSMutableSet set];
        for (LSRouteArchive *existing in result) [ids addObject:existing.identifier];
        NSUInteger added = 0;
        for (LSRouteArchive *candidate in routes) {
            if (result.count >= LSRouteStore.capacity) break;
            if (![candidate isKindOfClass:LSRouteArchive.class] || !candidate.isValid || [ids containsObject:candidate.identifier]) continue;
            [ids addObject:candidate.identifier];
            [result addObject:[candidate copy]];
            added++;
        }
        if (!added && !replace) return 0;
        NSMutableArray<LSRouteArchive *> *previous = _routes;
        _routes = result;
        if (![self persistLocked]) { _routes = previous; return 0; }
        return added;
    }
}

@end
