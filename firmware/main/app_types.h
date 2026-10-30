#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * 跨模块共享的线格式数据类型。
 *
 * 设计要点：全部用整数表示物理量。原因有两条——
 *   1) sdkconfig 启用了 CONFIG_NEWLIB_NANO_FORMAT，printf 不支持 %f；
 *   2) 定点数在跨任务传递时没有浮点舍入差异，比较与去重更可靠。
 * 与文档的换算关系写在每个字段的注释里。
 */

#define BKL_PROTOCOL_VERSION 1

/* 角度以 1e-7 度（WGS-84 十进制 7 位）存储，与 GPS 原始精度匹配。 */
typedef int32_t bkl_e7_t;

/* 海拔未知时使用该哨兵值；勿与 0（海平面）混淆。 */
#define BKL_ALT_UNKNOWN INT32_MIN

typedef enum {
    BKL_FIX_NONE = 0,
    BKL_FIX_2D   = 2,
    BKL_FIX_3D   = 3,
} bkl_fix_t;

typedef struct {
    uint32_t seq;          /* 设备单调序号，每点独占，见 docs/protocol.md §3.1 */
    int64_t  ts_s;         /* UTC epoch 秒；0 表示时间未知 */
    bkl_e7_t lat;          /* 度 * 1e7 */
    bkl_e7_t lon;          /* 度 * 1e7 */
    int32_t  alt_cm;       /* 海拔厘米，或 BKL_ALT_UNKNOWN */
    uint32_t speed_mm_s;   /* 速度 mm/s（协议要求 m/s，编码时换算） */
    uint16_t course_cdeg;  /* 航向 0.01 度 */
    uint16_t hdop_x10;     /* HDOP * 10；0 表示未知 */
    uint16_t acc_dm;       /* 水平误差分米；0 表示未知 */
    uint8_t  fix;          /* bkl_fix_t */
} bkl_point_t;

typedef struct {
    int millivolts;        /* 电池电压 mV */
    int percent;           /* 0-100；-1 表示未知 */
} bkl_battery_t;

/* 度 → 定点。超出 int32 范围的双精度值会被截断，调用方应先校验范围。 */
bkl_e7_t bkl_e7_from_deg(double deg);

/* 定点 → 度。 */
double bkl_e7_to_deg(bkl_e7_t v);

/* 坐标与 fix 是否构成一个可上报的点。 */
bool bkl_point_is_valid(const bkl_point_t *p);
