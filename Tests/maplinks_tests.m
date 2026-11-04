// Host tests for Apple Maps, Google Maps and Waze links. Build with Tests/run.sh.
#import <Foundation/Foundation.h>
#import "../Source/LSMapLinks.h"
#include <math.h>

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static LSMapLink *P(NSString *text) { return [LSMapLinks parseString:text]; }

static BOOL At(LSMapLinkPlace *place, double lat, double lon) {
    return place.hasCoordinate && fabs(place.latitude - lat) < 1e-6 && fabs(place.longitude - lon) < 1e-6;
}

static BOOL Query(LSMapLinkPlace *place, NSString *query) {
    return !place.hasCoordinate && [place.query isEqualToString:query];
}

static LSMapLinkPlace *Place(LSMapLink *link, NSUInteger i) {
    return i < link.places.count ? [link.places objectAtIndex:i] : nil;
}

static void TestGoogle(void) {
    LSMapLink *link = P(@"https://www.google.com/maps/dir/?api=1&origin=Space+Needle+Seattle+WA&destination=Pike+Place+Market+Seattle+WA"
                        @"&travelmode=bicycling&waypoints=47.62,-122.35%7CMuseum+of+Pop+Culture");
    CHECK(link.isDirections && !link.startsAtCurrentLocation && link.places.count == 4, "api=1 directions with stops (%lu)", (unsigned long)link.places.count);
    CHECK(Query(Place(link, 0), @"Space Needle Seattle WA") && At(Place(link, 1), 47.62, -122.35) &&
          Query(Place(link, 2), @"Museum of Pop Culture") && Query(Place(link, 3), @"Pike Place Market Seattle WA"), "api=1 places in order");
    CHECK([link.mode isEqualToString:@"cycling"] && link.app == LSMapAppGoogle, "bicycling is cycling");

    link = P(@"https://www.google.com/maps/dir/Googleplex,+Amphitheatre+Parkway,+Mountain+View,+CA/Computer+History+Museum,+1401+N+Shoreline+Blvd/"
             @"@37.4190,-122.0800,15z/data=!3m1!4b1!4m14!4m13!1m5!1m1!1s0x808fba02425dad8f:0x6c296c66619367e0!2m2!1d-122.0840575!2d37.4219999"
             @"!1m5!1m1!1s0x808fb7c8e2e1e3b1:0x1a0c4c4a3e0a0!2m2!1d-122.0773!2d37.4143!3e2");
    CHECK(link.places.count == 2 && At(Place(link, 0), 37.4219999, -122.0840575) && At(Place(link, 1), 37.4143, -122.0773),
          "app directions take coordinates from the data blob");
    CHECK([Place(link, 0).name isEqualToString:@"Googleplex, Amphitheatre Parkway, Mountain View, CA"], "app directions keep names: %s", Place(link, 0).name.UTF8String);
    CHECK([link.mode isEqualToString:@"walking"] && !link.startsAtCurrentLocation, "!3e2 is walking");

    link = P(@"https://www.google.com/maps/dir//Eiffel+Tower/@48.85,2.29,15z/data=!4m8!4m7!1m0!1m5!1m1!1s0x0:0x0!2m2!1d2.2944813!2d48.8583701");
    CHECK(link.startsAtCurrentLocation && link.places.count == 1 && At(Place(link, 0), 48.8583701, 2.2944813), "empty origin is your location");

    link = P(@"https://www.google.com/maps/dir/40.7,-74.0/Central+Park/@40.75,-73.98,13z/data=!4m9!4m8!1m1!4e1!1m5!1m1!1s0x0:0x0!2m2!1d-73.9654!2d40.7829");
    CHECK(link.places.count == 2 && At(Place(link, 0), 40.7, -74.0) && At(Place(link, 1), 40.7829, -73.9654), "coordinate origin plus text destination");

    link = P(@"https://www.google.com/maps/place/Eiffel+Tower/@48.8583701,2.2919064,17z/data=!3m1!4b1!4m6!3m5!1s0x47e66e2964e34e2d:0x8ddca9ee380ef7e0!8m2!3d48.8583701!4d2.2944813!16zL20vMDJqODE");
    CHECK(!link.isDirections && At(Place(link, 0), 48.8583701, 2.2944813) && [Place(link, 0).name isEqualToString:@"Eiffel Tower"], "place pin from !3d!4d, not the view");

    link = P(@"https://www.google.com/maps/place/37%C2%B025'19.6%22N+122%C2%B005'02.4%22W/@37.4221,-122.0843,17z");
    CHECK(At(Place(link, 0), 37.0 + 25.0 / 60 + 19.6 / 3600, -(122.0 + 5.0 / 60 + 2.4 / 3600)), "dropped pin name in degrees, minutes, seconds");

    link = P(@"https://www.google.com/maps/place/Louvre/@48.86,2.33,15z");
    CHECK(Query(Place(link, 0), @"Louvre") && Place(link, 0).hasHint && fabs(Place(link, 0).hintLatitude - 48.86) < 1e-9, "place without pin is looked up near the view");

    CHECK(At(Place(P(@"https://www.google.com/maps/@40.7128,-74.006,14z"), 0), 40.7128, -74.006), "bare map view");
    CHECK(At(Place(P(@"https://maps.google.com/?q=40.7,-74.0"), 0), 40.7, -74.0), "legacy q coordinate");
    link = P(@"https://www.google.com/maps?q=Statue+of+Liberty&ll=40.68,-74.04");
    CHECK(Query(Place(link, 0), @"Statue of Liberty") && fabs(Place(link, 0).hintLongitude + 74.04) < 1e-9, "q with ll hint");
    CHECK(At(Place(P(@"https://www.google.com/maps?q=loc:12.5,-7.25"), 0), 12.5, -7.25), "loc: prefix");

    link = P(@"https://maps.google.com/maps?saddr=40.7,-74.0&daddr=Boston+to:Providence&dirflg=w");
    CHECK(link.places.count == 3 && At(Place(link, 0), 40.7, -74.0) && Query(Place(link, 1), @"Boston") && Query(Place(link, 2), @"Providence"), "legacy saddr/daddr with to:");
    CHECK([link.mode isEqualToString:@"walking"], "dirflg w");

    CHECK(At(Place(P(@"https://www.google.co.uk/maps/search/51.5007,+-0.1246"), 0), 51.5007, -0.1246), "country domain search path");
    CHECK(Query(Place(P(@"https://www.google.com/maps/search/?api=1&query=Big%20Ben"), 0), @"Big Ben"), "api=1 search");

    link = P(@"comgooglemaps://?saddr=&daddr=37.77,-122.41&directionsmode=transit");
    CHECK(link.startsAtCurrentLocation && At(Place(link, 0), 37.77, -122.41) && [link.mode isEqualToString:@"transit"], "comgooglemaps scheme");
    CHECK(At(Place(P(@"comgooglemapsurl://www.google.com/maps/@1,2,3z"), 0), 1, 2), "comgooglemapsurl wraps a web link");
    CHECK(At(Place(P(@"https://consent.google.com/m?continue=https://www.google.com/maps/@1.5,2.5,10z&gl=DE"), 0), 1.5, 2.5), "consent page continue link");
    CHECK(P(@"https://www.google.com/search?q=pizza") == nil, "web search is not a map link");
    CHECK(![LSMapLinks isMapLink:[NSURL URLWithString:@"https://www.google.com/search?q=maps"]], "google search not a map link");
    CHECK(![LSMapLinks isMapLink:[NSURL URLWithString:@"https://evilgoogle.com/maps/@1,2,3z"]], "lookalike host refused");
}

