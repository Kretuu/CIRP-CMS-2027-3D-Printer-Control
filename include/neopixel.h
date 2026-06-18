#ifndef NEOPIXEL_H
#define NEOPIXEL_H

#include <stdint.h>
#include <stdbool.h>

#include "hardware/pio.h"

typedef struct {
    PIO pio;
    uint sm;
    uint pin;
    bool initialized;
} neopixel_t;

void neopixel_init(neopixel_t *np, PIO pio, uint sm, uint pin);

void neopixel_set_rgb(neopixel_t *np, uint8_t r, uint8_t g, uint8_t b);

void neopixel_off(neopixel_t *np);

#endif