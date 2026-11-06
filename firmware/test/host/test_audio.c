/*
 * 提示音合成模块的主机单测：不依赖 ESP-IDF，可在普通 PC 上用 gcc 编译运行。
 *
 *   gcc -std=c11 -Wall -Wextra -Werror \
 *       -I main -I main/audio \
 *       test/host/test_audio.c main/audio/tone_gen.c -o test_audio && ./test_audio
 *
 * 覆盖提示音最容易出错的地方：
 *   1) 方波周期与采样率/频率的定点换算（不能用浮点、不能用 %f）；
 *   2) 段序列展开（最后一声后面不该多停顿）；
 *   3) 流式渲染与一次性渲染必须逐采样一致（I²S 分块写不能改变波形）。
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "tone_gen.h"

#define CHECK(cond)                                                           \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);   \
            g_failures++;                                                     \
        }                                                                     \
    } while (0)

static int g_failures = 0;

#define TEST_RATE 16000u
#define TEST_AMP 8000

/* 找车提示音：2 kHz、120 ms 响 + 80 ms 停、3 声。 */
static const bkl_beep_pattern_t k_find_me = {
    .freq_hz = 2000,
    .on_ms = 120,
    .off_ms = 80,
    .repeat = 3,
};

/* 一周期 = 1920 采样；3 声 + 2 段停顿 = 8320 采样。 */
#define FIND_ME_FRAMES (3u * 1920u + 2u * 1280u)

static int16_t s_render[FIND_ME_FRAMES];
static int16_t s_streamed[FIND_ME_FRAMES];

static size_t count_sign_changes(const int16_t *buf, size_t frames)
{
    size_t changes = 0;
    for (size_t i = 1; i < frames; i++) {
        bool was_positive = buf[i - 1] > 0;
        bool is_positive = buf[i] > 0;
        if (was_positive != is_positive) {
            changes++;
        }
    }
    return changes;
}

/* ---------- 方波本身 ---------- */

static void test_tone_period(void)
{
    int16_t buf[64];
    bkl_tone_t tone;

    /* 1 kHz @ 16 kHz = 每周期 16 采样 -> 64 采样里有 8 次极性翻转。 */
    bkl_tone_init(&tone, TEST_RATE, 1000, TEST_AMP);
    CHECK(bkl_tone_render(&tone, buf, 64) == 64);
    CHECK(count_sign_changes(buf, 64) == 8);

    /* 2 kHz @ 16 kHz = 每周期 8 采样 -> 16 次翻转。 */
    bkl_tone_init(&tone, TEST_RATE, 2000, TEST_AMP);
    CHECK(bkl_tone_render(&tone, buf, 64) == 64);
    CHECK(count_sign_changes(buf, 64) == 16);

    bool amplitude_ok = true;
    for (size_t i = 0; i < 64; i++) {
        if (buf[i] != TEST_AMP && buf[i] != (int16_t)-TEST_AMP) {
            amplitude_ok = false;
        }
    }
    CHECK(amplitude_ok);
}

static void test_tone_degenerate(void)
{
    int16_t buf[32];
    bkl_tone_t tone;

    /* 0 Hz：没有方波，按静音处理，不能输出直流。 */
    bkl_tone_init(&tone, TEST_RATE, 0, TEST_AMP);
    CHECK(bkl_tone_render(&tone, buf, 32) == 32);
    for (size_t i = 0; i < 32; i++) {
        CHECK(buf[i] == 0);
    }

    /* 达到奈奎斯特（2*9000 >= 16000）：同样静音。 */
    bkl_tone_init(&tone, TEST_RATE, 9000, TEST_AMP);
    CHECK(bkl_tone_render(&tone, buf, 32) == 32);
    for (size_t i = 0; i < 32; i++) {
        CHECK(buf[i] == 0);
    }

    /* 静音填充 */
    memset(buf, 0x7F, sizeof(buf));
    CHECK(bkl_tone_render_silence(buf, 32) == 32);
    for (size_t i = 0; i < 32; i++) {
        CHECK(buf[i] == 0);
    }

    /* 空指针不崩 */
    CHECK(bkl_tone_render(NULL, buf, 32) == 0);
    CHECK(bkl_tone_render(&tone, NULL, 32) == 0);
    CHECK(bkl_tone_render_silence(NULL, 32) == 0);
}

/* ---------- 段序列展开 ---------- */

