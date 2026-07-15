#include "trinkey_protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pico/stdlib.h"

#define SAMPLE_RATE_HZ   400
#define SAMPLE_PERIOD_US (1000000 / SAMPLE_RATE_HZ)

/**
 * Start a new streaming run and reset the per-run sample counter.
 *
 * @param state Mutable protocol state allocated by the caller.
 * @param run_id Short identifier supplied by the Klipper host.
 */
static void start_streaming(
        trinkey_protocol_state_t *state,
        const char *run_id) {
    state->streaming = true;
    state->sample = 0;
    state->next_sample_us = time_us_32();

    strncpy(state->run_id, run_id, TRINKEY_RUN_ID_BUFFER_SIZE - 1);
    state->run_id[TRINKEY_RUN_ID_BUFFER_SIZE - 1] = '\0';

    printf("ACK_START,%s,%llu\n",
           state->run_id,
           (unsigned long long)time_us_64());
    stdio_flush();
}

/**
 * Stop sample streaming while keeping the command interface alive.
 *
 * @param state Mutable protocol state allocated by the caller.
 */
static void stop_streaming(trinkey_protocol_state_t *state) {
    state->streaming = false;
    printf("ACK_STOP,%llu\n", (unsigned long long)time_us_64());
    stdio_flush();
}

/**
 * Reply to a host clock synchronisation request.
 *
 * @param sequence Host-supplied sequence number used to match request/reply.
 */
static void reply_sync(uint32_t sequence) {
    printf("SYNC,%lu,%llu\n",
           (unsigned long)sequence,
           (unsigned long long)time_us_64());
    stdio_flush();
}

/**
 * Execute one complete command line received from USB serial.
 *
 * Supported commands are START,<run_id>, STOP, and SYNC,<sequence>.
 *
 * @param state Mutable protocol state allocated by the caller.
 * @param line Null-terminated command line without the newline character.
 */
static void handle_command_line(
        trinkey_protocol_state_t *state,
        const char *line) {
    if (strcmp(line, "START") == 0 || strncmp(line, "START,", 6) == 0) {
        const char *run_id = "";
        if (line[5] == ',') {
            run_id = line + 6;
        }
        start_streaming(state, run_id);
        return;
    }

    if (strcmp(line, "STOP") == 0) {
        stop_streaming(state);
        return;
    }

    if (strncmp(line, "SYNC,", 5) == 0) {
        uint32_t sequence = (uint32_t)strtoul(line + 5, NULL, 10);
        reply_sync(sequence);
        return;
    }

    printf("ERR,UNKNOWN_COMMAND,%llu,%s\n",
           (unsigned long long)time_us_64(),
           line);
    stdio_flush();
}

/**
 * Read one BNO055 and emit a tagged accelerometer sample row.
 *
 * @param imu BNO055 device to read.
 * @param chip_id Logical sensor name, for example base or toolhead.
 * @param sample Shared sample counter value for this sampling instant.
 */
static void write_accel_sample(
        const bno055_t *imu,
        const char *chip_id,
        uint32_t sample) {
    bno055_accel_raw_t accel;
    if (!bno055_read_accel_raw(imu, &accel)) {
        printf("ERR,READ_ACCEL,%s,%lu,%llu\n",
               chip_id,
               (unsigned long)sample,
               (unsigned long long)time_us_64());
        return;
    }

    printf(
        "A,%s,%lu,%llu,%d,%d,%d\n",
        chip_id,
        (unsigned long)sample,
        (unsigned long long)time_us_64(),
        accel.x,
        accel.y,
        accel.z
    );
}

void trinkey_protocol_init(trinkey_protocol_state_t *state) {
    state->streaming = false;
    state->sample = 0;
    state->next_sample_us = time_us_32();
    state->run_id[0] = '\0';
    state->command_buffer[0] = '\0';
    state->command_length = 0;
}

void trinkey_protocol_print_ready(void) {
    printf("Sample rate target: %u Hz per IMU\n", SAMPLE_RATE_HZ);
    printf("Protocol: START,<run_id> STOP SYNC,<sequence>\n");
    printf("Sample row: A,chip_id,sample,t_us,ax_raw,ay_raw,az_raw\n");
    printf("READY,%llu\n", (unsigned long long)time_us_64());
    stdio_flush();
}

void trinkey_protocol_poll_commands(trinkey_protocol_state_t *state) {
    while (true) {
        int ch = getchar_timeout_us(0);
        if (ch == PICO_ERROR_TIMEOUT) {
            return;
        }

        if (ch == '\r' || ch == '\n') {
            if (state->command_length > 0) {
                state->command_buffer[state->command_length] = '\0';
                handle_command_line(state, state->command_buffer);
                state->command_length = 0;
            }
            continue;
        }

        if (state->command_length < TRINKEY_COMMAND_BUFFER_SIZE - 1) {
            state->command_buffer[state->command_length++] = (char)ch;
        } else {
            state->command_length = 0;
            printf("ERR,COMMAND_TOO_LONG,%llu\n",
                   (unsigned long long)time_us_64());
            stdio_flush();
        }
    }
}

void trinkey_protocol_stream_samples_if_due(
        trinkey_protocol_state_t *state,
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead) {
    const int32_t time_to_sample =
        (int32_t)(state->next_sample_us - time_us_32());
    if (time_to_sample > 0) {
        return;
    }

    const uint32_t current_sample = state->sample++;
    write_accel_sample(imu_base, "base", current_sample);
    trinkey_protocol_poll_commands(state);
    if (state->streaming) {
        write_accel_sample(imu_toolhead, "toolhead", current_sample);
    }

    state->next_sample_us += SAMPLE_PERIOD_US;
    if ((int32_t)(state->next_sample_us - time_us_32()) < -SAMPLE_PERIOD_US) {
        state->next_sample_us = time_us_32();
    }
}

void trinkey_protocol_loop_once(
        trinkey_protocol_state_t *state,
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead) {
    trinkey_protocol_poll_commands(state);
    if (state->streaming) {
        trinkey_protocol_stream_samples_if_due(state, imu_base, imu_toolhead);
        sleep_us(100);
    } else {
        sleep_ms(1);
    }
}
