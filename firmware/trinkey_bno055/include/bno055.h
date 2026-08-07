#ifndef BNO055_H
#define BNO055_H

#include <stdint.h>
#include <stdbool.h>

#include "hardware/i2c.h"

#define BNO055_ADDR_DEFAULT 0x28
#define BNO055_ADDR_ALT     0x29

#define BNO055_DEFAULT_ACCEL_RANGE_G 4
#define BNO055_DEFAULT_ACCEL_BANDWIDTH_HZ 250

typedef enum {
    BNO055_AXIS_X = 0,
    BNO055_AXIS_Y = 1,
    BNO055_AXIS_Z = 2,
    BNO055_AXIS_COUNT = 3,
} bno055_axis_t;

typedef struct {
    // Source input axis used for each output x/y/z axis.
    bno055_axis_t src[BNO055_AXIS_COUNT];
    int8_t sign[BNO055_AXIS_COUNT]; // +1 or -1
} bno055_axis_remap_t;

typedef struct {
    i2c_inst_t *i2c;
    uint8_t addr;
    bno055_axis_remap_t accel_remap;
} bno055_t;

typedef struct {
    int16_t x;
    int16_t y;
    int16_t z;
} bno055_accel_raw_t;

extern const bno055_axis_remap_t TOOLHEAD_AXIS_REMAP;
extern const bno055_axis_remap_t BASE_AXIS_REMAP;

void bno055_init_struct(
        bno055_t *dev,
        i2c_inst_t *i2c,
        uint8_t addr,
        bno055_axis_remap_t axis_remap);

bool bno055_read_chip_id(const bno055_t *dev, uint8_t *chip_id);

bool bno055_begin_acconly(const bno055_t *dev);

/**
 * Change the accelerometer anti-alias filter while preserving ACCONLY mode.
 * Supported values are 8, 16, 31, 63, 125, 250, 500, and 1000 Hz.
 */
bool bno055_set_accel_bandwidth(
        const bno055_t *dev,
        uint32_t bandwidth_hz);

bool bno055_read_accel_raw(const bno055_t *dev, bno055_accel_raw_t *accel);

#endif
