#ifndef LS_ROUTE_GEOMETRY_H
#define LS_ROUTE_GEOMETRY_H

#include <stdbool.h>

typedef struct {
    double latitude;
    double longitude;
} LSRouteCoordinate;

bool LSRouteCoordinateIsValid(LSRouteCoordinate coordinate);
LSRouteCoordinate LSRouteInterpolate(LSRouteCoordinate from, LSRouteCoordinate to, double progress);
double LSRouteBearing(LSRouteCoordinate from, LSRouteCoordinate to);
double LSRouteAdvanceDistance(double covered, double speed, double elapsed, double total);

#endif
