#import "LSMapLinks.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static const NSUInteger kLSMapLinkMaximumPlaces = 16;
static const NSUInteger kLSMapLinkMaximumHTML = 512 * 1024;

static BOOL LSValidCoordinate(double latitude, double longitude) {
    return isfinite(latitude) && isfinite(longitude) && fabs(latitude) <= 90.0 && fabs(longitude) <= 180.0;
}

static NSString *LSTrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

// Reads "lat,lon", allowing spaces, a "loc:" prefix and a trailing "(Label)".
static BOOL LSLinkCoordinatePair(NSString *text, double *latitude, double *longitude, NSString **label) {
    if (label) *label = nil;
    NSString *value = LSTrim(text);
    if ([value.lowercaseString hasPrefix:@"loc:"]) value = LSTrim([value substringFromIndex:4]);
    NSRange paren = [value rangeOfString:@"("];
    if (paren.location != NSNotFound && [value hasSuffix:@")"]) {
        NSString *inside = LSTrim([value substringWithRange:NSMakeRange(paren.location + 1, value.length - paren.location - 2)]);
        if (label && inside.length) *label = inside;
        value = LSTrim([value substringToIndex:paren.location]);
    }
    const char *utf8 = value.UTF8String;
    if (!utf8 || !*utf8) return NO;
    char *end = NULL;
    double lat = strtod(utf8, &end);
    if (end == utf8) return NO;
    while (*end == ' ') end++;
    if (*end != ',') return NO;
    const char *second = end + 1;
    while (*second == ' ') second++;
    double lon = strtod(second, &end);
    if (end == second) return NO;
    while (*end == ' ') end++;
    if (*end != '\0' || !LSValidCoordinate(lat, lon)) return NO;
    if (latitude) *latitude = lat;
    if (longitude) *longitude = lon;
    return YES;
}

// Reads 37°25'19.6"N 122°05'02.4"W, the name Google gives a dropped pin.
static BOOL LSParseDMS(NSString *text, double *latitude, double *longitude) {
    NSString *value = [[[LSTrim(text) stringByReplacingOccurrencesOfString:@"\u2032" withString:@"'"]
                        stringByReplacingOccurrencesOfString:@"\u2033" withString:@"\""]
                       stringByReplacingOccurrencesOfString:@"''" withString:@"\""];
    const char *utf8 = value.UTF8String;
    if (!utf8 || !strstr(utf8, "\xC2\xB0")) return NO;
    double parts[2];
    const char *cursor = utf8;
    for (int axis = 0; axis < 2; axis++) {
        while (*cursor == ' ' || *cursor == ',') cursor++;
        char *end = NULL;
        double degrees = strtod(cursor, &end);
        if (end == cursor || strncmp(end, "\xC2\xB0", 2) != 0) return NO;
        cursor = end + 2;
        double minutes = 0, seconds = 0;
        const char *peek = cursor;
        while (*peek == ' ') peek++;
        double number = strtod(peek, &end);
        if (end != peek && *end == '\'') { minutes = number; cursor = end + 1; peek = cursor; while (*peek == ' ') peek++; number = strtod(peek, &end); }
        if (end != peek && *end == '"') { seconds = number; cursor = end + 1; }
        while (*cursor == ' ') cursor++;
        char hemisphere = (char)toupper((unsigned char)*cursor);
        if (axis == 0 && hemisphere != 'N' && hemisphere != 'S') return NO;
        if (axis == 1 && hemisphere != 'E' && hemisphere != 'W') return NO;
        if (minutes >= 60 || seconds >= 60 || minutes < 0 || seconds < 0) return NO;
        double result = fabs(degrees) + minutes / 60.0 + seconds / 3600.0;
        parts[axis] = (hemisphere == 'S' || hemisphere == 'W') ? -result : result;
        cursor++;
    }
    while (*cursor == ' ') cursor++;
    if (*cursor != '\0' || !LSValidCoordinate(parts[0], parts[1])) return NO;
    *latitude = parts[0];
    *longitude = parts[1];
    return YES;
}

static NSString *LSDecodeComponent(NSString *raw) {
    NSString *spaced = [raw stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [spaced stringByRemovingPercentEncoding] ?: spaced;
}

// Query items in order, with '+' read as a space and repeated names kept.
static NSArray<NSArray<NSString *> *> *LSQueryItems(NSURL *url) {
    NSMutableArray *items = [NSMutableArray array];
    NSString *query = url.query;
    if (!query.length) return items;
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSRange equals = [pair rangeOfString:@"="];
        NSString *name = equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location];
        NSString *value = equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1];
        [items addObject:@[ LSDecodeComponent(name).lowercaseString, LSDecodeComponent(value) ]];
    }
    return items;
}

static NSString *LSQueryValue(NSArray<NSArray<NSString *> *> *items, NSString *name) {
    for (NSArray<NSString *> *item in items) {
        if ([[item objectAtIndex:0] isEqualToString:name]) {
            NSString *value = LSTrim([item objectAtIndex:1]);
            return value.length ? value : nil;
        }
    }
    return nil;
}

static NSArray<NSString *> *LSQueryValues(NSArray<NSArray<NSString *> *> *items, NSString *name) {
    NSMutableArray *values = [NSMutableArray array];
    for (NSArray<NSString *> *item in items) {
        if ([[item objectAtIndex:0] isEqualToString:name] && LSTrim([item objectAtIndex:1]).length) [values addObject:LSTrim([item objectAtIndex:1])];
    }
    return values;
}

// Path components without percent decoding, so an encoded '/' stays inside its component.
static NSArray<NSString *> *LSRawPathComponents(NSURL *url) {
    NSString *path = nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    path = components.percentEncodedPath;
    if (!path) path = url.path ?: @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        [parts addObject:part];
    }
    while (parts.count && [[parts objectAtIndex:0] length] == 0) [parts removeObjectAtIndex:0];
    return parts;
}

static NSString *LSFormatCoordinate(double value) {
    NSString *text = [NSString stringWithFormat:@"%.6f", value];
    while ([text hasSuffix:@"0"]) text = [text substringToIndex:text.length - 1];
    if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    if ([text isEqualToString:@"-0"]) text = @"0";
    return text;
}

