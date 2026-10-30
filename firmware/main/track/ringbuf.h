#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app_types.h"

/*
 * 掉电安全的轨迹点环形缓冲。
 *
 * 为什么要这一层：设备会在骑行途中随时断电（车锁、电池保护板），而 4G 可能长时间无信号。
 * 缓冲必须做到"最多丢最后一条正在写的记录"，不能让整段轨迹作废。
 *
 * 一致性约定（很重要）：
 *   1. 先写记录体，再更新 head/count；
 *   2. head/tail/count/dropped 由调用方在 push/commit 成功后写入 NVS；
 *   3. 掉电发生在 1 与 2 之间时，该记录只是"没被计入"，
 *      下次 push 会用同一条槽位覆盖它——因此不会留下半条可见记录。
 *
 * 容量换算：slots = capacity / record_size，容量应为 record_size 的整数倍。
 */

typedef struct {
    int (*write)(void *ctx, uint32_t offset, const void *src, size_t len);
    int (*read)(void *ctx, uint32_t offset, void *dst, size_t len);
    void *ctx;
    uint32_t capacity;
} bkl_ringbuf_io_t;

typedef struct {
    bkl_ringbuf_io_t io;
    uint32_t record_size;
    uint32_t slots;
    uint32_t head;    /* 下一条写入槽位 */
    uint32_t tail;    /* 最旧记录槽位 */
    uint32_t count;   /* 有效记录数 */
    uint32_t dropped; /* 因写满而丢弃的累计条数 */
} bkl_ringbuf_t;

/* 初始化并清空。失败返回 -1（容量不足或非整除）。 */
int bkl_ringbuf_init(bkl_ringbuf_t *rb, const bkl_ringbuf_io_t *io, uint32_t record_size);

/* 上电时用 NVS 中的元数据恢复。参数非法返回 -1 并按空缓冲处理。 */
int bkl_ringbuf_restore(bkl_ringbuf_t *rb, uint32_t head, uint32_t tail,
                        uint32_t count, uint32_t dropped);

/* 写入一条记录；缓冲满时丢弃最旧的记录。返回 0 成功，-1 失败。 */
int bkl_ringbuf_push(bkl_ringbuf_t *rb, const bkl_point_t *point);

/* 从最旧开始读取第 index 条（0 起）。越界返回 -1。 */
int bkl_ringbuf_peek(const bkl_ringbuf_t *rb, uint32_t index, bkl_point_t *out);

/* 丢弃最旧的 n 条（上报成功后调用）。 */
int bkl_ringbuf_commit(bkl_ringbuf_t *rb, uint32_t n);

uint32_t bkl_ringbuf_count(const bkl_ringbuf_t *rb);
uint32_t bkl_ringbuf_dropped(const bkl_ringbuf_t *rb);

/* 供调用方持久化到 NVS。 */
uint32_t bkl_ringbuf_head(const bkl_ringbuf_t *rb);
uint32_t bkl_ringbuf_tail(const bkl_ringbuf_t *rb);
