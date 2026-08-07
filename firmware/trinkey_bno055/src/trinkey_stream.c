#include "trinkey_stream.h"

#include <string.h>

#include "hardware/sync.h"
#include "pico/multicore.h"
#include "pico/stdlib.h"

#define STREAM_RING_CAPACITY 8
#define STREAM_FRAME_MAGIC 0x32534b54u /* little-endian bytes: TKS2 */
#define STREAM_FRAME_DATA 1
#define STREAM_FRAME_SYNC 2
#define STREAM_FRAME_STOP 3
#define STREAM_FRAME_STATUS 4

#define STREAM_RAW_FRAME_CAPACITY 600
#define STREAM_ENCODED_FRAME_CAPACITY 608

typedef struct {
    uint32_t packet_sequence;
    uint32_t sample_rate_hz;
    uint8_t sensor_mask;
    uint8_t sample_count;
    uint32_t total_sample_count;
    uint32_t dropped_count;
    uint32_t transport_dropped_count;
    uint32_t overrun_count;
    uint32_t max_loop_us;
    uint32_t max_base_read_us;
    uint32_t max_toolhead_read_us;
    trinkey_acquisition_sample_t samples[TRINKEY_STREAM_MAX_BATCH_SIZE];
} trinkey_stream_batch_t;

typedef struct {
    volatile bool started;
    volatile bool sampling;
    volatile bool worker_busy;
    volatile uint32_t generation;
    trinkey_capture_mode_t mode;
    uint32_t sample_rate_hz;
    uint32_t sample_period_us;
    uint32_t batch_size;
    volatile uint32_t sample_count;
    volatile uint32_t dropped_count;
    volatile uint32_t transport_dropped_count;
    volatile uint32_t overrun_count;
    volatile uint32_t max_loop_us;
    volatile uint32_t max_base_read_us;
    volatile uint32_t max_toolhead_read_us;
    volatile uint32_t write_index;
    volatile uint32_t read_index;
    trinkey_stream_batch_t batches[STREAM_RING_CAPACITY];
} trinkey_stream_state_t;

static trinkey_stream_state_t stream;
static const bno055_t *stream_imu_base;
static const bno055_t *stream_imu_toolhead;

static void snapshot_batch_counters(trinkey_stream_batch_t *batch) {
    batch->sample_rate_hz = stream.sample_rate_hz;
    batch->sensor_mask = trinkey_acquisition_sensor_mask(stream.mode);
    batch->total_sample_count = stream.sample_count;
    batch->dropped_count = stream.dropped_count;
    batch->transport_dropped_count = stream.transport_dropped_count;
    batch->overrun_count = stream.overrun_count;
    batch->max_loop_us = stream.max_loop_us;
    batch->max_base_read_us = stream.max_base_read_us;
    batch->max_toolhead_read_us = stream.max_toolhead_read_us;
}

static void push_batch(trinkey_stream_batch_t *batch) {
    if (!batch->sample_count) {
        return;
    }
    snapshot_batch_counters(batch);
    const uint32_t write_index = stream.write_index;
    const uint32_t next_index =
        (write_index + 1u) % STREAM_RING_CAPACITY;
    if (next_index == stream.read_index) {
        stream.transport_dropped_count += batch->sample_count;
        return;
    }
    stream.batches[write_index] = *batch;
    __dmb();
    stream.write_index = next_index;
}

static bool pop_batch(trinkey_stream_batch_t *batch) {
    const uint32_t read_index = stream.read_index;
    if (read_index == stream.write_index) {
        return false;
    }
    __dmb();
    *batch = stream.batches[read_index];
    stream.read_index = (read_index + 1u) % STREAM_RING_CAPACITY;
    return true;
}