static NSString *LSEncode(NSString *text) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,"];
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

#pragma mark - Values

@implementation LSMapLinkPlace

+ (instancetype)placeWithLatitude:(double)latitude longitude:(double)longitude name:(NSString *)name {
    LSMapLinkPlace *place = [[self alloc] init];
    place->_latitude = latitude;
    place->_longitude = longitude;
    place->_hintLatitude = NAN;
    place->_hintLongitude = NAN;
    NSString *trimmed = LSTrim(name ?: @"");
    place->_name = trimmed.length ? [trimmed copy] : nil;
    return place;
}

+ (instancetype)placeWithQuery:(NSString *)query hintLatitude:(double)latitude hintLongitude:(double)longitude {
    LSMapLinkPlace *place = [[self alloc] init];
    place->_latitude = NAN;
    place->_longitude = NAN;
    BOOL hint = LSValidCoordinate(latitude, longitude);
    place->_hintLatitude = hint ? latitude : NAN;
    place->_hintLongitude = hint ? longitude : NAN;
    NSString *trimmed = LSTrim(query ?: @"");
    if (trimmed.length > 300) trimmed = [trimmed substringToIndex:300];
    place->_query = [trimmed copy];
    place->_name = [trimmed copy];
    return place;
}

- (BOOL)hasCoordinate { return LSValidCoordinate(_latitude, _longitude); }
- (double)latitude { return _latitude; }
- (double)longitude { return _longitude; }
- (BOOL)hasHint { return LSValidCoordinate(_hintLatitude, _hintLongitude); }
- (double)hintLatitude { return _hintLatitude; }
- (double)hintLongitude { return _hintLongitude; }
- (NSString *)query { return _query; }
- (NSString *)name { return _name; }
- (NSString *)description {
    return self.hasCoordinate ? [NSString stringWithFormat:@"<%f,%f %@>", _latitude, _longitude, _name ?: @""]
                              : [NSString stringWithFormat:@"<query %@>", _query];
}

@end

@implementation LSMapLink
- (NSArray<LSMapLinkPlace *> *)places { return _places; }
- (BOOL)isDirections { return _directions; }
- (BOOL)startsAtCurrentLocation { return _startsAtCurrentLocation; }
- (NSString *)mode { return _mode; }
- (LSMapApp)app { return _app; }

+ (instancetype)linkWithApp:(LSMapApp)app places:(NSArray<LSMapLinkPlace *> *)places directions:(BOOL)directions
               fromCurrent:(BOOL)fromCurrent mode:(NSString *)mode {
    if (!places.count) return nil;
    if (places.count > kLSMapLinkMaximumPlaces) places = [places subarrayWithRange:NSMakeRange(0, kLSMapLinkMaximumPlaces)];
    LSMapLink *link = [[self alloc] init];
    link->_app = app;
    link->_places = [places copy];
    // Directions to a single place start where you are.
    link->_directions = directions;
    link->_startsAtCurrentLocation = directions && (fromCurrent || places.count == 1);
    link->_mode = [mode copy];
    return link;
}
@end

#pragma mark - Parsing helpers

// "lat,lon" becomes a coordinate, anything else text to look up.
static LSMapLinkPlace *LSPlaceFromText(NSString *text, double hintLatitude, double hintLongitude) {
    NSString *value = LSTrim(text);
    if (!value.length) return nil;
    double lat, lon;
    NSString *label = nil;
    if (LSLinkCoordinatePair(value, &lat, &lon, &label)) return [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:label];
    if (LSParseDMS(value, &lat, &lon)) return [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:nil];
    return [LSMapLinkPlace placeWithQuery:value hintLatitude:hintLatitude hintLongitude:hintLongitude];
}

static BOOL LSIsCurrentLocationText(NSString *text) {
    NSString *value = LSTrim(text).lowercaseString;
    return !value.length || [value isEqualToString:@"my location"] || [value isEqualToString:@"your location"] ||
           [value isEqualToString:@"current location"];
}

// Google's "data=" blob lists each place as ...!1d<lon>!2d<lat>..., a single place's pin as
// !3d<lat>!4d<lon>, and the travel mode as !3e<n>.
static NSArray<NSArray<NSNumber *> *> *LSGoogleDataPairs(NSString *data, NSString *firstKey, NSString *secondKey) {
    NSMutableArray *pairs = [NSMutableArray array];
    NSString *firstToken = [NSString stringWithFormat:@"!%@", firstKey];
    NSString *secondToken = [NSString stringWithFormat:@"!%@", secondKey];
    NSRange search = NSMakeRange(0, data.length);
    while (search.length) {
        NSRange first = [data rangeOfString:firstToken options:0 range:search];
        if (first.location == NSNotFound) break;
        NSUInteger valueStart = NSMaxRange(first);
        NSRange next = [data rangeOfString:@"!" options:0 range:NSMakeRange(valueStart, data.length - valueStart)];
        NSUInteger valueEnd = next.location == NSNotFound ? data.length : next.location;
        double a = strtod([[data substringWithRange:NSMakeRange(valueStart, valueEnd - valueStart)] UTF8String], NULL);
        if (next.location != NSNotFound && [data rangeOfString:secondToken options:NSAnchoredSearch range:NSMakeRange(next.location, data.length - next.location)].location != NSNotFound) {
            NSUInteger bStart = next.location + secondToken.length;
            NSRange bEnd = [data rangeOfString:@"!" options:0 range:NSMakeRange(bStart, data.length - bStart)];
            NSUInteger bStop = bEnd.location == NSNotFound ? data.length : bEnd.location;
            double b = strtod([[data substringWithRange:NSMakeRange(bStart, bStop - bStart)] UTF8String], NULL);
            [pairs addObject:@[ @(a), @(b) ]];
            valueEnd = bStop;
        }
        search = NSMakeRange(valueEnd, data.length - valueEnd);
    }
    return pairs;
}

