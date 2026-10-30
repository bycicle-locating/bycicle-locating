#include "modem_at.h"

#include "esp_log.h"

static const char *TAG = "bkl.at";

/*
 * M1 实现顺序建议：
 *   1. UART 驱动 + 环形接收缓冲（driver/uart.h）
 *   2. 行切分任务：把字节流拆成行，区分"指令回显/结果码/URC"
 *   3. bkl_at_cmd 用信号量等待匹配行，带超时
 *   4. 上电序列：AT → ATE0 → AT+CPIN? → AT+CREG? → AT+CGREG? → AT+QENG="servingcell"
 *   5. PSM/eDRX 配置并记录在 sdkconfig 之外（模组侧配置需持久化）
 *
 * 严禁在这些函数内部长时间忙等：看门狗 30 s，阻塞会给采样任务带来抖动。
 */

esp_err_t bkl_at_init(int uart_num, int tx_gpio, int rx_gpio, int baud)
{
    ESP_LOGW(TAG, "bkl_at_init(uart=%d, tx=%d, rx=%d, baud=%d) 尚未实现（M1）",
             uart_num, tx_gpio, rx_gpio, baud);
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_at_cmd(const char *cmd, const char *expect_prefix,
                     char *out, size_t out_cap, uint32_t timeout_ms)
{
    (void)cmd;
    (void)expect_prefix;
    (void)out;
    (void)out_cap;
    (void)timeout_ms;
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t bkl_at_register_urc(bkl_urc_handler_t handler, void *ctx)
{
    (void)handler;
    (void)ctx;
    return ESP_ERR_NOT_SUPPORTED;
}

bool bkl_at_ready(void)
{
    return false;
}
