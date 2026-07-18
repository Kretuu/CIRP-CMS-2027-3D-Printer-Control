#include "trinkey_protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pico/stdlib.h"

#include "trinkey_capture.h"

/**
 * Copy one comma-delimited field into a fixed buffer.
 *
 * @param dest Destination buffer.
 * @param dest_size Destination buffer size in bytes.
 * @param start Start of the field.
 * @param end Pointer to comma or string terminator.
 */
static void copy_field(
        char *dest,
        size_t dest_size,
        const char *start,
        const char *end) {
    size_t len = (size_t)(end - start);
    if (len >= dest_size) {
        len = dest_size - 1;
    }
    memcpy(dest, start, len);
    dest[len] = '\0';
}

/**
 * Start a new RAM-buffered capture run.
 *
 * @param state Mutable protocol state allocated by the caller.
 * @param run_id Short identifier supplied by the Klipper host.
 * @param mode Which accelerometer or accelerometers to capture.
 */
static void start_capture(
        trinkey_protocol_state_t *state,
        const char *run_id,
        trinkey_capture_mode_t mode) {
    strncpy(state->run_id, run_id, TRINKEY_RUN_ID_BUFFER_SIZE - 1);
    state->run_id[TRINKEY_RUN_ID_BUFFER_SIZE - 1] = '\0';
    trinkey_capture_start(mode);

    printf("ACK_START,%s,%s,%llu\n",
           state->run_id,
           trinkey_capture_mode_name(mode),
           (unsigned long long)time_us_64());
    stdio_flush();
}

/**
 * Stop RAM-buffered capture while keeping the buffer available for dumping.
 */
static void stop_capture(void) {
    trinkey_capture_stop();
    const trinkey_capture_status_t status = trinkey_capture_status();
    printf("ACK_STOP,%llu,%lu,%lu,%lu,%lu\n",
           (unsigned long long)time_us_64(),
           (unsigned long)status.stored_count,
           (unsigned long)status.sample_count,
           (unsigned long)status.dropped_count,
           (unsigned long)status.overrun_count);
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
 * Handle a START command with optional run id and capture mode fields.
 *
 * Supported forms are START, START,<run_id>, and START,<run_id>,<mode>.
 * Mode may be base, toolhead, or both.
 *
 * @param state Mutable protocol state allocated by the caller.
 * @param line Null-terminated command line.
 */
static void handle_start_command(
        trinkey_protocol_state_t *state,
        const char *line) {
    char run_id[TRINKEY_RUN_ID_BUFFER_SIZE] = "";
    char mode_text[16] = "both";
    trinkey_capture_mode_t mode = TRINKEY_CAPTURE_BOTH;

    if (line[5] == ',') {
        const char *run_start = line + 6;
        const char *run_end = strchr(run_start, ',');
        if (run_end == NULL) {
            run_end = run_start + strlen(run_start);
        }
        copy_field(run_id, sizeof(run_id), run_start, run_end);

        if (*run_end == ',') {
            const char *mode_start = run_end + 1;
            const char *mode_end = mode_start + strlen(mode_start);
            copy_field(mode_text, sizeof(mode_text), mode_start, mode_end);
        }
    }

    if (!trinkey_capture_mode_from_string(mode_text, &mode)) {
        printf("ERR,BAD_CAPTURE_MODE,%llu,%s\n",
               (unsigned long long)time_us_64(),
               mode_text);
        stdio_flush();
        return;
    }

    start_capture(state, run_id, mode);
}

/**
 * Execute one complete command line received from USB serial.
 *
 * Supported commands are START,<run_id>,<mode>, STOP, DUMP, and
 * SYNC,<sequence>.
 *
 * @param state Mutable protocol state allocated by the caller.
 * @param line Null-terminated command line without the newline character.
 */
static void handle_command_line(
        trinkey_protocol_state_t *state,
        const char *line) {
    if (strcmp(line, "START") == 0 || strncmp(line, "START,", 6) == 0) {
        handle_start_command(state, line);
        return;
    }

    if (strcmp(line, "STOP") == 0) {
        stop_capture();
        return;
    }

    if (strcmp(line, "DUMP") == 0) {
        trinkey_capture_dump_csv();
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

void trinkey_protocol_init(trinkey_protocol_state_t *state) {
    state->run_id[0] = '\0';
    state->command_buffer[0] = '\0';
    state->command_length = 0;
    trinkey_capture_init();
}

void trinkey_protocol_print_ready(void) {
    printf("Sample rate target: %u Hz per selected IMU\n",
           TRINKEY_CAPTURE_SAMPLE_RATE_HZ);
    printf("Capture capacity: %u sample instants\n",
           TRINKEY_CAPTURE_CAPACITY);
    printf("Protocol: START,<run_id>,<base|toolhead|both> STOP DUMP "
           "SYNC,<sequence>\n");
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

void trinkey_protocol_loop_once(
        trinkey_protocol_state_t *state,
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead) {
    trinkey_protocol_poll_commands(state);
    trinkey_capture_sample_if_due(imu_base, imu_toolhead);

    if (trinkey_capture_status().active) {
        sleep_us(50);
    } else {
        sleep_ms(1);
    }
}