static NSString *LSGoogleModeFromData(NSString *data) {
    NSRange range = [data rangeOfString:@"!3e"];
    if (range.location == NSNotFound || NSMaxRange(range) >= data.length) return nil;
    switch ([data characterAtIndex:NSMaxRange(range)]) {
        case '0': return @"driving";
        case '1': return @"cycling";
        case '2': return @"walking";
        case '3': return @"transit";
        default: return nil;
    }
}

static NSString *LSModeFromWord(NSString *word) {
    NSString *value = LSTrim(word).lowercaseString;
    if (!value.length) return nil;
    if ([value hasPrefix:@"walk"] || [value isEqualToString:@"w"]) return @"walking";
    if ([value hasPrefix:@"bicycl"] || [value hasPrefix:@"cycl"] || [value hasPrefix:@"bik"] || [value isEqualToString:@"b"] || [value isEqualToString:@"c"]) return @"cycling";
    if ([value hasPrefix:@"transit"] || [value isEqualToString:@"r"]) return @"transit";
    if ([value hasPrefix:@"driv"] || [value isEqualToString:@"d"] || [value isEqualToString:@"h"]) return @"driving";
    return nil;
}

// "@lat,lon,15z" or "@lat,lon,500m": where the map was looking.
static BOOL LSParseViewport(NSString *component, double *latitude, double *longitude) {
    if (![component hasPrefix:@"@"]) return NO;
    NSArray<NSString *> *parts = [[component substringFromIndex:1] componentsSeparatedByString:@","];
    if (parts.count < 2) return NO;
    return LSLinkCoordinatePair([NSString stringWithFormat:@"%@,%@", [parts objectAtIndex:0], [parts objectAtIndex:1]], latitude, longitude, NULL);
}

// "A to:B to:C" in legacy saddr/daddr parameters.
static NSArray<NSString *> *LSSplitLegacyDestinations(NSString *text) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByString:@"to:"]) {
        NSString *trimmed = LSTrim(part);
        if (trimmed.length) [parts addObject:trimmed];
    }
    return parts;
}

static double LSGeohashDecode(NSString *hash, double *longitudeOut) {
    static const char *alphabet = "0123456789bcdefghjkmnpqrstuvwxyz";
    double latMin = -90, latMax = 90, lonMin = -180, lonMax = 180;
    BOOL even = YES;
    NSString *lower = hash.lowercaseString;
    if (!lower.length || lower.length > 16) return NAN;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        const char *found = c < 128 ? strchr(alphabet, (char)c) : NULL;
        if (!found || !*found) return NAN;
        int value = (int)(found - alphabet);
        for (int bit = 4; bit >= 0; bit--) {
            int set = (value >> bit) & 1;
            if (even) {
                double mid = (lonMin + lonMax) / 2;
                if (set) lonMin = mid; else lonMax = mid;
            } else {
                double mid = (latMin + latMax) / 2;
                if (set) latMin = mid; else latMax = mid;
            }
            even = !even;
        }
    }
    if (longitudeOut) *longitudeOut = (lonMin + lonMax) / 2;
    return (latMin + latMax) / 2;
}

#pragma mark - Per app

