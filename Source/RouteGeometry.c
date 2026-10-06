#include "RouteGeometry.h"
#include <math.h>

static double LSNormalizeLongitude(double longitude) {
    double normalized = fmod(longitude + 180.0, 360.0);
    if (normalized < 0.0) normalized += 360.0;
    return normalized - 180.0;
}

bool LSRouteCoordinateIsValid(LSRouteCoordinate coordinate) {
    return isfinite(coordinate.latitude) && isfinite(coordinate.longitude) &&
        fabs(coordinate.latitude) <= 90.0 && fabs(coordinate.longitude) <= 180.0;
}

LSRouteCoordinate LSRouteInterpolate(LSRouteCoordinate from, LSRouteCoordinate to, double progress) {
    if (!LSRouteCoordinateIsValid(from) || !LSRouteCoordinateIsValid(to) || !isfinite(progress))
        return (LSRouteCoordinate){NAN, NAN};
    progress = fmax(0.0, fmin(1.0, progress));
    double delta = LSNormalizeLongitude(to.longitude - from.longitude);
    return (LSRouteCoordinate){
        from.latitude + (to.latitude - from.latitude) * progress,
        LSNormalizeLongitude(from.longitude + delta * progress)
    };
}

double LSRouteBearing(LSRouteCoordinate from, LSRouteCoordinate to) {
    if (!LSRouteCoordinateIsValid(from) || !LSRouteCoordinateIsValid(to)) return NAN;
    const double radians = 3.14159265358979323846 / 180.0;
    double latitude1 = from.latitude * radians;
    double latitude2 = to.latitude * radians;
    double delta = LSNormalizeLongitude(to.longitude - from.longitude) * radians;
    double y = sin(delta) * cos(latitude2);
    double x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(delta);
    if (fabs(x) < 1e-15 && fabs(y) < 1e-15) return 0.0;
    return fmod(atan2(y, x) / radians + 360.0, 360.0);
}

double LSRouteAdvanceDistance(double covered, double speed, double elapsed, double total) {
    if (!isfinite(covered) || !isfinite(speed) || !isfinite(elapsed) || !isfinite(total) ||
        covered < 0.0 || speed < 0.0 || elapsed < 0.0 || total <= 0.0) return NAN;
    return fmin(total, covered + speed * elapsed);
}
