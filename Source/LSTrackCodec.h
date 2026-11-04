#ifndef LS_TRACK_CODEC_H
#define LS_TRACK_CODEC_H

#include <stddef.h>
#include <stdint.h>

// Format-level helpers for track files that need no Foundation: ISO 8601 times
// (GPX, TCX) and the binary FIT activity format.

typedef struct {
    double time;       // Unix seconds, NAN when unknown.
    double latitude;
    double longitude;
    double altitude;   // Meters, NAN when unknown.
    double distance;   // Meters from the start, NAN when unknown.
    double speed;      // m/s, NAN when unknown.
} LSTrackPoint;

// "2026-11-04T09:30:00Z", fractional seconds and +hh:mm offsets allowed. NAN on failure.
double LSParseISO8601(const char *text);
// Writes "YYYY-MM-DDTHH:MM:SSZ" (or with .mmm when milliseconds is nonzero) into a
// buffer of at least 32 bytes.
void LSFormatISO8601(double unixSeconds, int milliseconds, char *buffer, size_t size);

enum { LSFitSportGeneric = 0, LSFitSportRunning = 1, LSFitSportCycling = 2, LSFitSportWalking = 11, LSFitSportDriving = 24 };

// Encodes a FIT activity (file_id, start/stop events, records, lap, session, activity).
// Returns the byte count and a malloc'd buffer in *out, or 0 on failure.
size_t LSFitEncodeActivity(const LSTrackPoint *points, size_t count, int sport, uint8_t **out);
// Reads the record messages of a FIT file. Returns the point count and a malloc'd array
// in *out, or 0 when the file is not FIT, is damaged, or has no positions.
size_t LSFitDecodeRecords(const uint8_t *data, size_t length, LSTrackPoint **out);
// True when the bytes start with a FIT file header.
int LSFitLooksLikeFit(const uint8_t *data, size_t length);

#endif
