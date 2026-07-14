#include "neopixel.h"

#include "ws2812.pio.h"
#include "pico/time.h"

static inline uint32_t urgb_u32(uint8_t r, uint8_t g, uint8_t b) {
    // WS2812 / NeoPixel expects GRB order, not RGB.
    return ((uint32_t)g << 16) | ((uint32_t)r << 8) | b;
}

static inline void neopixel_put_raw(neopixel_t *np, uint32_t pixel_grb) {
    pio_sm_put_blocking(np->pio, np->sm, pixel_grb << 8u);
}

void neopixel_init(neopixel_t *np, PIO pio, uint sm, uint pin) {
    np->pio = pio;
    np->sm = sm;
    np->pin = pin;
    np->initialized = false;

    uint offset = pio_add_program(pio, &ws2812_program);

    ws2812_program_init(
        pio,
        sm,
        offset,
        pin,
        800000,
        false
    );

    np->initialized = true;

    neopixel_off(np);
}

void neopixel_set_rgb(neopixel_t *np, uint8_t r, uint8_t g, uint8_t b) {
    if (!np->initialized) {
        return;
    }

    neopixel_put_raw(np, urgb_u32(r, g, b));
    sleep_us(100);
}

void neopixel_off(neopixel_t *np) {
    neopixel_set_rgb(np, 0, 0, 0);
}