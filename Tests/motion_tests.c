// Host tests for the route motion model. Run with Tests/run.sh.
#include "../Source/RouteMotion.h"
#include "../Source/RouteGeometry.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

typedef struct { double *lat, *lon, *cum, *radius; size_t count; } Path;

static double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    double r = 6371008.8, p = 3.14159265358979323846 / 180.0;
    double dlat = (lat2 - lat1) * p, dlon = (lon2 - lon1) * p;
    double a = sin(dlat / 2) * sin(dlat / 2) + cos(lat1 * p) * cos(lat2 * p) * sin(dlon / 2) * sin(dlon / 2);
    return 2 * r * atan2(sqrt(a), sqrt(1 - a));
}

// An L: `leg` meters east, then `leg` meters north, a point every `spacing` meters.
static Path makeL(double leg, double spacing) {
    size_t perLeg = (size_t)(leg / spacing);
    Path path = {0};
    path.count = perLeg * 2 + 1;
    path.lat = calloc(path.count, sizeof(double)); path.lon = calloc(path.count, sizeof(double));
    path.cum = calloc(path.count, sizeof(double)); path.radius = calloc(path.count, sizeof(double));
    double lat0 = 48.0, lon0 = 11.0, mPerDegLat = 111320.0, mPerDegLon = 111320.0 * cos(lat0 * 3.14159265358979323846 / 180.0);
    for (size_t i = 0; i < path.count; i++) {
        double east = i <= perLeg ? i * spacing : leg;
        double north = i <= perLeg ? 0 : (i - perLeg) * spacing;
        path.lat[i] = lat0 + north / mPerDegLat;
        path.lon[i] = lon0 + east / mPerDegLon;
        path.cum[i] = i == 0 ? 0 : path.cum[i - 1] + distanceMeters(path.lat[i - 1], path.lon[i - 1], path.lat[i], path.lon[i]);
    }
    LSRouteCornerRadii(path.lat, path.lon, path.cum, path.count, 15.0, path.radius);
    return path;
}

static void freePath(Path *path) {
    free(path->lat); free(path->lon); free(path->cum); free(path->radius);
    *path = (Path){0};
}

static LSMotionParams driving(bool smooth) {
    LSMotionParams p = {0};
    p.cruiseSpeed = 50 / 3.6; p.paceMultiplier = 1; p.smooth = smooth;
    p.acceleration = 2.2; p.deceleration = 3.0; p.lateralAcceleration = 2.8; p.minimumCornerSpeed = 3.0;
    return p;
}

static void testCornerRadii(void) {
    Path path = makeL(200, 5);
    size_t corner = path.count / 2;
    CHECK(isfinite(path.radius[corner]), "corner point has a radius");
    CHECK(path.radius[corner] > 10 && path.radius[corner] < 30, "90 degree corner radius %.1f is plausible", path.radius[corner]);
    CHECK(!isfinite(path.radius[10]) && !isfinite(path.radius[path.count - 10]), "straight points have no radius");
    CHECK(!isfinite(path.radius[0]) && !isfinite(path.radius[path.count - 1]), "end points have no radius");
    freePath(&path);
}

static void testConstantSpeed(void) {
    Path path = makeL(500, 10);
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, NULL, NULL, 0, NULL, 0};
    LSMotionParams params = driving(false);
    double total = LSMotionTotal(&route);
    double duration = LSMotionEstimateDuration(&route, &params, 1.0, 1e6);
    CHECK(fabs(duration - total / params.cruiseSpeed) < 1e-6, "constant speed duration %.3f vs %.3f", duration, total / params.cruiseSpeed);
    LSMotionState state; LSMotionReset(&state);
    double used = LSMotionStep(&route, &params, &state, 10.0);
    CHECK(fabs(used - 10.0) < 1e-9 && fabs(state.covered - params.cruiseSpeed * 10.0) < 1e-6, "ten seconds at cruise");
    CHECK(fabs(state.speed - params.cruiseSpeed) < 1e-9, "instant speed without smoothing");
    freePath(&path);
}