static LSMapLink *LSParseGoogle(NSURL *url) {
    NSArray *items = LSQueryItems(url);
    NSArray<NSString *> *path = LSRawPathComponents(url);
    NSUInteger mapsIndex = [path indexOfObject:@"maps"];
    NSArray<NSString *> *rest = mapsIndex == NSNotFound ? path : [path subarrayWithRange:NSMakeRange(mapsIndex + 1, path.count - mapsIndex - 1)];
    NSString *first = rest.count ? [rest objectAtIndex:0] : @"";
    NSString *data = @"";
    double viewLat = NAN, viewLon = NAN;
    for (NSString *component in rest) {
        if ([component hasPrefix:@"data="]) data = [component substringFromIndex:5];
        LSParseViewport(component, &viewLat, &viewLon);
    }
    NSString *mode = LSModeFromWord(LSQueryValue(items, @"travelmode") ?: LSQueryValue(items, @"directionsmode") ?: LSQueryValue(items, @"dirflg") ?: @"");

    // Maps URLs API: /maps/dir/?api=1&origin=&destination=&waypoints=a|b
    if ([first isEqualToString:@"dir"] && LSQueryValue(items, @"destination")) {
        NSMutableArray *places = [NSMutableArray array];
        NSString *origin = LSQueryValue(items, @"origin");
        BOOL fromCurrent = LSIsCurrentLocationText(origin ?: @"");
        if (!fromCurrent) [places addObject:LSPlaceFromText(origin, NAN, NAN)];
        for (NSString *stop in [(LSQueryValue(items, @"waypoints") ?: @"") componentsSeparatedByString:@"|"]) {
            LSMapLinkPlace *place = LSPlaceFromText(stop, NAN, NAN);
            if (place) [places addObject:place];
        }
        [places addObject:LSPlaceFromText(LSQueryValue(items, @"destination"), NAN, NAN)];
        return [LSMapLink linkWithApp:LSMapAppGoogle places:places directions:YES fromCurrent:fromCurrent mode:mode];
    }

    // App directions: /maps/dir/A/B/C/@view/data=...
    if ([first isEqualToString:@"dir"]) {
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        for (NSUInteger i = 1; i < rest.count; i++) {
            NSString *component = [rest objectAtIndex:i];
            if ([component hasPrefix:@"@"] || [component hasPrefix:@"data="] || [component hasPrefix:@"am="]) break;
            [texts addObject:LSDecodeComponent(component)];
        }
        while (texts.count && !LSTrim(texts.lastObject).length) [texts removeLastObject];
        if (!texts.count) return nil;
        BOOL fromCurrent = LSIsCurrentLocationText([texts objectAtIndex:0]) || texts.count == 1;
        if (LSIsCurrentLocationText([texts objectAtIndex:0])) [texts removeObjectAtIndex:0];
        if (!texts.count) return nil;
        // Text places get their coordinates, in order, from the data blob when it has one per place.
        // Either every place has an entry, or only the ones given as text do.
        NSArray *pairs = LSGoogleDataPairs(data, @"1d", @"2d");
        NSUInteger textCount = 0;
        for (NSString *text in texts) {
            if (!LSPlaceFromText(text, NAN, NAN).hasCoordinate) textCount++;
        }
        BOOL pairPerPlace = pairs.count == texts.count;
        BOOL pairPerText = !pairPerPlace && pairs.count == textCount;
        NSUInteger pairIndex = 0;
        NSMutableArray *places = [NSMutableArray array];
        for (NSUInteger i = 0; i < texts.count; i++) {
            NSString *text = [texts objectAtIndex:i];
            LSMapLinkPlace *place = LSPlaceFromText(text, viewLat, viewLon);
            if (!place) continue;
            if (!place.hasCoordinate && (pairPerPlace || pairPerText)) {
                NSArray<NSNumber *> *pair = [pairs objectAtIndex:pairPerPlace ? i : pairIndex++];
                double lon = [[pair objectAtIndex:0] doubleValue], lat = [[pair objectAtIndex:1] doubleValue];
                if (LSValidCoordinate(lat, lon)) place = [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:place.query];
            }
            [places addObject:place];
        }
        return [LSMapLink linkWithApp:LSMapAppGoogle places:places directions:YES fromCurrent:fromCurrent mode:mode ?: LSGoogleModeFromData(data)];
    }

    // A place: /maps/place/Name/@view/data=...!3d<lat>!4d<lon>
    if ([first isEqualToString:@"place"] && rest.count > 1) {
        NSString *name = LSDecodeComponent([rest objectAtIndex:1]);
        NSArray *pins = LSGoogleDataPairs(data, @"3d", @"4d");
        if (pins.count) {
            NSArray<NSNumber *> *pin = pins.lastObject;
            double lat = [[pin objectAtIndex:0] doubleValue], lon = [[pin objectAtIndex:1] doubleValue];
            if (LSValidCoordinate(lat, lon)) {
                LSMapLinkPlace *named = LSPlaceFromText(name, NAN, NAN);
                return [LSMapLink linkWithApp:LSMapAppGoogle places:@[ [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:named.hasCoordinate ? nil : name] ]
                                   directions:NO fromCurrent:NO mode:nil];
            }
        }
        LSMapLinkPlace *place = LSPlaceFromText(name, viewLat, viewLon);
        return place ? [LSMapLink linkWithApp:LSMapAppGoogle places:@[ place ] directions:NO fromCurrent:NO mode:nil] : nil;
    }

    // Search: /maps/search/?api=1&query=  or  /maps/search/<text>/@view
    if ([first isEqualToString:@"search"]) {
        NSString *query = LSQueryValue(items, @"query");
        if (!query && rest.count > 1 && ![[rest objectAtIndex:1] hasPrefix:@"@"]) query = LSDecodeComponent([rest objectAtIndex:1]);
        LSMapLinkPlace *place = query ? LSPlaceFromText(query, viewLat, viewLon) : nil;
        return place ? [LSMapLink linkWithApp:LSMapAppGoogle places:@[ place ] directions:NO fromCurrent:NO mode:nil] : nil;
    }

    // Legacy parameters: ?saddr=&daddr=, ?q=, ?ll=, ?center=
    NSString *daddr = LSQueryValue(items, @"daddr");
    if (daddr) {
        NSMutableArray *places = [NSMutableArray array];
        NSString *saddr = LSQueryValue(items, @"saddr");
        BOOL fromCurrent = LSIsCurrentLocationText(saddr ?: @"");
        if (!fromCurrent) [places addObject:LSPlaceFromText(saddr, NAN, NAN)];
        for (NSString *text in LSSplitLegacyDestinations(daddr)) [places addObject:LSPlaceFromText(text, NAN, NAN)];
        return [LSMapLink linkWithApp:LSMapAppGoogle places:places directions:YES fromCurrent:fromCurrent mode:mode];
    }
    NSString *ll = LSQueryValue(items, @"ll") ?: LSQueryValue(items, @"center");
    double llLat = NAN, llLon = NAN;
    BOOL hasLL = ll && LSLinkCoordinatePair(ll, &llLat, &llLon, NULL);
    NSString *q = LSQueryValue(items, @"q") ?: LSQueryValue(items, @"query");
    if (q) {
        LSMapLinkPlace *place = LSPlaceFromText(q, hasLL ? llLat : viewLat, hasLL ? llLon : viewLon);
        return place ? [LSMapLink linkWithApp:LSMapAppGoogle places:@[ place ] directions:NO fromCurrent:NO mode:nil] : nil;
    }
    if (hasLL) return [LSMapLink linkWithApp:LSMapAppGoogle places:@[ [LSMapLinkPlace placeWithLatitude:llLat longitude:llLon name:nil] ] directions:NO fromCurrent:NO mode:nil];
    // Just a map view: /maps/@lat,lon,15z
    if (LSValidCoordinate(viewLat, viewLon)) {
        return [LSMapLink linkWithApp:LSMapAppGoogle places:@[ [LSMapLinkPlace placeWithLatitude:viewLat longitude:viewLon name:nil] ] directions:NO fromCurrent:NO mode:nil];
    }
    return nil;
}

