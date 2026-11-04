// Host tests for GPX, TCX and FIT reading and writing. Build with Tests/run.sh.
#import <Foundation/Foundation.h>
#import "../Source/LSTrackIO.h"
#include <math.h>

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
#define NEAR(a, b, eps) (fabs((a) - (b)) <= (eps))

static NSData *D(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }

static LSTrack *Read(NSString *text, NSString *fileName, NSString **error) {
    return [LSTrackIO trackFromData:D(text) fileName:fileName error:error];
}

static void TestGPXTrack(void) {
    NSString *gpx =
        @"<?xml version=\"1.0\"?>\n"
        @"<gpx:gpx xmlns:gpx=\"http://www.topografix.com/GPX/1/1\" xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v2\">"
        @"<gpx:metadata><gpx:name>Meta name</gpx:name></gpx:metadata>"
        @"<gpx:trk><gpx:name>Morning &amp; ride</gpx:name><gpx:type>cycling</gpx:type><gpx:trkseg>"
        @"<gpx:trkpt lat=\"52.5200\" lon=\"13.4050\"><gpx:ele>34.5</gpx:ele><gpx:time>2026-11-04T08:00:00Z</gpx:time>"
        @"<gpx:extensions><gpxtpx:TrackPointExtension><gpxtpx:speed>4.5</gpxtpx:speed></gpxtpx:TrackPointExtension></gpx:extensions></gpx:trkpt>"
        @"<gpx:trkpt lat=\"52.5210\" lon=\"13.4060\"><gpx:time>2026-11-04T08:00:10.500+01:00</gpx:time></gpx:trkpt>"
        @"<gpx:trkpt lat=\"bad\" lon=\"13.4\"><gpx:time>2026-11-04T08:00:11Z</gpx:time></gpx:trkpt>"
        @"<gpx:trkpt lat=\"52.5220\" lon=\"13.4070\"><gpx:time>2026-11-04T07:00:20Z</gpx:time></gpx:trkpt>"
        @"</gpx:trkseg></gpx:trk></gpx:gpx>";
    NSString *error = nil;
    LSTrack *track = Read(gpx, @"ride.gpx", &error);
    CHECK(track != nil, "GPX track parsed (%s)", error.UTF8String);
    if (!track) return;
    CHECK(track.count == 3, "GPX drops the point with an unreadable latitude (%lu)", (unsigned long)track.count);
    CHECK([track.name isEqualToString:@"Morning & ride"], "GPX track name wins: %s", track.name.UTF8String);
    CHECK([track.activity isEqualToString:@"cycling"], "GPX type maps to cycling");
    CHECK([track.format isEqualToString:@"GPX"], "format GPX");
    const LSTrackPoint *p = track.points;
    CHECK(NEAR(p[0].latitude, 52.52, 1e-9) && NEAR(p[0].longitude, 13.405, 1e-9), "first position");
    CHECK(NEAR(p[0].altitude, 34.5, 1e-9), "elevation read");
    CHECK(NEAR(p[0].speed, 4.5, 1e-9), "Garmin extension speed read");
    CHECK(isnan(p[1].altitude), "missing elevation stays NAN");
    // 08:00:10.5+01:00 is 07:00:10.5Z, an hour before the first point.
    CHECK(NEAR(p[1].time - p[0].time, -3600 + 10.5, 1e-6), "offset time %f", p[1].time - p[0].time);
    CHECK(!track.hasTimes, "times going backwards are not usable timing");
}

static void TestGPXRouteAndWaypoints(void) {
    NSString *route = @"<gpx><rte><name>Planned</name><rtept lat=\"1\" lon=\"2\"/><rtept lat=\"1.001\" lon=\"2.001\"/></rte>"
                      @"<wpt lat=\"5\" lon=\"6\"/><wpt lat=\"5.1\" lon=\"6.1\"/><wpt lat=\"5.2\" lon=\"6.2\"/></gpx>";
    LSTrack *track = Read(route, nil, NULL);
    CHECK(track.count == 2 && [track.name isEqualToString:@"Planned"], "route points preferred over waypoints");
    CHECK(!track.hasTimes, "untimed route has no timing");

    LSTrack *waypoints = Read(@"<gpx><wpt lat=\"5\" lon=\"6\"/><wpt lat=\"5.1\" lon=\"6.1\"/></gpx>", @"pins.gpx", NULL);
    CHECK(waypoints.count == 2 && [waypoints.name isEqualToString:@"pins"], "waypoints used last, name from file");

    NSString *error = nil;
    CHECK(Read(@"<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"2\"/></trkseg></trk></gpx>", nil, &error) == nil && error.length,
          "one point is refused with a reason");
    CHECK(Read(@"<gpx><trk><trkseg><trkpt lat=\"0\" lon=\"0\"/><trkpt lat=\"95\" lon=\"2\"/><trkpt lat=\"1\" lon=\"200\"/></trkseg></trk></gpx>", nil, &error) == nil,
          "null island and out of range positions dropped");
}

