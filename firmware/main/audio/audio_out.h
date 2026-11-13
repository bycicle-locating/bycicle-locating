#pragma once

#include <stdbool.h>

#include "esp_err.h"

#include "tone_gen.h"

/*
 * 提示音输出：I²S 数字功放模块（docs/hardware.md §3.2）。
 *
 * 约束：
 *   - 采样路径不得阻塞在音频上：play 系列只入队，真正写 I²S 在独立任务里；
 *   - 空闲时关闭 I²S 通道，不给功放白送时钟与底噪（M4 低功耗阶段还会关功放使能脚）；
 *   - 引脚来自 Kconfig（CONFIG_BKL_AUDIO_LRCLK / BCLK / DIN），不在代码里硬编码接线。
 *
 * 状态：M1 实现，**尚未在 ESP-IDF 下编译验证**（本机没装 IDF），接口与主机可测部分见
 * test/host/test_audio.c。
 */

/* 安装 I²S 通道并启动播放任务。引脚非法/通道被占用时返回错误。 */
esp_err_t bkl_audio_init(void);

/* 入队一段提示音；队列满时返回 ESP_ERR_TIMEOUT，调用方不应阻塞等待。 */
esp_err_t bkl_audio_play(const bkl_beep_pattern_t *pattern);

/* 「找车」提示音：2 kHz 短促 3 声，总长约 0.6 s。 */
esp_err_t bkl_audio_find_me(void);

/* 是否正在播放。 */
bool bkl_audio_playing(void);
