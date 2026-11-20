#include "tone_gen.h"

#include <string.h>

/* 先乘后除，避免 (sample_rate/1000)*ms 的截断误差。 */
static uint32_t frames_for_ms(uint32_t sample_rate_hz, uint32_t ms)
{
    return (uint32_t)(((uint64_t)sample_rate_hz * (uint64_t)ms) / 1000u);
}

void bkl_tone_set_freq(bkl_tone_t *tone, uint32_t freq_hz)
{
    if (tone == NULL || tone->sample_rate_hz == 0) {
        return;
    }
    /* 0 Hz 或达到奈奎斯特频率：没有可用的方波，当作静音处理。 */
    if (freq_hz == 0 || (uint64_t)freq_hz * 2u >= tone->sample_rate_hz) {
        tone->phase_inc = 0;
        return;
    }
    tone->phase_inc = (uint32_t)(((uint64_t)freq_hz << 32) / tone->sample_rate_hz);
}

void bkl_tone_init(bkl_tone_t *tone, uint32_t sample_rate_hz, uint32_t freq_hz, int16_t amplitude)
{
    if (tone == NULL) {
        return;
    }
    tone->sample_rate_hz = sample_rate_hz;
    tone->phase = 0;
    tone->phase_inc = 0;
    tone->amplitude = (amplitude < 0) ? 0 : amplitude;
    bkl_tone_set_freq(tone, freq_hz);
}

size_t bkl_tone_render_silence(int16_t *out, size_t frames)
{
    if (out == NULL) {
        return 0;
    }
    memset(out, 0, frames * sizeof(int16_t));
    return frames;
}

size_t bkl_tone_render(bkl_tone_t *tone, int16_t *out, size_t frames)
{
    if (tone == NULL || out == NULL) {
        return 0;
    }
    if (tone->phase_inc == 0) {
        return bkl_tone_render_silence(out, frames);
    }
    for (size_t i = 0; i < frames; i++) {
        tone->phase += tone->phase_inc;
        /* 相位最高位即方波极性，天然 50% 占空比。 */
        out[i] = ((tone->phase & 0x80000000u) != 0u) ? tone->amplitude
                                                     : (int16_t)(-tone->amplitude);
    }
    return frames;
}

size_t bkl_beep_segment_count(const bkl_beep_pattern_t *pattern)
{
    if (pattern == NULL || pattern->repeat == 0 || pattern->on_ms == 0) {
        return 0;
    }
    if (pattern->off_ms == 0) {
        return (size_t)pattern->repeat; /* 连着响，没有静音段 */
    }
    /* 每声之后都有停顿，但最后一声后面不再补停顿。 */
    return (size_t)pattern->repeat * 2u - 1u;
}

size_t bkl_beep_expand(const bkl_beep_pattern_t *pattern, uint32_t sample_rate_hz,
                       bkl_beep_segment_t *out, size_t cap)
{
    if (pattern == NULL || out == NULL || cap == 0 || sample_rate_hz == 0) {
        return 0;
    }
    if (pattern->on_ms == 0 || pattern->repeat == 0) {
        return 0; /* 与 bkl_beep_segment_count() 保持一致：没有可播的内容 */
    }
    size_t written = 0;
    for (uint8_t i = 0; i < pattern->repeat && written < cap; i++) {
        out[written].is_tone = true;
        out[written].frames = frames_for_ms(sample_rate_hz, pattern->on_ms);
        out[written].freq_hz = pattern->freq_hz;
        written++;

        if (pattern->off_ms == 0 || (uint8_t)(i + 1u) >= pattern->repeat || written >= cap) {
            continue;
        }
        out[written].is_tone = false;
        out[written].frames = frames_for_ms(sample_rate_hz, pattern->off_ms);
        out[written].freq_hz = 0;
        written++;
    }
    return written;
}

void bkl_beep_stream_init(bkl_beep_stream_t *stream, const bkl_beep_segment_t *segments,
                          size_t segment_count, uint32_t sample_rate_hz, int16_t amplitude)
{
    if (stream == NULL) {
        return;
    }
    stream->segments = segments;
    stream->segment_count = (segments == NULL) ? 0 : segment_count;
    stream->index = 0;
    stream->frames_left = 0;
    stream->sample_rate_hz = sample_rate_hz;
    stream->amplitude = (amplitude < 0) ? 0 : amplitude;
    bkl_tone_init(&stream->tone, sample_rate_hz, 0, stream->amplitude);
}

size_t bkl_beep_stream_read(bkl_beep_stream_t *stream, int16_t *out, size_t frames)
{
    if (stream == NULL || out == NULL || frames == 0) {
        return 0;
    }
    size_t written = 0;
    while (written < frames) {
        if (stream->frames_left == 0) {
            if (stream->index >= stream->segment_count) {
                break; /* 播完了 */
            }
            const bkl_beep_segment_t *seg = &stream->segments[stream->index];
            stream->index++;
            stream->frames_left = seg->frames;
            if (seg->is_tone) {
                bkl_tone_init(&stream->tone, stream->sample_rate_hz, seg->freq_hz, stream->amplitude);
            }
            if (stream->frames_left == 0) {
                continue; /* 0 长度段（例如 on_ms 太小）跳过 */
            }
        }

        const bkl_beep_segment_t *seg = &stream->segments[stream->index - 1u];
        size_t take = frames - written;
        if (take > (size_t)stream->frames_left) {
            take = (size_t)stream->frames_left;
        }
        size_t got = seg->is_tone ? bkl_tone_render(&stream->tone, out + written, take)
                                  : bkl_tone_render_silence(out + written, take);
        written += got;
        stream->frames_left -= (uint32_t)got;
        if (got < take) {
            break; /* 只可能是参数非法，防止死循环 */
        }
    }
    return written;
}

size_t bkl_beep_render(const bkl_beep_segment_t *segments, size_t segment_count,
                       uint32_t sample_rate_hz, int16_t amplitude, int16_t *out, size_t frames)
{
    if (out == NULL || frames == 0) {
        return 0;
    }
    bkl_beep_stream_t stream;
    bkl_beep_stream_init(&stream, segments, segment_count, sample_rate_hz, amplitude);
    return bkl_beep_stream_read(&stream, out, frames);
}
