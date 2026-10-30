#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app_types.h"
#include "proto_encode.h"
#include "ringbuf.h"

/*
 * 上报状态机：从环形缓冲取一批点 → 编码 → 发布 → 成功后 commit。
 *
 * 失败处理是这一层的核心：指数退避、不丢数据、不允许阻塞采样任务。
 * 它通过 bkl_publish_fn_t 拿到"发送能力"，因此不依赖 AT 指令实现细节；
 * 换 MQTT 客户端（例如从 EC800M AT 栈换成 ESP-MQTT）只需换掉这个回调。
 */

typedef struct {
    /* 返回 0 表示 broker 已确认（PUBACK）；非 0 表示失败，需重试。 */
    int (*publish)(void *ctx, const char *topic, const char *payload, size_t len, bool retain);
    void *ctx;
} bkl_publish_fn_t;

typedef enum {
    BKL_UPLOAD_SENT = 0,   /* 成功发出一批 */
    BKL_UPLOAD_EMPTY,      /* 缓冲为空 */
    BKL_UPLOAD_BACKOFF,    /* 处于退避窗口，本次跳过 */
    BKL_UPLOAD_ERROR,      /* 本次失败，已安排退避 */
} bkl_upload_result_t;

typedef struct {
    const char *device_id;
    const char *firmware;
    const char *topic_telemetry;
    bkl_publish_fn_t transport;
    bkl_ringbuf_t *ring;

    uint32_t max_points_per_batch;
    uint32_t failures;
    int64_t next_attempt_s;

    /* 预分配的批次缓冲，放在结构体里是为了让栈占用可预测（约 2.4 KB）。 */
    bkl_point_t batch[BKL_MAX_POINTS_PER_BATCH];
} bkl_uploader_t;

/* 初始化。max_points_per_batch 会被夹到 [1, BKL_MAX_POINTS_PER_BATCH]。 */
int bkl_uploader_init(bkl_uploader_t *up, const char *device_id, const char *firmware,
                      const char *topic_telemetry, bkl_publish_fn_t transport,
                      bkl_ringbuf_t *ring, uint32_t max_points_per_batch);

/* 尝试上报一批。scratch 用于编码 JSON，建议 4096 字节。 */
bkl_upload_result_t bkl_uploader_step(bkl_uploader_t *up, int64_t now_s,
                                      char *scratch, size_t scratch_cap,
                                      uint32_t *sent_out);

/* 下次允许尝试的时间（epoch 秒），供调度任务计算唤醒时刻。 */
int64_t bkl_uploader_next_attempt(const bkl_uploader_t *up);
