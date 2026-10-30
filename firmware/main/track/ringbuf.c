#include "ringbuf.h"

#include <string.h>

static uint32_t slot_offset(const bkl_ringbuf_t *rb, uint32_t slot)
{
    return slot * rb->record_size;
}

static int io_write(bkl_ringbuf_t *rb, uint32_t offset, const void *src, size_t len)
{
    if (rb->io.write == NULL) {
        return -1;
    }
    return rb->io.write(rb->io.ctx, offset, src, len);
}

static int io_read(const bkl_ringbuf_t *rb, uint32_t offset, void *dst, size_t len)
{
    if (rb->io.read == NULL) {
        return -1;
    }
    return rb->io.read(rb->io.ctx, offset, dst, len);
}

int bkl_ringbuf_init(bkl_ringbuf_t *rb, const bkl_ringbuf_io_t *io, uint32_t record_size)
{
    if (rb == NULL || io == NULL || record_size == 0 || io->capacity < record_size) {
        return -1;
    }
    if (io->capacity % record_size != 0) {
        return -1;
    }

    memset(rb, 0, sizeof(*rb));
    rb->io = *io;
    rb->record_size = record_size;
    rb->slots = io->capacity / record_size;
    rb->head = 0;
    rb->tail = 0;
    rb->count = 0;
    rb->dropped = 0;
    return 0;
}

int bkl_ringbuf_restore(bkl_ringbuf_t *rb, uint32_t head, uint32_t tail,
                        uint32_t count, uint32_t dropped)
{
    if (rb == NULL || rb->slots == 0) {
        return -1;
    }
    if (head >= rb->slots || tail >= rb->slots || count > rb->slots) {
        /* 元数据损坏：宁可当空缓冲，也不要读到随机内容 */
        rb->head = 0;
        rb->tail = 0;
        rb->count = 0;
        return -1;
    }
    rb->head = head;
    rb->tail = tail;
    rb->count = count;
    rb->dropped = dropped;
    return 0;
}

int bkl_ringbuf_push(bkl_ringbuf_t *rb, const bkl_point_t *point)
{
    if (rb == NULL || point == NULL || rb->slots == 0) {
        return -1;
    }

    /* 满则丢最旧：旧点价值低于新点（protocol.md §8） */
    if (rb->count == rb->slots) {
        rb->tail = (rb->tail + 1) % rb->slots;
        rb->count--;
        rb->dropped++;
    }

    /* 先落数据，再移动 head —— 顺序与文件头的一致性约定一致 */
    if (io_write(rb, slot_offset(rb, rb->head), point, sizeof(*point)) != 0) {
        return -1;
    }

    rb->head = (rb->head + 1) % rb->slots;
    rb->count++;
    return 0;
}

int bkl_ringbuf_peek(const bkl_ringbuf_t *rb, uint32_t index, bkl_point_t *out)
{
    if (rb == NULL || out == NULL || index >= rb->count) {
        return -1;
    }
    uint32_t slot = (rb->tail + index) % rb->slots;
    return io_read(rb, slot_offset(rb, slot), out, sizeof(*out));
}

int bkl_ringbuf_commit(bkl_ringbuf_t *rb, uint32_t n)
{
    if (rb == NULL) {
        return -1;
    }
    if (n > rb->count) {
        n = rb->count;
    }
    rb->tail = (rb->tail + n) % rb->slots;
    rb->count -= n;
    return 0;
}

uint32_t bkl_ringbuf_count(const bkl_ringbuf_t *rb)
{
    return rb != NULL ? rb->count : 0;
}

uint32_t bkl_ringbuf_dropped(const bkl_ringbuf_t *rb)
{
    return rb != NULL ? rb->dropped : 0;
}

uint32_t bkl_ringbuf_head(const bkl_ringbuf_t *rb)
{
    return rb != NULL ? rb->head : 0;
}

uint32_t bkl_ringbuf_tail(const bkl_ringbuf_t *rb)
{
    return rb != NULL ? rb->tail : 0;
}
