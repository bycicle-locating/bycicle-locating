/*
 * 纯 C 模块的主机单测：不依赖 ESP-IDF，可在普通 PC 上用 gcc 编译运行。
 *
 *   gcc -std=c11 -Wall -Wextra -Werror \
 *       -I main -I main/proto -I main/track \
 *       test/host/test_core.c main/app_types.c main/proto/proto_encode.c \
 *       main/track/ringbuf.c main/track/uploader.c -o test_core && ./test_core
 *
 * 覆盖三个最容易出错的地方：
 *   1) 定点小数的 JSON 格式化（不能用 %f）；
 *   2) 环形缓冲写满后的丢弃顺序与计数；
 *   3) 上报失败时不得 commit（宁可重传也不能丢点）。
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "app_types.h"
#include "proto_encode.h"
#include "ringbuf.h"
#include "uploader.h"

static int g_failures = 0;

#define CHECK(cond)                                                           \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);   \
            g_failures++;                                                     \
        }                                                                     \
    } while (0)

/* ---------- 定点换算 ---------- */

static void test_fixed_point(void)
{
    CHECK(bkl_e7_from_deg(31.2304) == 312304000);
    CHECK(bkl_e7_from_deg(-121.4737) == -1214737000);
    CHECK(bkl_e7_from_deg(0.0) == 0);
    /* 超出 ±180° 视为非法输入，返回 0 而不是溢出 */
    CHECK(bkl_e7_from_deg(200.0) == 0);
    CHECK(bkl_e7_from_deg(-200.0) == 0);

    bkl_point_t p;
    memset(&p, 0, sizeof(p));
    p.seq = 1;
    p.lat = 312304000;
    p.lon = 1214737000;
    p.fix = BKL_FIX_3D;
    CHECK(bkl_point_is_valid(&p));

    p.seq = 0;
    CHECK(!bkl_point_is_valid(&p));
    p.seq = 1;
    p.lat = 900000001; /* 超过 90° */
    CHECK(!bkl_point_is_valid(&p));
    p.lat = 312304000;
    p.fix = 1; /* 非法 fix */
    CHECK(!bkl_point_is_valid(&p));
    CHECK(!bkl_point_is_valid(NULL));
}

/* ---------- 编码 ---------- */

static void test_encode_telemetry(void)
{
    bkl_point_t pts[2];
    memset(pts, 0, sizeof(pts));

    pts[0].seq = 1042;
    pts[0].ts_s = 1793000000;
    pts[0].lat = 312304000;
    pts[0].lon = 1214737000;
    pts[0].alt_cm = 1240;
    pts[0].speed_mm_s = 6200;
    pts[0].course_cdeg = 18750;
    pts[0].hdop_x10 = 9;
    pts[0].acc_dm = 40;
    pts[0].fix = BKL_FIX_3D;

    /* 50 mm/s 必须编码成 0.05，验证小数补零 */
    pts[1] = pts[0];
    pts[1].seq = 1043;
    pts[1].ts_s = 1793000010;
    pts[1].speed_mm_s = 50;
    pts[1].alt_cm = BKL_ALT_UNKNOWN;

    bkl_battery_t batt = { .millivolts = 3890, .percent = 76 };
    bkl_telemetry_batch_t batch = {
        .device_id = "BKL-2026-000123",
        .firmware = "0.1.0",
        .seq = 1043,
        .ts_s = 1793000010,
        .points = pts,
        .point_count = 2,
        .battery = &batt,
        .rsrp = -92,
        .has_net = true,
        .dropped = 7,
    };

    char buf[2048];
    int n = bkl_proto_encode_telemetry(buf, sizeof(buf), &batch);
    CHECK(n > 0);
    if (n > 0) {
        CHECK(buf[n] == '\0');
        CHECK(strstr(buf, "\"v\":1") != NULL);
        CHECK(strstr(buf, "\"type\":\"telemetry\"") != NULL);
        CHECK(strstr(buf, "\"seq\":1042") != NULL);
        CHECK(strstr(buf, "\"lat\":31.2304000") != NULL);
        CHECK(strstr(buf, "\"lon\":121.4737000") != NULL);
        CHECK(strstr(buf, "\"spd\":6.20") != NULL);
        CHECK(strstr(buf, "\"spd\":0.05") != NULL);
        CHECK(strstr(buf, "\"crs\":187.5") != NULL);
        CHECK(strstr(buf, "\"alt\":12.4") != NULL);
        CHECK(strstr(buf, "\"hdop\":0.9") != NULL);
        CHECK(strstr(buf, "\"acc\":4.0") != NULL);
        CHECK(strstr(buf, "\"battery\":{\"mv\":3890,\"pct\":76}") != NULL);
        CHECK(strstr(buf, "\"dropped\":7") != NULL);
        /* 只有第一个点带 alt，第二个点应省略该字段 */
        CHECK(strstr(buf, "\"alt\"") == strstr(buf, "\"alt\":12.4"));
    }

    /* 缓冲区不足必须失败，而不是写出半截 JSON */
    char tiny[48];
    CHECK(bkl_proto_encode_telemetry(tiny, sizeof(tiny), &batch) == -1);

    /* 参数校验 */
    CHECK(bkl_proto_encode_telemetry(NULL, sizeof(buf), &batch) == -1);
    bkl_telemetry_batch_t empty = batch;
    empty.point_count = 0;
    CHECK(bkl_proto_encode_telemetry(buf, sizeof(buf), &empty) == -1);
}

