#include "LSTrackCodec.h"
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ISO 8601

static int64_t LSDaysFromCivil(int64_t year, unsigned month, unsigned day) {
    year -= month <= 2;
    int64_t era = (year >= 0 ? year : year - 399) / 400;
    unsigned yearOfEra = (unsigned)(year - era * 400);
    unsigned dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
    unsigned dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
    return era * 146097 + (int64_t)dayOfEra - 719468;
}

static void LSCivilFromDays(int64_t days, int64_t *year, unsigned *month, unsigned *day) {
    days += 719468;
    int64_t era = (days >= 0 ? days : days - 146096) / 146097;
    unsigned dayOfEra = (unsigned)(days - era * 146097);
    unsigned yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
    unsigned dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
    unsigned mp = (5 * dayOfYear + 2) / 153;
    *day = dayOfYear - (153 * mp + 2) / 5 + 1;
    *month = mp < 10 ? mp + 3 : mp - 9;
    *year = (int64_t)yearOfEra + era * 400 + (*month <= 2);
}

static int LSReadDigits(const char **cursor, int count, int *value) {
    int result = 0;
    for (int index = 0; index < count; index++) {
        if (!isdigit((unsigned char)**cursor)) return 0;
        result = result * 10 + (**cursor - '0');
        (*cursor)++;
    }
    *value = result;
    return 1;
}

double LSParseISO8601(const char *text) {
    if (!text) return NAN;
    const char *p = text;
    while (isspace((unsigned char)*p)) p++;
    int year, month, day, hour = 0, minute = 0, second = 0;
    if (!LSReadDigits(&p, 4, &year) || *p++ != '-' || !LSReadDigits(&p, 2, &month) || *p++ != '-' || !LSReadDigits(&p, 2, &day)) return NAN;
    double fraction = 0.0;
    if (*p == 'T' || *p == 't' || *p == ' ') {
        p++;
        if (!LSReadDigits(&p, 2, &hour) || *p++ != ':' || !LSReadDigits(&p, 2, &minute)) return NAN;
        if (*p == ':') {
            p++;
            if (!LSReadDigits(&p, 2, &second)) return NAN;
            if (*p == '.' || *p == ',') {
                p++;
                double scale = 0.1;
                if (!isdigit((unsigned char)*p)) return NAN;
                while (isdigit((unsigned char)*p)) { fraction += (*p - '0') * scale; scale /= 10.0; p++; }
            }
        }
    }
    int offset = 0;
    if (*p == 'Z' || *p == 'z') {
        p++;
    } else if (*p == '+' || *p == '-') {
        int sign = *p == '-' ? -1 : 1, offsetHours = 0, offsetMinutes = 0;
        p++;
        if (!LSReadDigits(&p, 2, &offsetHours)) return NAN;
        if (*p == ':') p++;
        if (isdigit((unsigned char)*p) && !LSReadDigits(&p, 2, &offsetMinutes)) return NAN;
        if (offsetHours > 23 || offsetMinutes > 59) return NAN;
        offset = sign * (offsetHours * 3600 + offsetMinutes * 60);
    }
    while (isspace((unsigned char)*p)) p++;
    if (*p) return NAN;
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 24 || minute > 59 || second > 60) return NAN;
    int64_t days = LSDaysFromCivil(year, (unsigned)month, (unsigned)day);
    return (double)(days * 86400 + hour * 3600 + minute * 60 + second - offset) + fraction;
}

void LSFormatISO8601(double unixSeconds, int milliseconds, char *buffer, size_t size) {
    if (!buffer || size == 0) return;
    if (!isfinite(unixSeconds)) { buffer[0] = 0; return; }
    double whole = floor(unixSeconds);
    int millis = (int)llround((unixSeconds - whole) * 1000.0);
    if (millis >= 1000) { whole += 1; millis -= 1000; }
    int64_t seconds = (int64_t)whole;
    int64_t days = seconds >= 0 ? seconds / 86400 : -((-seconds + 86399) / 86400);
    int64_t rest = seconds - days * 86400;
    int64_t year;
    unsigned month, day;
    LSCivilFromDays(days, &year, &month, &day);
    if (milliseconds || millis) {
        snprintf(buffer, size, "%04lld-%02u-%02uT%02d:%02d:%02d.%03dZ", (long long)year, month, day,
                 (int)(rest / 3600), (int)(rest % 3600 / 60), (int)(rest % 60), millis);
    } else {
        snprintf(buffer, size, "%04lld-%02u-%02uT%02d:%02d:%02dZ", (long long)year, month, day,
                 (int)(rest / 3600), (int)(rest % 3600 / 60), (int)(rest % 60));
    }
}

