#include "st25dv.h"

#include "esp_log.h"

static const char *TAG = "bkl.nfc";

/*
 * M1 实现顺序建议：
 *   1. I²C 主机初始化（与 MPU-6050 共用总线，ST25DV 从地址 0x53）；
 *   2. 读 UID 与 capability 寄存器确认芯片在线——这是最快的接线自检；
 *   3. 读 EEPROM 前 32 字节，确认 CC 已格式化；
 *   4. 写 NDEF：CC(块0) -> TLV(0x03) -> URI 记录（前缀码 0x04 表示 https://）；
 *   5. 写后读回逐字节比较；
 *   6. GPO 配置为 RF 场检测中断，写前检查。
 *
 * 注意 ST25DV 的 EEPROM 写入需要约 5 ms，写完要等内部写完成再读回，
 * 否则会读到旧内容并误判校验失败。
 *
 * 认证：不启用 I²C 写保护密码（ADR-0004 决定），因此任何能碰到 I²C 总线的人都能改写标签。
 * 这是可接受的——标签内容不是密钥，真正的授权在后端。
 */

esp_err_t bkl_st25dv_init(int i2c_port, int sda_gpio, int scl_gpio, int gpo_gpio)
{
    ESP_LOGW(TAG, "bkl_st25dv_init(i2c=%d, sda=%d, scl=%d, gpo=%d) 尚未实现（M1）",
             i2c_port, sda_gpio, scl_gpio, gpo_gpio);
    return ESP_ERR_NOT_SUPPORTED;
}

bool bkl_st25dv_rf_field(void)
{
    /* 保守返回 true：未实现时不允许任何写入发生。 */
    return true;
}

esp_err_t bkl_st25dv_read_uri(char *out, size_t cap)
{
    (void)out;
    (void)cap;
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_st25dv_write_bind_uri(const char *host, const char *device_id,
                                    const char *claim_code)
{
    (void)host;
    (void)device_id;
    (void)claim_code;
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_st25dv_write_raw(uint16_t offset, const void *data, size_t len)
{
    (void)offset;
    (void)data;
    (void)len;
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_st25dv_read_raw(uint16_t offset, void *out, size_t len)
{
    (void)offset;
    (void)out;
    (void)len;
    return ESP_ERR_NOT_SUPPORTED;
}
