#include "modem_gnss.h"

#include "esp_log.h"

static const char *TAG = "bkl.gnss";

/*
 * M1 实现要点：
 *   - AT+QGPSLOC? 返回 `<lat>,<lon>,<alt>,<hdop>,<satellites>,<speed>,<course>,...`，
 *     单位与符号位需按手册换算：南纬/西经为负，速度单位是 km/h（协议要 m/s，
 *     因此 speed_mm_s = kmh * 1000000 / 3600）。
 *   - 没有定位时不要上报伪造坐标：置 fix=BKL_FIX_NONE 并让上层决定是否上报心跳。
 *   - AT+QGPSLOC? 在无定位时返回 +CME ERROR，属于正常情况，不要当致命错误。
 */

esp_err_t bkl_gnss_init(void)
{
    ESP_LOGW(TAG, "bkl_gnss_init 尚未实现（M1）");
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_gnss_power(bool on)
{
    (void)on;
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_gnss_read(bkl_gnss_fix_t *out)
{
    if (out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    out->valid = false;
    out->satellites = 0;
    return ESP_ERR_NOT_SUPPORTED;
}
