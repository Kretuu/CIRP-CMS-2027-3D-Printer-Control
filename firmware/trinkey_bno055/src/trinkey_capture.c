#include "trinkey_capture.h"

#include <stdio.h>
#include <string.h>

#include "pico/stdlib.h"

#define CAPTURE_FLAG_BASE_VALID     0x01
#define CAPTURE_FLAG_TOOLHEAD_VALID 0x02
#define CAPTURE_FLAG_BASE_ERROR     0x04
#define CAPTURE_FLAG_TOOLHEAD_ERROR 0x08

typedef struct {
    uint32_t sample;
    uint64_t base_t_us;
    int16_t base_x;
    int16_t base_y;
    int16_t base_z;
    uint64_t toolhead_t_us;
    int16_t toolhead_x;
    int16_t toolhead_y;
    int16_t toolhead_z;
    uint8_t flags;
} trinkey_capture_record_t;

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
    trinkey_capture_record_t records[TRINKEY_CAPTURE_CAPACITY];
} trinkey_capture_state_t;

static trinkey_capture_state_t capture;

/**
 * Return whether the current capture mode includes the bed/base IMU.
 *
 * @param mode Selected capture mode.
 * @return true when the base sensor should be sampled.
 */
static bool should_capture_base(trinkey_capture_mode_t mode) {
    return mode == TRINKEY_CAPTURE_BASE || mode == TRINKEY_CAPTURE_BOTH;
}

/**
 * Return whether the current capture mode includes the toolhead IMU.
 *
 * @param mode Selected capture mode.
 * @return true when the toolhead sensor should be sampled.
 */
static bool should_capture_toolhead(trinkey_capture_mode_t mode) {
    return mode == TRINKEY_CAPTURE_TOOLHEAD || mode == TRINKEY_CAPTURE_BOTH;
}

/**
 * Return elapsed microseconds using wrap-safe unsigned subtraction.
 *
 * @param start_us Start timestamp from time_us_32().
 * @param end_us End timestamp from time_us_32().
 * @return Elapsed time in microseconds.
 */
static uint32_t elapsed_us(uint32_t start_us, uint32_t end_us) {
    return (uint32_t)(end_us - start_us);
}

/**
 * Update a running maximum diagnostic value.
 *
 * @param current_max Stored maximum value.
 * @param value New value to compare against the stored maximum.
 */
static void update_max(uint32_t *current_max, uint32_t value) {
    if (value > *current_max) {
        *current_max = value;
    }
}

/**
 * Read one accelerometer and store its raw sample in the capture record.
 *
 * @param imu BNO055 device to read.
 * @param timestamp_us Destination timestamp field.
 * @param x Destination raw X acceleration field.
 * @param y Destination raw Y acceleration field.
 * @param z Destination raw Z acceleration field.
 * @param valid_flag Flag set when the read succeeds.
 * @param error_flag Flag set when the read fails.
 * @param max_read_us Running maximum read duration for this sensor.
 * @param record Capture record receiving flags and sample values.
 */
static void capture_one_sensor(
        const bno055_t *imu,
        uint64_t *timestamp_us,
        int16_t *x,
        int16_t *y,
        int16_t *z,
        uint8_t valid_flag,
        uint8_t error_flag,
        uint32_t *max_read_us,
        trinkey_capture_record_t *record) {
    bno055_accel_raw_t accel;
    const uint32_t start_us = time_us_32();
    const bool ok = bno055_read_accel_raw(imu, &accel);
    const uint32_t end_us = time_us_32();

    update_max(max_read_us, elapsed_us(start_us, end_us));
    if (!ok) {
        record->flags |= error_flag;
        return;
    }

    *timestamp_us = time_us_64();
    *x = accel.x;
    *y = accel.y;
    *z = accel.z;
    record->flags |= valid_flag;
}

void trinkey_capture_init(void) {
    memset(&capture, 0, sizeof(capture));
    capture.mode = TRINKEY_CAPTURE_BOTH;
    capture.next_sample_us = time_us_32();
}

bool trinkey_capture_mode_from_string(
        const char *text,
        trinkey_capture_mode_t *mode) {
    if (strcmp(text, "base") == 0) {
        *mode = TRINKEY_CAPTURE_BASE;
        return true;
    }
    if (strcmp(text, "toolhead") == 0) {
        *mode = TRINKEY_CAPTURE_TOOLHEAD;
        return true;
    }
    if (strcmp(text, "both") == 0) {
        *mode = TRINKEY_CAPTURE_BOTH;
        return true;
    }
    return false;
}

const char *trinkey_capture_mode_name(trinkey_capture_mode_t mode) {
    if (mode == TRINKEY_CAPTURE_BASE) {
        return "base";
    }
    if (mode == TRINKEY_CAPTURE_TOOLHEAD) {
        return "toolhead";
    }
    return "both";
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
        trinkey_capture_record_t *record =
            &capture.records[capture.stored_count++];
        memset(record, 0, sizeof(*record));
        record->sample = sample_index;

        if (should_capture_base(capture.mode)) {
            capture_one_sensor(
                imu_base,
                &record->base_t_us,
                &record->base_x,
                &record->base_y,
                &record->base_z,
                CAPTURE_FLAG_BASE_VALID,
                CAPTURE_FLAG_BASE_ERROR,
                &capture.max_base_read_us,
                record);
        }

        if (should_capture_toolhead(capture.mode)) {
            capture_one_sensor(
                imu_toolhead,
                &record->toolhead_t_us,
                &record->toolhead_x,
                &record->toolhead_y,
                &record->toolhead_z,
                CAPTURE_FLAG_TOOLHEAD_VALID,
                CAPTURE_FLAG_TOOLHEAD_ERROR,
                &capture.max_toolhead_read_us,
                record);
        }
    }

    const uint32_t loop_end_us = time_us_32();
    const uint32_t loop_us = elapsed_us(loop_start_us, loop_end_us);
    update_max(&capture.max_loop_us, loop_us);

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
        trinkey_capture_mode_name(status.mode),
        (unsigned long)status.max_loop_us,
        (unsigned long)status.max_base_read_us,
        (unsigned long)status.max_toolhead_read_us
    );

    for (uint32_t i = 0; i < capture.stored_count; i++) {
        const trinkey_capture_record_t *record = &capture.records[i];
        if (record->flags & CAPTURE_FLAG_BASE_VALID) {
            dump_one_sample(
                "base",
                record->sample,
                record->base_t_us,
                record->base_x,
                record->base_y,
                record->base_z);
        }
        if (record->flags & CAPTURE_FLAG_TOOLHEAD_VALID) {
            dump_one_sample(
                "toolhead",
                record->sample,
                record->toolhead_t_us,
                record->toolhead_x,
                record->toolhead_y,
                record->toolhead_z);
        }
        if (record->flags & CAPTURE_FLAG_BASE_ERROR) {
            printf("ERR,READ_ACCEL,base,%lu,%llu\n",
                   (unsigned long)record->sample,
                   (unsigned long long)time_us_64());
        }
        if (record->flags & CAPTURE_FLAG_TOOLHEAD_ERROR) {
            printf("ERR,READ_ACCEL,toolhead,%lu,%llu\n",
                   (unsigned long)record->sample,
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
        trinkey_capture_mode_name(status.mode),
        (unsigned long)status.max_loop_us,
        (unsigned long)status.max_base_read_us,
        (unsigned long)status.max_toolhead_read_us
    );
    stdio_flush();
}
