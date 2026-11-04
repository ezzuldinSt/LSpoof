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
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, NULL, NULL, 0};
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
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, NULL, NULL, 0};
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
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, stops, dwell, 2};
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
    LSMotionRoute route = {path.cum, path.radius, speeds, path.count, stops, dwell, 1};
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
    LSMotionRoute route = {path.cum, path.radius, NULL, path.count, stops, dwell, 1};
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
    LSMotionRoute empty = {path.cum, NULL, NULL, 1, NULL, NULL, 0};
    CHECK(isnan(LSMotionEstimateDuration(&empty, &params, 1, 100)), "a one-point route has no duration");
    params.cruiseSpeed = 0.5;
    CHECK(isnan(LSMotionEstimateDuration(&route, &params, 1, 10)), "the estimate stops at its limit");
    freePath(&path);
}

int main(void) {
    testCornerRadii();
    testConstantSpeed();
    testSmoothMotion();
    testStops();
    testRecordedPace();
    testSeekAndGuards();
    printf("motion: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