static void TestTCX(void) {
    NSString *tcx =
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        @"<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\" xmlns:ns3=\"http://www.garmin.com/xmlschemas/ActivityExtension/v2\">"
        @"<Activities><Activity Sport=\"Biking\"><Id>2026-11-04T08:00:00Z</Id><Lap StartTime=\"2026-11-04T08:00:00Z\"><DistanceMeters>999</DistanceMeters><Track>"
        @"<Trackpoint><Time>2026-11-04T08:00:00Z</Time><Position><LatitudeDegrees>40.0</LatitudeDegrees><LongitudeDegrees>-74.0</LongitudeDegrees></Position>"
        @"<AltitudeMeters>10</AltitudeMeters><DistanceMeters>0</DistanceMeters><Extensions><ns3:TPX><ns3:Speed>5.5</ns3:Speed></ns3:TPX></Extensions></Trackpoint>"
        @"<Trackpoint><Time>2026-11-04T08:00:05Z</Time><HeartRateBpm><Value>120</Value></HeartRateBpm></Trackpoint>"
        @"<Trackpoint><Time>2026-11-04T08:00:10Z</Time><Position><LatitudeDegrees>40.0005</LatitudeDegrees><LongitudeDegrees>-74.0005</LongitudeDegrees></Position>"
        @"<DistanceMeters>70</DistanceMeters></Trackpoint>"
        @"</Track></Lap></Activity></Activities></TrainingCenterDatabase>";
    LSTrack *track = Read(tcx, @"commute.tcx", NULL);
    CHECK(track.count == 2, "TCX skips points without a position (%lu)", (unsigned long)track.count);
    CHECK([track.activity isEqualToString:@"cycling"], "TCX Biking maps to cycling");
    CHECK([track.format isEqualToString:@"TCX"], "format TCX");
    CHECK([track.name isEqualToString:@"commute"], "TCX name from file");
    CHECK(track.hasTimes, "TCX has timing");
    if (track.count == 2) {
        CHECK(NEAR(track.points[0].speed, 5.5, 1e-9) && NEAR(track.points[0].altitude, 10, 1e-9), "TCX speed and altitude");
        CHECK(NEAR(track.points[1].distance, 70, 1e-9), "TCX trackpoint distance, not the lap distance");
    }

    NSString *course = @"<TrainingCenterDatabase><Courses><Course><Name>Loop</Name><Track>"
                       @"<Trackpoint><Position><LatitudeDegrees>1</LatitudeDegrees><LongitudeDegrees>1</LongitudeDegrees></Position></Trackpoint>"
                       @"<Trackpoint><Position><LatitudeDegrees>1.01</LatitudeDegrees><LongitudeDegrees>1.01</LongitudeDegrees></Position></Trackpoint>"
                       @"</Track></Course></Courses></TrainingCenterDatabase>";
    LSTrack *loop = Read(course, nil, NULL);
    CHECK(loop.count == 2 && [loop.name isEqualToString:@"Loop"], "TCX course read");
}

static void FillPoints(LSTrackPoint *points, int count) {
    for (int i = 0; i < count; i++) {
        points[i].time = 1793779200.0 + i * 2.0;
        points[i].latitude = 48.8566 + i * 0.0001;
        points[i].longitude = 2.3522 - i * 0.00007;
        points[i].altitude = i % 3 ? 35.0 + i * 0.1 : NAN;
        points[i].distance = i * 12.5;
        points[i].speed = 6.25;
    }
}