static LSMapLink *LSParseApple(NSURL *url) {
    NSArray *items = LSQueryItems(url);
    NSArray<NSString *> *path = LSRawPathComponents(url);
    NSString *first = path.count ? [path objectAtIndex:0] : @"";
    NSString *mode = LSModeFromWord(LSQueryValue(items, @"mode") ?: LSQueryValue(items, @"dirflg") ?: @"");
    double hintLat = NAN, hintLon = NAN;
    NSString *hint = LSQueryValue(items, @"center") ?: LSQueryValue(items, @"sll") ?: LSQueryValue(items, @"near");
    if (hint) LSLinkCoordinatePair(hint, &hintLat, &hintLon, NULL);

    // Unified links (iOS 18.4 and later).
    if ([first isEqualToString:@"directions"]) {
        NSString *destination = LSQueryValue(items, @"destination");
        if (!destination) return nil;
        NSMutableArray *places = [NSMutableArray array];
        NSString *source = LSQueryValue(items, @"source");
        BOOL fromCurrent = LSIsCurrentLocationText(source ?: @"");
        if (!fromCurrent) [places addObject:LSPlaceFromText(source, hintLat, hintLon)];
        for (NSString *stop in LSQueryValues(items, @"waypoint")) [places addObject:LSPlaceFromText(stop, hintLat, hintLon)];
        [places addObject:LSPlaceFromText(destination, hintLat, hintLon)];
        return [LSMapLink linkWithApp:LSMapAppApple places:places directions:YES fromCurrent:fromCurrent mode:mode];
    }
    if ([first isEqualToString:@"place"] || [first isEqualToString:@"search"]) {
        NSString *name = LSQueryValue(items, @"name");
        double lat, lon;
        NSString *coordinate = LSQueryValue(items, @"coordinate") ?: LSQueryValue(items, @"ll");
        if (coordinate && LSLinkCoordinatePair(coordinate, &lat, &lon, NULL)) {
            return [LSMapLink linkWithApp:LSMapAppApple places:@[ [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:name ?: LSQueryValue(items, @"address")] ]
                               directions:NO fromCurrent:NO mode:nil];
        }
        NSString *text = LSQueryValue(items, @"address") ?: LSQueryValue(items, @"query") ?: LSQueryValue(items, @"q") ?: name;
        LSMapLinkPlace *place = text ? LSPlaceFromText(text, hintLat, hintLon) : nil;
        return place ? [LSMapLink linkWithApp:LSMapAppApple places:@[ place ] directions:NO fromCurrent:NO mode:nil] : nil;
    }

    // Legacy links: ?saddr=&daddr=&dirflg=, ?ll=&q=, ?address=, ?q=
    NSString *daddr = LSQueryValue(items, @"daddr");
    if (daddr) {
        NSMutableArray *places = [NSMutableArray array];
        NSString *saddr = LSQueryValue(items, @"saddr");
        BOOL fromCurrent = LSIsCurrentLocationText(saddr ?: @"");
        if (!fromCurrent) [places addObject:LSPlaceFromText(saddr, hintLat, hintLon)];
        for (NSString *text in LSSplitLegacyDestinations(daddr)) [places addObject:LSPlaceFromText(text, hintLat, hintLon)];
        return [LSMapLink linkWithApp:LSMapAppApple places:places directions:YES fromCurrent:fromCurrent mode:mode];
    }
    NSString *ll = LSQueryValue(items, @"ll");
    double lat, lon;
    if (ll && LSLinkCoordinatePair(ll, &lat, &lon, NULL)) {
        return [LSMapLink linkWithApp:LSMapAppApple places:@[ [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:LSQueryValue(items, @"q") ?: LSQueryValue(items, @"address")] ]
                           directions:NO fromCurrent:NO mode:nil];
    }
    NSString *text = LSQueryValue(items, @"address") ?: LSQueryValue(items, @"q");
    LSMapLinkPlace *place = text ? LSPlaceFromText(text, hintLat, hintLon) : nil;
    return place ? [LSMapLink linkWithApp:LSMapAppApple places:@[ place ] directions:NO fromCurrent:NO mode:nil] : nil;
}

static LSMapLink *LSParseWaze(NSURL *url) {
    NSArray *items = LSQueryItems(url);
    NSArray<NSString *> *path = LSRawPathComponents(url);
    BOOL navigate = [LSQueryValue(items, @"navigate").lowercaseString isEqualToString:@"yes"];
    // waze.com/ul/h<geohash>
    if (path.count >= 2 && [[path objectAtIndex:0] isEqualToString:@"ul"] && [[path objectAtIndex:1] hasPrefix:@"h"] && [[path objectAtIndex:1] length] > 4) {
        double lon = NAN;
        double lat = LSGeohashDecode([[path objectAtIndex:1] substringFromIndex:1], &lon);
        if (LSValidCoordinate(lat, lon)) {
            return [LSMapLink linkWithApp:LSMapAppWaze places:@[ [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:nil] ] directions:navigate fromCurrent:YES mode:@"driving"];
        }
    }
    // live-map/directions?from=ll.lat,lon&to=ll.lat,lon
    NSString *to = LSQueryValue(items, @"to");
    if (to) {
        NSMutableArray *places = [NSMutableArray array];
        NSString *from = LSQueryValue(items, @"from");
        if ([from hasPrefix:@"ll."]) {
            LSMapLinkPlace *origin = LSPlaceFromText([from substringFromIndex:3], NAN, NAN);
            if (origin.hasCoordinate) [places addObject:origin];
        }
        BOOL fromCurrent = places.count == 0;
        if (![to hasPrefix:@"ll."]) return nil;
        LSMapLinkPlace *destination = LSPlaceFromText([to substringFromIndex:3], NAN, NAN);
        if (!destination.hasCoordinate) return nil;
        [places addObject:destination];
        return [LSMapLink linkWithApp:LSMapAppWaze places:places directions:YES fromCurrent:fromCurrent mode:@"driving"];
    }
    NSString *ll = LSQueryValue(items, @"ll") ?: LSQueryValue(items, @"latlng");
    double lat, lon;
    if (ll && LSLinkCoordinatePair(ll, &lat, &lon, NULL)) {
        return [LSMapLink linkWithApp:LSMapAppWaze places:@[ [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:LSQueryValue(items, @"q")] ]
                           directions:navigate fromCurrent:YES mode:@"driving"];
    }
    NSString *q = LSQueryValue(items, @"q");
    LSMapLinkPlace *place = q ? LSPlaceFromText(q, NAN, NAN) : nil;
    return place ? [LSMapLink linkWithApp:LSMapAppWaze places:@[ place ] directions:navigate fromCurrent:YES mode:@"driving"] : nil;
}

