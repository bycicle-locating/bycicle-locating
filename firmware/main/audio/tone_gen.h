#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * 提示音合成（纯 C，不依赖 ESP-IDF，可在主机上用 gcc 单测）。
 *
 * 为什么不是 LEDC/PWM：实物提示音模块是 I²S 数字功放（见 docs/hardware.md §3.2），
 * 只接受 I²S 串行 PCM；ESP32-S3 又没有 DAC，所以这里只负责"算出该播的 16 bit
 * 单声道 PCM"，由 audio/audio_out.c 通过 i2s_std 推给模块。
 *
 * 全部整数运算：CONFIG_NEWLIB_NANO_FORMAT=y 时 printf 不支持 %f，采样路径上也不该有软浮点。
 */

/* 一段提示音最多展开成多少段（3 声 → 5 段，留足余量）。 */
#define BKL_BEEP_MAX_SEGMENTS 16

typedef struct {
    uint32_t sample_rate_hz;
    uint32_t phase;     /* 相位累加器，满 2^32 回绕 */
    uint32_t phase_inc; /* 每个采样累加的相位 */
    int16_t amplitude;  /* 峰值幅度，0..32767 */
} bkl_tone_t;

void bkl_tone_init(bkl_tone_t *tone, uint32_t sample_rate_hz, uint32_t freq_hz, int16_t amplitude);

/* 改频率但保留相位连续性（连响时音高变化不炸响）。 */
void bkl_tone_set_freq(bkl_tone_t *tone, uint32_t freq_hz);

/* 生成 frames 个 50% 占空比方波采样，返回实际写入的采样数。 */
size_t bkl_tone_render(bkl_tone_t *tone, int16_t *out, size_t frames);

/* 全 0 填充，返回实际写入的采样数。 */
size_t bkl_tone_render_silence(int16_t *out, size_t frames);

/* 提示音形状：on_ms 发声、off_ms 停顿，重复 repeat 次（最后一次后面不再补停顿）。 */
typedef struct {
    uint16_t freq_hz;
    uint16_t on_ms;
    uint16_t off_ms;
    uint8_t repeat;
} bkl_beep_pattern_t;

/* 展开后的一段：发声或静音。 */
typedef struct {
    bool is_tone;
    uint32_t frames;
    uint16_t freq_hz; /* is_tone 时有效 */
} bkl_beep_segment_t;

/* 展开后有多少段；非法输入返回 0。 */
size_t bkl_beep_segment_count(const bkl_beep_pattern_t *pattern);

/* 展开成段序列；空间不足时截断，返回实际写入段数。 */
size_t bkl_beep_expand(const bkl_beep_pattern_t *pattern, uint32_t sample_rate_hz,
                       bkl_beep_segment_t *out, size_t cap);

/*
 * 流式渲染：一次只取一小块，播放整段提示音不需要按总长度分配堆内存。
 * I²S 写是分批阻塞的，只有音频任务会碰这个结构，无需加锁。
 */
typedef struct {
    const bkl_beep_segment_t *segments;
    size_t segment_count;
    size_t index;         /* 下一个待取段的序号 */
    uint32_t frames_left; /* 当前段剩余采样数 */
    bkl_tone_t tone;      /* 当前发声段的相位状态 */
    uint32_t sample_rate_hz;
    int16_t amplitude;
} bkl_beep_stream_t;

void bkl_beep_stream_init(bkl_beep_stream_t *stream, const bkl_beep_segment_t *segments,
                          size_t segment_count, uint32_t sample_rate_hz, int16_t amplitude);

/* 取下一块 PCM；返回 0 表示整段提示音已经播完。 */
size_t bkl_beep_stream_read(bkl_beep_stream_t *stream, int16_t *out, size_t frames);

/* 一次性渲染整段（主机单测与小缓冲用）；输出空间不够时只写 frames 个采样。 */
size_t bkl_beep_render(const bkl_beep_segment_t *segments, size_t segment_count,
                       uint32_t sample_rate_hz, int16_t amplitude, int16_t *out, size_t frames);
