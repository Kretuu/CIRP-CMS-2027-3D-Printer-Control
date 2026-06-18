#include "i2c_utils.h"

#include <stdio.h>

#include "pico/stdlib.h"

void i2c_utils_init(i2c_inst_t *i2c, uint sda_pin, uint scl_pin, uint baudrate_hz) {
    i2c_init(i2c, baudrate_hz);

    gpio_set_function(sda_pin, GPIO_FUNC_I2C);
    gpio_set_function(scl_pin, GPIO_FUNC_I2C);

    gpio_pull_up(sda_pin);
    gpio_pull_up(scl_pin);
}

bool i2c_utils_reserved_addr(uint8_t addr) {
    // Reserved I2C addresses:
    // 000 0xxx and 111 1xxx
    return (addr & 0x78) == 0x00 || (addr & 0x78) == 0x78;
}

bool i2c_utils_probe_addr(i2c_inst_t *i2c, uint8_t addr) {
    if (i2c_utils_reserved_addr(addr)) {
        return false;
    }

    uint8_t rxdata = 0;
    int ret = i2c_read_blocking(i2c, addr, &rxdata, 1, false);

    return ret >= 0;
}

void i2c_utils_scan_print(i2c_inst_t *i2c) {
    printf("\nI2C scan start\n");

    for (uint8_t addr = 0; addr < 128; addr++) {
        if (i2c_utils_probe_addr(i2c, addr)) {
            printf("Found device at 0x%02X\n", addr);
        }
    }

    printf("I2C scan complete\n\n");
}