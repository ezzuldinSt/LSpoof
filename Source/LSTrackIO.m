#import "LSTrackIO.h"
#include <math.h>
#include <stdlib.h>

static const NSUInteger kLSTrackMaximumBytes = 64 * 1024 * 1024;
static const NSUInteger kLSTrackMaximumPoints = 400000;

// strtod with the whole (trimmed) text consumed, so "bad" or "" is NAN rather than 0.
static double LSNumber(NSString *text) {
    const char *utf8 = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].UTF8String;
    if (!utf8 || !*utf8) return NAN;
    char *end = NULL;
    double value = strtod(utf8, &end);
    return end && *end == '\0' && isfinite(value) ? value : NAN;
}

static LSTrackPoint LSEmptyPoint(void) {
    LSTrackPoint point = { NAN, NAN, NAN, NAN, NAN, NAN };
    return point;
}

static BOOL LSPointHasPosition(const LSTrackPoint *point) {
    return isfinite(point->latitude) && isfinite(point->longitude) &&
           fabs(point->latitude) <= 90.0 && fabs(point->longitude) <= 180.0 &&
           !(point->latitude == 0.0 && point->longitude == 0.0);
}

// Maps the activity words used by GPX <type>, TCX Sport and app exports to our modes.
static NSString *LSActivityFromText(NSString *text) {
    NSString *value = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!value.length) return nil;
    for (NSString *word in @[ @"walk", @"hik", @"run", @"jog", @"trail", @"foot" ]) {
        if ([value containsString:word]) return @"walking";
    }
    for (NSString *word in @[ @"bik", @"cycl", @"ride", @"bicycl" ]) {
        if ([value containsString:word]) return @"cycling";
    }
    for (NSString *word in @[ @"driv", @"car", @"motor", @"auto" ]) {
        if ([value containsString:word]) return @"driving";
    }
    return nil;
}

static int LSFitSportForActivity(NSString *activity) {
    if ([activity isEqualToString:@"walking"]) return LSFitSportWalking;
    if ([activity isEqualToString:@"cycling"]) return LSFitSportCycling;
    if ([activity isEqualToString:@"driving"]) return LSFitSportDriving;
    return LSFitSportGeneric;
}

static NSString *LSXMLEscape(NSString *text) {
    NSMutableString *escaped = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        switch (c) {
            case '&': [escaped appendString:@"&amp;"]; break;
            case '<': [escaped appendString:@"&lt;"]; break;
            case '>': [escaped appendString:@"&gt;"]; break;
            case '"': [escaped appendString:@"&quot;"]; break;
            case '\'': [escaped appendString:@"&apos;"]; break;
            default:
                // XML 1.0 allows tab, newline and carriage return below 0x20; the rest are dropped.
                if (c >= 0x20 || c == '\t' || c == '\n' || c == '\r') [escaped appendFormat:@"%C", c];
                break;
        }
    }
    return escaped;
}

static NSString *LSTimeString(double unixSeconds) {
    char buffer[40];
    double whole = floor(unixSeconds);
    int milliseconds = (int)llround((unixSeconds - whole) * 1000.0);
    if (milliseconds >= 1000) { whole += 1.0; milliseconds = 0; }
    LSFormatISO8601(whole, milliseconds, buffer, sizeof buffer);
    return [NSString stringWithUTF8String:buffer] ?: @"";
}

static NSString *LSNumberString(double value, int decimals) {
    NSString *text = [NSString stringWithFormat:@"%.*f", decimals, value];
    if ([text containsString:@"."]) {
        while ([text hasSuffix:@"0"]) text = [text substringToIndex:text.length - 1];
        if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    }
    if ([text isEqualToString:@"-0"]) text = @"0";
    return text;
}

#pragma mark - Track

