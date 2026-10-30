#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app_types.h"

/*
 * 把采样数据编码成 docs/protocol.md 规定的 JSON。
 *
 * 本模块是后端 internal/protocol 的对偶实现：只负责"结构化数据 → 字节"，
 * 不做网络、不做重试、不碰 flash。因此可以脱离硬件做纯逻辑测试。
 *
 * 约束：
 *   - 缓冲区不足时返回 -1，绝不写出半截 JSON（调用方据此回退到更小的批次）；
 *   - 不含 memset/sprintf 浮点，避免 CONFIG_NEWLIB_NANO_FORMAT 下 %f 不可用；
 *   - device_id 由产线保证是 `BKL-YYYY-NNNNNN` 形式，不做转义。
 */

/* 与后端 MaxPointsPerBatch 保持一致，改一处必须改另一处。 */
#define BKL_MAX_POINTS_PER_BATCH 60

typedef struct {
    const char *device_id;
    const char *firmware;          /* 可为 NULL */
    uint32_t seq;                  /* 本批最后一个点的 seq */
    int64_t ts_s;
    const bkl_point_t *points;
    size_t point_count;
    const bkl_battery_t *battery;  /* NULL 表示不带电量 */
    int rsrp;
    bool has_net;                  /* rsrp 是否有效 */
    uint32_t dropped;              /* 缓冲累计丢弃数 */
} bkl_telemetry_batch_t;

typedef struct {
    const char *device_id;
    const char *firmware;          /* 可为 NULL */
    uint32_t seq;
    int64_t ts_s;
    bool online;
    bool gps_fix;
    bool ble_enabled;
    const bkl_battery_t *battery;  /* NULL 表示不带电量 */
} bkl_status_t;

typedef struct {
    const char *device_id;
    const char *firmware;          /* 可为 NULL */
    uint32_t seq;
    int64_t ts_s;
    const char *event;             /* protocol.md §5 的枚举值 */
    const char *level;             /* info / warn / critical */
    const bkl_point_t *point;      /* 可为 NULL */
} bkl_event_t;

/* 返回写入的字节数（不含结尾 NUL），失败返回 -1。 */
int bkl_proto_encode_telemetry(char *buf, size_t cap, const bkl_telemetry_batch_t *batch);
int bkl_proto_encode_status(char *buf, size_t cap, const bkl_status_t *status);
int bkl_proto_encode_event(char *buf, size_t cap, const bkl_event_t *event);