// geo:lat,lon?q=lat,lon(Label)  or  geo:0,0?q=address
static LSMapLink *LSParseGeo(NSString *text) {
    NSString *body = [text substringFromIndex:4];
    if ([body hasPrefix:@"//"]) body = [body substringFromIndex:2];
    NSRange question = [body rangeOfString:@"?"];
    NSString *coordinatePart = question.location == NSNotFound ? body : [body substringToIndex:question.location];
    NSRange semicolon = [coordinatePart rangeOfString:@";"];
    if (semicolon.location != NSNotFound) coordinatePart = [coordinatePart substringToIndex:semicolon.location];
    NSArray *items = question.location == NSNotFound ? @[] : LSQueryItems([NSURL URLWithString:[@"x://y/?" stringByAppendingString:[body substringFromIndex:question.location + 1]]]);
    double lat = NAN, lon = NAN;
    BOOL hasCoordinate = LSLinkCoordinatePair(LSDecodeComponent(coordinatePart), &lat, &lon, NULL);
    NSString *q = LSQueryValue(items, @"q");
    if (hasCoordinate && lat == 0.0 && lon == 0.0 && q) hasCoordinate = NO;
    if (q) {
        LSMapLinkPlace *place = LSPlaceFromText(q, hasCoordinate ? lat : NAN, hasCoordinate ? lon : NAN);
        if (place) return [LSMapLink linkWithApp:LSMapAppApple places:@[ place ] directions:NO fromCurrent:NO mode:nil];
    }
    if (!hasCoordinate) return nil;
    return [LSMapLink linkWithApp:LSMapAppApple places:@[ [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:nil] ] directions:NO fromCurrent:NO mode:nil];
}

// App links (comgooglemaps://?..., maps://?..., waze://?...) as their web equivalents, which
// every NSURL implementation splits the same way.
static NSString *LSWebLinkString(NSString *text) {
    NSString *lower = text.lowercaseString;
    NSArray<NSArray<NSString *> *> *rewrites = @[ @[ @"comgooglemapsurl://", @"https://" ],
                                                 @[ @"comgooglemaps://", @"https://maps.google.com/" ],
                                                 @[ @"googlemaps://", @"https://maps.google.com/" ],
                                                 @[ @"maps://", @"https://maps.apple.com/" ],
                                                 @[ @"waze://", @"https://waze.com/ul" ] ];
    for (NSArray<NSString *> *rewrite in rewrites) {
        NSString *prefix = [rewrite objectAtIndex:0];
        if ([lower hasPrefix:prefix]) {
            NSString *rest = [text substringFromIndex:prefix.length];
            NSString *base = [rewrite objectAtIndex:1];
            if ([base hasSuffix:@"/"] && [rest hasPrefix:@"/"]) rest = [rest substringFromIndex:1];
            if ([base hasSuffix:@"/ul"] && rest.length && ![rest hasPrefix:@"?"] && ![rest hasPrefix:@"/"]) rest = [@"/" stringByAppendingString:rest];
            return [base stringByAppendingString:rest];
        }
    }
    return text;
}

static NSURL *LSURLFromLinkString(NSString *text) {
    NSString *web = LSWebLinkString(LSTrim(text));
    NSURL *url = [NSURL URLWithString:web];
    if (!url) {
        // Pasted links can hold characters such as '|' that NSURL refuses.
        NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
        [allowed addCharactersInString:@"%#"];
        url = [NSURL URLWithString:[web stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
    }
    return url;
}

typedef NS_ENUM(NSInteger, LSLinkKind) { LSLinkNone, LSLinkGoogle, LSLinkApple, LSLinkWaze, LSLinkGeo };

static LSLinkKind LSKindOfURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString ?: @"";
    if ([scheme isEqualToString:@"geo"]) return LSLinkGeo;
    if ([scheme isEqualToString:@"comgooglemaps"] || [scheme isEqualToString:@"comgooglemapsurl"] || [scheme isEqualToString:@"googlemaps"]) return LSLinkGoogle;
    if ([scheme isEqualToString:@"maps"] || [scheme isEqualToString:@"map"]) return LSLinkApple;
    if ([scheme isEqualToString:@"waze"]) return LSLinkWaze;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return LSLinkNone;
    if ([host isEqualToString:@"maps.apple.com"] || [host isEqualToString:@"maps.apple"] || [host hasSuffix:@".maps.apple"] || [host isEqualToString:@"collections.apple.com"]) return LSLinkApple;
    if ([host isEqualToString:@"waze.com"] || [host hasSuffix:@".waze.com"]) return LSLinkWaze;
    if ([host isEqualToString:@"maps.app.goo.gl"] || ([host isEqualToString:@"goo.gl"] && [url.path hasPrefix:@"/maps"])) return LSLinkGoogle;
    NSArray<NSString *> *labels = [host componentsSeparatedByString:@"."];
    NSUInteger google = [labels indexOfObject:@"google"];
    if (google != NSNotFound && google + 1 < labels.count) {
        if ([labels.firstObject isEqualToString:@"maps"] || [url.path hasPrefix:@"/maps"]) return LSLinkGoogle;
    }
    return LSLinkNone;
}

#ifndef GNUSTEP
// Stops at the first redirect that already names a place, such as maps.google.com/?q=…,
// so the full map page behind it (or a consent page in the EU) is never loaded.
@interface LSLinkRedirectStopper : NSObject <NSURLSessionTaskDelegate>
@property (atomic, strong) NSURL *stoppedAt;
@end

@implementation LSLinkRedirectStopper
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if ([LSMapLinks resolvedLinkNamesPlace:request.URL]) {
        self.stoppedAt = request.URL;
        completionHandler(nil);
        return;
    }
    completionHandler(request);
}
@end
#endif

#pragma mark - Public

@implementation LSMapLinks

+ (BOOL)isMapLink:(NSURL *)url {
    return url && LSKindOfURL(url) != LSLinkNone;
}

+ (BOOL)needsResolving:(NSURL *)url {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"maps.app.goo.gl"] || [host isEqualToString:@"goo.gl"]) return YES;
    if ([host isEqualToString:@"maps.apple"] || [host hasSuffix:@".maps.apple"]) return YES;
    if ([host isEqualToString:@"maps.apple.com"] && [url.path hasPrefix:@"/p/"]) return YES;
    return NO;
}