static void testSmoothMotion(void) {
    Path path = makeL(400, 5);
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, NULL, NULL, 0, NULL, 0};
    LSMotionParams params = driving(true);
    LSMotionState state; LSMotionReset(&state);
    double t = 0, maxSpeed = 0, cornerSpeed = INFINITY, previousCovered = 0;
    double cornerAt = path.cum[path.count / 2];
    int monotonic = 1, accelOK = 1;
    double previousSpeed = 0;
    while (!state.finished && t < 600) {
        LSMotionStep(&route, &params, &state, 0.1);
        t += 0.1;
        if (state.covered < previousCovered - 1e-9) monotonic = 0;
        if (state.speed - previousSpeed > params.acceleration * 0.1 + 1e-6) accelOK = 0;
        previousCovered = state.covered; previousSpeed = state.speed;
        if (state.speed > maxSpeed) maxSpeed = state.speed;
        if (fabs(state.covered - cornerAt) < 3) cornerSpeed = fmin(cornerSpeed, state.speed);
    }
    CHECK(state.finished, "smooth route finishes (t=%.1f)", t);
    CHECK(monotonic, "distance never goes backwards");
    CHECK(accelOK, "acceleration never exceeds the limit");
    CHECK(maxSpeed <= params.cruiseSpeed + 1e-9, "never above cruise (%.2f)", maxSpeed);
    CHECK(maxSpeed > params.cruiseSpeed * 0.95, "reaches cruise on the straights (%.2f)", maxSpeed);
    CHECK(cornerSpeed < 9.0 && cornerSpeed > 3.0, "slows to %.2f m/s for the corner", cornerSpeed);
    double plain = LSMotionTotal(&route) / params.cruiseSpeed;
    CHECK(t > plain + 5 && t < plain + 40, "smooth trip %.1f s vs constant %.1f s", t, plain);
    CHECK(state.speed == 0.0, "stopped at the destination");
    freePath(&path);
}

static void testStops(void) {
    Path path = makeL(300, 5);
    double stops[] = {150.0, 450.0};
    double dwell[] = {-1.0, -1.0};
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, stops, dwell, 2, NULL, 0};
    LSMotionParams params = driving(false);
    params.defaultDwell = 30.0;
    double plain = LSMotionTotal(&route) / params.cruiseSpeed;
    double withStops = LSMotionEstimateDuration(&route, &params, 1.0, 1e6);
    CHECK(fabs(withStops - (plain + 60.0)) < 1e-6, "two 30 s waits add 60 s (%.3f vs %.3f)", withStops, plain + 60);
    params.defaultDwell = 0;
    CHECK(fabs(LSMotionEstimateDuration(&route, &params, 1.0, 1e6) - plain) < 1e-6, "no wait drives through stops");

    // Smooth: speed reaches zero at the stop, waits, then continues.
    params = driving(true); params.defaultDwell = 10.0;
    LSMotionState state; LSMotionReset(&state);
    double t = 0, dwellStart = -1, dwellEnd = -1;
    while (!state.finished && t < 900) {
        LSMotionStep(&route, &params, &state, 0.1);
        t += 0.1;
        if (state.dwelling && dwellStart < 0) { dwellStart = t; CHECK(fabs(state.covered - 150.0) < 1e-9, "waits exactly at the first stop (%.3f)", state.covered); }
        if (dwellStart >= 0 && dwellEnd < 0 && !state.dwelling) dwellEnd = t;
    }
    CHECK(dwellStart > 0 && dwellEnd > 0 && fabs((dwellEnd - dwellStart) - 10.0) < 0.25, "first wait lasts 10 s (%.2f)", dwellEnd - dwellStart);
    CHECK(state.finished, "finishes after the stops");
    freePath(&path);
}