static void TestRoundTrips(void) {
    enum { N = 40 };
    LSTrackPoint points[N];
    FillPoints(points, N);

    NSData *gpx = [LSTrackIO GPXDataForPoints:points count:N name:@"Trip <A & \"B\">\x01" activity:@"driving"];
    LSTrack *fromGPX = [LSTrackIO trackFromData:gpx fileName:@"x.gpx" error:NULL];
    CHECK(fromGPX.count == N, "GPX round trip count");
    CHECK([fromGPX.name isEqualToString:@"Trip <A & \"B\">"], "GPX name escaped and control characters dropped: %s", fromGPX.name.UTF8String);
    CHECK([fromGPX.activity isEqualToString:@"driving"], "GPX activity round trip");
    CHECK(fromGPX.hasTimes, "GPX round trip timing");
    BOOL same = fromGPX.count == N;
    for (int i = 0; same && i < N; i++) {
        same = NEAR(fromGPX.points[i].latitude, points[i].latitude, 1e-7) && NEAR(fromGPX.points[i].longitude, points[i].longitude, 1e-7) &&
               NEAR(fromGPX.points[i].time, points[i].time, 1e-3) &&
               (isnan(points[i].altitude) ? isnan(fromGPX.points[i].altitude) : NEAR(fromGPX.points[i].altitude, points[i].altitude, 0.06));
    }
    CHECK(same, "GPX round trip values");

    NSData *tcx = [LSTrackIO TCXDataForPoints:points count:N name:@"Trip" activity:@"walking"];
    LSTrack *fromTCX = [LSTrackIO trackFromData:tcx fileName:nil error:NULL];
    CHECK(fromTCX.count == N && fromTCX.hasTimes, "TCX round trip count and timing");
    CHECK([fromTCX.activity isEqualToString:@"walking"], "TCX Running reads as walking");
    same = fromTCX.count == N;
    for (int i = 0; same && i < N; i++) {
        same = NEAR(fromTCX.points[i].distance, points[i].distance, 0.06) && NEAR(fromTCX.points[i].speed, points[i].speed, 0.006) &&
               NEAR(fromTCX.points[i].time, points[i].time, 1e-3);
    }
    CHECK(same, "TCX round trip distance, speed and time");
    NSString *tcxText = [[NSString alloc] initWithData:tcx encoding:NSUTF8StringEncoding];
    CHECK([tcxText containsString:@"<TotalTimeSeconds>78</TotalTimeSeconds>"], "TCX lap total time");
    CHECK([tcxText containsString:@"<DistanceMeters>487.5</DistanceMeters>"], "TCX lap distance");

    NSData *fit = [LSTrackIO FITDataForPoints:points count:N activity:@"cycling"];
    CHECK(fit.length > 100, "FIT written");
    LSTrack *fromFIT = [LSTrackIO trackFromData:fit fileName:@"ride.fit" error:NULL];
    CHECK(fromFIT.count == N && fromFIT.hasTimes && [fromFIT.format isEqualToString:@"FIT"] && [fromFIT.name isEqualToString:@"ride"], "FIT round trip");
    if (fromFIT.count == N) CHECK(NEAR(fromFIT.points[N - 1].latitude, points[N - 1].latitude, 1e-6), "FIT position");

    LSTrackPoint untimed[3];
    FillPoints(untimed, 3);
    untimed[1].time = NAN;
    NSData *partial = [LSTrackIO TCXDataForPoints:untimed count:3 name:@"" activity:nil];
    LSTrack *partialTrack = [LSTrackIO trackFromData:partial fileName:nil error:NULL];
    CHECK(partialTrack.count == 2, "TCX writer skips points without time");
    CHECK([[[NSString alloc] initWithData:partial encoding:NSUTF8StringEncoding] containsString:@"Sport=\"Other\""], "TCX unknown sport is Other");
    CHECK([LSTrackIO FITDataForPoints:untimed count:0 activity:nil] == nil, "FIT with no points is refused");
}

static void TestRejects(void) {
    NSString *error = nil;
    CHECK([LSTrackIO trackFromData:[NSData data] fileName:nil error:&error] == nil && [error containsString:@"empty"], "empty refused");
    CHECK(Read(@"<html><body>hi</body></html>", nil, &error) == nil && [error containsString:@"GPX"], "HTML refused: %s", error.UTF8String);
    CHECK(Read(@"not xml at all", nil, &error) == nil, "plain text refused");
    uint8_t junk[14] = { 14, 0x10, 0, 0, 0, 0, 0, 0, '.', 'F', 'I', 'T', 0, 0 };
    CHECK([LSTrackIO trackFromData:[NSData dataWithBytes:junk length:sizeof junk] fileName:nil error:&error] == nil && error.length, "header-only FIT refused");
    // A cut-off GPX still gives the points read before the damage.
    LSTrack *cut = Read(@"<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"2\"/><trkpt lat=\"1.1\" lon=\"2.1\"/><trkpt lat=\"1.2\"", nil, &error);
    CHECK(cut.count == 2, "truncated GPX keeps complete points");
}

static void TestFileNames(void) {
    CHECK([[LSTrackIO safeFileName:@"Home / Work: \"fast\"?" extension:@"gpx"] isEqualToString:@"Home Work fast.gpx"], "unsafe characters removed: %s",
          [LSTrackIO safeFileName:@"Home / Work: \"fast\"?" extension:@"gpx"].UTF8String);
    CHECK([[LSTrackIO safeFileName:@"  ..  " extension:@"fit"] isEqualToString:@"LSpoof route.fit"], "empty name falls back");
    NSString *longName = [@"" stringByPaddingToLength:200 withString:@"a" startingAtIndex:0];
    CHECK([LSTrackIO safeFileName:longName extension:@"tcx"].length == 84, "long name cut to 80 characters");
}

int main(void) {
    @autoreleasepool {
        TestGPXTrack();
        TestGPXRouteAndWaypoints();
        TestTCX();
        TestRoundTrips();
        TestRejects();
        TestFileNames();
    }
    printf("trackio_tests: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
