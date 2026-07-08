#include <stdio.h>
#include <stdint.h>

#include "pico/stdlib.h"
#include "hardware/i2c.h"
#include "hardware/pio.h"

#include "board_config.h"
#include "i2c_utils.h"
#include "neopixel.h"
#include "bno055.h"

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
        100 * 1000
    );

    printf(
        "I2C initialized: SDA GPIO%d, SCL GPIO%d\n",
        TRINKEY_I2C_SDA_PIN,
        TRINKEY_I2C_SCL_PIN
    );

    neopixel_set_rgb(&led, 40, 40, 0); // yellow = scanning
    i2c_utils_scan_print(TRINKEY_I2C_PORT);

    bno055_t imu_base;
    bno055_t imu_toolhead;
    bno055_init_struct(&imu_base, TRINKEY_I2C_PORT, BNO055_ADDR_DEFAULT);
    bno055_init_struct(&imu_toolhead, TRINKEY_I2C_PORT, BNO055_ADDR_ALT);

    const char *base_chip_id = "base";
    const char *toolhead_chip_id = "toolhead";

    init_imu_chip(&imu_base, &led, base_chip_id);
    init_imu_chip(&imu_toolhead, &led, toolhead_chip_id);

    printf("BNO055 chips init complete\n");
    neopixel_set_rgb(&led, 0, 40, 0); // green = running

    uint32_t sample = 0;
    printf("chip_id,csv,t_us,ax_raw,ay_raw,az_raw\n");

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

        sleep_ms(10);
    }
}