static void stream_worker(void) {
    uint32_t seen_generation = 0;
    while (true) {
        if (!stream.sampling) {
            stream.worker_busy = false;
            sleep_us(100);
            continue;
        }

        /* Acquire the configuration published before sampling was enabled. */
        __dmb();
        const uint32_t generation = stream.generation;
        if (seen_generation == generation) {
            sleep_us(20);
            continue;
        }
        seen_generation = generation;
        stream.worker_busy = true;

        trinkey_stream_batch_t batch;
        memset(&batch, 0, sizeof(batch));
        uint64_t next_sample_us = time_us_64();
        uint32_t packet_sequence = 0;

        while (stream.sampling && seen_generation == stream.generation) {
            const uint64_t now_us = time_us_64();
            if (now_us < next_sample_us) {
                const uint64_t wait_us = next_sample_us - now_us;
                sleep_us((uint32_t)(wait_us > 50u ? 50u : wait_us));
                continue;
            }

            const uint32_t loop_start_us = time_us_32();
            trinkey_acquisition_sample_t *sample =
                &batch.samples[batch.sample_count];
            trinkey_acquisition_timing_t timing;
            trinkey_acquisition_take_sample(
                stream.mode,
                stream_imu_base,
                stream_imu_toolhead,
                stream.sample_count++,
                sample,
                &timing);
            stream.max_base_read_us = trinkey_max_u32(
                stream.max_base_read_us, timing.base_read_us);
            stream.max_toolhead_read_us = trinkey_max_u32(
                stream.max_toolhead_read_us, timing.toolhead_read_us);

            batch.sample_count++;
            const uint32_t loop_us = trinkey_elapsed_us(
                loop_start_us, time_us_32());
            stream.max_loop_us = trinkey_max_u32(
                stream.max_loop_us, loop_us);

            next_sample_us += stream.sample_period_us;
            const uint64_t after_sample_us = time_us_64();
            if (after_sample_us >= next_sample_us) {
                stream.overrun_count++;
                const uint64_t behind_us = after_sample_us - next_sample_us;
                const uint32_t missed =
                    (uint32_t)(behind_us / stream.sample_period_us) + 1u;
                stream.dropped_count += missed;
                stream.sample_count += missed;
                next_sample_us +=
                    (uint64_t)missed * stream.sample_period_us;
            }

            if (batch.sample_count >= stream.batch_size) {
                batch.packet_sequence = packet_sequence++;
                push_batch(&batch);
                memset(&batch, 0, sizeof(batch));
            }
        }

        if (batch.sample_count) {
            batch.packet_sequence = packet_sequence;
            push_batch(&batch);
        }
        stream.worker_busy = false;
    }
}

static void put_u8(uint8_t *buffer, size_t *pos, uint8_t value) {
    buffer[(*pos)++] = value;
}

static void put_u16(uint8_t *buffer, size_t *pos, uint16_t value) {
    buffer[(*pos)++] = (uint8_t)value;
    buffer[(*pos)++] = (uint8_t)(value >> 8);
}

static void put_i16(uint8_t *buffer, size_t *pos, int16_t value) {
    put_u16(buffer, pos, (uint16_t)value);
}

static void put_u32(uint8_t *buffer, size_t *pos, uint32_t value) {
    for (unsigned int shift = 0; shift < 32; shift += 8) {
        buffer[(*pos)++] = (uint8_t)(value >> shift);
    }
}

static void put_u64(uint8_t *buffer, size_t *pos, uint64_t value) {
    for (unsigned int shift = 0; shift < 64; shift += 8) {
        buffer[(*pos)++] = (uint8_t)(value >> shift);
    }
}

/* CRC-32/ISO-HDLC, compatible with zlib.crc32().  This is the bitwise form
 * of the algorithm specified in RFC 1952, Appendix 8.  The normal polynomial
 * is 0x04c11db7; 0xedb88320 is its reflected representation. */
