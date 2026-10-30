#include "modem_mqtt.h"

#include "esp_log.h"

static const char *TAG = "bkl.mqtt";

/*
 * M1 实现注意：
 *   - 一次只允许一个在途发布（msgId 递增，等待 +QMTPUB 回执）；
 *   - TLS 需要先把 CA 写入模组文件系统（AT+QFUPL）或在 AT+QSSLCFG 里配置，
 *     设备侧必须校验证书，不能无条件信任（protocol.md §10）；
 *   - 连接断开后不要立刻重连：退避策略与 uploader 共用一处，避免两套定时器打架。
 */

esp_err_t bkl_mqtt_connect(const bkl_mqtt_config_t *cfg)
{
    if (cfg == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    ESP_LOGW(TAG, "bkl_mqtt_connect(%s:%u, tls=%d) 尚未实现（M1）",
             cfg->broker_host != NULL ? cfg->broker_host : "(null)",
             cfg->broker_port, cfg->use_tls ? 1 : 0);
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_mqtt_disconnect_graceful(void)
{
    /*
     * 睡眠前必须调用。broker 只在非正常断开时发遗嘱，
     * 主动断开不会触发 LWT，因此离线状态要由调用方自己发布
     * （见 docs/protocol.md §2.2 与 uploader 的 offline 流程）。
     */
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_mqtt_publish(const char *topic, const char *payload, size_t len,
                           uint8_t qos, bool retain)
{
    (void)topic;
    (void)payload;
    (void)len;
    (void)qos;
    (void)retain;
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_mqtt_subscribe_cmd(const char *device_id)
{
    (void)device_id;
    return ESP_ERR_NOT_SUPPORTED;
}

bool bkl_mqtt_connected(void)
{
    return false;
}
