#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"

/*
 * BLE 近场服务（GATT Peripheral），契约见 docs/pairing.md §5。
 *
 * ⚠️ 权限边界：本模块**不提供绑定/解绑能力**。
 * 绑定只由 App 触碰 NFC → 后端核验一次性声明码完成；
 * BLE 只暴露 device-info / status-notify / local-cmd 三类只读或本地动作。
 * 任何"连上蓝牙就算车主"的实现都视为严重缺陷。
 */

typedef struct {
    const char *device_id;
    const char *model;
    const char *firmware;
} bkl_ble_identity_t;

/* 初始化 GATT 表；NimBLE 的 host 栈在此启动。 */
esp_err_t bkl_ble_init(const bkl_ble_identity_t *identity);

/* 开/关广播。未绑定或近场连接结束后应关闭以省电。 */
esp_err_t bkl_ble_set_enabled(bool enabled);
bool bkl_ble_enabled(void);

/* 推送 status-notify（JSON，见 pairing.md §5.1）。 */
esp_err_t bkl_ble_publish_status(const char *json, size_t len);
