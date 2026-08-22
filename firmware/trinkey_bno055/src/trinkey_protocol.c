#include "trinkey_protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pico/stdlib.h"

#include "trinkey_capture.h"
#include "trinkey_stream.h"

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
static bool start_capture(
        trinkey_protocol_state_t *state,
        const char *run_id,
        trinkey_capture_mode_t mode) {
    // Buffered-v1 has a fixed, reproducible anti-alias configuration even if
    // a previous streaming session selected another bandwidth.
    if (state->accel_bandwidth_hz
            != BNO055_DEFAULT_ACCEL_BANDWIDTH_HZ) {
        if (!bno055_set_accel_bandwidth(
                state->imu_base, BNO055_DEFAULT_ACCEL_BANDWIDTH_HZ)
                || !bno055_set_accel_bandwidth(
                    state->imu_toolhead,
                    BNO055_DEFAULT_ACCEL_BANDWIDTH_HZ)) {
            return false;
        }
        state->accel_bandwidth_hz = BNO055_DEFAULT_ACCEL_BANDWIDTH_HZ;
    }
    strncpy(state->run_id, run_id, TRINKEY_RUN_ID_BUFFER_SIZE - 1);
    state->run_id[TRINKEY_RUN_ID_BUFFER_SIZE - 1] = '\0';
    trinkey_capture_start(mode);

    printf("ACK_START,%s,%s,%llu\n",
           state->run_id,
           trinkey_acquisition_mode_name(mode),
           (unsigned long long)time_us_64());
    stdio_flush();
    return true;
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

static void acknowledge_stream_stop(void) {
    printf("ACK_STREAM_STOP,%llu\n",
           (unsigned long long)time_us_64());
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

    if (!trinkey_acquisition_mode_from_string(mode_text, &mode)) {
        printf("ERR,BAD_CAPTURE_MODE,%llu,%s\n",
               (unsigned long long)time_us_64(),
               mode_text);
        stdio_flush();
        return;
    }

    if (!start_capture(state, run_id, mode)) {
        printf("ERR,ACCEL_CONFIG_FAILED,%llu\n",
               (unsigned long long)time_us_64());
        stdio_flush();
    }
}

/**
 * Start the independent binary streaming-v2 protocol.
 *
 * The command is STREAM_START,<run_id>,<mode>,<rate_hz>,<batch_size>.
 * Buffered-v1 START/STOP/DUMP records are deliberately not changed.
 */
static void handle_stream_start_command(
        trinkey_protocol_state_t *state,
        const char *line) {
    char run_id[TRINKEY_RUN_ID_BUFFER_SIZE] = "";
    char mode_text[16] = "";
    char rate_text[16] = "";
    char batch_text[16] = "";
    char *fields[] = {run_id, mode_text, rate_text, batch_text};
    const size_t sizes[] = {
        sizeof(run_id), sizeof(mode_text), sizeof(rate_text),
        sizeof(batch_text)
    };

    const char *field_start = line + strlen("STREAM_START,");
    for (size_t i = 0; i < 4; i++) {
        const char *field_end = strchr(field_start, ',');
        if (field_end == NULL) {
            field_end = field_start + strlen(field_start);
        }
        copy_field(fields[i], sizes[i], field_start, field_end);
        if (i < 3 && *field_end != ',') {
            printf("ERR,BAD_STREAM_START,%llu\n",
                   (unsigned long long)time_us_64());
            stdio_flush();
            return;
        }
        field_start = field_end + (*field_end == ',');
    }

    trinkey_capture_mode_t mode;
    if (!trinkey_acquisition_mode_from_string(mode_text, &mode)) {
        printf("ERR,BAD_CAPTURE_MODE,%llu,%s\n",
               (unsigned long long)time_us_64(), mode_text);
        stdio_flush();
        return;
    }
    char *rate_end = NULL;
    char *batch_end = NULL;
    const uint32_t rate = (uint32_t)strtoul(rate_text, &rate_end, 10);
    const uint32_t batch = (uint32_t)strtoul(batch_text, &batch_end, 10);
    if (!rate_text[0] || *rate_end || !batch_text[0] || *batch_end
            || trinkey_capture_status().active
            || !trinkey_stream_start(mode, rate, batch)) {
        printf("ERR,BAD_STREAM_CONFIG,%llu,%s,%s,%s\n",
               (unsigned long long)time_us_64(),
               mode_text, rate_text, batch_text);
        stdio_flush();
        return;
    }

    strncpy(state->run_id, run_id, TRINKEY_RUN_ID_BUFFER_SIZE - 1);
    state->run_id[TRINKEY_RUN_ID_BUFFER_SIZE - 1] = '\0';
    printf("ACK_STREAM_START,%s,%s,%lu,%lu,%u,%llu\n",
           state->run_id,
           trinkey_acquisition_mode_name(mode),
           (unsigned long)rate,
           (unsigned long)batch,
           TRINKEY_STREAM_PROTOCOL_VERSION,
           (unsigned long long)time_us_64());
    stdio_flush();
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
    if (trinkey_stream_is_started()) {
        if (strcmp(line, "STREAM_STOP") == 0) {
            trinkey_stream_stop();
            acknowledge_stream_stop();
            return;
        }
        if (strncmp(line, "STREAM_SYNC,", 12) == 0) {
            const uint32_t sequence =
                (uint32_t)strtoul(line + 12, NULL, 10);
            const uint64_t timestamp_us = time_us_64();
            trinkey_stream_send_sync(sequence, timestamp_us);
            return;
        }
        if (strcmp(line, "STREAM_STATUS") == 0) {
            trinkey_stream_send_status();
            return;
        }
        // Text output would corrupt binary framing. Return a framed status
        // response for unsupported commands instead.
        trinkey_stream_send_status();
        return;
    }

    if (strncmp(line, "STREAM_START,", 13) == 0) {
        handle_stream_start_command(state, line);
        return;
    }

    if (strcmp(line, "STREAM_STOP") == 0) {
        acknowledge_stream_stop();
        return;
    }

    if (strcmp(line, "CAPS") == 0) {
        printf("CAPS,buffered_v1,stream_v2,%u,%u,%u,%u,%u,%lu,%u,%llu\n",
               TRINKEY_STREAM_MIN_RATE_HZ,
               TRINKEY_STREAM_MAX_RATE_HZ,
               TRINKEY_STREAM_MIN_BATCH_SIZE,
               TRINKEY_STREAM_MAX_BATCH_SIZE,
               TRINKEY_CAPTURE_SAMPLE_RATE_HZ,
               (unsigned long)state->accel_bandwidth_hz,
               BNO055_DEFAULT_ACCEL_RANGE_G,
               (unsigned long long)time_us_64());
        stdio_flush();
        return;
    }

    if (strncmp(line, "SET_BW,", 7) == 0) {
        char *end = NULL;
        const uint32_t bandwidth_hz =
            (uint32_t)strtoul(line + 7, &end, 10);
        // Mark the shared setting unknown until both devices confirm it. This
        // ensures the next buffered START retries its fixed configuration if
        // only one of the two I2C writes succeeds.
        state->accel_bandwidth_hz = 0;
        if (!line[7] || *end || trinkey_capture_status().active
                || !bno055_set_accel_bandwidth(
                    state->imu_base, bandwidth_hz)
                || !bno055_set_accel_bandwidth(
                    state->imu_toolhead, bandwidth_hz)) {
            printf("ERR,BAD_ACCEL_BW,%llu,%lu\n",
                   (unsigned long long)time_us_64(),
                   (unsigned long)bandwidth_hz);
            stdio_flush();
            return;
        }
        state->accel_bandwidth_hz = bandwidth_hz;
        printf("ACK_BW,%lu,%llu\n",
               (unsigned long)bandwidth_hz,
               (unsigned long long)time_us_64());
        stdio_flush();
        return;
    }

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

void trinkey_protocol_init(
        trinkey_protocol_state_t *state,
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead) {
    state->run_id[0] = '\0';
    state->command_buffer[0] = '\0';
    state->command_length = 0;
    state->imu_base = imu_base;
    state->imu_toolhead = imu_toolhead;
    state->accel_bandwidth_hz = BNO055_DEFAULT_ACCEL_BANDWIDTH_HZ;
    trinkey_capture_init();
    trinkey_stream_init(imu_base, imu_toolhead);
}

void trinkey_protocol_print_ready(void) {
    printf("Sample rate target: %u Hz per selected IMU\n",
           TRINKEY_CAPTURE_SAMPLE_RATE_HZ);
    printf("Capture capacity: %u sample instants\n",
           TRINKEY_CAPTURE_CAPACITY);
    printf("Protocol: START,<run_id>,<base|toolhead|both> STOP DUMP "
           "SYNC,<sequence>\n");
    printf("Streaming: STREAM_START,<run_id>,<mode>,<rate>,<batch> "
           "STREAM_SYNC,<sequence> STREAM_STATUS STREAM_STOP\n");
    printf("Accelerometer: range=%ug bandwidth=%uHz; SET_BW,<hz> while idle\n",
           BNO055_DEFAULT_ACCEL_RANGE_G,
           BNO055_DEFAULT_ACCEL_BANDWIDTH_HZ);
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
    if (trinkey_stream_is_started()) {
        trinkey_stream_service_output();
    } else {
        trinkey_capture_sample_if_due(imu_base, imu_toolhead);
    }

    if (trinkey_capture_status().active || trinkey_stream_is_started()) {
        sleep_us(50);
    } else {
        sleep_ms(1);
    }
}
