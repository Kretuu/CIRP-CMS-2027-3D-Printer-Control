#include "trinkey_capture.h"

#include <stdio.h>
#include <string.h>

#include "pico/stdlib.h"

typedef struct {
    bool active;
    trinkey_capture_mode_t mode;
    uint32_t next_sample_us;
    uint32_t sample_count;
    uint32_t stored_count;
    uint32_t dropped_count;
    uint32_t overrun_count;
    uint32_t max_loop_us;
    uint32_t max_base_read_us;
    uint32_t max_toolhead_read_us;
    trinkey_acquisition_sample_t records[TRINKEY_CAPTURE_CAPACITY];
} trinkey_capture_state_t;

static trinkey_capture_state_t capture;

void trinkey_capture_init(void) {
    memset(&capture, 0, sizeof(capture));
    capture.mode = TRINKEY_CAPTURE_BOTH;
    capture.next_sample_us = time_us_32();
}

void trinkey_capture_start(trinkey_capture_mode_t mode) {
    capture.active = true;
    capture.mode = mode;
    capture.next_sample_us = time_us_32();
    capture.sample_count = 0;
    capture.stored_count = 0;
    capture.dropped_count = 0;
    capture.overrun_count = 0;
    capture.max_loop_us = 0;
    capture.max_base_read_us = 0;
    capture.max_toolhead_read_us = 0;
}

void trinkey_capture_stop(void) {
    capture.active = false;
}

trinkey_capture_status_t trinkey_capture_status(void) {
    trinkey_capture_status_t status = {
        .mode = capture.mode,
        .active = capture.active,
        .stored_count = capture.stored_count,
        .sample_count = capture.sample_count,
        .dropped_count = capture.dropped_count,
        .overrun_count = capture.overrun_count,
        .capacity = TRINKEY_CAPTURE_CAPACITY,
        .sample_rate_hz = TRINKEY_CAPTURE_SAMPLE_RATE_HZ,
        .max_loop_us = capture.max_loop_us,
        .max_base_read_us = capture.max_base_read_us,
        .max_toolhead_read_us = capture.max_toolhead_read_us,
    };
    return status;
}

void trinkey_capture_sample_if_due(
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead) {
    if (!capture.active) {
        return;
    }

    const int32_t time_to_sample =
        (int32_t)(capture.next_sample_us - time_us_32());
    if (time_to_sample > 0) {
        return;
    }

    const uint32_t loop_start_us = time_us_32();
    const uint32_t sample_index = capture.sample_count++;

    if (capture.stored_count >= TRINKEY_CAPTURE_CAPACITY) {
        capture.dropped_count++;
    } else {
        trinkey_acquisition_sample_t *record =
            &capture.records[capture.stored_count++];
        trinkey_acquisition_timing_t timing;
        trinkey_acquisition_take_sample(
            capture.mode,
            imu_base,
            imu_toolhead,
            sample_index,
            record,
            &timing);
        capture.max_base_read_us = trinkey_max_u32(
            capture.max_base_read_us, timing.base_read_us);
        capture.max_toolhead_read_us = trinkey_max_u32(
            capture.max_toolhead_read_us, timing.toolhead_read_us);
    }

    const uint32_t loop_end_us = time_us_32();
    const uint32_t loop_us = trinkey_elapsed_us(
        loop_start_us, loop_end_us);
    capture.max_loop_us = trinkey_max_u32(capture.max_loop_us, loop_us);

    capture.next_sample_us += TRINKEY_CAPTURE_PERIOD_US;
    if ((int32_t)(capture.next_sample_us - time_us_32()) < 0) {
        capture.overrun_count++;
    }
    if ((int32_t)(capture.next_sample_us - time_us_32())
            < -(int32_t)TRINKEY_CAPTURE_PERIOD_US) {
        capture.next_sample_us = time_us_32();
    }
}

/**
 * Emit one accelerometer sample in the host-facing CSV format.
 *
 * @param chip_id Logical sensor name.
 * @param sample Sample index for the capture instant.
 * @param t_us Trinkey timestamp in microseconds.
 * @param x Raw X acceleration.
 * @param y Raw Y acceleration.
 * @param z Raw Z acceleration.
 */
static void dump_one_sample(
        const char *chip_id,
        uint32_t sample,
        uint64_t t_us,
        int16_t x,
        int16_t y,
        int16_t z) {
    printf(
        "A,%s,%lu,%llu,%d,%d,%d\n",
        chip_id,
        (unsigned long)sample,
        (unsigned long long)t_us,
        x,
        y,
        z
    );
}

void trinkey_capture_dump_csv(void) {
    const trinkey_capture_status_t status = trinkey_capture_status();

    printf(
        "DUMP_BEGIN,%llu,%lu,%lu,%lu,%lu,%lu,%lu,%s,%lu,%lu,%lu\n",
        (unsigned long long)time_us_64(),
        (unsigned long)status.stored_count,
        (unsigned long)status.sample_count,
        (unsigned long)status.dropped_count,
        (unsigned long)status.overrun_count,
        (unsigned long)status.capacity,
        (unsigned long)status.sample_rate_hz,
        trinkey_acquisition_mode_name(status.mode),
        (unsigned long)status.max_loop_us,
        (unsigned long)status.max_base_read_us,
        (unsigned long)status.max_toolhead_read_us
    );

    for (uint32_t i = 0; i < capture.stored_count; i++) {
        const trinkey_acquisition_sample_t *record = &capture.records[i];
        if (record->flags & TRINKEY_SAMPLE_FLAG_BASE_VALID) {
            dump_one_sample(
                "base",
                record->sequence,
                record->base_t_us,
                record->base_x,
                record->base_y,
                record->base_z);
        }
        if (record->flags & TRINKEY_SAMPLE_FLAG_TOOLHEAD_VALID) {
            dump_one_sample(
                "toolhead",
                record->sequence,
                record->toolhead_t_us,
                record->toolhead_x,
                record->toolhead_y,
                record->toolhead_z);
        }
        if (record->flags & TRINKEY_SAMPLE_FLAG_BASE_ERROR) {
            printf("ERR,READ_ACCEL,base,%lu,%llu\n",
                   (unsigned long)record->sequence,
                   (unsigned long long)time_us_64());
        }
        if (record->flags & TRINKEY_SAMPLE_FLAG_TOOLHEAD_ERROR) {
            printf("ERR,READ_ACCEL,toolhead,%lu,%llu\n",
                   (unsigned long)record->sequence,
                   (unsigned long long)time_us_64());
        }
        if ((i % 64u) == 63u) {
            stdio_flush();
        }
    }

    printf(
        "DUMP_END,%llu,%lu,%lu,%lu,%lu,%lu,%lu,%s,%lu,%lu,%lu\n",
        (unsigned long long)time_us_64(),
        (unsigned long)status.stored_count,
        (unsigned long)status.sample_count,
        (unsigned long)status.dropped_count,
        (unsigned long)status.overrun_count,
        (unsigned long)status.capacity,
        (unsigned long)status.sample_rate_hz,
        trinkey_acquisition_mode_name(status.mode),
        (unsigned long)status.max_loop_us,
        (unsigned long)status.max_base_read_us,
        (unsigned long)status.max_toolhead_read_us
    );
    stdio_flush();
}
