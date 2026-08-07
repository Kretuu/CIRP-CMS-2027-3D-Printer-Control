#include "trinkey_acquisition.h"

#include <string.h>

#include "pico/stdlib.h"

static bool mode_has_base(trinkey_capture_mode_t mode) {
    return mode == TRINKEY_CAPTURE_BASE || mode == TRINKEY_CAPTURE_BOTH;
}

static bool mode_has_toolhead(trinkey_capture_mode_t mode) {
    return mode == TRINKEY_CAPTURE_TOOLHEAD || mode == TRINKEY_CAPTURE_BOTH;
}

static void read_one_sensor(
        const bno055_t *imu,
        uint64_t *timestamp_us,
        int16_t *x,
        int16_t *y,
        int16_t *z,
        uint8_t valid_flag,
        uint8_t error_flag,
        uint32_t *read_duration_us,
        uint8_t *flags) {
    bno055_accel_raw_t accel;
    const uint32_t start_us = time_us_32();
    const bool ok = bno055_read_accel_raw(imu, &accel);
    const uint32_t end_us = time_us_32();
    *read_duration_us = trinkey_elapsed_us(start_us, end_us);

    if (!ok) {
        *flags |= error_flag;
        return;
    }

    *timestamp_us = time_us_64();
    *x = accel.x;
    *y = accel.y;
    *z = accel.z;
    *flags |= valid_flag;
}

bool trinkey_acquisition_mode_from_string(
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

const char *trinkey_acquisition_mode_name(trinkey_capture_mode_t mode) {
    if (mode == TRINKEY_CAPTURE_BASE) {
        return "base";
    }
    if (mode == TRINKEY_CAPTURE_TOOLHEAD) {
        return "toolhead";
    }
    return "both";
}

uint8_t trinkey_acquisition_sensor_mask(trinkey_capture_mode_t mode) {
    uint8_t mask = 0;
    if (mode_has_base(mode)) {
        mask |= TRINKEY_SENSOR_BASE;
    }
    if (mode_has_toolhead(mode)) {
        mask |= TRINKEY_SENSOR_TOOLHEAD;
    }
    return mask;
}

void trinkey_acquisition_take_sample(
        trinkey_capture_mode_t mode,
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead,
        uint32_t sequence,
        trinkey_acquisition_sample_t *sample,
        trinkey_acquisition_timing_t *timing) {
    memset(sample, 0, sizeof(*sample));
    memset(timing, 0, sizeof(*timing));
    sample->sequence = sequence;

    if (mode_has_base(mode)) {
        read_one_sensor(
            imu_base,
            &sample->base_t_us,
            &sample->base_x,
            &sample->base_y,
            &sample->base_z,
            TRINKEY_SAMPLE_FLAG_BASE_VALID,
            TRINKEY_SAMPLE_FLAG_BASE_ERROR,
            &timing->base_read_us,
            &sample->flags);
    }

    if (mode_has_toolhead(mode)) {
        read_one_sensor(
            imu_toolhead,
            &sample->toolhead_t_us,
            &sample->toolhead_x,
            &sample->toolhead_y,
            &sample->toolhead_z,
            TRINKEY_SAMPLE_FLAG_TOOLHEAD_VALID,
            TRINKEY_SAMPLE_FLAG_TOOLHEAD_ERROR,
            &timing->toolhead_read_us,
            &sample->flags);
    }
}
