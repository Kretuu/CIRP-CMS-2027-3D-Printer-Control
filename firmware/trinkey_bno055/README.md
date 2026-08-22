# Trinkey BNO055 firmware

The firmware supports two mutually exclusive acquisition modes. The original
RAM-buffered protocol remains compatible with `RUN_VIBRATION_TEST`; streaming
v2 provides continuous timestamped batches for Klipper and Motan.

## Accelerometer configuration

Both BNO055s run in `ACCONLY` mode with a ±4 g range. The power-on and buffered
vibration-test bandwidth is 250 Hz, paired with a 500 Hz buffered acquisition
rate for measurements up to 100 Hz. While idle, the host may select one of the
BNO055 bandwidth settings:

```text
SET_BW,<8|16|31|63|125|250|500|1000>
ACK_BW,<bandwidth_hz>,<trinkey_t_us>
```

The Klipper streaming extra sends this command automatically. Bandwidth is not
the same as acquisition rate: the configured filter, the BNO055 register update
rate, and the Trinkey polling rate are separate quantities.

## Buffered protocol v1

These commands and records are unchanged:

```text
START,<run_id>,<base|toolhead|both>
STOP
DUMP
SYNC,<sequence>
```

Buffered acquisition remains fixed at 500 Hz with a capacity of 4608 sample
instants (9.216 seconds). `DUMP` emits the existing CSV rows. This is the mode
used by `RUN_VIBRATION_TEST`, which selects only the moving-axis sensor: the
toolhead sensor for X and the base/bed sensor for Y.

## Streaming protocol v2

Streaming is started with an ASCII control command:

```text
STREAM_START,<run_id>,<base|toolhead|both>,<rate_hz>,<batch_size>
ACK_STREAM_START,<run_id>,<mode>,<rate_hz>,<batch_size>,2,<trinkey_t_us>
```

Supported rates are 100–1000 Hz and must divide 1,000,000 exactly. Batch sizes
are 1–16. After `ACK_STREAM_START`, all device-to-host records are binary COBS
frames terminated by a zero byte. The host may continue sending ASCII commands:

```text
STREAM_SYNC,<sequence>
STREAM_STATUS
STREAM_STOP
```

`STREAM_STOP` discards any completed batches, emits a binary stop frame, and
then returns to text framing with `ACK_STREAM_STOP,<trinkey_t_us>`. Discarding
the final few samples keeps recovery independent of USB backpressure. When
already idle, it returns the same acknowledgement without emitting a stop
frame.

### Binary envelope

All integer fields are little-endian:

```text
uint32  magic = 0x32534b54       # bytes "TKS2"
uint8   frame_type               # data=1, sync=2, stop=3, status=4
uint16  payload_length
uint8   payload[payload_length]
uint32  crc32_ieee               # envelope and payload, before CRC
```

The complete envelope is COBS encoded and followed by `0x00`.

Each data sample contains:

```text
uint32 sample_sequence
uint64 base_t_us
int16  base_x, base_y, base_z
uint64 toolhead_t_us
int16  toolhead_x, toolhead_y, toolhead_z
uint8  flags
```

Separate 64-bit timestamps are retained because the two I2C devices are read
sequentially. Flag bits are base-valid `0x01`, toolhead-valid `0x02`, base-error
`0x04`, and toolhead-error `0x08`.

Acquisition runs on RP2040 core 1 and places batches in a bounded ring. USB
transmission runs on core 0. If the host cannot drain the ring, acquisition
continues and `transport_dropped_count` increases. Sequence gaps, scheduling
overruns, read durations, and transport drops are carried in data/status frames.

## Rate validation

Before using 1 kHz for experiments, run a sustained hardware test and verify:

- `overrun_count == 0` and `transport_dropped_count == 0`;
- no host packet-sequence or CRC errors;
- `max_loop_us < 1000` when both sensors are enabled;
- the BNO055 values are actually fresh rather than repeated register values;
- the selected bandwidth is appropriate for the acquisition Nyquist limit.

For buffered sweeps through 100 Hz, use the fixed 500 Hz acquisition with
250 Hz bandwidth and reject runs reporting any drops or overruns. This remains
practical because `RUN_VIBRATION_TEST` reads only the sensor for the moving
axis. Continuous acquisition reads both sensors sequentially, so use 250 Hz
acquisition with 125 Hz bandwidth. This matches the filtered-register update
rate without exceeding the reliable throughput of the shared I2C bus.