// FIT

static const double kLSFitEpoch = 631065600.0;  // 1989-12-31T00:00:00Z
static const double kLSSemicircles = 2147483648.0 / 180.0;

static uint16_t LSFitCRC(uint16_t crc, uint8_t byte) {
    static const uint16_t table[16] = {0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                                       0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400};
    uint16_t tmp = table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ tmp ^ table[byte & 0xF];
    tmp = table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    return crc ^ tmp ^ table[(byte >> 4) & 0xF];
}

static uint16_t LSFitCRCBytes(const uint8_t *bytes, size_t length) {
    uint16_t crc = 0;
    for (size_t index = 0; index < length; index++) crc = LSFitCRC(crc, bytes[index]);
    return crc;
}

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
    int failed;
} LSBuffer;

static void LSPut8(LSBuffer *buffer, uint8_t value) {
    if (buffer->failed) return;
    if (buffer->length == buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity * 2 : 4096;
        uint8_t *bytes = realloc(buffer->bytes, capacity);
        if (!bytes) { buffer->failed = 1; return; }
        buffer->bytes = bytes;
        buffer->capacity = capacity;
    }
    buffer->bytes[buffer->length++] = value;
}
static void LSPut16(LSBuffer *buffer, uint16_t value) { LSPut8(buffer, value & 0xFF); LSPut8(buffer, value >> 8); }
static void LSPut32(LSBuffer *buffer, uint32_t value) { LSPut16(buffer, value & 0xFFFF); LSPut16(buffer, value >> 16); }

typedef struct { uint8_t number, size, type; } LSFitField;

static void LSFitDefine(LSBuffer *buffer, uint8_t local, uint16_t global, const LSFitField *fields, uint8_t count) {
    LSPut8(buffer, 0x40 | local);
    LSPut8(buffer, 0);      // reserved
    LSPut8(buffer, 0);      // little endian
    LSPut16(buffer, global);
    LSPut8(buffer, count);
    for (uint8_t index = 0; index < count; index++) {
        LSPut8(buffer, fields[index].number);
        LSPut8(buffer, fields[index].size);
        LSPut8(buffer, fields[index].type);
    }
}

static uint32_t LSFitTime(double unixSeconds) {
    double value = floor(unixSeconds - kLSFitEpoch);
    return value > 0 && value < 4294967295.0 ? (uint32_t)value : 0;
}
static uint32_t LSFitSemicircles(double degrees) {
    double value = round(degrees * kLSSemicircles);
    if (value > 2147483647.0) value = 2147483647.0;
    if (value < -2147483647.0) value = -2147483647.0;
    return (uint32_t)(int32_t)value;
}
static uint16_t LSFitScaled16(double value, double scale, double offset) {
    if (!isfinite(value)) return 0xFFFF;
    double scaled = round((value + offset) * scale);
    return scaled >= 0 && scaled < 65535.0 ? (uint16_t)scaled : 0xFFFF;
}
static uint32_t LSFitScaled32(double value, double scale, double offset) {
    if (!isfinite(value)) return 0xFFFFFFFF;
    double scaled = round((value + offset) * scale);
    return scaled >= 0 && scaled < 4294967295.0 ? (uint32_t)scaled : 0xFFFFFFFF;
}

