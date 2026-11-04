// Host tests for ISO 8601 and FIT encoding/decoding. Run with Tests/run.sh.
// With an argument, also writes a sample FIT file there for external validation.
#include "../Source/LSTrackCodec.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void testISO(void) {
    CHECK(LSParseISO8601("1970-01-01T00:00:00Z") == 0.0, "epoch");
    CHECK(LSParseISO8601("2026-11-04T09:30:15Z") == 1793784615.0, "a known instant (%f)", LSParseISO8601("2026-11-04T09:30:15Z"));
    CHECK(fabs(LSParseISO8601("2026-11-04T09:30:15.250Z") - 1793784615.25) < 1e-6, "fractional seconds");
    CHECK(LSParseISO8601("2026-11-04T11:30:15+02:00") == 1793784615.0, "positive offset");
    CHECK(LSParseISO8601("2026-11-04T04:30:15-0500") == 1793784615.0, "negative offset without colon");
    CHECK(LSParseISO8601("  2026-11-04T09:30:15Z \n") == 1793784615.0, "surrounding whitespace");
    CHECK(LSParseISO8601("2026-11-04T09:30Z") == 1793784600.0, "no seconds");
    CHECK(LSParseISO8601("2026-11-04") == 1793750400.0, "date only");
    CHECK(LSParseISO8601("2024-02-29T00:00:00Z") == 1709164800.0, "leap day");
    CHECK(LSParseISO8601("1969-12-31T23:59:59Z") == -1.0, "before the epoch");
    CHECK(isnan(LSParseISO8601("2026-13-01T00:00:00Z")), "bad month");
    CHECK(isnan(LSParseISO8601("yesterday")), "not a date");
    CHECK(isnan(LSParseISO8601("2026-11-04T09:30:15Zjunk")), "trailing junk");
    CHECK(isnan(LSParseISO8601(NULL)), "null");
    char buffer[40];
    LSFormatISO8601(1793784615.0, 0, buffer, sizeof buffer);
    CHECK(strcmp(buffer, "2026-11-04T09:30:15Z") == 0, "format %s", buffer);
    LSFormatISO8601(1793784615.25, 1, buffer, sizeof buffer);
    CHECK(strcmp(buffer, "2026-11-04T09:30:15.250Z") == 0, "format millis %s", buffer);
    LSFormatISO8601(951782400.0, 0, buffer, sizeof buffer);
    CHECK(strcmp(buffer, "2000-02-29T00:00:00Z") == 0, "format leap %s", buffer);
    for (double t = -86400.0 * 400; t < 86400.0 * 365 * 80; t += 86400.0 * 37 + 3601.5) {
        LSFormatISO8601(t, 1, buffer, sizeof buffer);
        if (fabs(LSParseISO8601(buffer) - t) > 1e-3) { CHECK(0, "round trip %f -> %s", t, buffer); break; }
    }
}

static LSTrackPoint *samplePoints(size_t count) {
    LSTrackPoint *points = calloc(count, sizeof(LSTrackPoint));
    for (size_t i = 0; i < count; i++) {
        points[i].time = 1793784615.0 + i;
        points[i].latitude = 51.5 + i * 0.0001;
        points[i].longitude = -0.12 - i * 0.0002;
        points[i].altitude = 12.0;
        points[i].distance = i * 15.0;
        points[i].speed = i == 0 ? 0.0 : 15.0;
    }
    return points;
}

