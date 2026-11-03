// Single-producer single-consumer float ring buffer, shared by the Go
// pump (cgo) and the Swift render blocks (SwiftPM C target CRings).
//
// The type is opaque so that Swift never sees the C11 atomics inside.
// Memory is allocated by ring_new with plain malloc so the Go collector
// never moves it. One producer thread and one consumer thread; no
// locks; the real-time side must call only ring_read / ring_write /
// ring_fill, which never block, allocate, or log.
//
// Untested scaffold, 2026-09-04.

#ifndef LASA_PROBE_RING_H
#define LASA_PROBE_RING_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ring ring_t;

// capacity_frames * channels floats are allocated; capacity should be a
// power of two for the cheap wrap. Returns NULL on allocation failure.
ring_t *ring_new(uint32_t capacity_frames, uint32_t channels);
void ring_free(ring_t *r);

// Producer: copies up to n frames of interleaved float; returns frames
// written (less than n when the ring is full).
uint32_t ring_write(ring_t *r, const float *src, uint32_t n);

// Consumer: copies up to n frames; returns frames read (less than n
// when the ring is short; the caller inserts silence for the rest).
uint32_t ring_read(ring_t *r, float *dst, uint32_t n);

// Producer wake-up (real-time safe: a dispatch semaphore). ring_signal
// records a monotonic timestamp of the signal so the consumer can
// measure its own wake latency, then posts. ring_wait blocks the
// consumer until a signal or the timeout (ms); returns 1 on signal,
// 0 on timeout. A consumer drains every whole frame it can after each
// wake, so coalesced signals are harmless.
void ring_signal(ring_t *r);
int ring_wait(ring_t *r, uint32_t timeout_ms);
uint64_t ring_last_signal_ns(ring_t *r);
uint64_t ring_now_ns(void); // the same clock ring_signal stamps with

// Frames currently buffered (an estimate, safe from either side).
uint32_t ring_fill(ring_t *r);
uint32_t ring_capacity(ring_t *r);
uint32_t ring_channels(ring_t *r);

// Diagnostics counters, updated by the ring itself: short reads
// (underruns) and short writes (overruns), and the frames lost to each.
uint64_t ring_underruns(ring_t *r);
uint64_t ring_underrun_frames(ring_t *r);
uint64_t ring_overruns(ring_t *r);
uint64_t ring_overrun_frames(ring_t *r);

#ifdef __cplusplus
}
#endif

#endif