size_t LSFitEncodeActivity(const LSTrackPoint *points, size_t count, int sport, uint8_t **out) {
    if (!out) return 0;
    *out = NULL;
    if (!points || count < 2) return 0;
    for (size_t index = 0; index < count; index++) {
        if (!isfinite(points[index].time) || !isfinite(points[index].latitude) || !isfinite(points[index].longitude)) return 0;
    }
    double startTime = points[0].time, endTime = points[count - 1].time;
    if (!(endTime >= startTime)) return 0;
    LSBuffer buffer = {0};
    for (int index = 0; index < 14; index++) LSPut8(&buffer, 0);   // header, filled in below

    static const LSFitField fileID[] = {{0, 1, 0x00}, {1, 2, 0x84}, {2, 2, 0x84}, {3, 4, 0x8C}, {4, 4, 0x86}};
    LSFitDefine(&buffer, 0, 0, fileID, 5);
    LSPut8(&buffer, 0);
    LSPut8(&buffer, 4);                 // activity file
    LSPut16(&buffer, 255);              // development manufacturer
    LSPut16(&buffer, 0);
    LSPut32(&buffer, 0x4C53504Fu);      // "LSPO"
    LSPut32(&buffer, LSFitTime(startTime));

    static const LSFitField event[] = {{253, 4, 0x86}, {0, 1, 0x00}, {1, 1, 0x00}};
    LSFitDefine(&buffer, 1, 21, event, 3);
    LSPut8(&buffer, 1);
    LSPut32(&buffer, LSFitTime(startTime));
    LSPut8(&buffer, 0);                 // timer
    LSPut8(&buffer, 0);                 // start

    static const LSFitField record[] = {{253, 4, 0x86}, {0, 4, 0x85}, {1, 4, 0x85}, {2, 2, 0x84}, {5, 4, 0x86}, {6, 2, 0x84}, {73, 4, 0x86}};
    LSFitDefine(&buffer, 2, 20, record, 7);
    double maxSpeed = 0.0, totalDistance = 0.0;
    for (size_t index = 0; index < count; index++) {
        const LSTrackPoint *point = &points[index];
        LSPut8(&buffer, 2);
        LSPut32(&buffer, LSFitTime(point->time));
        LSPut32(&buffer, LSFitSemicircles(point->latitude));
        LSPut32(&buffer, LSFitSemicircles(point->longitude));
        LSPut16(&buffer, LSFitScaled16(point->altitude, 5.0, 500.0));
        LSPut32(&buffer, LSFitScaled32(point->distance, 100.0, 0.0));
        LSPut16(&buffer, LSFitScaled16(point->speed, 1000.0, 0.0));
        LSPut32(&buffer, LSFitScaled32(point->speed, 1000.0, 0.0));
        if (isfinite(point->speed) && point->speed > maxSpeed) maxSpeed = point->speed;
        if (isfinite(point->distance) && point->distance > totalDistance) totalDistance = point->distance;
    }

    LSPut8(&buffer, 1);
    LSPut32(&buffer, LSFitTime(endTime));
    LSPut8(&buffer, 0);                 // timer
    LSPut8(&buffer, 4);                 // stop all

    double elapsed = endTime - startTime;
    double average = elapsed > 0 ? totalDistance / elapsed : 0.0;
    const LSTrackPoint *first = &points[0], *last = &points[count - 1];
    static const LSFitField lap[] = {{253, 4, 0x86}, {254, 2, 0x84}, {2, 4, 0x86}, {3, 4, 0x85}, {4, 4, 0x85}, {5, 4, 0x85}, {6, 4, 0x85},
                                     {7, 4, 0x86}, {8, 4, 0x86}, {9, 4, 0x86}, {13, 2, 0x84}, {14, 2, 0x84}, {0, 1, 0x00}, {1, 1, 0x00}, {25, 1, 0x00}};
    LSFitDefine(&buffer, 3, 19, lap, 15);
    LSPut8(&buffer, 3);
    LSPut32(&buffer, LSFitTime(endTime));
    LSPut16(&buffer, 0);
    LSPut32(&buffer, LSFitTime(startTime));
    LSPut32(&buffer, LSFitSemicircles(first->latitude));
    LSPut32(&buffer, LSFitSemicircles(first->longitude));
    LSPut32(&buffer, LSFitSemicircles(last->latitude));
    LSPut32(&buffer, LSFitSemicircles(last->longitude));
    LSPut32(&buffer, LSFitScaled32(elapsed, 1000.0, 0.0));
    LSPut32(&buffer, LSFitScaled32(elapsed, 1000.0, 0.0));
    LSPut32(&buffer, LSFitScaled32(totalDistance, 100.0, 0.0));
    LSPut16(&buffer, LSFitScaled16(average, 1000.0, 0.0));
    LSPut16(&buffer, LSFitScaled16(maxSpeed, 1000.0, 0.0));
    LSPut8(&buffer, 9);                 // lap
    LSPut8(&buffer, 1);                 // stop
    LSPut8(&buffer, (uint8_t)sport);

    static const LSFitField session[] = {{253, 4, 0x86}, {254, 2, 0x84}, {2, 4, 0x86}, {3, 4, 0x85}, {4, 4, 0x85}, {7, 4, 0x86}, {8, 4, 0x86},
                                         {9, 4, 0x86}, {14, 2, 0x84}, {15, 2, 0x84}, {25, 2, 0x84}, {26, 2, 0x84}, {0, 1, 0x00}, {1, 1, 0x00},
                                         {5, 1, 0x00}, {6, 1, 0x00}};
    LSFitDefine(&buffer, 4, 18, session, 16);
    LSPut8(&buffer, 4);
    LSPut32(&buffer, LSFitTime(endTime));
    LSPut16(&buffer, 0);
    LSPut32(&buffer, LSFitTime(startTime));
    LSPut32(&buffer, LSFitSemicircles(first->latitude));
    LSPut32(&buffer, LSFitSemicircles(first->longitude));
    LSPut32(&buffer, LSFitScaled32(elapsed, 1000.0, 0.0));
    LSPut32(&buffer, LSFitScaled32(elapsed, 1000.0, 0.0));
    LSPut32(&buffer, LSFitScaled32(totalDistance, 100.0, 0.0));
    LSPut16(&buffer, LSFitScaled16(average, 1000.0, 0.0));
    LSPut16(&buffer, LSFitScaled16(maxSpeed, 1000.0, 0.0));
    LSPut16(&buffer, 0);
    LSPut16(&buffer, 1);
    LSPut8(&buffer, 8);                 // session
    LSPut8(&buffer, 1);                 // stop
    LSPut8(&buffer, (uint8_t)sport);
    LSPut8(&buffer, 0);                 // generic sub sport

    static const LSFitField activity[] = {{253, 4, 0x86}, {0, 4, 0x86}, {1, 2, 0x84}, {2, 1, 0x00}, {3, 1, 0x00}, {4, 1, 0x00}};
    LSFitDefine(&buffer, 5, 34, activity, 6);
    LSPut8(&buffer, 5);
    LSPut32(&buffer, LSFitTime(endTime));
    LSPut32(&buffer, LSFitScaled32(elapsed, 1000.0, 0.0));
    LSPut16(&buffer, 1);
    LSPut8(&buffer, 0);                 // manual
    LSPut8(&buffer, 26);                // activity
    LSPut8(&buffer, 1);                 // stop

    if (buffer.failed || buffer.length < 14) { free(buffer.bytes); return 0; }
    uint32_t dataSize = (uint32_t)(buffer.length - 14);
    uint8_t *header = buffer.bytes;
    header[0] = 14;
    header[1] = 0x10;                   // protocol 1.0
    header[2] = 2132 & 0xFF;            // profile 21.32
    header[3] = 2132 >> 8;
    header[4] = dataSize & 0xFF;
    header[5] = (dataSize >> 8) & 0xFF;
    header[6] = (dataSize >> 16) & 0xFF;
    header[7] = (dataSize >> 24) & 0xFF;
    memcpy(header + 8, ".FIT", 4);
    uint16_t headerCRC = LSFitCRCBytes(header, 12);
    header[12] = headerCRC & 0xFF;
    header[13] = headerCRC >> 8;
    uint16_t fileCRC = LSFitCRCBytes(buffer.bytes, buffer.length);
    LSPut16(&buffer, fileCRC);
    if (buffer.failed) { free(buffer.bytes); return 0; }
    *out = buffer.bytes;
    return buffer.length;
}

