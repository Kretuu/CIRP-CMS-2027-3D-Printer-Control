#include <stdio.h>
#include <stdint.h>

#include "pico/stdlib.h"
#include "hardware/i2c.h"
#include "hardware/pio.h"

#include "board_config.h"
#include "i2c_utils.h"
#include "neopixel.h"
#include "bno055.h"

#define I2C_BAUDRATE_HZ  (400 * 1000)
#define SAMPLE_RATE_HZ   400
#define SAMPLE_PERIOD_US (1000000 / SAMPLE_RATE_HZ)

void init_imu_chip(const bno055_t *imu, neopixel_t *led, const char *name) {
    uint8_t chip_id = 0;

    if (bno055_read_chip_id(imu, &chip_id)) {
        printf("%s BNO055 chip ID: 0x%02X\n", name, chip_id);
    } else {
        printf("Failed to read %s BNO055 chip ID\n", name);
        neopixel_set_rgb(led, 60, 0, 0); // red = error

        while (true) {
            sleep_ms(1000);
        }
    }

    if (!bno055_begin_acconly(imu)) {
        printf("%s BNO055 init failed\n", name);
        neopixel_set_rgb(led, 60, 0, 0); // red = error

        while (true) {
            sleep_ms(1000);
        }
    }
}

int main(void) {
    stdio_init_all();

    neopixel_t led;
    neopixel_init(&led, pio0, 0, TRINKEY_NEOPIXEL_PIN);
    neopixel_set_rgb(&led, 0, 0, 100); // blue = booting
    sleep_ms(3000);

    printf("Trinkey QT2040 BNO055 firmware start\n");

    i2c_utils_init(
        TRINKEY_I2C_PORT,
        TRINKEY_I2C_SDA_PIN,
        TRINKEY_I2C_SCL_PIN,
        I2C_BAUDRATE_HZ
    );

    printf(
        "I2C initialized: SDA GPIO%d, SCL GPIO%d, %lu Hz\n",
        TRINKEY_I2C_SDA_PIN,
        TRINKEY_I2C_SCL_PIN,
        (unsigned long)I2C_BAUDRATE_HZ
    );

    neopixel_set_rgb(&led, 40, 40, 0); // yellow = scanning
    i2c_utils_scan_print(TRINKEY_I2C_PORT);

    bno055_t imu_base;
    bno055_t imu_toolhead;
    bno055_init_struct(
        &imu_base,
        TRINKEY_I2C_PORT,
        BNO055_ADDR_DEFAULT,
        BASE_AXIS_REMAP
    );
    bno055_init_struct(
        &imu_toolhead,
        TRINKEY_I2C_PORT,
        BNO055_ADDR_ALT,
        TOOLHEAD_AXIS_REMAP
    );

    const char *base_chip_id = "base";
    const char *toolhead_chip_id = "toolhead";

    init_imu_chip(&imu_base, &led, base_chip_id);
    init_imu_chip(&imu_toolhead, &led, toolhead_chip_id);

    printf("BNO055 chips init complete\n");
    neopixel_set_rgb(&led, 0, 40, 0); // green = running

    uint32_t sample = 0;
    uint32_t next_sample_us = time_us_32();

    printf("Sample rate target: %u Hz per IMU\n", SAMPLE_RATE_HZ);
    printf("chip_id,sample,t_us,ax_raw,ay_raw,az_raw\n");

    while (true) {
        bno055_accel_raw_t accel;
        const uint32_t current_sample = sample++;

        if (bno055_read_accel_raw(&imu_base, &accel)) {
            printf(
                "%s,%lu,%llu,%d,%d,%d\n",
                base_chip_id,
                current_sample,
                (unsigned long long)time_us_64(),
                accel.x,
                accel.y,
                accel.z
                );
        }

        if (bno055_read_accel_raw(&imu_toolhead, &accel)) {
            printf(
                "%s,%lu,%llu,%d,%d,%d\n",
                toolhead_chip_id,
                current_sample,
                (unsigned long long)time_us_64(),
                accel.x,
                accel.y,
                accel.z
                );
        }

        next_sample_us += SAMPLE_PERIOD_US;
        const int32_t sleep_time_us = (int32_t)(next_sample_us - time_us_32());

        if (sleep_time_us > 0) {
            sleep_us((uint32_t)sleep_time_us);
        } else {
            next_sample_us = time_us_32();
        }
    }
}