static void test_encode_status_and_event(void)
{
    bkl_battery_t batt = { .millivolts = 3890, .percent = -1 }; /* 未知百分比 */
    bkl_status_t st = {
        .device_id = "BKL-2026-000123",
        .firmware = "0.1.0",
        .seq = 99,
        .ts_s = 1793000000,
        .online = true,
        .gps_fix = false,
        .ble_enabled = false,
        .battery = &batt,
    };
    char buf[512];
    int n = bkl_proto_encode_status(buf, sizeof(buf), &st);
    CHECK(n > 0);
    if (n > 0) {
        CHECK(strstr(buf, "\"online\":true") != NULL);
        CHECK(strstr(buf, "\"gpsFix\":false") != NULL);
        /* percent 为 -1 时不能出现 pct 字段 */
        CHECK(strstr(buf, "pct") == NULL);
    }

    bkl_point_t p;
    memset(&p, 0, sizeof(p));
    p.seq = 7;
    p.lat = 312304000;
    p.lon = 1214737000;
    p.fix = BKL_FIX_3D;

    bkl_event_t ev = {
        .device_id = "BKL-2026-000123",
        .firmware = "0.1.0",
        .seq = 7,
        .ts_s = 1793000000,
        .event = "motion",
        .level = "critical",
        .point = &p,
    };
    n = bkl_proto_encode_event(buf, sizeof(buf), &ev);
    CHECK(n > 0);
    if (n > 0) {
        CHECK(strstr(buf, "\"type\":\"event\"") != NULL);
        CHECK(strstr(buf, "\"event\":\"motion\"") != NULL);
        CHECK(strstr(buf, "\"level\":\"critical\"") != NULL);
        CHECK(strstr(buf, "\"lat\":31.2304000") != NULL);
    }

    /* 未定位时不应带坐标（避免上报伪造位置） */
    p.fix = BKL_FIX_NONE;
    n = bkl_proto_encode_event(buf, sizeof(buf), &ev);
    CHECK(n > 0);
    if (n > 0) {
        CHECK(strstr(buf, "\"lat\"") == NULL);
    }
}

/* ---------- 环形缓冲 ---------- */

#define TEST_SLOTS 3
static bkl_point_t g_slots[TEST_SLOTS];

static int mem_write(void *ctx, uint32_t off, const void *src, size_t len)
{
    if (off > sizeof(g_slots) || len > sizeof(g_slots) - off) {
        return -1;
    }
    memcpy((uint8_t *)ctx + off, src, len);
    return 0;
}

static int mem_read(void *ctx, uint32_t off, void *dst, size_t len)
{
    if (off > sizeof(g_slots) || len > sizeof(g_slots) - off) {
        return -1;
    }
    memcpy(dst, (const uint8_t *)ctx + off, len);
    return 0;
}

static void push_point(bkl_ringbuf_t *rb, uint32_t seq)
{
    bkl_point_t p;
    memset(&p, 0, sizeof(p));
    p.seq = seq;
    p.ts_s = 1793000000 + (int64_t)seq;
    p.fix = BKL_FIX_3D;
    CHECK(bkl_ringbuf_push(rb, &p) == 0);
}

static void test_ringbuf(void)
{
    bkl_ringbuf_t rb;
    bkl_ringbuf_io_t io = {
        .write = mem_write,
        .read = mem_read,
        .ctx = g_slots,
        .capacity = sizeof(g_slots),
    };
    CHECK(bkl_ringbuf_init(&rb, &io, sizeof(bkl_point_t)) == 0);
    CHECK(rb.slots == TEST_SLOTS);

    /* 空缓冲 */
    bkl_point_t out;
    CHECK(bkl_ringbuf_peek(&rb, 0, &out) == -1);
    CHECK(bkl_ringbuf_count(&rb) == 0);

    /* 写满后继续写：丢最旧，计数正确 */
    for (uint32_t i = 1; i <= 5; i++) {
        push_point(&rb, i);
    }
    CHECK(bkl_ringbuf_count(&rb) == TEST_SLOTS);
    CHECK(bkl_ringbuf_dropped(&rb) == 2);

    /* 最旧应该是 seq=3，最新是 seq=5 */
    CHECK(bkl_ringbuf_peek(&rb, 0, &out) == 0 && out.seq == 3);
    CHECK(bkl_ringbuf_peek(&rb, 2, &out) == 0 && out.seq == 5);
    CHECK(bkl_ringbuf_peek(&rb, 3, &out) == -1); /* 越界 */

    /* commit 掉两条后只剩最新一条 */
    CHECK(bkl_ringbuf_commit(&rb, 2) == 0);
    CHECK(bkl_ringbuf_count(&rb) == 1);
    CHECK(bkl_ringbuf_peek(&rb, 0, &out) == 0 && out.seq == 5);

    /* commit 超过总数不应把计数搞成负数 */
    CHECK(bkl_ringbuf_commit(&rb, 99) == 0);
    CHECK(bkl_ringbuf_count(&rb) == 0);

    /* 元数据损坏时恢复失败并按空缓冲处理 */
    CHECK(bkl_ringbuf_restore(&rb, 99, 0, 0, 0) == -1);
    CHECK(bkl_ringbuf_count(&rb) == 0);

    /* 容量不是记录大小整数倍时拒绝初始化 */
    bkl_ringbuf_io_t bad = io;
    bad.capacity = sizeof(g_slots) - 1;
    CHECK(bkl_ringbuf_init(&rb, &bad, sizeof(bkl_point_t)) == -1);
}

