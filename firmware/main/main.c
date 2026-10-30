#include <stdio.h>
#include <string.h>
#include <time.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "app_types.h"
#include "ble_status.h"
#include "modem_at.h"
#include "modem_gnss.h"
#include "modem_mqtt.h"
#include "power_mgr.h"
#include "proto_encode.h"
#include "ringbuf.h"
#include "st25dv.h"
#include "uploader.h"

static const char *TAG = "bkl";

/* TODO(M1): 改为由构建注入（git describe --tags）或编译期宏，避免手工漏改。 */
#define BKL_FIRMWARE_VERSION "0.1.0"

#define BKL_NVS_NAMESPACE "bkl"
#define BKL_NVS_KEY_DEVICE_ID "device_id"

/* 自检用的 RAM 后端：即使 flash 还没分区好，也能验证缓冲与编码链路。 */
#define BKL_SELFTEST_RECORDS 8
static bkl_point_t s_selftest_records[BKL_SELFTEST_RECORDS];

static bkl_ringbuf_t s_ring;
static bkl_uploader_t s_uploader;
static char s_scratch[4096];

/* --- RAM 版存储后端 --- */

static int ram_write(void *ctx, uint32_t offset, const void *src, size_t len)
{
    uint32_t cap = (uint32_t)(BKL_SELFTEST_RECORDS * sizeof(bkl_point_t));
    if (offset > cap || len > cap - offset) {
        return -1;
    }
    memcpy((uint8_t *)ctx + offset, src, len);
    return 0;
}

static int ram_read(void *ctx, uint32_t offset, void *dst, size_t len)
{
    uint32_t cap = (uint32_t)(BKL_SELFTEST_RECORDS * sizeof(bkl_point_t));
    if (offset > cap || len > cap - offset) {
        return -1;
    }
    memcpy(dst, (const uint8_t *)ctx + offset, len);
    return 0;
}

/* --- 传输适配：M1 换成真正走 bkl_mqtt_publish 的实现 --- */

static int publish_via_log(void *ctx, const char *topic, const char *payload,
                           size_t len, bool retain)
{
    (void)ctx;
    (void)retain;
    ESP_LOGI(TAG, "publish %s (%u B): %.*s", topic, (unsigned)len, (int)len, payload);
    return 0;
}

static bkl_publish_fn_t make_transport(void)
{
    bkl_publish_fn_t t = { .publish = publish_via_log, .ctx = NULL };
    return t;
}

/* --- 设备身份：产线写入 NVS，缺失时用占位值以免刷机后直接不启动 --- */

static void load_device_id(char *out, size_t cap)
{
    nvs_handle_t h;
    if (nvs_open(BKL_NVS_NAMESPACE, NVS_READONLY, &h) == ESP_OK) {
        size_t len = cap;
        if (nvs_get_str(h, BKL_NVS_KEY_DEVICE_ID, out, &len) == ESP_OK) {
            nvs_close(h);
            return;
        }
        nvs_close(h);
    }
    snprintf(out, cap, "BKL-0000-000000");
    ESP_LOGW(TAG, "NVS 中没有 device_id，使用占位值 %s（产线未烧写？）", out);
}

#ifdef CONFIG_BKL_SELFTEST_ON_BOOT
static void run_selftest(void)
{
    int64_t base_ts = 1793000000; /* 固定时间戳，便于对照日志 */
    for (uint32_t i = 0; i < 3; i++) {
        bkl_point_t p = {
            .seq = 1000 + i,
            .ts_s = base_ts + (int64_t)i * 10,
            .lat = 312304000,   /* 31.2304 */
            .lon = 1214737000,  /* 121.4737 */
            .alt_cm = 1240,
            .speed_mm_s = 6200,
            .course_cdeg = 18750,
            .hdop_x10 = 9,
            .acc_dm = 40,
            .fix = BKL_FIX_3D,
        };
        if (bkl_ringbuf_push(&s_ring, &p) != 0) {
            ESP_LOGE(TAG, "自检：写缓冲失败");
            return;
        }
    }

    uint32_t sent = 0;
    bkl_upload_result_t r = bkl_uploader_step(&s_uploader, base_ts + 30, s_scratch, sizeof(s_scratch), &sent);
    ESP_LOGI(TAG, "自检结果：%d，发送 %u 条，缓冲剩余 %u 条",
             (int)r, (unsigned)sent, (unsigned)bkl_ringbuf_count(&s_ring));
    if (r != BKL_UPLOAD_SENT || sent != 3 || bkl_ringbuf_count(&s_ring) != 0) {
        ESP_LOGE(TAG, "自检失败：期望发送 3 条并清空缓冲");
    }
}
#endif

