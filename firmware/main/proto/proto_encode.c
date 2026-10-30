#include "proto_encode.h"

#include <stdarg.h>
#include <stdio.h>

/* "2026-10-30T06:12:03Z" + NUL */
#define ISO8601_LEN 21

/* 追加格式化内容，返回新的偏移；空间不足或已出错时返回 -1。 */
static int appendf(char *buf, size_t cap, int off, const char *fmt, ...)
{
    if (off < 0 || (size_t)off >= cap) {
        return -1;
    }
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + off, cap - (size_t)off, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= cap - (size_t)off) {
        return -1;
    }
    return off + n;
}

/*
 * epoch 秒 → UTC 年月日时分秒。
 *
 * 不用 gmtime_r：它在严格 C11 下需要 _POSIX_C_SOURCE 才能声明，
 * 且行为受 libc 时区实现影响。自己算保证主机与目标机结果完全一致，
 * 也省掉一个 time.h 依赖。算法取自 Howard Hinnant 的 civil_from_days。
 */
static void epoch_to_civil(int64_t ts, int *year, int *month, int *day,
                           int *hour, int *minute, int *second)
{
    int64_t days = ts / 86400;
    int64_t rem = ts % 86400;
    if (rem < 0) {
        rem += 86400;
        days -= 1;
    }
    *hour = (int)(rem / 3600);
    *minute = (int)((rem % 3600) / 60);
    *second = (int)(rem % 60);

    int64_t z = days + 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    int64_t doe = z - era * 146097;                                        /* [0, 146096] */
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;    /* [0, 399] */
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);                  /* [0, 365] */
    int64_t mp = (5 * doy + 2) / 153;                                       /* [0, 11] */
    int64_t d = doy - (153 * mp + 2) / 5 + 1;                               /* [1, 31] */
    int64_t m = (mp < 10) ? mp + 3 : mp - 9;                                /* [1, 12] */
    *year = (int)(y + (m <= 2));
    *month = (int)m;
    *day = (int)d;
}

static int format_iso8601(int64_t ts_s, char out[ISO8601_LEN])
{
    int year, month, day, hour, minute, second;
    epoch_to_civil(ts_s, &year, &month, &day, &hour, &minute, &second);

    int n = snprintf(out, ISO8601_LEN, "%04d-%02d-%02dT%02d:%02d:%02dZ",
                     year, month, day, hour, minute, second);
    return (n == ISO8601_LEN - 1) ? 0 : -1;
}

/* 把 value/from_scale 四舍五入到 decimals 位小数的整数表示。 */
static int64_t scale_round(int64_t value, int32_t from_scale, int decimals)
{
    if (from_scale <= 0 || decimals < 0) {
        return 0;
    }
    int64_t unit = 1;
    for (int i = 0; i < decimals; i++) {
        unit *= 10;
    }
    int64_t num = value * unit;
    if (num >= 0) {
        return (num + from_scale / 2) / from_scale;
    }
    return (num - from_scale / 2) / from_scale;
}

/* 用整数运算输出定点小数，替代不可用的 %f。 */
static int append_scaled(char *buf, size_t cap, int off, int64_t value,
                         int32_t from_scale, int decimals)
{
    if (decimals < 0 || decimals > 7) {
        return -1;
    }
    int64_t scaled = scale_round(value, from_scale, decimals);
    bool neg = scaled < 0;
    uint64_t mag = neg ? (uint64_t)(-scaled) : (uint64_t)scaled;

    uint64_t unit = 1;
    for (int i = 0; i < decimals; i++) {
        unit *= 10;
    }
    uint64_t whole = mag / unit;
    uint64_t frac = mag % unit;

    if (neg) {
        off = appendf(buf, cap, off, "-");
    }
    off = appendf(buf, cap, off, "%llu", (unsigned long long)whole);
    if (decimals > 0 && off >= 0) {
        off = appendf(buf, cap, off, ".");
        /* 补足前导零：0.05 而不是 0.5 */
        uint64_t cut = unit / 10;
        while (cut > 1 && frac < cut) {
            off = appendf(buf, cap, off, "0");
            if (off < 0) {
                return -1;
            }
            cut /= 10;
        }
        off = appendf(buf, cap, off, "%llu", (unsigned long long)frac);
    }
    return off;
}

static int append_point(char *buf, size_t cap, int off, const bkl_point_t *p)
{
    char ts[ISO8601_LEN];
    if (format_iso8601(p->ts_s, ts) != 0) {
        return -1;
    }

    off = appendf(buf, cap, off, "{\"seq\":%lu,\"t\":\"%s\",\"lat\":",
                  (unsigned long)p->seq, ts);
    off = append_scaled(buf, cap, off, (int64_t)p->lat, 10000000, 7);
    off = appendf(buf, cap, off, ",\"lon\":");
    off = append_scaled(buf, cap, off, (int64_t)p->lon, 10000000, 7);
    off = appendf(buf, cap, off, ",\"spd\":");
    off = append_scaled(buf, cap, off, (int64_t)p->speed_mm_s, 1000, 2);
    off = appendf(buf, cap, off, ",\"crs\":");
    off = append_scaled(buf, cap, off, (int64_t)p->course_cdeg, 100, 1);

    if (p->alt_cm != BKL_ALT_UNKNOWN) {
        off = appendf(buf, cap, off, ",\"alt\":");
        off = append_scaled(buf, cap, off, (int64_t)p->alt_cm, 100, 1);
    }
    if (p->hdop_x10 > 0) {
        off = appendf(buf, cap, off, ",\"hdop\":");
        off = append_scaled(buf, cap, off, (int64_t)p->hdop_x10, 10, 1);
    }
    if (p->acc_dm > 0) {
        off = appendf(buf, cap, off, ",\"acc\":");
        off = append_scaled(buf, cap, off, (int64_t)p->acc_dm, 10, 1);
    }
    off = appendf(buf, cap, off, ",\"fix\":%u}", (unsigned)p->fix);
    return off;
}

