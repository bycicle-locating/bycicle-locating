#include "audio_out.h"

#include "driver/i2s_std.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#include "tone_gen.h"

#define BKL_AUDIO_TAG "bkl.audio"

#define BKL_AUDIO_QUEUE_DEPTH 4
#define BKL_AUDIO_CHUNK_FRAMES 256 /* 每个 DMA 块 = 256 采样 = 16 ms @16 kHz */
#define BKL_AUDIO_TASK_STACK 4096
#define BKL_AUDIO_TASK_PRIO 5
#define BKL_AUDIO_WRITE_TIMEOUT_MS 200

static i2s_chan_handle_t s_tx;
static QueueHandle_t s_queue;
static TaskHandle_t s_task;
/* 只有音频任务会改它；其他任务读，用于 BLE 状态上报"正在响"。 */
static volatile bool s_playing;

static void audio_render_pattern(const bkl_beep_pattern_t *pattern)
{
    bkl_beep_segment_t segments[BKL_BEEP_MAX_SEGMENTS];
    size_t seg_count = bkl_beep_expand(pattern, CONFIG_BKL_AUDIO_SAMPLE_RATE_HZ, segments,
                                       BKL_BEEP_MAX_SEGMENTS);
    if (seg_count == 0) {
        ESP_LOGW(BKL_AUDIO_TAG, "提示音参数非法，跳过");
        return;
    }

    bkl_beep_stream_t stream;
    bkl_beep_stream_init(&stream, segments, seg_count, CONFIG_BKL_AUDIO_SAMPLE_RATE_HZ,
                         CONFIG_BKL_AUDIO_AMPLITUDE);

    esp_err_t err = i2s_channel_enable(s_tx);
    if (err != ESP_OK) {
        ESP_LOGE(BKL_AUDIO_TAG, "i2s_channel_enable 失败: %s", esp_err_to_name(err));
        return;
    }

    int16_t chunk[BKL_AUDIO_CHUNK_FRAMES];
    for (;;) {
        size_t got = bkl_beep_stream_read(&stream, chunk, BKL_AUDIO_CHUNK_FRAMES);
        if (got == 0) {
            break;
        }
        size_t sent = 0;
        err = i2s_channel_write(s_tx, chunk, got * sizeof(int16_t), &sent,
                                pdMS_TO_TICKS(BKL_AUDIO_WRITE_TIMEOUT_MS));
        if (err != ESP_OK) {
            ESP_LOGW(BKL_AUDIO_TAG, "i2s_channel_write 失败: %s", esp_err_to_name(err));
            break;
        }
    }

    /* 播完就关通道：不再输出 BCLK/LRCLK，功放静音。 */
    i2s_channel_disable(s_tx);
}

static void audio_task(void *arg)
{
    (void)arg;
    bkl_beep_pattern_t pattern;
    for (;;) {
        if (xQueueReceive(s_queue, &pattern, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        s_playing = true;
        audio_render_pattern(&pattern);
        s_playing = false;
    }
}

esp_err_t bkl_audio_init(void)
{
    if (s_tx != NULL) {
        return ESP_OK;
    }

    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 4;
    chan_cfg.dma_frame_num = BKL_AUDIO_CHUNK_FRAMES;

    esp_err_t err = i2s_new_channel(&chan_cfg, &s_tx, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(BKL_AUDIO_TAG, "i2s_new_channel 失败: %s", esp_err_to_name(err));
        s_tx = NULL;
        return err;
    }

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(CONFIG_BKL_AUDIO_SAMPLE_RATE_HZ),
        .slot_cfg =
            I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg =
            {
                .mclk = I2S_GPIO_UNUSED,
                .bclk = (gpio_num_t)CONFIG_BKL_AUDIO_BCLK,
                .ws = (gpio_num_t)CONFIG_BKL_AUDIO_LRCLK,
                .dout = (gpio_num_t)CONFIG_BKL_AUDIO_DIN,
                .din = I2S_GPIO_UNUSED,
                .invert_flags =
                    {
                        .mclk_inv = false,
                        .bclk_inv = false,
                        .ws_inv = false,
                    },
            },
    };

    err = i2s_channel_init_std_mode(s_tx, &std_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(BKL_AUDIO_TAG, "i2s_channel_init_std_mode 失败: %s", esp_err_to_name(err));
        i2s_del_channel(s_tx);
        s_tx = NULL;
        return err;
    }

    s_queue = xQueueCreate(BKL_AUDIO_QUEUE_DEPTH, sizeof(bkl_beep_pattern_t));
    if (s_queue == NULL) {
        ESP_LOGE(BKL_AUDIO_TAG, "提示音队列创建失败");
        i2s_del_channel(s_tx);
        s_tx = NULL;
        return ESP_ERR_NO_MEM;
    }

    if (xTaskCreate(audio_task, "bkl_audio", BKL_AUDIO_TASK_STACK, NULL, BKL_AUDIO_TASK_PRIO,
                    &s_task) != pdPASS) {
        ESP_LOGE(BKL_AUDIO_TAG, "提示音任务创建失败");
        vQueueDelete(s_queue);
        s_queue = NULL;
        i2s_del_channel(s_tx);
        s_tx = NULL;
        return ESP_ERR_NO_MEM;
    }

    ESP_LOGI(BKL_AUDIO_TAG, "I²S 提示音就绪：LRCLK=%d BCLK=%d DIN=%d %d Hz",
             CONFIG_BKL_AUDIO_LRCLK, CONFIG_BKL_AUDIO_BCLK, CONFIG_BKL_AUDIO_DIN,
             CONFIG_BKL_AUDIO_SAMPLE_RATE_HZ);
    return ESP_OK;
}

esp_err_t bkl_audio_play(const bkl_beep_pattern_t *pattern)
{
    if (pattern == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_queue == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (xQueueSend(s_queue, pattern, 0) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    return ESP_OK;
}

esp_err_t bkl_audio_find_me(void)
{
    /* 2 kHz、120 ms 响 + 80 ms 停、3 声 ≈ 0.6 s。低频沉闷/高频刺耳，2 kHz 在户外最容易被听到。 */
    const bkl_beep_pattern_t pattern = {
        .freq_hz = 2000,
        .on_ms = 120,
        .off_ms = 80,
        .repeat = 3,
    };
    return bkl_audio_play(&pattern);
}

bool bkl_audio_playing(void)
{
    return s_playing;
}
