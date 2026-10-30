#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

/*
 * 电源与睡眠策略。
 *
 * 目标：静止时降到 µA 级，骑行时保证采样不丢。
 * 关键约束：
 *   - 深度睡眠会重置 RAM，因此唤醒后必须从 NVS 恢复 ringbuf 元数据与 seq；
 *   - 睡眠前要发布 offline 状态并优雅断开 MQTT（LWT 不会因为主动断开而触发）；
 *   - 睡眠时长受 MQTT keepalive 影响，睡太久等于放弃会话，两者要一致。
 */

typedef enum {
    BKL_POWER_ACTIVE = 0,  /* 骑行中：GNSS 连续、上报频繁 */
    BKL_POWER_IDLE,        /* 静止但近期有震动：降频心跳 */
    BKL_POWER_SLEEP,       /* 深度睡眠，等定时/震动/按键唤醒 */
} bkl_power_mode_t;

esp_err_t bkl_power_init(void);

esp_err_t bkl_power_set_mode(bkl_power_mode_t mode);

/* 当前处于哪种模式。 */
bkl_power_mode_t bkl_power_mode(void);

/* 进入深度睡眠直到指定时刻（epoch 秒）；返回时说明是被唤醒的（不会返回则说明断电）。 */
esp_err_t bkl_power_deep_sleep_until(int64_t wake_at_s);