static void testRecordedPace(void) {
    Path path = makeL(100, 10);
    double *speeds = calloc(path.count, sizeof(double));
    for (size_t i = 1; i < path.count; i++) speeds[i] = i < path.count / 2 ? 2.0 : 4.0;
    double stops[] = {50.0};
    double dwell[] = {20.0};
    LSMotionRoute route = {path.cum, path.radius, speeds, path.count, stops, dwell, 1, NULL, 0};
    LSMotionParams params = driving(false);
    params.useRecordedPace = true;
    double expected = 0;
    for (size_t i = 1; i < path.count; i++) expected += (path.cum[i] - path.cum[i - 1]) / speeds[i];
    double duration = LSMotionEstimateDuration(&route, &params, 0.5, 1e6);
    CHECK(fabs(duration - (expected + 20.0)) < 1e-6, "recorded pace plus recorded pause (%.3f vs %.3f)", duration, expected + 20);
    params.paceMultiplier = 2.0;
    duration = LSMotionEstimateDuration(&route, &params, 0.5, 1e6);
    CHECK(fabs(duration - (expected + 20.0) / 2.0) < 1e-6, "double pace halves the time (%.3f)", duration);
    params.useRecordedPace = false; params.paceMultiplier = 1.0;
    duration = LSMotionEstimateDuration(&route, &params, 0.5, 1e6);
    CHECK(fabs(duration - LSMotionTotal(&route) / params.cruiseSpeed) < 1e-6, "fixed speed ignores recorded pauses");
    free(speeds);
    freePath(&path);
}

static void testSeekAndGuards(void) {
    Path path = makeL(100, 10);
    double stops[] = {50.0};
    double dwell[] = {-1.0};
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, stops, dwell, 1, NULL, 0};
    LSMotionParams params = driving(false); params.defaultDwell = 5;
    LSMotionState state;
    LSMotionSeek(&route, &state, 120.0);
    CHECK(state.nextStop == 1 && fabs(state.covered - 120.0) < 1e-9, "seeking past a stop skips it");
    CHECK(path.cum[state.segment] > 120.0 && path.cum[state.segment - 1] <= 120.0, "seek finds the segment");
    LSMotionSeek(&route, &state, 1e9);
    CHECK(state.finished, "seeking beyond the end finishes");
    CHECK(LSMotionStep(&route, &params, &state, 1.0) == 0.0, "a finished state does not move");
    LSMotionReset(&state);
    CHECK(LSMotionStep(&route, &params, &state, NAN) == 0.0 && state.covered == 0.0, "NaN time is ignored");
    CHECK(LSMotionStep(&route, &params, &state, -1.0) == 0.0, "negative time is ignored");
    LSMotionRoute empty = {path.cum, NULL, NULL, 1, NULL, NULL, 0, NULL, 0};
    CHECK(isnan(LSMotionEstimateDuration(&empty, &params, 1, 100)), "a one-point route has no duration");
    params.cruiseSpeed = 0.5;
    CHECK(isnan(LSMotionEstimateDuration(&route, &params, 1, 10)), "the estimate stops at its limit");
    freePath(&path);
}

// A straight line `length` meters east, a point every `spacing` meters.
static Path makeLine(double length, double spacing) {
    Path path = {0};
    path.count = (size_t)(length / spacing) + 1;
    path.lat = calloc(path.count, sizeof(double)); path.lon = calloc(path.count, sizeof(double));
    path.cum = calloc(path.count, sizeof(double)); path.radius = calloc(path.count, sizeof(double));
    double lat0 = 48.0, lon0 = 11.0, mPerDegLon = 111320.0 * cos(lat0 * 3.14159265358979323846 / 180.0);
    for (size_t i = 0; i < path.count; i++) {
        path.lat[i] = lat0;
        path.lon[i] = lon0 + i * spacing / mPerDegLon;
        path.cum[i] = i == 0 ? 0 : path.cum[i - 1] + distanceMeters(path.lat[i - 1], path.lon[i - 1], path.lat[i], path.lon[i]);
    }
    LSRouteCornerRadii(path.lat, path.lon, path.cum, path.count, 15.0, path.radius);
    return path;
}

