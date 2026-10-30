#include "power_mgr.h"

#include "esp_log.h"

static const char *TAG = "bkl.power";

/*
 * M1 实现要点：
 *   - 唤醒源：GPIO（按键、IMU 中断、模组 RI）+ 定时器；
 *   - esp_sleep_enable_timer_wakeup() 的时长取 min(上报间隔, keepalive 的 2/3)；
 *   - 进睡眠前：停 GNSS（AT+QGPS=0）→ 发 offline 状态 → 优雅断开 → esp_deep_sleep_start()；
 *   - 唤醒后重新初始化 AT、恢复 ringbuf 元数据、补传积压；
 *   - 用 RTC 内存保存 seq 高水位，避免每次唤醒都读 NVS。
 */

esp_err_t bkl_power_init(void)
{
    ESP_LOGW(TAG, "bkl_power_init 尚未实现（M1）");
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_power_set_mode(bkl_power_mode_t mode)
{
    ESP_LOGI(TAG, "切换电源模式 -> %d（策略待实现）", (int)mode);
    return ESP_ERR_NOT_SUPPORTED;
}

bkl_power_mode_t bkl_power_mode(void)
{
    return BKL_POWER_ACTIVE;
}

esp_err_t bkl_power_deep_sleep_until(int64_t wake_at_s)
{
    (void)wake_at_s;
    return ESP_ERR_NOT_SUPPORTED;
}