static void testFit(const char *outputPath) {
    size_t count = 120;
    LSTrackPoint *points = samplePoints(count);
    uint8_t *bytes = NULL;
    size_t length = LSFitEncodeActivity(points, count, LSFitSportDriving, &bytes);
    CHECK(length > 14 && bytes, "encodes");
    CHECK(LSFitLooksLikeFit(bytes, length), "has a FIT header");
    if (outputPath) { FILE *file = fopen(outputPath, "wb"); fwrite(bytes, 1, length, file); fclose(file); }
    LSTrackPoint *decoded = NULL;
    size_t decodedCount = LSFitDecodeRecords(bytes, length, &decoded);
    CHECK(decodedCount == count, "decodes every record (%zu)", decodedCount);
    double worst = 0;
    for (size_t i = 0; i < decodedCount && i < count; i++) {
        worst = fmax(worst, fabs(decoded[i].latitude - points[i].latitude) + fabs(decoded[i].longitude - points[i].longitude));
        if (decoded[i].time != points[i].time) { CHECK(0, "time %zu", i); break; }
    }
    CHECK(worst < 1e-6, "positions survive (%g)", worst);
    CHECK(fabs(decoded[5].speed - 15.0) < 1e-3 && fabs(decoded[5].distance - 75.0) < 1e-2 && fabs(decoded[5].altitude - 12.0) < 0.3, "speed, distance, altitude");
    free(decoded);
    // Damaged and foreign data never crash and never invent points.
    CHECK(LSFitDecodeRecords(bytes, 20, &decoded) == 0 && !decoded, "truncated file has no records");
    for (size_t cut = 14; cut < length; cut += 7) { size_t n = LSFitDecodeRecords(bytes, cut, &decoded); free(decoded); if (n > count) CHECK(0, "cut %zu", cut); }
    uint8_t garbage[64] = {14, 0x10, 0, 0, 50, 0, 0, 0, '.', 'F', 'I', 'T', 0, 0, 0x02, 0xFF};
    CHECK(LSFitDecodeRecords(garbage, sizeof garbage, &decoded) == 0, "undefined local message is rejected");
    CHECK(!LSFitLooksLikeFit((const uint8_t *)"<?xml version", 13), "XML is not FIT");
    free(bytes);
    points[3].time = NAN;
    CHECK(LSFitEncodeActivity(points, count, 0, &bytes) == 0 && !bytes, "a point without a time is refused");
    free(points);

    // Compressed timestamp headers and big-endian definitions, as some devices write them.
    uint8_t handmade[256];
    size_t n = 0;
    uint8_t header[14] = {14, 0x10, 0, 0, 0, 0, 0, 0, '.', 'F', 'I', 'T', 0, 0};
    memcpy(handmade, header, 14); n = 14;
    // Definition, local 0, big endian, record: timestamp, lat, lon
    uint8_t def[] = {0x40, 0, 1, 0, 20, 3, 253, 4, 0x86, 0, 4, 0x85, 1, 4, 0x85};
    memcpy(handmade + n, def, sizeof def); n += sizeof def;
    uint32_t ts = 1000000000u;
    int32_t lat = (int32_t)(10.0 * 2147483648.0 / 180.0), lon = (int32_t)(20.0 * 2147483648.0 / 180.0);
    handmade[n++] = 0x00;
    for (int s = 3; s >= 0; s--) handmade[n++] = (ts >> (8 * s)) & 0xFF;
    for (int s = 3; s >= 0; s--) handmade[n++] = ((uint32_t)lat >> (8 * s)) & 0xFF;
    for (int s = 3; s >= 0; s--) handmade[n++] = ((uint32_t)lon >> (8 * s)) & 0xFF;
    // Definition, local 1, little endian, record without timestamp: lat, lon
    uint8_t def2[] = {0x41, 0, 0, 20, 0, 2, 0, 4, 0x85, 1, 4, 0x85};
    memcpy(handmade + n, def2, sizeof def2); n += sizeof def2;
    // Compressed header, local 1, offset (ts & 31) + 3.
    uint32_t offset = ((ts & 0x1F) + 3) & 0x1F;
    handmade[n++] = 0x80 | (1 << 5) | offset;
    for (int s = 0; s < 4; s++) handmade[n++] = ((uint32_t)(lat + 1000) >> (8 * s)) & 0xFF;
    for (int s = 0; s < 4; s++) handmade[n++] = ((uint32_t)(lon + 1000) >> (8 * s)) & 0xFF;
    uint32_t size = (uint32_t)(n - 14);
    handmade[4] = size & 0xFF; handmade[5] = size >> 8;
    size_t got = LSFitDecodeRecords(handmade, n, &decoded);
    CHECK(got == 2, "handmade file has two records (%zu)", got);
    if (got == 2) {
        CHECK(fabs(decoded[0].latitude - 10.0) < 1e-6 && fabs(decoded[0].longitude - 20.0) < 1e-6, "big endian position");
        CHECK(decoded[1].time - decoded[0].time == 3.0, "compressed timestamp adds 3 s (%f)", decoded[1].time - decoded[0].time);
    }
    free(decoded);
}

int main(int argc, char **argv) {
    testISO();
    testFit(argc > 1 ? argv[1] : NULL);
    printf("codec: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