static void test_segment_expand(void)
{
    CHECK(bkl_beep_segment_count(&k_find_me) == 5);
    CHECK(bkl_beep_segment_count(NULL) == 0);

    bkl_beep_pattern_t no_gap = k_find_me;
    no_gap.off_ms = 0;
    CHECK(bkl_beep_segment_count(&no_gap) == 3);

    bkl_beep_pattern_t zero_repeat = k_find_me;
    zero_repeat.repeat = 0;
    CHECK(bkl_beep_segment_count(&zero_repeat) == 0);

    bkl_beep_segment_t segs[BKL_BEEP_MAX_SEGMENTS];
    size_t n = bkl_beep_expand(&k_find_me, TEST_RATE, segs, BKL_BEEP_MAX_SEGMENTS);
    CHECK(n == 5);

    /* 段间结构：响、停、响、停、响——最后一声后面不再补停顿。 */
    CHECK(segs[0].is_tone && segs[0].frames == 1920 && segs[0].freq_hz == 2000);
    CHECK(!segs[1].is_tone && segs[1].frames == 1280);
    CHECK(segs[2].is_tone && segs[2].frames == 1920);
    CHECK(!segs[3].is_tone && segs[3].frames == 1280);
    CHECK(segs[4].is_tone && segs[4].frames == 1920);

    /* 空间不够时截断，且不越界写 */
    memset(segs, 0, sizeof(segs));
    CHECK(bkl_beep_expand(&k_find_me, TEST_RATE, segs, 2) == 2);
    CHECK(segs[0].is_tone && !segs[1].is_tone);

    CHECK(bkl_beep_expand(&k_find_me, TEST_RATE, segs, 0) == 0);
    CHECK(bkl_beep_expand(NULL, TEST_RATE, segs, BKL_BEEP_MAX_SEGMENTS) == 0);
}

/* ---------- 渲染与流式一致性 ---------- */

static void test_render_matches_stream(void)
{
    bkl_beep_segment_t segs[BKL_BEEP_MAX_SEGMENTS];
    size_t n = bkl_beep_expand(&k_find_me, TEST_RATE, segs, BKL_BEEP_MAX_SEGMENTS);
    CHECK(n == 5);

    size_t one_shot = bkl_beep_render(segs, n, TEST_RATE, TEST_AMP, s_render, FIND_ME_FRAMES);
    CHECK(one_shot == FIND_ME_FRAMES);

    /* 用 7 采样这种除不尽的块大小流式取，必须逐采样一致。 */
    bkl_beep_stream_t stream;
    bkl_beep_stream_init(&stream, segs, n, TEST_RATE, TEST_AMP);
    size_t total = 0;
    while (total < FIND_ME_FRAMES) {
        size_t got = bkl_beep_stream_read(&stream, s_streamed + total, 7);
        if (got == 0) {
            break;
        }
        total += got;
    }
    CHECK(total == FIND_ME_FRAMES);
    CHECK(memcmp(s_render, s_streamed, FIND_ME_FRAMES * sizeof(int16_t)) == 0);

    /* 播完后继续取应当返回 0，不能重复出声或死循环。 */
    int16_t tail[8];
    CHECK(bkl_beep_stream_read(&stream, tail, 8) == 0);

    /* 停顿时段必须是真正的 0（否则功放会发出直流/噪声）。 */
    bool silence_ok = true;
    for (size_t i = 1920; i < 3200; i++) {
        if (s_render[i] != 0) {
            silence_ok = false;
        }
    }
    CHECK(silence_ok);

    /* 输出空间不足时只写 frames 个，而不是越界。 */
    CHECK(bkl_beep_render(segs, n, TEST_RATE, TEST_AMP, s_render, 100) == 100);
    CHECK(bkl_beep_render(segs, n, TEST_RATE, TEST_AMP, s_render, 0) == 0);
    CHECK(bkl_beep_render(segs, n, TEST_RATE, TEST_AMP, NULL, 100) == 0);
}

static void test_zero_length_segments(void)
{
    /* on_ms = 0：没有可播内容，展开为 0 段，流式读取立刻结束（不能卡住）。 */
    bkl_beep_pattern_t p = k_find_me;
    p.on_ms = 0;
    bkl_beep_segment_t segs[BKL_BEEP_MAX_SEGMENTS];
    CHECK(bkl_beep_expand(&p, TEST_RATE, segs, BKL_BEEP_MAX_SEGMENTS) == 0);

    bkl_beep_stream_t stream;
    bkl_beep_stream_init(&stream, segs, 0, TEST_RATE, TEST_AMP);
    int16_t buf[16];
    CHECK(bkl_beep_stream_read(&stream, buf, 16) == 0);

    /* 零长度流：直接返回 0 */
    bkl_beep_stream_init(&stream, NULL, 0, TEST_RATE, TEST_AMP);
    CHECK(bkl_beep_stream_read(&stream, buf, 16) == 0);

    /* 极端参数不崩 */
    bkl_beep_stream_init(NULL, segs, 0, TEST_RATE, TEST_AMP);
    CHECK(bkl_beep_stream_read(NULL, buf, 16) == 0);
    CHECK(bkl_beep_stream_read(&stream, NULL, 16) == 0);
}

int main(void)
{
    test_tone_period();
    test_tone_degenerate();
    test_segment_expand();
    test_render_matches_stream();
    test_zero_length_segments();

    if (g_failures == 0) {
        printf("提示音主机单测全部通过\n");
        return 0;
    }
    fprintf(stderr, "失败 %d 项\n", g_failures);
    return 1;
}
