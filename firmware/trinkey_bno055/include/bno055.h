#ifndef BNO055_H
#define BNO055_H

#include <stdint.h>
#include <stdbool.h>

#include "hardware/i2c.h"

#define BNO055_ADDR_DEFAULT 0x28
#define BNO055_ADDR_ALT     0x29

typedef struct {
    i2c_inst_t *i2c;
    uint8_t addr;
} bno055_t;

typedef struct {
    int16_t x;
    int16_t y;
    int16_t z;
} bno055_accel_raw_t;

void bno055_init_struct(bno055_t *dev, i2c_inst_t *i2c, uint8_t addr);

bool bno055_read_chip_id(const bno055_t *dev, uint8_t *chip_id);

bool bno055_begin_acconly(const bno055_t *dev);

bool bno055_read_accel_raw(const bno055_t *dev, bno055_accel_raw_t *accel);

#endif