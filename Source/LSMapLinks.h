#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LSMapApp) {
    LSMapAppApple,
    LSMapAppGoogle,
    LSMapAppWaze
};

// A place named by a map link: an exact coordinate, or text to look up. Foundation only so
// it can be tested on Linux, which is also why instance variables are declared here.
@interface LSMapLinkPlace : NSObject {
@private
    double _latitude;
    double _longitude;
    double _hintLatitude;
    double _hintLongitude;
    NSString *_query;
    NSString *_name;
}
+ (instancetype)placeWithLatitude:(double)latitude longitude:(double)longitude name:(nullable NSString *)name;
// hint is where the link's map was looking, used to look the text up nearby. NAN when unknown.
+ (instancetype)placeWithQuery:(NSString *)query hintLatitude:(double)latitude hintLongitude:(double)longitude;
- (BOOL)hasCoordinate;
- (double)latitude;
- (double)longitude;
- (BOOL)hasHint;
- (double)hintLatitude;
- (double)hintLongitude;
- (nullable NSString *)query;
- (nullable NSString *)name;
@end

// What a map link describes: one place, or directions through several.
@interface LSMapLink : NSObject {
@private
    NSArray<LSMapLinkPlace *> *_places;
    BOOL _directions;
    BOOL _startsAtCurrentLocation;
    NSString *_mode;
    LSMapApp _app;
}
// Directions: origin (left out when startsAtCurrentLocation), stops, destination.
- (NSArray<LSMapLinkPlace *> *)places;
- (BOOL)isDirections;
- (BOOL)startsAtCurrentLocation;
// "driving", "walking", "cycling", "transit" or nil.
- (nullable NSString *)mode;
- (LSMapApp)app;
@end

@interface LSMapLinks : NSObject
// The first Apple Maps, Google Maps, Waze or geo: link in pasted text.
+ (nullable NSURL *)firstMapLinkInText:(NSString *)text;
+ (BOOL)isMapLink:(NSURL *)url;
// Short links (maps.app.goo.gl, maps.apple) have to be opened to see where they point.
+ (BOOL)needsResolving:(NSURL *)url;
+ (nullable LSMapLink *)parseURL:(NSURL *)url;
// Same, from link text; app links such as comgooglemaps://?daddr= are read as web links.
+ (nullable LSMapLink *)parseString:(NSString *)text;
// Places are origin, stops, destination. One place gives a pin link. Waze links only carry
// the destination; legacy Apple links (before iOS 18.4) only carry origin and destination.
// mode applies to the whole trip, as none of the apps takes one per leg: for a route whose
// legs differ, the picker passes the first leg's and says so in the share menu.
+ (nullable NSURL *)URLForApp:(LSMapApp)app places:(NSArray<LSMapLinkPlace *> *)places mode:(nullable NSString *)mode legacyApple:(BOOL)legacyApple;
// How many places (origin and destination included) a link for the app keeps.
+ (NSUInteger)maximumPlacesForApp:(LSMapApp)app legacyApple:(BOOL)legacyApple;
// Apple place pages name their coordinate in meta tags; used when a link only has a place id.
+ (nullable LSMapLinkPlace *)placeFromHTML:(NSString *)html;
#ifndef GNUSTEP
// Follows redirects. On main: the final URL, plus the page text when it is a small HTML page.
+ (void)resolveURL:(NSURL *)url completion:(void (^)(NSURL * _Nullable resolved, NSString * _Nullable html))completion;
#endif
@end

NS_ASSUME_NONNULL_END