+ (NSURL *)firstMapLinkInText:(NSString *)text {
    if (!text.length) return nil;
    if (text.length > 20000) text = [text substringToIndex:20000];
    NSCharacterSet *stops = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\"'<>`"];
    NSArray<NSString *> *prefixes = @[ @"https://", @"http://", @"comgooglemaps://", @"comgooglemapsurl://", @"maps://", @"waze://", @"geo:" ];
    NSString *lower = text.lowercaseString;
    NSUInteger index = 0;
    while (index < lower.length) {
        NSUInteger best = NSNotFound;
        for (NSString *prefix in prefixes) {
            NSRange found = [lower rangeOfString:prefix options:0 range:NSMakeRange(index, lower.length - index)];
            if (found.location != NSNotFound && found.location < best) best = found.location;
        }
        if (best == NSNotFound) break;
        NSRange end = [text rangeOfCharacterFromSet:stops options:0 range:NSMakeRange(best, text.length - best)];
        NSUInteger stop = end.location == NSNotFound ? text.length : end.location;
        NSString *candidate = [text substringWithRange:NSMakeRange(best, stop - best)];
        // Sentence punctuation after a link is not part of it.
        while (candidate.length && [@".,;:!?)]}" rangeOfString:[candidate substringFromIndex:candidate.length - 1]].location != NSNotFound) {
            candidate = [candidate substringToIndex:candidate.length - 1];
        }
        NSURL *url = LSURLFromLinkString(candidate);
        if (url && [self isMapLink:url]) return url;
        index = stop > best ? stop : best + 1;
    }
    return nil;
}

+ (LSMapLink *)parseString:(NSString *)text {
    return text.length ? [self parseURL:LSURLFromLinkString(text)] : nil;
}

+ (LSMapLink *)parseURL:(NSURL *)url {
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"comgooglemaps"] || [scheme isEqualToString:@"comgooglemapsurl"] || [scheme isEqualToString:@"googlemaps"] ||
        [scheme isEqualToString:@"maps"] || [scheme isEqualToString:@"waze"]) {
        NSURL *web = [NSURL URLWithString:LSWebLinkString(url.absoluteString)];
        return web && ![web.scheme.lowercaseString isEqualToString:scheme] ? [self parseURL:web] : nil;
    }
    // In the EU a resolved Google link can land on the cookie consent page first.
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"consent.google."] || [host hasPrefix:@"consent.youtube."]) {
        NSString *next = LSQueryValue(LSQueryItems(url), @"continue");
        NSURL *inner = next ? [NSURL URLWithString:next] : nil;
        return inner && ![inner.host.lowercaseString hasPrefix:@"consent."] ? [self parseURL:inner] : nil;
    }
    switch (LSKindOfURL(url)) {
        case LSLinkGoogle: return LSParseGoogle(url);
        case LSLinkApple: return LSParseApple(url);
        case LSLinkWaze: return LSParseWaze(url);
        case LSLinkGeo: return LSParseGeo(url.absoluteString);
        case LSLinkNone: return nil;
    }
    return nil;
}

+ (NSUInteger)maximumPlacesForApp:(LSMapApp)app legacyApple:(BOOL)legacyApple {
    switch (app) {
        case LSMapAppGoogle: return 11; // origin, 9 waypoints, destination
        case LSMapAppWaze: return 1;
        case LSMapAppApple: return legacyApple ? 2 : kLSMapLinkMaximumPlaces;
    }
    return 2;
}

static NSString *LSPlaceParameter(LSMapLinkPlace *place) {
    if (place.hasCoordinate) return [NSString stringWithFormat:@"%@,%@", LSFormatCoordinate(place.latitude), LSFormatCoordinate(place.longitude)];
    return LSEncode(place.query ?: @"");
}

+ (NSURL *)URLForApp:(LSMapApp)app places:(NSArray<LSMapLinkPlace *> *)places mode:(NSString *)mode legacyApple:(BOOL)legacyApple {
    NSMutableArray<LSMapLinkPlace *> *usable = [NSMutableArray array];
    for (LSMapLinkPlace *place in places) {
        if (place.hasCoordinate || place.query.length) [usable addObject:place];
    }
    if (!usable.count) return nil;
    NSUInteger limit = [self maximumPlacesForApp:app legacyApple:legacyApple];
    if (usable.count > limit) {
        // Keep the origin and destination; drop stops from the end.
        LSMapLinkPlace *destination = usable.lastObject;
        [usable removeObjectsInRange:NSMakeRange(limit - 1, usable.count - limit + 1)];
        if (limit == 1) [usable removeAllObjects];
        [usable addObject:destination];
    }
    LSMapLinkPlace *destination = usable.lastObject;
    NSMutableString *link = [NSMutableString string];
    switch (app) {
        case LSMapAppGoogle: {
            if (usable.count == 1) {
                [link appendFormat:@"https://www.google.com/maps/search/?api=1&query=%@", LSPlaceParameter(destination)];
                break;
            }
            NSString *travel = [mode isEqualToString:@"walking"] ? @"walking" : [mode isEqualToString:@"cycling"] ? @"bicycling" :
                               [mode isEqualToString:@"transit"] ? @"transit" : @"driving";
            [link appendFormat:@"https://www.google.com/maps/dir/?api=1&origin=%@&destination=%@", LSPlaceParameter(usable.firstObject), LSPlaceParameter(destination)];
            if (usable.count > 2) {
                NSMutableArray *stops = [NSMutableArray array];
                for (NSUInteger i = 1; i + 1 < usable.count; i++) [stops addObject:LSPlaceParameter([usable objectAtIndex:i])];
                [link appendFormat:@"&waypoints=%@", [stops componentsJoinedByString:@"%7C"]];
            }
            [link appendFormat:@"&travelmode=%@", travel];
            break;
        }
        case LSMapAppWaze: {
            if (destination.hasCoordinate) [link appendFormat:@"https://www.waze.com/ul?ll=%@&navigate=yes", LSPlaceParameter(destination)];
            else [link appendFormat:@"https://www.waze.com/ul?q=%@&navigate=yes", LSPlaceParameter(destination)];
            break;
        }
        case LSMapAppApple: {
            if (legacyApple) {
                NSString *flag = [mode isEqualToString:@"walking"] ? @"w" : [mode isEqualToString:@"transit"] ? @"r" : @"d";
                if (usable.count == 1) {
                    if (destination.hasCoordinate) {
                        [link appendFormat:@"https://maps.apple.com/?ll=%@", LSPlaceParameter(destination)];
                        if (destination.name.length) [link appendFormat:@"&q=%@", LSEncode(destination.name)];
                    } else {
                        [link appendFormat:@"https://maps.apple.com/?q=%@", LSPlaceParameter(destination)];
                    }
                } else {
                    [link appendFormat:@"https://maps.apple.com/?saddr=%@&daddr=%@&dirflg=%@", LSPlaceParameter(usable.firstObject), LSPlaceParameter(destination), flag];
                }
                break;
            }
            if (usable.count == 1) {
                if (destination.hasCoordinate) {
                    [link appendFormat:@"https://maps.apple.com/place?coordinate=%@", LSPlaceParameter(destination)];
                    if (destination.name.length) [link appendFormat:@"&name=%@", LSEncode(destination.name)];
                } else {
                    [link appendFormat:@"https://maps.apple.com/search?query=%@", LSPlaceParameter(destination)];
                }
                break;
            }
            NSString *appleMode = [mode isEqualToString:@"walking"] ? @"walking" : [mode isEqualToString:@"cycling"] ? @"cycling" :
                                  [mode isEqualToString:@"transit"] ? @"transit" : @"driving";
            [link appendFormat:@"https://maps.apple.com/directions?source=%@", LSPlaceParameter(usable.firstObject)];
            for (NSUInteger i = 1; i + 1 < usable.count; i++) [link appendFormat:@"&waypoint=%@", LSPlaceParameter([usable objectAtIndex:i])];
            [link appendFormat:@"&destination=%@&mode=%@", LSPlaceParameter(destination), appleMode];
            break;
        }
    }
    return [NSURL URLWithString:link];
}

