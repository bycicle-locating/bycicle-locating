#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

/*
 * EC800M 的 AT 指令引擎。
 *
 * ⚠️ 全工程只有 modem/ 目录允许出现 AT 指令字符串与 URC 前缀解析。
 * 其他模块（采样、上报、电源）只调用本接口，不知道模组型号。
 *
 * 实现要点（M1）：
 *   - 单写线程 + 单读线程：写指令与解析 URC 不能互相阻塞；
 *   - 每条指令带超时，超时后必须回到干净状态（\r\n 清缓冲 + 重试一次）；
 *   - URC 随时可能插到指令回显中间，必须按行解析而不是按次读取；
 *   - 具体指令见《ECx00x&EG800K&EG810M&EG91xN&EG915K&EG950A Series AT Commands Manual》，
 *     引用时在代码注释里写上章节号。
 */

#define BKL_AT_LINE_MAX 256

/* URC 回调：收到不含指令回显的独立行时调用。返回 0 表示已处理。 */
typedef int (*bkl_urc_handler_t)(const char *line, void *ctx);

/* 打开 UART 并让模组进入可接受指令的状态。 */
esp_err_t bkl_at_init(int uart_num, int tx_gpio, int rx_gpio, int baud);

/* 发送一条指令并等待期望前缀。out 为 NULL 时不回传内容。 */
esp_err_t bkl_at_cmd(const char *cmd, const char *expect_prefix,
                     char *out, size_t out_cap, uint32_t timeout_ms);

/* 注册 URC 处理器，可多次调用。 */
esp_err_t bkl_at_register_urc(bkl_urc_handler_t handler, void *ctx);

/* 模组是否已完成上电初始化（能稳定回应 AT）。 */
bool bkl_at_ready(void);