void app_main(void)
{
    ESP_LOGI(TAG, "BKL 固件 %s 启动（型号 %s）", BKL_FIRMWARE_VERSION, CONFIG_BKL_DEVICE_MODEL);

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    char device_id[32];
    load_device_id(device_id, sizeof(device_id));

    bkl_ringbuf_io_t io = {
        .write = ram_write,
        .read = ram_read,
        .ctx = s_selftest_records,
        .capacity = (uint32_t)sizeof(s_selftest_records),
    };
    if (bkl_ringbuf_init(&s_ring, &io, sizeof(bkl_point_t)) != 0) {
        ESP_LOGE(TAG, "ringbuf 初始化失败");
        return;
    }
    ESP_LOGW(TAG, "ringbuf 使用 RAM 后端（%d 条），休眠即丢失；M1 换成 track 分区上的 LittleFS",
             BKL_SELFTEST_RECORDS);

    const int64_t now_s = (int64_t)time(NULL);

    /*
     * uploader 只保存指针，因此主题必须放在静态缓冲里，
     * 不能传给栈上的临时数组。
     */
    static char s_topic_telemetry[64];
    snprintf(s_topic_telemetry, sizeof(s_topic_telemetry),
             "v1/device/%s/telemetry", device_id);

    if (bkl_uploader_init(&s_uploader, device_id, BKL_FIRMWARE_VERSION,
                          s_topic_telemetry, make_transport(),
                          &s_ring, 10) != 0) {
        ESP_LOGE(TAG, "uploader 初始化失败");
        return;
    }
    ESP_LOGI(TAG, "上报主题 %s（当前时间 %lld）", s_topic_telemetry, (long long)now_s);

#ifdef CONFIG_BKL_SELFTEST_ON_BOOT
    run_selftest();
#endif

    /* 硬件外设：M1 前全部返回 NOT_SUPPORTED，这里只记录状态，不阻塞启动。 */
    if (bkl_power_init() != ESP_OK) {
        ESP_LOGW(TAG, "电源管理未就绪");
    }
    if (bkl_at_init(1, 17, 16, 115200) != ESP_OK) {
        ESP_LOGW(TAG, "AT 引擎未就绪（无法连接模组）");
    }
    if (bkl_gnss_init() != ESP_OK) {
        ESP_LOGW(TAG, "GNSS 未就绪");
    }
    bkl_ble_identity_t ble_id = {
        .device_id = device_id,
        .model = CONFIG_BKL_DEVICE_MODEL,
        .firmware = BKL_FIRMWARE_VERSION,
    };
    if (bkl_ble_init(&ble_id) != ESP_OK) {
        ESP_LOGW(TAG, "BLE 未就绪");
    }
    if (bkl_st25dv_init(0, 5, 6, 9) != ESP_OK) {
        ESP_LOGW(TAG, "NFC 标签未就绪（ST25DV16K，I²C0 SDA=5 SCL=6 GPO=9）");
    }

    ESP_LOGW(TAG, "M0 骨架：采样/AT/GNSS/BLE 均为桩实现，见 docs/roadmap.md 的 M1");

    /* 骨架阶段只保持存活并定期打点，便于确认看门狗与睡眠未误触发。 */
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(60000));
        ESP_LOGI(TAG, "心跳：缓冲 %u 条，丢弃累计 %u",
                 (unsigned)bkl_ringbuf_count(&s_ring),
                 (unsigned)bkl_ringbuf_dropped(&s_ring));
    }
}