@implementation LSTrack
@synthesize name = _name, pointData = _pointData, activity = _activity, format = _format;
- (NSUInteger)count { return self.pointData.length / sizeof(LSTrackPoint); }
- (const LSTrackPoint *)points { return self.pointData.bytes; }
- (BOOL)hasTimes {
    NSUInteger count = self.count;
    if (count < 2) return NO;
    const LSTrackPoint *points = self.points;
    for (NSUInteger i = 0; i < count; i++) {
        if (!isfinite(points[i].time)) return NO;
        if (i && points[i].time < points[i - 1].time) return NO;
    }
    return points[count - 1].time > points[0].time;
}
@end

#pragma mark - XML reader

// Reads GPX (tracks, then routes, then waypoints) and TCX (activities and courses).
// Namespace prefixes are ignored so files from Garmin, Strava and others all read the same.
@interface LSTrackXMLReader : NSObject <NSXMLParserDelegate> {
@public
    NSMutableData *_trackPoints;
    NSMutableData *_routePoints;
    NSMutableData *_waypointPoints;
    NSString *_activity;
    BOOL _sawGPX;
    BOOL _sawTCX;
    BOOL _tooMany;
@private
    NSMutableArray<NSString *> *_stack;
    NSMutableString *_text;
    LSTrackPoint _point;
    BOOL _inPoint;
    NSInteger _pointKind; // 0 track, 1 route, 2 waypoint
    NSString *_metadataName;
    NSString *_trackName;
    NSString *_routeName;
}
- (NSString *)name;
@end

@implementation LSTrackXMLReader

- (instancetype)init {
    if ((self = [super init])) {
        _stack = [NSMutableArray array];
        _text = [NSMutableString string];
        _trackPoints = [NSMutableData data];
        _routePoints = [NSMutableData data];
        _waypointPoints = [NSMutableData data];
    }
    return self;
}

static NSString *LSLocalName(NSString *name) {
    NSRange colon = [name rangeOfString:@":" options:NSBackwardsSearch];
    NSString *local = colon.location == NSNotFound ? name : [name substringFromIndex:colon.location + 1];
    return local.lowercaseString;
}

- (NSString *)parentName {
    return _stack.count >= 2 ? [_stack objectAtIndex:_stack.count - 2] : nil;
}

- (BOOL)stackContains:(NSString *)name {
    return [_stack containsObject:name];
}

- (void)beginPointOfKind:(NSInteger)kind attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    _point = LSEmptyPoint();
    _inPoint = YES;
    _pointKind = kind;
    for (NSString *key in attributes) {
        NSString *local = LSLocalName(key);
        if ([local isEqualToString:@"lat"]) _point.latitude = LSNumber([attributes objectForKey:key]);
        else if ([local isEqualToString:@"lon"]) _point.longitude = LSNumber([attributes objectForKey:key]);
    }
}