static int append_battery(char *buf, size_t cap, int off, const bkl_battery_t *b)
{
    off = appendf(buf, cap, off, ",\"battery\":{\"mv\":%d", b->millivolts);
    if (b->percent >= 0) {
        off = appendf(buf, cap, off, ",\"pct\":%d", b->percent);
    }
    return appendf(buf, cap, off, "}");
}

int bkl_proto_encode_telemetry(char *buf, size_t cap, const bkl_telemetry_batch_t *batch)
{
    if (buf == NULL || cap == 0 || batch == NULL || batch->device_id == NULL) {
        return -1;
    }
    if (batch->points == NULL || batch->point_count == 0 ||
        batch->point_count > BKL_MAX_POINTS_PER_BATCH) {
        return -1;
    }

    char ts[ISO8601_LEN];
    if (format_iso8601(batch->ts_s, ts) != 0) {
        return -1;
    }

    int off = appendf(buf, cap, 0,
                      "{\"v\":%d,\"id\":\"%s\",\"seq\":%lu,\"ts\":\"%s\",\"type\":\"telemetry\"",
                      BKL_PROTOCOL_VERSION, batch->device_id,
                      (unsigned long)batch->seq, ts);
    if (batch->firmware != NULL) {
        off = appendf(buf, cap, off, ",\"fw\":\"%s\"", batch->firmware);
    }
    if (batch->battery != NULL) {
        off = append_battery(buf, cap, off, batch->battery);
    }
    if (batch->has_net) {
        off = appendf(buf, cap, off, ",\"net\":{\"rsrp\":%d}", batch->rsrp);
    }

    off = appendf(buf, cap, off, ",\"points\":[");
    for (size_t i = 0; i < batch->point_count; i++) {
        if (i > 0) {
            off = appendf(buf, cap, off, ",");
        }
        off = append_point(buf, cap, off, &batch->points[i]);
    }
    return appendf(buf, cap, off, "],\"dropped\":%lu}", (unsigned long)batch->dropped);
}

int bkl_proto_encode_status(char *buf, size_t cap, const bkl_status_t *status)
{
    if (buf == NULL || cap == 0 || status == NULL || status->device_id == NULL) {
        return -1;
    }

    char ts[ISO8601_LEN];
    if (format_iso8601(status->ts_s, ts) != 0) {
        return -1;
    }

    int off = appendf(buf, cap, 0,
                      "{\"v\":%d,\"id\":\"%s\",\"seq\":%lu,\"ts\":\"%s\",\"type\":\"status\","
                      "\"online\":%s,\"gpsFix\":%s,\"ble\":%s",
                      BKL_PROTOCOL_VERSION, status->device_id, (unsigned long)status->seq, ts,
                      status->online ? "true" : "false",
                      status->gps_fix ? "true" : "false",
                      status->ble_enabled ? "true" : "false");
    if (status->firmware != NULL) {
        off = appendf(buf, cap, off, ",\"fw\":\"%s\"", status->firmware);
    }
    if (status->battery != NULL) {
        off = append_battery(buf, cap, off, status->battery);
    }
    return appendf(buf, cap, off, "}");
}

int bkl_proto_encode_event(char *buf, size_t cap, const bkl_event_t *event)
{
    if (buf == NULL || cap == 0 || event == NULL || event->device_id == NULL ||
        event->event == NULL) {
        return -1;
    }

    char ts[ISO8601_LEN];
    if (format_iso8601(event->ts_s, ts) != 0) {
        return -1;
    }

    int off = appendf(buf, cap, 0,
                      "{\"v\":%d,\"id\":\"%s\",\"seq\":%lu,\"ts\":\"%s\",\"type\":\"event\","
                      "\"event\":\"%s\",\"level\":\"%s\"",
                      BKL_PROTOCOL_VERSION, event->device_id, (unsigned long)event->seq, ts,
                      event->event, event->level != NULL ? event->level : "info");
    if (event->firmware != NULL) {
        off = appendf(buf, cap, off, ",\"fw\":\"%s\"", event->firmware);
    }
    if (event->point != NULL && event->point->fix != BKL_FIX_NONE) {
        off = appendf(buf, cap, off, ",\"lat\":");
        off = append_scaled(buf, cap, off, (int64_t)event->point->lat, 10000000, 7);
        off = appendf(buf, cap, off, ",\"lon\":");
        off = append_scaled(buf, cap, off, (int64_t)event->point->lon, 10000000, 7);
    }
    return appendf(buf, cap, off, "}");
}