/* ---------- 上报状态机 ---------- */

static char g_last_payload[4096];
static int g_publish_calls = 0;
static int g_publish_fail = 0;

static int capture_publish(void *ctx, const char *topic, const char *payload,
                           size_t len, bool retain)
{
    (void)ctx;
    (void)topic;
    (void)retain;
    if (g_publish_fail) {
        return -1;
    }
    if (len >= sizeof(g_last_payload)) {
        return -1;
    }
    memcpy(g_last_payload, payload, len);
    g_last_payload[len] = '\0';
    g_publish_calls++;
    return 0;
}

static void test_uploader(void)
{
    bkl_ringbuf_t rb;
    bkl_ringbuf_io_t io = {
        .write = mem_write,
        .read = mem_read,
        .ctx = g_slots,
        .capacity = sizeof(g_slots),
    };
    CHECK(bkl_ringbuf_init(&rb, &io, sizeof(bkl_point_t)) == 0);

    for (uint32_t i = 1; i <= 3; i++) {
        push_point(&rb, i);
    }

    bkl_publish_fn_t transport = { .publish = capture_publish, .ctx = NULL };
    bkl_uploader_t up;
    CHECK(bkl_uploader_init(&up, "BKL-2026-000123", "0.1.0",
                            "v1/device/BKL-2026-000123/telemetry", transport, &rb, 10) == 0);

    char scratch[4096];
    uint32_t sent = 0;

    /* 发布失败：不得 commit，缓冲条数不变，且安排退避 */
    g_publish_fail = 1;
    bkl_upload_result_t r = bkl_uploader_step(&up, 1793000000, scratch, sizeof(scratch), &sent);
    CHECK(r == BKL_UPLOAD_ERROR);
    CHECK(sent == 0);
    CHECK(bkl_ringbuf_count(&rb) == 3);
    CHECK(bkl_uploader_next_attempt(&up) > 1793000000);

    /* 退避窗口内直接跳过 */
    r = bkl_uploader_step(&up, 1793000000, scratch, sizeof(scratch), &sent);
    CHECK(r == BKL_UPLOAD_BACKOFF);

    /* 窗口过后重试成功：一次发完 3 条并清空缓冲 */
    g_publish_fail = 0;
    g_publish_calls = 0;
    r = bkl_uploader_step(&up, 1793000100, scratch, sizeof(scratch), &sent);
    CHECK(r == BKL_UPLOAD_SENT);
    CHECK(sent == 3);
    CHECK(g_publish_calls == 1);
    CHECK(bkl_ringbuf_count(&rb) == 0);
    CHECK(strstr(g_last_payload, "\"type\":\"telemetry\"") != NULL);
    CHECK(strstr(g_last_payload, "\"seq\":3") != NULL); /* 本批最后一点的 seq */

    /* 空缓冲 */
    r = bkl_uploader_step(&up, 1793000200, scratch, sizeof(scratch), &sent);
    CHECK(r == BKL_UPLOAD_EMPTY);

    /* 编码空间不足：缩小批次而不是无限退避 */
    for (uint32_t i = 10; i <= 14; i++) {
        push_point(&rb, i); /* 缓冲只有 3 槽，最终留下 12,13,14 */
    }
    CHECK(bkl_ringbuf_count(&rb) == 3);
    char small[120];
    r = bkl_uploader_step(&up, 1793000300, small, sizeof(small), &sent);
    CHECK(r == BKL_UPLOAD_ERROR);
    CHECK(up.max_points_per_batch == 1); /* 3 条装不下 -> 改为 3/2 = 1 条 */
    CHECK(bkl_ringbuf_count(&rb) == 3);  /* 一个点都没丢 */
}

int main(void)
{
    test_fixed_point();
    test_encode_telemetry();
    test_encode_status_and_event();
    test_ringbuf();
    test_uploader();

    if (g_failures == 0) {
        printf("全部主机单测通过\n");
        return 0;
    }
    fprintf(stderr, "失败 %d 项\n", g_failures);
    return 1;
}
