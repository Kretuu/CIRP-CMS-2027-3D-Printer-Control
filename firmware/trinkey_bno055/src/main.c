#include <stdio.h>
#include <stdint.h>

#include "pico/stdlib.h"
#include "hardware/i2c.h"
#include "hardware/pio.h"

#include "board_config.h"
#include "i2c_utils.h"
#include "neopixel.h"
#include "bno055.h"

int main(void) {
    stdio_init_all();
    sleep_ms(3000);

    printf("Trinkey QT2040 BNO055 firmware start\n");

    neopixel_t led;
    neopixel_init(&led, pio0, 0, TRINKEY_NEOPIXEL_PIN);

    neopixel_set_rgb(&led, 0, 0, 40); // blue = booting

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

    bno055_t imu;
    bno055_init_struct(&imu, TRINKEY_I2C_PORT, BNO055_ADDR_DEFAULT);

    uint8_t chip_id = 0;

    if (bno055_read_chip_id(&imu, &chip_id)) {
        printf("BNO055 chip ID: 0x%02X\n", chip_id);
    } else {
        printf("Failed to read BNO055 chip ID\n");
        neopixel_set_rgb(&led, 60, 0, 0); // red = error

        while (true) {
            sleep_ms(1000);
        }
    }

    if (!bno055_begin_acconly(&imu)) {
        printf("BNO055 init failed\n");
        neopixel_set_rgb(&led, 60, 0, 0); // red = error

        while (true) {
            sleep_ms(1000);
        }
    }

    printf("BNO055 init complete\n");

    neopixel_set_rgb(&led, 0, 40, 0); // green = running

    uint32_t sample = 0;
    printf("csv,t_us,ax_raw,ay_raw,az_raw\n");

    while (true) {
        bno055_accel_raw_t accel;

        if (bno055_read_accel_raw(&imu, &accel)) {
            printf(
                "%lu,%llu,%d,%d,%d\n",
                sample++,
                (unsigned long long)time_us_64(),
                accel.x,
                accel.y,
                accel.z
                );
        }

        sleep_ms(10);
    }
}