static void TestApple(void) {
    LSMapLink *link = P(@"https://maps.apple.com/directions?source=37.33,-122.03&destination=San+Francisco&waypoint=37.5,-122.2&waypoint=Palo%20Alto&mode=cycling");
    CHECK(link.places.count == 4 && At(Place(link, 0), 37.33, -122.03) && At(Place(link, 1), 37.5, -122.2) &&
          Query(Place(link, 2), @"Palo Alto") && Query(Place(link, 3), @"San Francisco"), "unified directions with waypoints");
    CHECK([link.mode isEqualToString:@"cycling"] && link.app == LSMapAppApple, "unified mode");
    link = P(@"https://maps.apple.com/directions?destination=37.77,-122.41");
    CHECK(link.startsAtCurrentLocation && link.places.count == 1, "no source starts where you are");
    link = P(@"https://maps.apple.com/place?coordinate=35.6586,139.7454&name=Tokyo%20Tower");
    CHECK(At(Place(link, 0), 35.6586, 139.7454) && [Place(link, 0).name isEqualToString:@"Tokyo Tower"], "unified place");
    CHECK(Query(Place(P(@"https://maps.apple.com/place?address=1%20Infinite%20Loop,%20Cupertino"), 0), @"1 Infinite Loop, Cupertino"), "unified address");
    link = P(@"https://maps.apple.com/?ll=50.894967,4.341626&q=Atomium");
    CHECK(At(Place(link, 0), 50.894967, 4.341626) && [Place(link, 0).name isEqualToString:@"Atomium"], "legacy ll and q");
    link = P(@"https://maps.apple.com/?saddr=Cupertino&daddr=San+Francisco&dirflg=w");
    CHECK(link.places.count == 2 && [link.mode isEqualToString:@"walking"] && Query(Place(link, 0), @"Cupertino"), "legacy directions");
    link = P(@"maps://?daddr=1,2");
    CHECK(link.startsAtCurrentLocation && At(Place(link, 0), 1, 2), "maps scheme");
    CHECK(P(@"https://maps.apple.com/place?place-id=I1234") == nil, "place id alone needs the page");
    CHECK([LSMapLinks needsResolving:[NSURL URLWithString:@"https://maps.apple/p/7cKm2oGv0hH-5Z"]], "maps.apple short link");

    NSString *html = @"<html><head><meta property=\"og:title\" content=\"Tokyo Tower &amp; Park\">"
                     @"<meta property=\"place:location:latitude\" content=\"35.6586\" />"
                     @"<meta content=\"139.7454\" property=\"place:location:longitude\"></head></html>";
    LSMapLinkPlace *place = [LSMapLinks placeFromHTML:html];
    CHECK(At(place, 35.6586, 139.7454) && [place.name isEqualToString:@"Tokyo Tower & Park"], "place page meta tags");
    CHECK([LSMapLinks placeFromHTML:@"<html><meta property=\"place:location:latitude\" content=\"95\"></html>"] == nil, "bad page refused");
}