// Drive, walk, drive: thirds of the path at 50, 5 and 50 km/h, like a route whose middle leg
// is set to walking. Filled the way the simulator fills them: driving and walking paths
// (MKDirectionsTransportType 1 and 2), at the speeds the planner gives each leg.
static const unsigned long kDrivingPath = 1, kWalkingPath = 2;
static void makeDriveWalkDrive(const Path *path, LSMotionLeg legs[3], bool halts) {
    double total = path->cum[path->count - 1];
    double ends[3] = {round(total / 3), round(2 * total / 3), total};
    // Each leg ends at a point of the path, the way the app takes it from the stop marker.
    for (size_t leg = 0; leg < 2; leg++) {
        size_t best = 0;
        for (size_t i = 0; i < path->count; i++) if (fabs(path->cum[i] - ends[leg]) < fabs(path->cum[best] - ends[leg])) best = i;
        ends[leg] = path->cum[best];
    }
    double speeds[3] = {50, 5, 50};
    unsigned long paths[3] = {kDrivingPath, kWalkingPath, kDrivingPath};
    LSMotionFillLegs(legs, 3, ends, speeds, paths, LSMotionKindDriving, 1);
    if (!halts) { legs[0].haltAtEnd = false; legs[1].haltAtEnd = false; }
}

static void testLegFill(void) {
    Path path = makeLine(900, 10);
    LSMotionLeg legs[3];
    makeDriveWalkDrive(&path, legs, true);
    CHECK(fabs(legs[0].cruiseSpeed - 50 / 3.6) < 1e-12 && fabs(legs[1].cruiseSpeed - 5 / 3.6) < 1e-12, "legs get their own speeds in m/s");
    CHECK(legs[1].acceleration == 0.6 && legs[1].deceleration == 1.0 && legs[1].lateralAcceleration == 1.5 && legs[1].minimumCornerSpeed == 0.8,
          "the walk moves like walking");
    CHECK(legs[0].acceleration == 2.2 && legs[2].deceleration == 3.0, "the drives move like driving");
    CHECK(legs[0].haltAtEnd && legs[1].haltAtEnd && !legs[2].haltAtEnd, "comes to rest at both changes, not at the end of the last leg");
    CHECK(legs[2].end == path.cum[path.count - 1], "the last leg runs to the end");

    double ends[4] = {100, 200, 300, 400};
    double speeds[4] = {NAN, 4, NAN, 50};
    unsigned long paths[4] = {kWalkingPath, kWalkingPath, kDrivingPath, kDrivingPath};
    LSMotionFillLegs(legs, 3, ends, speeds, paths, LSMotionKindWalking, 1);
    CHECK(isnan(legs[0].cruiseSpeed) && legs[0].acceleration == 0.0, "a leg at the route speed takes the route's speed and physics");
    CHECK(!legs[0].haltAtEnd, "walking on at another walking speed does not stop");
    CHECK(legs[1].haltAtEnd, "a change of path stops, even at a speed of the same kind");
    LSMotionLeg four[4];
    LSMotionFillLegs(four, 4, ends, speeds, paths, LSMotionKindWalking, 1);
    CHECK(four[2].haltAtEnd, "starting to drive on the same path stops first");
    LSMotionFillLegs(four, 4, ends, speeds, paths, LSMotionKindWalking, 2);
    CHECK(fabs(four[3].acceleration - 2.2 * 1.6) < 1e-12 && fabs(four[3].lateralAcceleration - 2.8 * 1.2) < 1e-12, "the sporty profile scales a leg's physics");
    CHECK(LSMotionKindForKmh(7) == LSMotionKindWalking && LSMotionKindForKmh(15) == LSMotionKindCycling && LSMotionKindForKmh(25.1) == LSMotionKindDriving,
          "speeds map to kinds of movement");
    LSMotionParams params = {0};
    LSMotionApplyPhysics(&params, LSMotionKindCycling, 0);
    CHECK(fabs(params.acceleration - 0.9 * 0.6) < 1e-12 && fabs(params.minimumCornerSpeed - 2.0) < 1e-12, "the gentle profile scales the route's physics");
    freePath(&path);
}

