// See include/ring.h. Darwin only (libdispatch). Untested scaffold, 2026-09-04.

#include "ring.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dispatch/dispatch.h>

struct ring {
    float *buf;
    uint32_t cap;      // frames, power of two
    uint32_t mask;
    uint32_t ch;
    _Atomic uint32_t head;  // producer writes, consumer reads
    _Atomic uint32_t tail;  // consumer writes, producer reads
    _Atomic uint64_t underruns, underrun_frames, overruns, overrun_frames;
    dispatch_semaphore_t sem;
    _Atomic uint64_t last_signal_ns;
};

uint64_t ring_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void ring_signal(ring_t *r) {
    atomic_store_explicit(&r->last_signal_ns, ring_now_ns(), memory_order_relaxed);
    dispatch_semaphore_signal(r->sem);
}

int ring_wait(ring_t *r, uint32_t timeout_ms) {
    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * 1000000);
    return dispatch_semaphore_wait(r->sem, t) == 0 ? 1 : 0;
}

uint64_t ring_last_signal_ns(ring_t *r) {
    return atomic_load_explicit(&r->last_signal_ns, memory_order_relaxed);
}

static uint32_t pow2_ceil(uint32_t v) {
    uint32_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

ring_t *ring_new(uint32_t capacity_frames, uint32_t channels) {
    ring_t *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->cap = pow2_ceil(capacity_frames);
    r->mask = r->cap - 1;
    r->ch = channels;
    r->buf = calloc((size_t)r->cap * channels, sizeof(float));
    if (!r->buf) { free(r); return NULL; }
    r->sem = dispatch_semaphore_create(0);
    return r;
}

void ring_free(ring_t *r) {
    if (!r) return;
    // A waiter must have returned before this; Stop signals it out.
    dispatch_semaphore_signal(r->sem);
    free(r->buf);
    free(r);
}

uint32_t ring_fill(ring_t *r) {
    uint32_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    uint32_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    return h - t;
}

uint32_t ring_capacity(ring_t *r) { return r->cap; }
uint32_t ring_channels(ring_t *r) { return r->ch; }

uint32_t ring_write(ring_t *r, const float *src, uint32_t n) {
    uint32_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    uint32_t space = r->cap - (h - t);
    uint32_t w = n < space ? n : space;
    if (w < n) {
        atomic_fetch_add_explicit(&r->overruns, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&r->overrun_frames, n - w, memory_order_relaxed);
    }
    uint32_t start = h & r->mask;
    uint32_t first = r->cap - start;
    if (first > w) first = w;
    memcpy(r->buf + (size_t)start * r->ch, src, (size_t)first * r->ch * sizeof(float));
    if (w > first)
        memcpy(r->buf, src + (size_t)first * r->ch, (size_t)(w - first) * r->ch * sizeof(float));
    atomic_store_explicit(&r->head, h + w, memory_order_release);
    return w;
}

uint32_t ring_read(ring_t *r, float *dst, uint32_t n) {
    uint32_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint32_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    uint32_t avail = h - t;
    uint32_t rd = n < avail ? n : avail;
    if (rd < n) {
        atomic_fetch_add_explicit(&r->underruns, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&r->underrun_frames, n - rd, memory_order_relaxed);
    }
    uint32_t start = t & r->mask;
    uint32_t first = r->cap - start;
    if (first > rd) first = rd;
    memcpy(dst, r->buf + (size_t)start * r->ch, (size_t)first * r->ch * sizeof(float));
    if (rd > first)
        memcpy(dst + (size_t)first * r->ch, r->buf, (size_t)(rd - first) * r->ch * sizeof(float));
    atomic_store_explicit(&r->tail, t + rd, memory_order_release);
    return rd;
}

uint64_t ring_underruns(ring_t *r)       { return atomic_load(&r->underruns); }
uint64_t ring_underrun_frames(ring_t *r) { return atomic_load(&r->underrun_frames); }
uint64_t ring_overruns(ring_t *r)        { return atomic_load(&r->overruns); }
uint64_t ring_overrun_frames(ring_t *r)  { return atomic_load(&r->overrun_frames); }