static NSString *LSMetaContent(NSString *html, NSString *property) {
    NSString *lower = html.lowercaseString;
    NSArray<NSString *> *needles = @[ [NSString stringWithFormat:@"property=\"%@\"", property], [NSString stringWithFormat:@"name=\"%@\"", property] ];
    for (NSString *needle in needles) {
        NSRange found = [lower rangeOfString:needle];
        if (found.location == NSNotFound) continue;
        // The content attribute can come before or after; look inside this tag only.
        NSRange tagStart = [lower rangeOfString:@"<" options:NSBackwardsSearch range:NSMakeRange(0, found.location)];
        NSRange tagEnd = [lower rangeOfString:@">" options:0 range:NSMakeRange(found.location, lower.length - found.location)];
        if (tagStart.location == NSNotFound || tagEnd.location == NSNotFound) continue;
        NSRange tag = NSMakeRange(tagStart.location, tagEnd.location - tagStart.location);
        NSRange content = [lower rangeOfString:@"content=\"" options:0 range:tag];
        if (content.location == NSNotFound) continue;
        NSUInteger start = NSMaxRange(content);
        NSRange quote = [lower rangeOfString:@"\"" options:0 range:NSMakeRange(start, NSMaxRange(tag) - start)];
        if (quote.location == NSNotFound) continue;
        return [html substringWithRange:NSMakeRange(start, quote.location - start)];
    }
    return nil;
}

static NSString *LSUnescapeHTML(NSString *text) {
    NSString *value = text;
    NSDictionary *entities = @{ @"&amp;": @"&", @"&quot;": @"\"", @"&#39;": @"'", @"&apos;": @"'", @"&lt;": @"<", @"&gt;": @">" };
    for (NSString *entity in entities) value = [value stringByReplacingOccurrencesOfString:entity withString:[entities objectForKey:entity]];
    return value;
}

+ (LSMapLinkPlace *)placeFromHTML:(NSString *)html {
    if (!html.length) return nil;
    if (html.length > kLSMapLinkMaximumHTML) html = [html substringToIndex:kLSMapLinkMaximumHTML];
    NSString *name = LSMetaContent(html, @"og:title");
    name = name ? LSUnescapeHTML(name) : nil;
    for (NSArray<NSString *> *keys in @[ @[ @"place:location:latitude", @"place:location:longitude" ],
                                         @[ @"og:latitude", @"og:longitude" ],
                                         @[ @"latitude", @"longitude" ] ]) {
        NSString *latText = LSMetaContent(html, [keys objectAtIndex:0]);
        NSString *lonText = LSMetaContent(html, [keys objectAtIndex:1]);
        if (!latText || !lonText) continue;
        double lat = NAN, lon = NAN;
        if (LSLinkCoordinatePair([NSString stringWithFormat:@"%@,%@", latText, lonText], &lat, &lon, NULL)) {
            return [LSMapLinkPlace placeWithLatitude:lat longitude:lon name:name];
        }
    }
    return nil;
}

+ (BOOL)resolvedLinkNamesPlace:(NSURL *)url {
    return url && ![self needsResolving:url] && [self parseURL:url].places.count > 0;
}

#ifndef GNUSTEP
+ (void)resolveURL:(NSURL *)url completion:(void (^)(NSURL *, NSString *))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
    request.HTTPMethod = @"GET";
    // No browser User-Agent: maps.app.goo.gl answers a desktop Safari agent with a script
    // page that has no redirect and no place in it (#20), and the plain redirect otherwise.
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCache = nil;
    LSLinkRedirectStopper *stopper = [[LSLinkRedirectStopper alloc] init];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:stopper delegateQueue:nil];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSURL *resolved = stopper.stoppedAt;
        NSString *html = nil;
        if (!resolved) {
            resolved = error ? nil : response.URL;
            NSString *type = [response isKindOfClass:NSHTTPURLResponse.class] ? [((NSHTTPURLResponse *)response).allHeaderFields objectForKey:@"Content-Type"] : nil;
            if (data.length && data.length <= kLSMapLinkMaximumHTML && [type.lowercaseString containsString:@"html"]) {
                html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
        }
        [session finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(resolved, html); });
    }] resume];
}
#endif

@end
