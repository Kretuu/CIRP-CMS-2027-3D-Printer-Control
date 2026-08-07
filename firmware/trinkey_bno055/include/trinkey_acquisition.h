#ifndef TRINKEY_ACQUISITION_H
#define TRINKEY_ACQUISITION_H

#include <stdbool.h>
#include <stdint.h>

#include "bno055.h"

#define TRINKEY_SENSOR_BASE     0x01
#define TRINKEY_SENSOR_TOOLHEAD 0x02

#define TRINKEY_SAMPLE_FLAG_BASE_VALID     0x01
#define TRINKEY_SAMPLE_FLAG_TOOLHEAD_VALID 0x02
#define TRINKEY_SAMPLE_FLAG_BASE_ERROR     0x04
#define TRINKEY_SAMPLE_FLAG_TOOLHEAD_ERROR 0x08

/** Sensor selection shared by buffered capture and continuous streaming. */
typedef enum {
    TRINKEY_CAPTURE_BASE = 0,
    TRINKEY_CAPTURE_TOOLHEAD = 1,
    TRINKEY_CAPTURE_BOTH = 2,
} trinkey_capture_mode_t;

/** One acquisition instant in the common buffered/streaming representation. */
typedef struct {
    uint32_t sequence;
    uint64_t base_t_us;
    int16_t base_x;
    int16_t base_y;
    int16_t base_z;
    uint64_t toolhead_t_us;
    int16_t toolhead_x;
    int16_t toolhead_y;
    int16_t toolhead_z;
    uint8_t flags;
} trinkey_acquisition_sample_t;

/** Time spent reading each selected sensor during one acquisition instant. */
typedef struct {
    uint32_t base_read_us;
    uint32_t toolhead_read_us;
} trinkey_acquisition_timing_t;

/** Return wrap-safe elapsed time for timestamps obtained from time_us_32(). */
static inline uint32_t trinkey_elapsed_us(
        uint32_t start_us,
        uint32_t end_us) {
    return end_us - start_us;
}

/** Return the greater of a running maximum and a new candidate value. */
static inline uint32_t trinkey_max_u32(
        uint32_t current,
        uint32_t candidate) {
    return candidate > current ? candidate : current;
}

bool trinkey_acquisition_mode_from_string(
        const char *text,
        trinkey_capture_mode_t *mode);

const char *trinkey_acquisition_mode_name(trinkey_capture_mode_t mode);

uint8_t trinkey_acquisition_sensor_mask(trinkey_capture_mode_t mode);

/** Read the selected sensors and record timestamps, axes, flags, and timing. */
void trinkey_acquisition_take_sample(
        trinkey_capture_mode_t mode,
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead,
        uint32_t sequence,
        trinkey_acquisition_sample_t *sample,
        trinkey_acquisition_timing_t *timing);

#endif