static void testLegSpeedsSteady(void) {
    Path path = makeLine(900, 10);
    LSMotionLeg legs[3];
    makeDriveWalkDrive(&path, legs, false);
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, NULL, NULL, 0, legs, 3};
    LSMotionParams params = driving(false);
    params.cruiseSpeed = 30 / 3.6;   // The route's own speed: no leg uses it here.
    double total = LSMotionTotal(&route);
    double expected = legs[0].end / legs[0].cruiseSpeed + (legs[1].end - legs[0].end) / legs[1].cruiseSpeed +
                      (total - legs[1].end) / legs[2].cruiseSpeed;
    double duration = LSMotionEstimateDuration(&route, &params, 1.0, 1e6);
    CHECK(fabs(duration - expected) < 1e-6, "drive, walk, drive takes %.3f s vs %.3f s", duration, expected);

    // Live playback at the 0.1 s tick crosses each leg at that leg's speed.
    LSMotionState state; LSMotionReset(&state);
    double t = 0, walkSpeed = -1, driveSpeed = -1;
    size_t lastLeg = 0;
    int legsInOrder = 1;
    while (!state.finished && t < 2000) {
        LSMotionStep(&route, &params, &state, 0.1);
        t += 0.1;
        if (state.leg < lastLeg) legsInOrder = 0;
        lastLeg = state.leg;
        if (state.covered > legs[0].end + 1 && state.covered < legs[1].end - 1) walkSpeed = state.speed;
        if (state.covered > legs[1].end + 1 && !state.finished) driveSpeed = state.speed;
    }
    CHECK(fabs(t - expected) < 0.15, "live playback %.2f s matches the estimate %.2f s", t, expected);
    CHECK(fabs(walkSpeed - legs[1].cruiseSpeed) < 1e-9, "the walking leg plays at 5 km/h (%.3f m/s)", walkSpeed);
    CHECK(fabs(driveSpeed - legs[2].cruiseSpeed) < 1e-9, "the last leg drives again (%.3f m/s)", driveSpeed);
    CHECK(legsInOrder && lastLeg == 2, "the legs are passed in order");

    // One second from the start of the walk, the location is exactly one walking second in.
    LSMotionSeek(&route, &state, legs[0].end - 2 * legs[0].cruiseSpeed);
    CHECK(state.leg == 0, "seeking before the first stop stays on the first leg");
    LSMotionStep(&route, &params, &state, 3.0);
    double into = state.covered - legs[0].end;
    CHECK(fabs(into - legs[1].cruiseSpeed) < 1e-6 && state.leg == 1, "a step across a leg end changes speed there (%.3f m in)", into);

    // A leg without its own speed plays at the route's speed.
    legs[1].cruiseSpeed = NAN;
    expected = legs[0].end / legs[0].cruiseSpeed + (legs[1].end - legs[0].end) / params.cruiseSpeed + (total - legs[1].end) / legs[2].cruiseSpeed;
    duration = LSMotionEstimateDuration(&route, &params, 1.0, 1e6);
    CHECK(fabs(duration - expected) < 1e-6, "a leg on the route speed uses it (%.3f vs %.3f)", duration, expected);
    LSMotionParams onLeg = LSMotionParamsForLeg(&route, &params, 1);
    CHECK(onLeg.cruiseSpeed == params.cruiseSpeed && onLeg.acceleration == 0.6, "the leg keeps its own physics without its own speed");
    CHECK(LSMotionLegAt(&route, legs[0].end) == 1 && LSMotionLegAt(&route, legs[0].end - 0.01) == 0 && LSMotionLegAt(&route, 1e9) == 2,
          "a leg starts at the previous leg's end");

    // Planned stops at the leg ends still wait.
    double stops[] = {legs[0].end, legs[1].end};
    double dwell[] = {-1.0, -1.0};
    legs[1].cruiseSpeed = 5 / 3.6;
    route.stopDistance = stops; route.stopDwell = dwell; route.stopCount = 2;
    params.defaultDwell = 20;
    expected = legs[0].end / legs[0].cruiseSpeed + (legs[1].end - legs[0].end) / legs[1].cruiseSpeed + (total - legs[1].end) / legs[2].cruiseSpeed + 40;
    duration = LSMotionEstimateDuration(&route, &params, 1.0, 1e6);
    CHECK(fabs(duration - expected) < 1e-6, "waits at the stops add to the leg times (%.3f vs %.3f)", duration, expected);
    freePath(&path);
}

