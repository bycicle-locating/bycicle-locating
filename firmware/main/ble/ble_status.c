#include "ble_status.h"

#include "esp_log.h"

static const char *TAG = "bkl.ble";

/*
 * M1 实现要点：
 *   - 用 NimBLE（比 Bluedroid 省 RAM），需在 CMakeLists.txt 加 REQUIRES bt，
 *     并启用 CONFIG_BT_ENABLED / CONFIG_BT_NIMBLE_ENABLED。
 *   - 广播名 `BKL-<deviceId 后 4 位>`，广播包内带 Service UUID 便于 App 过滤。
 *   - 单次写入默认 20 字节，必须实现 [seq][flags][payload] 分片重组（pairing.md §5.3）。
 *   - local-cmd 只接受 find / locate / read_battery / reboot；
 *     未知 op 回 not_supported，绝不要在此处打开任何绑定入口。
 *   - 连接空闲 60 s 后关闭广播，避免长期暴露。
 */

esp_err_t bkl_ble_init(const bkl_ble_identity_t *identity)
{
    if (identity == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    ESP_LOGW(TAG, "bkl_ble_init(device=%s) 尚未实现（M1）",
             identity->device_id != NULL ? identity->device_id : "(null)");
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_ble_set_enabled(bool enabled)
{
    (void)enabled;
    return ESP_ERR_NOT_SUPPORTED;
}

bool bkl_ble_enabled(void)
{
    return false;
}

esp_err_t bkl_ble_publish_status(const char *json, size_t len)
{
    (void)json;
    (void)len;
    return ESP_ERR_NOT_SUPPORTED;
}
