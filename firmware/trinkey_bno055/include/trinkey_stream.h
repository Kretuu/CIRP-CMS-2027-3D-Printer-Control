#ifndef TRINKEY_STREAM_H
#define TRINKEY_STREAM_H

#include <stdbool.h>
#include <stdint.h>

#include "trinkey_acquisition.h"

#define TRINKEY_STREAM_PROTOCOL_VERSION 2
#define TRINKEY_STREAM_MIN_RATE_HZ 100
#define TRINKEY_STREAM_MAX_RATE_HZ 1000
#define TRINKEY_STREAM_MIN_BATCH_SIZE 1
#define TRINKEY_STREAM_MAX_BATCH_SIZE 16

typedef struct {
    bool started;
    bool sampling;
    trinkey_capture_mode_t mode;
    uint32_t sample_rate_hz;
    uint32_t batch_size;
    uint32_t sample_count;
    uint32_t dropped_count;
    uint32_t transport_dropped_count;
    uint32_t overrun_count;
    uint32_t max_loop_us;
    uint32_t max_base_read_us;
    uint32_t max_toolhead_read_us;
} trinkey_stream_status_t;

/**
 * Initialise the continuous acquisition worker. This launches the second
 * RP2040 core, which remains idle until a stream is started.
 */
void trinkey_stream_init(
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead);

/**
 * Start continuous sampling into the bounded inter-core batch queue.
 */
bool trinkey_stream_start(
        trinkey_capture_mode_t mode,
        uint32_t sample_rate_hz,
        uint32_t batch_size);

/**
 * Stop sampling, drain acquired batches, and emit a framed stop record.
 */
void trinkey_stream_stop(void);

/**
 * Return whether a streaming session owns the accelerometers.
 */
bool trinkey_stream_is_started(void);

/**
 * Return a snapshot of stream counters and timing diagnostics.
 */
trinkey_stream_status_t trinkey_stream_status(void);

/**
 * Transmit at most one queued data batch. Sampling continues on core 1 if USB
 * output blocks or is temporarily backpressured.
 */
void trinkey_stream_service_output(void);

/**
 * Emit a binary clock-sync response while streaming.
 */
void trinkey_stream_send_sync(uint32_t sequence, uint64_t trinkey_t_us);

/**
 * Emit a binary status response while streaming.
 */
void trinkey_stream_send_status(void);

#endif