static void testLegHaltsSmooth(void) {
    Path path = makeLine(900, 5);
    LSMotionLeg legs[3];
    makeDriveWalkDrive(&path, legs, true);
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, NULL, NULL, 0, legs, 3};
    LSMotionParams params = driving(true);
    LSMotionState state; LSMotionReset(&state);
    double t = 0, previousSpeed = 0, maxWalk = 0, maxDrive = 0;
    double slowestAtEnd[2] = {INFINITY, INFINITY};
    int stoppedAtEnd[2] = {0, 0}, walkAccelOK = 1, monotonic = 1;
    double previousCovered = 0;
    while (!state.finished && t < 3000) {
        size_t legBefore = state.leg;
        LSMotionStep(&route, &params, &state, 0.1);
        t += 0.1;
        if (state.covered < previousCovered - 1e-9) monotonic = 0;
        previousCovered = state.covered;
        for (int end = 0; end < 2; end++) {
            if (fabs(state.covered - legs[end].end) < 2) slowestAtEnd[end] = fmin(slowestAtEnd[end], state.speed);
            if (state.covered == legs[end].end && state.speed == 0.0) stoppedAtEnd[end] = 1;
        }
        if (legBefore == 1 && state.leg == 1) {
            maxWalk = fmax(maxWalk, state.speed);
            if (state.speed - previousSpeed > 0.6 * 0.1 + 1e-9) walkAccelOK = 0;
        }
        if (state.leg == 0 || state.leg == 2) maxDrive = fmax(maxDrive, state.speed);
        previousSpeed = state.speed;
    }
    CHECK(state.finished, "a smooth drive, walk, drive route finishes (t=%.1f)", t);
    CHECK(monotonic, "distance never goes backwards across mode changes");
    CHECK(stoppedAtEnd[0] && stoppedAtEnd[1], "comes to rest exactly where the mode changes (%d, %d)", stoppedAtEnd[0], stoppedAtEnd[1]);
    CHECK(slowestAtEnd[0] == 0.0 && slowestAtEnd[1] == 0.0, "speed reaches zero at both changes");
    CHECK(maxWalk <= legs[1].cruiseSpeed + 1e-9 && maxWalk > legs[1].cruiseSpeed * 0.95, "walks at up to 5 km/h (%.3f m/s)", maxWalk);
    CHECK(walkAccelOK, "the walking leg speeds up at walking pace");
    CHECK(maxDrive > legs[0].cruiseSpeed * 0.95 && maxDrive <= legs[0].cruiseSpeed + 1e-9, "drives at up to 50 km/h (%.2f m/s)", maxDrive);
    double steady = legs[0].end / legs[0].cruiseSpeed + (legs[1].end - legs[0].end) / legs[1].cruiseSpeed +
                    (LSMotionTotal(&route) - legs[1].end) / legs[2].cruiseSpeed;
    CHECK(t > steady + 5 && t < steady + 40, "braking and starting again add a little (%.1f s vs %.1f s steady)", t, steady);
    double estimate = LSMotionEstimateDuration(&route, &params, 0.1, 1e6);
    CHECK(fabs(estimate - t) < 0.15, "the estimate matches live playback (%.2f vs %.2f)", estimate, t);

    // Without a change of mode the location keeps moving; a slower leg is reached at its speed.
    legs[0].haltAtEnd = false; legs[1].haltAtEnd = false;
    LSMotionReset(&state);
    t = 0;
    double atFirstEnd = -1, slowest = INFINITY;
    while (!state.finished && t < 3000) {
        double before = state.covered;
        LSMotionStep(&route, &params, &state, 0.1);
        t += 0.1;
        if (before < legs[0].end && state.covered >= legs[0].end) atFirstEnd = state.speed;
        if (state.leg == 1 && state.covered < legs[1].end - 50) slowest = fmin(slowest, state.speed);
    }
    CHECK(atFirstEnd >= 0 && atFirstEnd <= legs[1].cruiseSpeed + 0.5, "slows to walking pace by the end of the drive (%.2f m/s)", atFirstEnd);
    CHECK(slowest > 0.5, "does not stop between legs of the same mode (%.2f m/s)", slowest);
    freePath(&path);
}

int main(void) {
    testCornerRadii();
    testConstantSpeed();
    testSmoothMotion();
    testStops();
    testRecordedPace();
    testSeekAndGuards();
    testLegFill();
    testLegSpeedsSteady();
    testLegHaltsSmooth();
    printf("motion: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