static uint32_t crc32_ieee(const uint8_t *data, size_t length) {
    uint32_t crc = 0xffffffffu;
    for (size_t i = 0; i < length; i++) {
        crc ^= data[i];
        for (unsigned int bit = 0; bit < 8; bit++) {
            const uint32_t mask = (uint32_t)-(int32_t)(crc & 1u);
            crc = (crc >> 1) ^ (0xedb88320u & mask);
        }
    }
    return ~crc;
}

static size_t cobs_encode(
        const uint8_t *input,
        size_t length,
        uint8_t *output) {
    size_t read_index = 0;
    size_t write_index = 1;
    size_t code_index = 0;
    uint8_t code = 1;

    while (read_index < length) {
        if (input[read_index] == 0) {
            output[code_index] = code;
            code = 1;
            code_index = write_index++;
            read_index++;
            continue;
        }
        output[write_index++] = input[read_index++];
        code++;
        if (code == 0xff) {
            output[code_index] = code;
            code = 1;
            code_index = write_index++;
        }
    }
    output[code_index] = code;
    return write_index;
}

static void send_frame(uint8_t type, const uint8_t *payload, size_t length) {
    uint8_t raw[STREAM_RAW_FRAME_CAPACITY];
    uint8_t encoded[STREAM_ENCODED_FRAME_CAPACITY];
    size_t pos = 0;
    put_u32(raw, &pos, STREAM_FRAME_MAGIC);
    put_u8(raw, &pos, type);
    put_u16(raw, &pos, (uint16_t)length);
    memcpy(raw + pos, payload, length);
    pos += length;
    put_u32(raw, &pos, crc32_ieee(raw, pos));

    size_t encoded_length = cobs_encode(raw, pos, encoded);
    encoded[encoded_length++] = 0;
    stdio_put_string((const char *)encoded, (int)encoded_length, false, false);
}

static size_t serialize_status_payload(uint8_t *payload) {
    const trinkey_stream_status_t status = trinkey_stream_status();
    size_t pos = 0;
    put_u32(payload, &pos, status.sample_rate_hz);
    put_u32(payload, &pos, status.batch_size);
    put_u8(
        payload, &pos, trinkey_acquisition_sensor_mask(status.mode));
    put_u32(payload, &pos, status.sample_count);
    put_u32(payload, &pos, status.dropped_count);
    put_u32(payload, &pos, status.transport_dropped_count);
    put_u32(payload, &pos, status.overrun_count);
    put_u32(payload, &pos, status.max_loop_us);
    put_u32(payload, &pos, status.max_base_read_us);
    put_u32(payload, &pos, status.max_toolhead_read_us);
    return pos;
}

static void send_data_batch(const trinkey_stream_batch_t *batch) {
    uint8_t payload[STREAM_RAW_FRAME_CAPACITY];
    size_t pos = 0;
    put_u32(payload, &pos, batch->packet_sequence);
    put_u16(payload, &pos, (uint16_t)batch->sample_rate_hz);
    put_u8(payload, &pos, batch->sensor_mask);
    put_u8(payload, &pos, batch->sample_count);
    put_u32(payload, &pos, batch->total_sample_count);
    put_u32(payload, &pos, batch->dropped_count);
    put_u32(payload, &pos, batch->transport_dropped_count);
    put_u32(payload, &pos, batch->overrun_count);
    put_u32(payload, &pos, batch->max_loop_us);
    put_u32(payload, &pos, batch->max_base_read_us);
    put_u32(payload, &pos, batch->max_toolhead_read_us);

    for (uint8_t i = 0; i < batch->sample_count; i++) {
        const trinkey_acquisition_sample_t *sample = &batch->samples[i];
        put_u32(payload, &pos, sample->sequence);
        put_u64(payload, &pos, sample->base_t_us);
        put_i16(payload, &pos, sample->base_x);
        put_i16(payload, &pos, sample->base_y);
        put_i16(payload, &pos, sample->base_z);
        put_u64(payload, &pos, sample->toolhead_t_us);
        put_i16(payload, &pos, sample->toolhead_x);
        put_i16(payload, &pos, sample->toolhead_y);
        put_i16(payload, &pos, sample->toolhead_z);
        put_u8(payload, &pos, sample->flags);
    }
    send_frame(STREAM_FRAME_DATA, payload, pos);
}

