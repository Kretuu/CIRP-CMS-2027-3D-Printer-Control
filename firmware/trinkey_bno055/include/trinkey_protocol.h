#ifndef TRINKEY_PROTOCOL_H
#define TRINKEY_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bno055.h"

#define TRINKEY_COMMAND_BUFFER_SIZE 96
#define TRINKEY_RUN_ID_BUFFER_SIZE 64

typedef struct {
    char run_id[TRINKEY_RUN_ID_BUFFER_SIZE];
    char command_buffer[TRINKEY_COMMAND_BUFFER_SIZE];
    size_t command_length;
} trinkey_protocol_state_t;

/**
 * Initialise the USB protocol state used by the Trinkey logger.
 *
 * @param state Mutable protocol state allocated by the caller.
 */
void trinkey_protocol_init(trinkey_protocol_state_t *state);

/**
 * Print the protocol banner and READY row after hardware initialisation.
 */
void trinkey_protocol_print_ready(void);

/**
 * Poll USB serial once and process any complete command lines.
 *
 * @param state Mutable protocol state allocated by the caller.
 */
void trinkey_protocol_poll_commands(trinkey_protocol_state_t *state);

/**
 * Run one iteration of command polling and optional buffered capture.
 *
 * @param state Mutable protocol state allocated by the caller.
 * @param imu_base Bed/base accelerometer.
 * @param imu_toolhead Toolhead accelerometer.
 */
void trinkey_protocol_loop_once(
        trinkey_protocol_state_t *state,
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead);

#endif