int LSFitLooksLikeFit(const uint8_t *data, size_t length) {
    return data && length >= 12 && (data[0] == 12 || data[0] == 14) && memcmp(data + 8, ".FIT", 4) == 0;
}

typedef struct {
    int defined;
    int bigEndian;
    uint16_t global;
    uint8_t fieldCount;
    LSFitField fields[255];
    size_t developerBytes;
} LSFitDefinition;

static uint64_t LSFitRead(const uint8_t *bytes, size_t size, int bigEndian) {
    uint64_t value = 0;
    for (size_t index = 0; index < size; index++) {
        uint8_t byte = bigEndian ? bytes[index] : bytes[size - 1 - index];
        value = (value << 8) | byte;
    }
    return value;
}

size_t LSFitDecodeRecords(const uint8_t *data, size_t length, LSTrackPoint **out) {
    if (!out) return 0;
    *out = NULL;
    if (!LSFitLooksLikeFit(data, length)) return 0;
    size_t headerSize = data[0];
    if (length < headerSize) return 0;
    uint32_t dataSize = (uint32_t)LSFitRead(data + 4, 4, 0);
    size_t end = headerSize + (size_t)dataSize;
    if (end > length || dataSize == 0) end = length;
    LSFitDefinition *definitions = calloc(16, sizeof(LSFitDefinition));
    if (!definitions) return 0;
    size_t count = 0, capacity = 0;
    LSTrackPoint *points = NULL;
    uint32_t lastTimestamp = 0;
    int haveTimestamp = 0, failed = 0;
    size_t position = headerSize;
    while (position < end && !failed) {
        uint8_t header = data[position++];
        int compressed = header & 0x80;
        uint8_t local = compressed ? (header >> 5) & 0x03 : header & 0x0F;
        if (!compressed && (header & 0x40)) {
            if (position + 5 > end) { failed = 1; break; }
            LSFitDefinition *definition = &definitions[local];
            definition->bigEndian = data[position + 1] == 1;
            definition->global = (uint16_t)LSFitRead(data + position + 2, 2, definition->bigEndian);
            definition->fieldCount = data[position + 4];
            position += 5;
            if (position + (size_t)definition->fieldCount * 3 > end) { failed = 1; break; }
            for (uint8_t index = 0; index < definition->fieldCount; index++) {
                definition->fields[index].number = data[position];
                definition->fields[index].size = data[position + 1];
                definition->fields[index].type = data[position + 2];
                position += 3;
            }
            definition->developerBytes = 0;
            if (header & 0x20) {
                if (position >= end) { failed = 1; break; }
                uint8_t developerCount = data[position++];
                if (position + (size_t)developerCount * 3 > end) { failed = 1; break; }
                for (uint8_t index = 0; index < developerCount; index++) definition->developerBytes += data[position + 3 * index + 1];
                position += (size_t)developerCount * 3;
            }
            definition->defined = 1;
            continue;
        }
        LSFitDefinition *definition = &definitions[local];
        if (!definition->defined) { failed = 1; break; }
        double time = NAN;
        if (compressed) {
            uint32_t offset = header & 0x1F;
            uint32_t timestamp = (lastTimestamp & ~0x1Fu) + offset;
            if (offset < (lastTimestamp & 0x1F)) timestamp += 0x20;
            lastTimestamp = timestamp;
            if (haveTimestamp) time = timestamp + kLSFitEpoch;
        }
        int32_t latitude = 0x7FFFFFFF, longitude = 0x7FFFFFFF;
        double altitude = NAN, speed = NAN, distance = NAN;
        for (uint8_t index = 0; index < definition->fieldCount; index++) {
            LSFitField field = definition->fields[index];
            if (position + field.size > end) { failed = 1; break; }
            const uint8_t *bytes = data + position;
            position += field.size;
            if (field.number == 253 && field.size == 4) {
                uint32_t value = (uint32_t)LSFitRead(bytes, 4, definition->bigEndian);
                if (value != 0xFFFFFFFF) { lastTimestamp = value; haveTimestamp = 1; time = value + kLSFitEpoch; }
                continue;
            }
            if (definition->global != 20) continue;
            if (field.number == 0 && field.size == 4) latitude = (int32_t)(uint32_t)LSFitRead(bytes, 4, definition->bigEndian);
            else if (field.number == 1 && field.size == 4) longitude = (int32_t)(uint32_t)LSFitRead(bytes, 4, definition->bigEndian);
            else if (field.number == 2 && field.size == 2 && !isfinite(altitude)) {
                uint16_t value = (uint16_t)LSFitRead(bytes, 2, definition->bigEndian);
                if (value != 0xFFFF) altitude = value / 5.0 - 500.0;
            } else if (field.number == 78 && field.size == 4) {
                uint32_t value = (uint32_t)LSFitRead(bytes, 4, definition->bigEndian);
                if (value != 0xFFFFFFFF) altitude = value / 5.0 - 500.0;
            } else if (field.number == 6 && field.size == 2 && !isfinite(speed)) {
                uint16_t value = (uint16_t)LSFitRead(bytes, 2, definition->bigEndian);
                if (value != 0xFFFF) speed = value / 1000.0;
            } else if (field.number == 73 && field.size == 4) {
                uint32_t value = (uint32_t)LSFitRead(bytes, 4, definition->bigEndian);
                if (value != 0xFFFFFFFF) speed = value / 1000.0;
            } else if (field.number == 5 && field.size == 4) {
                uint32_t value = (uint32_t)LSFitRead(bytes, 4, definition->bigEndian);
                if (value != 0xFFFFFFFF) distance = value / 100.0;
            }
        }
        if (failed) break;
        if (position + definition->developerBytes > end) { failed = 1; break; }
        position += definition->developerBytes;
        if (definition->global != 20 || latitude == 0x7FFFFFFF || longitude == 0x7FFFFFFF) continue;
        double lat = latitude / kLSSemicircles, lon = longitude / kLSSemicircles;
        if (!(fabs(lat) <= 90.0) || !(fabs(lon) <= 180.0)) continue;
        if (count == capacity) {
            if (capacity >= 200000) break;
            size_t next = capacity ? capacity * 2 : 1024;
            LSTrackPoint *grown = realloc(points, next * sizeof(LSTrackPoint));
            if (!grown) { failed = 1; break; }
            points = grown;
            capacity = next;
        }
        points[count++] = (LSTrackPoint){time, lat, lon, altitude, distance, speed};
    }
    free(definitions);
    if (!count) { free(points); return 0; }
    *out = points;
    return count;
}
