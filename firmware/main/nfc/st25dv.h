#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

/*
 * ST25DV16K：I²C + ISO/IEC 15693（NFC Forum Type 5）双接口动态标签。
 * 契约见 docs/pairing.md §2 与 docs/adr/0004-st25dv16k-tag.md。
 *
 * 本模块只暴露"读写标签里的绑定 URI"这一件事。NDEF 的能力容器（CC）、TLV 与
 * URI 记录都由实现内部拼装，调用方只要给 deviceId + claimCode。
 *
 * 三条硬约束：
 *   1. 写之前必须确认没有 RF 场——手机正在读时写会失败甚至写坏，靠 GPO 判断；
 *   2. 写完必须读回校验，不一致就返回错误，不许谎报成功；
 *   3. 标签里除了 NDEF URI 不放任何密钥。
 */

/* "https://<host>/bind?d=<deviceId>&c=<claimCode>" 的长度上限，留足余量。 */
#define BKL_NDEF_URI_MAX 96

/* 初始化 I²C 与 GPO 中断。gpo_gpio 用于 RF 场检测，可传 -1 表示不接。 */
esp_err_t bkl_st25dv_init(int i2c_port, int sda_gpio, int scl_gpio, int gpo_gpio);

/* 当前是否有手机在场（RF 场存在）。写 NDEF 前必须为 false。 */
bool bkl_st25dv_rf_field(void);

/* 读出标签里的绑定 URI，结果以 NUL 结尾。未格式化或无 URI 返回 ESP_ERR_NOT_FOUND。 */
esp_err_t bkl_st25dv_read_uri(char *out, size_t cap);

/* 写入绑定 URI 并读回校验。 */
esp_err_t bkl_st25dv_write_bind_uri(const char *host, const char *device_id,
                                    const char *claim_code);

/* 产线与测试用的原始访问。写入同样受"无 RF 场"约束。 */
esp_err_t bkl_st25dv_write_raw(uint16_t offset, const void *data, size_t len);
esp_err_t bkl_st25dv_read_raw(uint16_t offset, void *out, size_t len);
