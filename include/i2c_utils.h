#ifndef I2C_UTILS_H
#define I2C_UTILS_H

#include <stdint.h>
#include <stdbool.h>

#include "hardware/i2c.h"

void i2c_utils_init(i2c_inst_t *i2c, uint sda_pin, uint scl_pin, uint baudrate_hz);

bool i2c_utils_reserved_addr(uint8_t addr);

bool i2c_utils_probe_addr(i2c_inst_t *i2c, uint8_t addr);

void i2c_utils_scan_print(i2c_inst_t *i2c);

#endif