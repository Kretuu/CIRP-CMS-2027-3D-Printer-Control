#include <stdio.h>
#include <stdint.h>

#include "pico/stdlib.h"
#include "hardware/i2c.h"
#include "hardware/pio.h"

#include "board_config.h"
#include "i2c_utils.h"
#include "neopixel.h"
#include "bno055.h"
#include "trinkey_protocol.h"

#define I2C_BAUDRATE_HZ  (400 * 1000)

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

    init_imu_chip(&imu_base, &led, "base");
    init_imu_chip(&imu_toolhead, &led, "toolhead");

    printf("BNO055 chips init complete\n");
    neopixel_set_rgb(&led, 0, 40, 0); // green = running

    trinkey_protocol_state_t protocol_state;
    trinkey_protocol_init(&protocol_state);
    trinkey_protocol_print_ready();

    while (true) {
        trinkey_protocol_loop_once(
            &protocol_state,
            &imu_base,
            &imu_toolhead
        );
    }
}
