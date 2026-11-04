#include "RouteMotion.h"
#include "RouteGeometry.h"
#include <math.h>

static const double kLSPi = 3.14159265358979323846;
// Fast enough for 500 km/h, and slow enough that "moving" never rounds to standing still.
static const double kLSMinimumSpeed = 0.1;
static const double kLSMaximumSpeed = 140.0;
// The last few centimeters before a stop are not crept through at walking pace.
static const double kLSArrivalDistance = 0.25;
static const double kLSArrivalSpeed = 0.75;

static double LSClamp(double value, double low, double high) {
    return value < low ? low : (value > high ? high : value);
}

double LSMotionTotal(const LSMotionRoute *route) {
    return route && route->cumulative && route->count >= 2 ? route->cumulative[route->count - 1] : 0.0;
}

void LSMotionReset(LSMotionState *state) {
    if (!state) return;
    *state = (LSMotionState){0};
    state->segment = 1;
}

void LSMotionSeek(const LSMotionRoute *route, LSMotionState *state, double covered) {
    if (!state) return;
    LSMotionReset(state);
    double total = LSMotionTotal(route);
    if (!(total > 0.0) || !isfinite(covered)) { state->finished = !(total > 0.0); return; }
    state->covered = LSClamp(covered, 0.0, total);
    while (state->segment + 1 < route->count && route->cumulative[state->segment] <= state->covered) state->segment++;
    while (state->nextStop < route->stopCount && route->stopDistance[state->nextStop] <= state->covered) state->nextStop++;
    state->finished = state->covered >= total;
}

double LSMotionDwellForStop(const LSMotionRoute *route, const LSMotionParams *params, size_t index) {
    if (!route || !params || index >= route->stopCount) return 0.0;
    double dwell = route->stopDwell ? route->stopDwell[index] : -1.0;
    if (!isfinite(dwell)) return 0.0;
    if (dwell < 0.0) return isfinite(params->defaultDwell) && params->defaultDwell > 0.0 ? params->defaultDwell : 0.0;
    if (!params->useRecordedPace) return 0.0;
    double multiplier = isfinite(params->paceMultiplier) && params->paceMultiplier > 0.0 ? params->paceMultiplier : 1.0;
    return dwell / multiplier;
}

double LSMotionCruise(const LSMotionRoute *route, const LSMotionParams *params, const LSMotionState *state) {
    double cruise = isfinite(params->cruiseSpeed) ? params->cruiseSpeed : kLSMinimumSpeed;
    if (params->useRecordedPace && route->recordedSpeed && route->count >= 2) {
        size_t index = state->segment < route->count ? state->segment : route->count - 1;
        if (index == 0) index = 1;
        double recorded = route->recordedSpeed[index];
        double multiplier = isfinite(params->paceMultiplier) && params->paceMultiplier > 0.0 ? params->paceMultiplier : 1.0;
        if (isfinite(recorded) && recorded > 0.0) cruise = recorded * multiplier;
    }
    return LSClamp(cruise, kLSMinimumSpeed, kLSMaximumSpeed);
}

// The highest speed from which every upcoming stop, turn and the destination can
// still be met by braking at the configured rate.
static double LSBrakingLimit(const LSMotionRoute *route, const LSMotionParams *params, const LSMotionState *state, double cruise) {
    double braking = params->deceleration > 0.0 ? params->deceleration : 1.0;
    double horizon = cruise * cruise / (2.0 * braking) + 5.0;
    double limit = INFINITY;
    double toEnd = LSMotionTotal(route) - state->covered;
    if (toEnd <= horizon) limit = fmin(limit, sqrt(2.0 * braking * fmax(0.0, toEnd)));
    for (size_t index = state->nextStop; index < route->stopCount; index++) {
        double distance = route->stopDistance[index] - state->covered;
        if (distance > horizon) break;
        if (distance < 0.0 || LSMotionDwellForStop(route, params, index) <= 0.0) continue;
        limit = fmin(limit, sqrt(2.0 * braking * distance));
        break;
    }
    if (route->cornerRadius && params->lateralAcceleration > 0.0) {
        for (size_t index = state->segment; index < route->count; index++) {
            double distance = route->cumulative[index] - state->covered;
            if (distance > horizon) break;
            double radius = route->cornerRadius[index];
            if (distance < 0.0 || !isfinite(radius) || radius <= 0.0) continue;
            double corner = fmax(params->minimumCornerSpeed, sqrt(params->lateralAcceleration * radius));
            if (corner >= cruise) continue;
            limit = fmin(limit, sqrt(corner * corner + 2.0 * braking * distance));
        }
    }
    return limit;
}