static void TestWazeAndGeo(void) {
    LSMapLink *link = P(@"https://waze.com/ul?ll=45.6906304,-120.810983&navigate=yes");
    CHECK(link.isDirections && link.startsAtCurrentLocation && At(Place(link, 0), 45.6906304, -120.810983) && link.app == LSMapAppWaze, "waze ul navigate");
    CHECK(!P(@"https://waze.com/ul?ll=45.69,-120.81").isDirections, "waze ul without navigate is a place");
    link = P(@"https://www.waze.com/ul/hdr5ru7v2");
    CHECK(At(Place(link, 0), 40.75798988342285, -73.98553848266602), "waze geohash link");
    link = P(@"https://www.waze.com/live-map/directions?from=ll.40.6,-73.9&to=ll.40.75,-73.98");
    CHECK(link.places.count == 2 && !link.startsAtCurrentLocation && At(Place(link, 1), 40.75, -73.98), "waze live map directions");
    CHECK(Query(Place(P(@"waze://?q=Times%20Square&navigate=yes"), 0), @"Times Square"), "waze scheme query");

    CHECK(At(Place(P(@"geo:37.786971,-122.399677"), 0), 37.786971, -122.399677), "geo coordinate");
    CHECK(Query(Place(P(@"geo:0,0?q=1600+Amphitheatre+Parkway"), 0), @"1600 Amphitheatre Parkway"), "geo query");
    link = P(@"geo:47.6,-122.3?q=47.61,-122.34(Pike+Place)");
    CHECK(At(Place(link, 0), 47.61, -122.34) && [Place(link, 0).name isEqualToString:@"Pike Place"], "geo labelled pin");
}

