#ifndef LS_ROUTE_MOTION_H
#define LS_ROUTE_MOTION_H

#include <stdbool.h>
#include <stddef.h>

// Pure motion model for route playback. The live simulator and the time estimates
// (ETA, "finish in", GPX/TCX/FIT export) all advance the same state with this code.

typedef struct {
    const double *cumulative;     // Meters from the start, increasing; cumulative[0] == 0.
    const double *cornerRadius;   // Meters per point, INFINITY where the path is straight. May be NULL.
    const double *recordedSpeed;  // m/s of the segment ending at each point (index 0 unused). May be NULL.
    size_t count;
    const double *stopDistance;   // Meters along the path, increasing, inside (0, total).
    const double *stopDwell;      // Seconds per stop. Negative: a planned stop that uses defaultDwell.
                                  // Zero or more: a pause found in a recording, used with recorded pace only.
    size_t stopCount;
} LSMotionRoute;

typedef struct {
    double cruiseSpeed;          // m/s when not following recorded pace.
    double paceMultiplier;       // Scales recorded pace, e.g. 2 plays a recording twice as fast.
    bool useRecordedPace;
    bool smooth;                 // Accelerate, brake before stops, slow down for turns.
    double acceleration;         // m/s^2
    double deceleration;         // m/s^2, positive.
    double lateralAcceleration;  // m/s^2 allowed in turns.
    double minimumCornerSpeed;   // m/s
    double defaultDwell;         // Seconds to wait at planned stops; 0 drives through.
    double substep;              // Largest integration step in seconds; 0 means 0.1.
} LSMotionParams;

typedef struct {
    double covered;          // Meters along the path.
    double speed;            // m/s right now.
    size_t segment;          // First point index whose cumulative distance is beyond covered.
    size_t nextStop;
    double dwellRemaining;
    bool dwelling;
    bool finished;
} LSMotionState;

double LSMotionTotal(const LSMotionRoute *route);
void LSMotionReset(LSMotionState *state);
// Places the state at a distance, e.g. after the route was paused and replaced.
void LSMotionSeek(const LSMotionRoute *route, LSMotionState *state, double covered);
// Advances by dt seconds and returns the time used, which is less than dt only on arrival.
double LSMotionStep(const LSMotionRoute *route, const LSMotionParams *params, LSMotionState *state, double dt);
double LSMotionDwellForStop(const LSMotionRoute *route, const LSMotionParams *params, size_t index);
// Speed the route aims for at the current position, before braking limits.
double LSMotionCruise(const LSMotionRoute *route, const LSMotionParams *params, const LSMotionState *state);
// Seconds from the start to the end, or NAN if it would take longer than `limit` seconds.
double LSMotionEstimateDuration(const LSMotionRoute *route, const LSMotionParams *params, double dt, double limit);

// Turn radius at each point from the heading change across a window of `window` meters
// on either side. Straight points get INFINITY.
void LSRouteCornerRadii(const double *latitude, const double *longitude, const double *cumulative,
                        size_t count, double window, double *radiusOut);

#endif
