#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "app_types.h"
#include "esp_err.h"

/*
 * GNSS 采样。底层是 EC800M 的 GNSS 部分（AT+QGPS / AT+QGPSLOC?），
 * 因此本模块只依赖 bkl_at_*，不直接碰 UART。
 *
 * ⚠️ 只有 GNSS 版本模组（EC800MCNGA / EC800MCNGD）才有这个能力，
 * 详见 docs/hardware.md §2。
 */

typedef struct {
    bool         valid;       /* 拿到定位且坐标合法 */
    uint8_t      satellites;  /* 参与解算的卫星数 */
    bkl_point_t  sample;      /* 已换算为定点；valid=false 时不要使用 */
} bkl_gnss_fix_t;

/* 打开 GNSS（AT+QGPS=1）。冷启动到首次定位可能超过 30 s，不要阻塞调用方。 */
esp_err_t bkl_gnss_init(void);

/* 关闭以省电（AT+QGPS=0）。深度睡眠前应调用。 */
esp_err_t bkl_gnss_power(bool on);

/* 读取一次定位结果。无定位时返回 ESP_ERR_NOT_FOUND 并置 valid=false。 */
esp_err_t bkl_gnss_read(bkl_gnss_fix_t *out);
