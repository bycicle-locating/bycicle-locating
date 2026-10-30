#include "uploader.h"

#include <string.h>

#define BKL_BACKOFF_BASE_S 1
#define BKL_BACKOFF_MAX_S  300

int bkl_uploader_init(bkl_uploader_t *up, const char *device_id, const char *firmware,
                      const char *topic_telemetry, bkl_publish_fn_t transport,
                      bkl_ringbuf_t *ring, uint32_t max_points_per_batch)
{
    if (up == NULL || device_id == NULL || topic_telemetry == NULL ||
        transport.publish == NULL || ring == NULL) {
        return -1;
    }

    memset(up, 0, sizeof(*up));
    up->device_id = device_id;
    up->firmware = firmware;
    up->topic_telemetry = topic_telemetry;
    up->transport = transport;
    up->ring = ring;

    if (max_points_per_batch == 0) {
        max_points_per_batch = 1;
    }
    if (max_points_per_batch > BKL_MAX_POINTS_PER_BATCH) {
        max_points_per_batch = BKL_MAX_POINTS_PER_BATCH;
    }
    up->max_points_per_batch = max_points_per_batch;
    return 0;
}

/* 1,2,4,...,300 秒封顶。网络恢复后最多等 5 分钟重试一次。 */
static int64_t backoff_delay(uint32_t failures)
{
    int64_t delay = BKL_BACKOFF_BASE_S;
    for (uint32_t i = 1; i < failures && delay < BKL_BACKOFF_MAX_S; i++) {
        delay *= 2;
    }
    return delay > BKL_BACKOFF_MAX_S ? BKL_BACKOFF_MAX_S : delay;
}

bkl_upload_result_t bkl_uploader_step(bkl_uploader_t *up, int64_t now_s,
                                      char *scratch, size_t scratch_cap,
                                      uint32_t *sent_out)
{
    if (sent_out != NULL) {
        *sent_out = 0;
    }
    if (up == NULL || scratch == NULL || scratch_cap == 0) {
        return BKL_UPLOAD_ERROR;
    }
    if (now_s < up->next_attempt_s) {
        return BKL_UPLOAD_BACKOFF;
    }

    uint32_t available = bkl_ringbuf_count(up->ring);
    if (available == 0) {
        return BKL_UPLOAD_EMPTY;
    }

    uint32_t n = available < up->max_points_per_batch ? available : up->max_points_per_batch;
    for (uint32_t i = 0; i < n; i++) {
        if (bkl_ringbuf_peek(up->ring, i, &up->batch[i]) != 0) {
            /* 读失败通常意味着存储介质出错，按可重试错误处理 */
            up->failures++;
            up->next_attempt_s = now_s + backoff_delay(up->failures);
            return BKL_UPLOAD_ERROR;
        }
    }

    bkl_telemetry_batch_t envelope = {
        .device_id = up->device_id,
        .firmware = up->firmware,
        .seq = up->batch[n - 1].seq,
        .ts_s = up->batch[n - 1].ts_s,
        .points = up->batch,
        .point_count = n,
        .battery = NULL,
        .rsrp = 0,
        .has_net = false,
        .dropped = bkl_ringbuf_dropped(up->ring),
    };

    int len = bkl_proto_encode_telemetry(scratch, scratch_cap, &envelope);
    if (len < 0) {
        /*
         * 编码放不下时不要退避——这是容量问题，不是网络问题。
         * 减少本批点数重试一次，仍失败才记为错误。
         */
        if (n > 1) {
            up->max_points_per_batch = n / 2;
            return BKL_UPLOAD_ERROR;
        }
        up->failures++;
        up->next_attempt_s = now_s + backoff_delay(up->failures);
        return BKL_UPLOAD_ERROR;
    }

    if (up->transport.publish(up->transport.ctx, up->topic_telemetry,
                              scratch, (size_t)len, false) != 0) {
        up->failures++;
        up->next_attempt_s = now_s + backoff_delay(up->failures);
        return BKL_UPLOAD_ERROR;
    }

    /* 发布成功才 commit：宁可重传，也不能丢点。 */
    bkl_ringbuf_commit(up->ring, n);
    up->failures = 0;
    up->next_attempt_s = 0;
    if (sent_out != NULL) {
        *sent_out = n;
    }
    return BKL_UPLOAD_SENT;
}

int64_t bkl_uploader_next_attempt(const bkl_uploader_t *up)
{
    return up != NULL ? up->next_attempt_s : 0;
}