- (void)finishPoint {
    _inPoint = NO;
    if (!LSPointHasPosition(&_point)) return;
    NSMutableData *target = _pointKind == 0 ? _trackPoints : (_pointKind == 1 ? _routePoints : _waypointPoints);
    if (target.length / sizeof(LSTrackPoint) >= kLSTrackMaximumPoints) { _tooMany = YES; return; }
    [target appendBytes:&_point length:sizeof _point];
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    (void)parser; (void)namespaceURI; (void)qName;
    NSString *local = LSLocalName(elementName);
    [_stack addObject:local];
    [_text setString:@""];
    if ([local isEqualToString:@"gpx"]) _sawGPX = YES;
    else if ([local isEqualToString:@"trainingcenterdatabase"]) _sawTCX = YES;
    if ([local isEqualToString:@"trkpt"]) [self beginPointOfKind:0 attributes:attributeDict];
    else if ([local isEqualToString:@"rtept"]) [self beginPointOfKind:1 attributes:attributeDict];
    else if ([local isEqualToString:@"wpt"]) [self beginPointOfKind:2 attributes:attributeDict];
    else if ([local isEqualToString:@"trackpoint"]) [self beginPointOfKind:0 attributes:@{}];
    else if ([local isEqualToString:@"activity"] && _sawTCX && !_activity) {
        for (NSString *key in attributeDict) {
            if ([LSLocalName(key) isEqualToString:@"sport"]) _activity = LSActivityFromText([attributeDict objectForKey:key]);
        }
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    (void)parser;
    if (_text.length < 4096) [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock {
    (void)parser;
    NSString *string = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
    if (string && _text.length < 4096) [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    (void)parser; (void)namespaceURI; (void)qName;
    NSString *local = LSLocalName(elementName);
    NSString *text = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *parent = [self parentName];

    if (_inPoint) {
        if ([local isEqualToString:@"ele"] || [local isEqualToString:@"altitudemeters"]) {
            _point.altitude = LSNumber(text);
        } else if ([local isEqualToString:@"time"]) {
            _point.time = LSParseISO8601(text.UTF8String);
        } else if ([local isEqualToString:@"latitudedegrees"]) {
            _point.latitude = LSNumber(text);
        } else if ([local isEqualToString:@"longitudedegrees"]) {
            _point.longitude = LSNumber(text);
        } else if ([local isEqualToString:@"distancemeters"] && [parent isEqualToString:@"trackpoint"]) {
            _point.distance = LSNumber(text);
        } else if ([local isEqualToString:@"speed"]) {
            // TCX TPX Speed and Garmin GPX TrackPointExtension speed, both m/s.
            _point.speed = LSNumber(text);
        } else if ([local isEqualToString:@"trkpt"] || [local isEqualToString:@"rtept"] ||
                   [local isEqualToString:@"wpt"] || [local isEqualToString:@"trackpoint"]) {
            [self finishPoint];
        }
    } else if ([local isEqualToString:@"name"] && text.length) {
        if ([parent isEqualToString:@"metadata"] && !_metadataName) _metadataName = text;
        else if ([parent isEqualToString:@"trk"] && !_trackName) _trackName = text;
        else if ([parent isEqualToString:@"rte"] && !_routeName) _routeName = text;
        else if ([parent isEqualToString:@"course"] && !_trackName) _trackName = text;
    } else if ([local isEqualToString:@"type"] && ([parent isEqualToString:@"trk"] || [parent isEqualToString:@"rte"]) && !_activity) {
        _activity = LSActivityFromText(text);
    }
    if (_stack.count) [_stack removeLastObject];
    [_text setString:@""];
}

- (NSString *)name {
    return _trackName ?: _routeName ?: _metadataName;
}

@end

#pragma mark - IO

@implementation LSTrackIO

+ (LSTrack *)trackFromData:(NSData *)data fileName:(NSString *)fileName error:(NSString **)error {
    if (error) *error = nil;
    if (!data.length) {
        if (error) *error = @"The file is empty.";
        return nil;
    }
    if (data.length > kLSTrackMaximumBytes) {
        if (error) *error = @"The file is larger than 64 MB.";
        return nil;
    }
    NSString *baseName = [[fileName lastPathComponent] stringByDeletingPathExtension];

    if (LSFitLooksLikeFit(data.bytes, data.length)) {
        LSTrackPoint *points = NULL;
        size_t count = LSFitDecodeRecords(data.bytes, data.length, &points);
        if (count < 2) {
            free(points);
            if (error) *error = count == 1 ? @"The FIT file has only one position." : @"The FIT file has no positions, or it is damaged.";
            return nil;
        }
        if (count > kLSTrackMaximumPoints) count = kLSTrackMaximumPoints;
        LSTrack *track = [[LSTrack alloc] init];
        track.pointData = [NSData dataWithBytes:points length:count * sizeof(LSTrackPoint)];
        free(points);
        track.name = baseName.length ? baseName : @"FIT activity";
        track.format = @"FIT";
        return track;
    }

    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.shouldProcessNamespaces = NO;
    parser.shouldResolveExternalEntities = NO;
    LSTrackXMLReader *reader = [[LSTrackXMLReader alloc] init];
    parser.delegate = reader;
    BOOL parsed = [parser parse];
    if (!reader->_sawGPX && !reader->_sawTCX) {
        if (error) *error = @"This isn't a GPX, TCX or FIT file.";
        return nil;
    }
    NSData *chosen = reader->_trackPoints.length / sizeof(LSTrackPoint) >= 2 ? reader->_trackPoints
                   : reader->_routePoints.length / sizeof(LSTrackPoint) >= 2 ? reader->_routePoints
                   : reader->_waypointPoints;
    NSUInteger count = chosen.length / sizeof(LSTrackPoint);
    if (count < 2) {
        if (error) *error = parsed ? @"The file has fewer than two positions." : @"The file is damaged and has fewer than two readable positions.";
        return nil;
    }
    LSTrack *track = [[LSTrack alloc] init];
    track.pointData = chosen;
    track.name = [reader name].length ? [reader name] : (baseName.length ? baseName : (reader->_sawTCX ? @"TCX track" : @"GPX track"));
    track.activity = reader->_activity;
    track.format = reader->_sawTCX ? @"TCX" : @"GPX";
    return track;
}

+ (NSData *)GPXDataForPoints:(const LSTrackPoint *)points count:(NSUInteger)count name:(NSString *)name activity:(NSString *)activity {
    NSMutableString *xml = [NSMutableString stringWithCapacity:count * 120 + 512];
    NSString *escapedName = LSXMLEscape(name.length ? name : @"LSpoof route");
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<gpx version=\"1.1\" creator=\"LSpoof\" xmlns=\"http://www.topografix.com/GPX/1/1\" "
                      @"xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
                      @"xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"];
    [xml appendFormat:@"  <metadata>\n    <name>%@</name>\n", escapedName];
    if (count && isfinite(points[0].time)) [xml appendFormat:@"    <time>%@</time>\n", LSTimeString(points[0].time)];
    [xml appendString:@"  </metadata>\n  <trk>\n"];
    [xml appendFormat:@"    <name>%@</name>\n", escapedName];
    if (activity.length) [xml appendFormat:@"    <type>%@</type>\n", LSXMLEscape(activity)];
    [xml appendString:@"    <trkseg>\n"];
    for (NSUInteger i = 0; i < count; i++) {
        const LSTrackPoint *p = &points[i];
        if (!LSPointHasPosition(p)) continue;
        [xml appendFormat:@"      <trkpt lat=\"%@\" lon=\"%@\">", LSNumberString(p->latitude, 7), LSNumberString(p->longitude, 7)];
        if (isfinite(p->altitude)) [xml appendFormat:@"<ele>%@</ele>", LSNumberString(p->altitude, 1)];
        if (isfinite(p->time)) [xml appendFormat:@"<time>%@</time>", LSTimeString(p->time)];
        [xml appendString:@"</trkpt>\n"];
    }
    [xml appendString:@"    </trkseg>\n  </trk>\n</gpx>\n"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

+ (NSData *)TCXDataForPoints:(const LSTrackPoint *)points count:(NSUInteger)count name:(NSString *)name activity:(NSString *)activity {
    // TCX knows Running, Biking and Other. Times are required, so untimed points are skipped.
    NSString *sport = [activity isEqualToString:@"cycling"] ? @"Biking" : ([activity isEqualToString:@"walking"] ? @"Running" : @"Other");
    double start = NAN, end = NAN, totalDistance = 0.0, maxSpeed = 0.0;
    for (NSUInteger i = 0; i < count; i++) {
        if (!isfinite(points[i].time) || !LSPointHasPosition(&points[i])) continue;
        if (!isfinite(start)) start = points[i].time;
        end = points[i].time;
        if (isfinite(points[i].distance)) totalDistance = fmax(totalDistance, points[i].distance);
        if (isfinite(points[i].speed)) maxSpeed = fmax(maxSpeed, points[i].speed);
    }
    if (!isfinite(start)) start = 0.0, end = 0.0;
    NSMutableString *xml = [NSMutableString stringWithCapacity:count * 260 + 1024];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\" "
                      @"xmlns:ns3=\"http://www.garmin.com/xmlschemas/ActivityExtension/v2\" "
                      @"xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
                      @"xsi:schemaLocation=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd\">\n"];
    [xml appendFormat:@"  <Activities>\n    <Activity Sport=\"%@\">\n", sport];
    [xml appendFormat:@"      <Id>%@</Id>\n", LSTimeString(start)];
    [xml appendFormat:@"      <Lap StartTime=\"%@\">\n", LSTimeString(start)];
    [xml appendFormat:@"        <TotalTimeSeconds>%@</TotalTimeSeconds>\n", LSNumberString(end - start, 1)];
    [xml appendFormat:@"        <DistanceMeters>%@</DistanceMeters>\n", LSNumberString(totalDistance, 1)];
    [xml appendFormat:@"        <MaximumSpeed>%@</MaximumSpeed>\n", LSNumberString(maxSpeed, 2)];
    [xml appendString:@"        <Calories>0</Calories>\n        <Intensity>Active</Intensity>\n        <TriggerMethod>Manual</TriggerMethod>\n        <Track>\n"];
    for (NSUInteger i = 0; i < count; i++) {
        const LSTrackPoint *p = &points[i];
        if (!isfinite(p->time) || !LSPointHasPosition(p)) continue;
        [xml appendString:@"          <Trackpoint>\n"];
        [xml appendFormat:@"            <Time>%@</Time>\n", LSTimeString(p->time)];
        [xml appendFormat:@"            <Position><LatitudeDegrees>%@</LatitudeDegrees><LongitudeDegrees>%@</LongitudeDegrees></Position>\n",
                          LSNumberString(p->latitude, 7), LSNumberString(p->longitude, 7)];
        if (isfinite(p->altitude)) [xml appendFormat:@"            <AltitudeMeters>%@</AltitudeMeters>\n", LSNumberString(p->altitude, 1)];
        if (isfinite(p->distance)) [xml appendFormat:@"            <DistanceMeters>%@</DistanceMeters>\n", LSNumberString(p->distance, 1)];
        if (isfinite(p->speed)) [xml appendFormat:@"            <Extensions><ns3:TPX><ns3:Speed>%@</ns3:Speed></ns3:TPX></Extensions>\n", LSNumberString(p->speed, 2)];
        [xml appendString:@"          </Trackpoint>\n"];
    }
    [xml appendString:@"        </Track>\n      </Lap>\n"];
    [xml appendFormat:@"      <Notes>%@</Notes>\n", LSXMLEscape(name.length ? name : @"LSpoof route")];
    [xml appendString:@"    </Activity>\n  </Activities>\n</TrainingCenterDatabase>\n"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

+ (NSData *)FITDataForPoints:(const LSTrackPoint *)points count:(NSUInteger)count activity:(NSString *)activity {
    uint8_t *bytes = NULL;
    size_t length = LSFitEncodeActivity(points, count, LSFitSportForActivity(activity), &bytes);
    if (!length || !bytes) {
        free(bytes);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}

+ (NSString *)safeFileName:(NSString *)name extension:(NSString *)extension {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r\t"];
    NSString *cleaned = [[[name ?: @"" componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@" "]
                         stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
    while ([cleaned containsString:@"  "]) cleaned = [cleaned stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    if (cleaned.length > 80) cleaned = [cleaned substringToIndex:80];
    if (!cleaned.length) cleaned = @"LSpoof route";
    return [cleaned stringByAppendingPathExtension:extension];
}

@end