double LSMotionStep(const LSMotionRoute *route, const LSMotionParams *params, LSMotionState *state, double dt) {
    if (!route || !params || !state || state->finished || route->count < 2 || !isfinite(dt) || dt <= 0.0) return 0.0;
    double total = LSMotionTotal(route);
    if (!(total > 0.0)) { state->finished = true; return 0.0; }
    double substep = params->substep > 0.0 ? params->substep : 0.1;
    double acceleration = params->acceleration > 0.0 ? params->acceleration : 1.0;
    double deceleration = params->deceleration > 0.0 ? params->deceleration : 1.0;
    double remaining = dt;
    unsigned guard = 0;
    while (remaining > 1e-9 && !state->finished && guard++ < 200000) {
        if (state->dwelling) {
            double used = fmin(remaining, state->dwellRemaining);
            state->dwellRemaining -= used;
            remaining -= used;
            state->speed = 0.0;
            if (state->dwellRemaining <= 1e-9) {
                state->dwelling = false;
                state->dwellRemaining = 0.0;
                state->nextStop++;
            }
            continue;
        }
        // Passing a stop with no wait leaves it behind.
        while (state->nextStop < route->stopCount && route->stopDistance[state->nextStop] < state->covered - 1e-9) state->nextStop++;
        double step = params->smooth ? fmin(remaining, substep) : remaining;
        double cruise = LSMotionCruise(route, params, state);
        if (params->smooth) {
            double limit = LSBrakingLimit(route, params, state, cruise);
            double target = fmin(cruise, limit);
            if (state->speed < target) {
                state->speed = fmin(target, state->speed + acceleration * step);
            } else if (state->speed > target) {
                // Stops and turns are met firmly; a lower cruise speed is eased into.
                double rate = limit < cruise ? 2.5 * deceleration : deceleration;
                state->speed = fmax(target, state->speed - rate * step);
            }
        } else {
            state->speed = cruise;
        }
        double next = state->covered + state->speed * step;
        if (!params->smooth && params->useRecordedPace && state->speed > 0.0) {
            // Recorded pace changes per segment; end the step where the segment ends.
            double segmentEnd = route->cumulative[state->segment < route->count ? state->segment : route->count - 1];
            if (segmentEnd > state->covered && next > segmentEnd) {
                step = (segmentEnd - state->covered) / state->speed;
                next = segmentEnd;
            }
        }
        bool arrivedAtStop = false;
        double dwell = 0.0;
        if (state->nextStop < route->stopCount) {
            double stopAt = route->stopDistance[state->nextStop];
            dwell = LSMotionDwellForStop(route, params, state->nextStop);
            if (next >= stopAt - 1e-9) {
                if (dwell > 0.0) {
                    if (!params->smooth && state->speed > 0.0) step = fmax(0.0, (stopAt - state->covered) / state->speed);
                    next = stopAt;
                    arrivedAtStop = true;
                } else {
                    state->nextStop++;
                }
            } else if (params->smooth && dwell > 0.0 && stopAt - next < kLSArrivalDistance && state->speed < kLSArrivalSpeed) {
                next = stopAt;
                arrivedAtStop = true;
            }
        }
        bool arrivedAtEnd = false;
        if (next >= total - 1e-9 || (params->smooth && total - next < kLSArrivalDistance && state->speed < kLSArrivalSpeed)) {
            if (!params->smooth && state->speed > 0.0 && next > total) step = fmax(0.0, (total - state->covered) / state->speed);
            next = total;
            arrivedAtEnd = true;
        }
        state->covered = next;
        remaining -= step;
        while (state->segment + 1 < route->count && route->cumulative[state->segment] <= state->covered) state->segment++;
        if (arrivedAtEnd) {
            state->finished = true;
            state->speed = 0.0;
        } else if (arrivedAtStop) {
            state->dwelling = true;
            state->dwellRemaining = dwell;
            state->speed = 0.0;
        }
    }
    return dt - fmax(0.0, remaining);
}

double LSMotionEstimateDuration(const LSMotionRoute *route, const LSMotionParams *params, double dt, double limit) {
    if (!route || !params || LSMotionTotal(route) <= 0.0) return NAN;
    if (!(dt > 0.0) || !isfinite(dt)) dt = 1.0;
    LSMotionState state;
    LSMotionReset(&state);
    double elapsed = 0.0;
    while (!state.finished) {
        double used = LSMotionStep(route, params, &state, dt);
        elapsed += used;
        if (used <= 0.0 || elapsed > limit) return NAN;
    }
    return elapsed;
}

void LSRouteCornerRadii(const double *latitude, const double *longitude, const double *cumulative,
                        size_t count, double window, double *radiusOut) {
    if (!radiusOut) return;
    for (size_t index = 0; index < count; index++) radiusOut[index] = INFINITY;
    if (!latitude || !longitude || !cumulative || count < 3 || !(window > 0.0)) return;
    size_t back = 0, ahead = 1;
    for (size_t index = 1; index + 1 < count; index++) {
        while (back + 1 < index && cumulative[index] - cumulative[back + 1] >= window) back++;
        if (ahead <= index) ahead = index + 1;
        while (ahead + 1 < count && cumulative[ahead] - cumulative[index] < window) ahead++;
        double before = cumulative[index] - cumulative[back];
        double after = cumulative[ahead] - cumulative[index];
        if (before < 1.0 || after < 1.0) continue;
        LSRouteCoordinate a = {latitude[back], longitude[back]};
        LSRouteCoordinate b = {latitude[index], longitude[index]};
        LSRouteCoordinate c = {latitude[ahead], longitude[ahead]};
        double incoming = LSRouteBearing(a, b), outgoing = LSRouteBearing(b, c);
        if (!isfinite(incoming) || !isfinite(outgoing)) continue;
        double turn = fabs(fmod(outgoing - incoming + 540.0, 360.0) - 180.0);
        if (turn < 12.0) continue;
        radiusOut[index] = (before + after) / (turn * kLSPi / 180.0);
    }
}