static void TestTextAndBuild(void) {
    NSURL *found = [LSMapLinks firstMapLinkInText:@"Check this out: Eiffel Tower\nhttps://maps.app.goo.gl/AbCdEf123?g_st=ic."];
    CHECK([found.absoluteString isEqualToString:@"https://maps.app.goo.gl/AbCdEf123?g_st=ic"] && [LSMapLinks needsResolving:found], "short link in shared text: %s", found.absoluteString.UTF8String);
    found = [LSMapLinks firstMapLinkInText:@"see https://example.com/x and (https://www.google.com/maps/@1,2,3z)"];
    CHECK([found.absoluteString isEqualToString:@"https://www.google.com/maps/@1,2,3z"], "skips other links and brackets");
    found = [LSMapLinks firstMapLinkInText:@"https://www.google.com/maps/dir/?api=1&origin=1,2&destination=3,4&waypoints=1.5,2.5|2,3"];
    LSMapLink *link = [LSMapLinks parseURL:found];
    CHECK(link.places.count == 4 && At(Place(link, 2), 2, 3), "raw pipe in pasted link");
    CHECK([LSMapLinks firstMapLinkInText:@"no links here"] == nil, "no link");

    NSArray *three = @[ [LSMapLinkPlace placeWithLatitude:37.33182 longitude:-122.03118 name:@"Home"],
                        [LSMapLinkPlace placeWithQuery:@"Palo Alto & Co" hintLatitude:NAN hintLongitude:NAN],
                        [LSMapLinkPlace placeWithLatitude:37.7749 longitude:-122.4194 name:nil] ];
    NSString *google = [LSMapLinks URLForApp:LSMapAppGoogle places:three mode:@"walking" legacyApple:NO].absoluteString;
    CHECK([google isEqualToString:@"https://www.google.com/maps/dir/?api=1&origin=37.33182,-122.03118&destination=37.7749,-122.4194&waypoints=Palo%20Alto%20%26%20Co&travelmode=walking"],
          "google link: %s", google.UTF8String);
    NSString *apple = [LSMapLinks URLForApp:LSMapAppApple places:three mode:@"cycling" legacyApple:NO].absoluteString;
    CHECK([apple isEqualToString:@"https://maps.apple.com/directions?source=37.33182,-122.03118&waypoint=Palo%20Alto%20%26%20Co&destination=37.7749,-122.4194&mode=cycling"],
          "apple link: %s", apple.UTF8String);
    NSString *legacy = [LSMapLinks URLForApp:LSMapAppApple places:three mode:@"driving" legacyApple:YES].absoluteString;
    CHECK([legacy isEqualToString:@"https://maps.apple.com/?saddr=37.33182,-122.03118&daddr=37.7749,-122.4194&dirflg=d"], "legacy apple link: %s", legacy.UTF8String);
    NSString *waze = [LSMapLinks URLForApp:LSMapAppWaze places:three mode:nil legacyApple:NO].absoluteString;
    CHECK([waze isEqualToString:@"https://www.waze.com/ul?ll=37.7749,-122.4194&navigate=yes"], "waze link: %s", waze.UTF8String);
    NSString *pin = [LSMapLinks URLForApp:LSMapAppApple places:@[ [LSMapLinkPlace placeWithLatitude:1 longitude:2 name:@"Café & Bar"] ] mode:nil legacyApple:NO].absoluteString;
    CHECK([pin isEqualToString:@"https://maps.apple.com/place?coordinate=1,2&name=Caf%C3%A9%20%26%20Bar"], "apple pin: %s", pin.UTF8String);

    // Round trips: what we build, we read back.
    for (NSNumber *appNumber in @[ @(LSMapAppGoogle), @(LSMapAppApple) ]) {
        LSMapApp app = (LSMapApp)appNumber.integerValue;
        LSMapLink *back = [LSMapLinks parseURL:[LSMapLinks URLForApp:app places:three mode:@"cycling" legacyApple:NO]];
        CHECK(back.places.count == 3 && At(Place(back, 0), 37.33182, -122.03118) && Query(Place(back, 1), @"Palo Alto & Co") &&
              At(Place(back, 2), 37.7749, -122.4194) && [back.mode isEqualToString:@"cycling"], "round trip app %ld", (long)app);
    }
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 13; i++) [many addObject:[LSMapLinkPlace placeWithLatitude:10 + i longitude:20 name:nil]];
    LSMapLink *capped = [LSMapLinks parseURL:[LSMapLinks URLForApp:LSMapAppGoogle places:many mode:nil legacyApple:NO]];
    CHECK(capped.places.count == 11 && At(Place(capped, 0), 10, 20) && At(capped.places.lastObject, 22, 20), "google keeps 9 stops plus both ends");
    CHECK([LSMapLinks URLForApp:LSMapAppGoogle places:@[] mode:nil legacyApple:NO] == nil, "no places, no link");
}

int main(void) {
    @autoreleasepool {
        TestGoogle();
        TestApple();
        TestWazeAndGeo();
        TestTextAndBuild();
    }
    printf("maplinks_tests: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
