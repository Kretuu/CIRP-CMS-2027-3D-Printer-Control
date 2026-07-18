#ifndef TRINKEY_CAPTURE_H
#define TRINKEY_CAPTURE_H

#include <stdbool.h>
#include <stdint.h>

#include "bno055.h"

#define TRINKEY_CAPTURE_SAMPLE_RATE_HZ 400
#define TRINKEY_CAPTURE_PERIOD_US (1000000 / TRINKEY_CAPTURE_SAMPLE_RATE_HZ)
#define TRINKEY_CAPTURE_CAPACITY 4096

typedef enum {
    TRINKEY_CAPTURE_BASE = 0,
    TRINKEY_CAPTURE_TOOLHEAD = 1,
    TRINKEY_CAPTURE_BOTH = 2,
} trinkey_capture_mode_t;

typedef struct {
    trinkey_capture_mode_t mode;
    bool active;
    uint32_t stored_count;
    uint32_t sample_count;
    uint32_t dropped_count;
    uint32_t overrun_count;
    uint32_t capacity;
    uint32_t sample_rate_hz;
    uint32_t max_loop_us;
    uint32_t max_base_read_us;
    uint32_t max_toolhead_read_us;
} trinkey_capture_status_t;

/**
 * Reset the buffered capture module.
 */
void trinkey_capture_init(void);

/**
 * Parse a capture mode string used by the USB protocol.
 *
 * @param text Mode string: base, toolhead, or both.
 * @param mode Output mode when parsing succeeds.
 * @return true when the mode is valid.
 */
bool trinkey_capture_mode_from_string(
        const char *text,
        trinkey_capture_mode_t *mode);

/**
 * Return a stable text name for a capture mode.
 *
 * @param mode Capture mode.
 * @return Static mode string.
 */
const char *trinkey_capture_mode_name(trinkey_capture_mode_t mode);

/**
 * Start writing timestamped accelerometer samples into RAM.
 *
 * @param mode Which accelerometer or accelerometers to record.
 */
void trinkey_capture_start(trinkey_capture_mode_t mode);

/**
 * Stop writing samples while keeping the buffer available for dumping.
 */
void trinkey_capture_stop(void);

/**
 * Return the current capture status counters.
 *
 * @return Snapshot of capture state and diagnostics.
 */
trinkey_capture_status_t trinkey_capture_status(void);

/**
 * Capture one scheduled sample if the next sample time has elapsed.
 *
 * @param imu_base Bed/base accelerometer.
 * @param imu_toolhead Toolhead accelerometer.
 */
void trinkey_capture_sample_if_due(
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead);

/**
 * Dump buffered samples as CSV protocol rows.
 */
void trinkey_capture_dump_csv(void);

#endif
