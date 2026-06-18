#include "bno055.h"

#include <stddef.h>

#include "pico/stdlib.h"

#define BNO055_CHIP_ID_REG      0x00
#define BNO055_PAGE_ID_REG      0x07
#define BNO055_ACCEL_DATA_X_LSB 0x08
#define BNO055_OPR_MODE_REG     0x3D
#define BNO055_PWR_MODE_REG     0x3E
#define BNO055_SYS_TRIGGER_REG  0x3F

#define BNO055_CHIP_ID          0xA0

#define BNO055_MODE_CONFIG      0x00
#define BNO055_MODE_ACCONLY     0x01
#define BNO055_PWR_NORMAL       0x00

void bno055_init_struct(bno055_t *dev, i2c_inst_t *i2c, uint8_t addr) {
    dev->i2c = i2c;
    dev->addr = addr;
}

static bool bno055_write_reg(const bno055_t *dev, uint8_t reg, uint8_t value) {
    uint8_t buf[2] = {reg, value};

    int ret = i2c_write_blocking(
        dev->i2c,
        dev->addr,
        buf,
        2,
        false
    );

    return ret == 2;
}

static bool bno055_read_reg(const bno055_t *dev, uint8_t reg, uint8_t *value) {
    int ret;

    ret = i2c_write_blocking(
        dev->i2c,
        dev->addr,
        &reg,
        1,
        true
    );

    if (ret != 1) {
        return false;
    }

    ret = i2c_read_blocking(
        dev->i2c,
        dev->addr,
        value,
        1,
        false
    );

    return ret == 1;
}

static bool bno055_read_regs(
    const bno055_t *dev,
    uint8_t start_reg,
    uint8_t *buf,
    size_t len
) {
    int ret;

    ret = i2c_write_blocking(
        dev->i2c,
        dev->addr,
        &start_reg,
        1,
        true
    );

    if (ret != 1) {
        return false;
    }

    ret = i2c_read_blocking(
        dev->i2c,
        dev->addr,
        buf,
        len,
        false
    );

    return ret == (int)len;
}

bool bno055_read_chip_id(const bno055_t *dev, uint8_t *chip_id) {
    return bno055_read_reg(dev, BNO055_CHIP_ID_REG, chip_id);
}

static bool bno055_wait_for_chip(const bno055_t *dev) {
    for (int attempt = 0; attempt < 20; attempt++) {
        uint8_t chip_id = 0;

        if (bno055_read_chip_id(dev, &chip_id)) {
            if (chip_id == BNO055_CHIP_ID) {
                return true;
            }
        }

        sleep_ms(100);
    }

    return false;
}

bool bno055_begin_acconly(const bno055_t *dev) {
    if (!bno055_wait_for_chip(dev)) {
        return false;
    }

    // Page 0 contains the normal operating registers.
    if (!bno055_write_reg(dev, BNO055_PAGE_ID_REG, 0x00)) {
        return false;
    }
    sleep_ms(10);

    // Must enter config mode before changing operating settings.
    if (!bno055_write_reg(dev, BNO055_OPR_MODE_REG, BNO055_MODE_CONFIG)) {
        return false;
    }
    sleep_ms(25);

    if (!bno055_write_reg(dev, BNO055_PWR_MODE_REG, BNO055_PWR_NORMAL)) {
        return false;
    }
    sleep_ms(10);

    if (!bno055_write_reg(dev, BNO055_SYS_TRIGGER_REG, 0x00)) {
        return false;
    }
    sleep_ms(10);

    // Accelerometer-only mode.
    if (!bno055_write_reg(dev, BNO055_OPR_MODE_REG, BNO055_MODE_ACCONLY)) {
        return false;
    }
    sleep_ms(25);

    return true;
}

bool bno055_read_accel_raw(const bno055_t *dev, bno055_accel_raw_t *accel) {
    uint8_t buf[6];

    if (!bno055_read_regs(dev, BNO055_ACCEL_DATA_X_LSB, buf, sizeof(buf))) {
        return false;
    }

    accel->x = (int16_t)((buf[1] << 8) | buf[0]);
    accel->y = (int16_t)((buf[3] << 8) | buf[2]);
    accel->z = (int16_t)((buf[5] << 8) | buf[4]);

    return true;
}