void trinkey_stream_init(
        const bno055_t *imu_base,
        const bno055_t *imu_toolhead) {
    memset(&stream, 0, sizeof(stream));
    stream.mode = TRINKEY_CAPTURE_BOTH;
    stream_imu_base = imu_base;
    stream_imu_toolhead = imu_toolhead;
    multicore_launch_core1(stream_worker);
}

bool trinkey_stream_start(
        trinkey_capture_mode_t mode,
        uint32_t sample_rate_hz,
        uint32_t batch_size) {
    if (stream.started || stream.worker_busy
            || sample_rate_hz < TRINKEY_STREAM_MIN_RATE_HZ
            || sample_rate_hz > TRINKEY_STREAM_MAX_RATE_HZ
            || batch_size < TRINKEY_STREAM_MIN_BATCH_SIZE
            || batch_size > TRINKEY_STREAM_MAX_BATCH_SIZE
            || 1000000u % sample_rate_hz != 0u) {
        return false;
    }

    stream.mode = mode;
    stream.sample_rate_hz = sample_rate_hz;
    stream.sample_period_us = 1000000u / sample_rate_hz;
    stream.batch_size = batch_size;
    stream.sample_count = 0;
    stream.dropped_count = 0;
    stream.transport_dropped_count = 0;
    stream.overrun_count = 0;
    stream.max_loop_us = 0;
    stream.max_base_read_us = 0;
    stream.max_toolhead_read_us = 0;
    stream.write_index = 0;
    stream.read_index = 0;
    stream.started = true;
    stream.generation++;
    __dmb();
    stream.sampling = true;
    return true;
}

void trinkey_stream_stop(void) {
    if (!stream.started) {
        return;
    }
    stream.sampling = false;
    const uint64_t deadline = time_us_64() + 100000u;
    while (stream.worker_busy && time_us_64() < deadline) {
        sleep_us(50);
    }
    trinkey_stream_batch_t batch;
    while (pop_batch(&batch)) {
        send_data_batch(&batch);
    }
    uint8_t payload[48];
    const size_t length = serialize_status_payload(payload);
    send_frame(STREAM_FRAME_STOP, payload, length);
    stream.started = false;
}

bool trinkey_stream_is_started(void) {
    return stream.started;
}

trinkey_stream_status_t trinkey_stream_status(void) {
    const trinkey_stream_status_t status = {
        .started = stream.started,
        .sampling = stream.sampling,
        .mode = stream.mode,
        .sample_rate_hz = stream.sample_rate_hz,
        .batch_size = stream.batch_size,
        .sample_count = stream.sample_count,
        .dropped_count = stream.dropped_count,
        .transport_dropped_count = stream.transport_dropped_count,
        .overrun_count = stream.overrun_count,
        .max_loop_us = stream.max_loop_us,
        .max_base_read_us = stream.max_base_read_us,
        .max_toolhead_read_us = stream.max_toolhead_read_us,
    };
    return status;
}

void trinkey_stream_service_output(void) {
    trinkey_stream_batch_t batch;
    if (pop_batch(&batch)) {
        send_data_batch(&batch);
    }
}

void trinkey_stream_send_sync(uint32_t sequence, uint64_t trinkey_t_us) {
    uint8_t payload[12];
    size_t pos = 0;
    put_u32(payload, &pos, sequence);
    put_u64(payload, &pos, trinkey_t_us);
    send_frame(STREAM_FRAME_SYNC, payload, pos);
}

void trinkey_stream_send_status(void) {
    uint8_t payload[48];
    const size_t length = serialize_status_payload(payload);
    send_frame(STREAM_FRAME_STATUS, payload, length);
}
