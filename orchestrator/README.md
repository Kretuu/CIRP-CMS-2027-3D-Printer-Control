# Orchestrator

This folder contains PC-side experiment runners for the Trinkey QT2040 BNO055
firmware and the Klipper vibration-test extra.

`run_experiment.py` opens the Trinkey USB serial port, logs each received line with a PC monotonic timestamp, sends a selected G-code file to Moonraker, and writes metadata JSON beside the CSV log.

`run_klipper_vibration_sweep.py` is the current FRF sweep runner. It sends
`RUN_VIBRATION_TEST` commands through Moonraker while Klipper opens the Trinkey
USB serial port and writes the input, output, sync, event, and metadata files on
the printer host.

`run_vibration_sweep.py` is the older local-serial sweep runner. It expects the
Trinkey to stream continuously to the computer running the orchestrator, so it
is mainly useful for older data or for debugging that older workflow.

## Python Setup

Create and activate a virtual environment from the repository root:

```sh
python3 -m venv orchestrator/.venv
source orchestrator/.venv/bin/activate
```

Install the Python dependencies:

```sh
python -m pip install -r orchestrator/requirements.txt
```

Check the Moonraker URL. Pass `--moonraker-url` if Moonraker runs somewhere other than the script default.

## Single G-Code Experiment

This is the first-pass experiment runner. It still assumes that the Trinkey is
connected to the computer running the orchestrator.

Check the local serial port. On macOS the Trinkey usually appears as
`/dev/tty.usbmodem...`; pass it with `--serial-port` if it differs from the
default.

Choose the G-code file. Bare `GCODE_FILE` filenames are loaded from `trajectories/gcode/`. Generated trajectories can be selected with a relative path from `trajectories/`, for example `GCODE_FILE = "generated/stationary_10s.gcode"`.

Run the experiment:

```sh
python orchestrator/run_experiment.py
```

Logs are written to `data/raw/`, which is ignored by Git except for its `.gitkeep` placeholder.

## Klipper-Logged Vibration Sweep

This is the preferred workflow for the current Trinkey firmware. The local
computer only sends Moonraker commands. Klipper performs the motion, talks to the
Trinkey over USB, and writes all time-critical data on the printer host.

Recommended Klipper config:

```ini
[vibration_test]
trinkey: true
trinkey_port: /dev/serial/by-id/<trinkey-usb-id>
trinkey_log_dir: ~/printer_data/logs/vibration_tests
trinkey_sync_count: 20
```

The Klipper Python environment also needs `pyserial`, because the extra opens
the Trinkey serial device directly.

Run a short dry plan first:

```sh
python orchestrator/run_klipper_vibration_sweep.py --dry-run --freq-start 1 --freq-end 3
```

Run the default X/Y 1-100 Hz sweep at 70 mm/s^2 commanded acceleration
amplitude:

```sh
python orchestrator/run_klipper_vibration_sweep.py
```

If `trinkey_port` is not configured in Klipper, pass the Trinkey device path on
the Klipper host:

```sh
python orchestrator/run_klipper_vibration_sweep.py --trinkey-port /dev/ttyACM0
```

Run only one axis, or choose a different input acceleration amplitude:

```sh
python orchestrator/run_klipper_vibration_sweep.py --axis X --accel-amplitude 100
```

The local runner creates only orchestration metadata:

```text
data/raw/<timestamp>_klipper_xy_frf_sweep/
  metadata.json
```

The local `metadata.json` lists every sweep point and its `remote_run_id`. The
actual measurement files are written on the Klipper host, normally under:

```text
~/printer_data/logs/vibration_tests/<remote_run_id>/
  metadata.json
  samples.csv
  sync.csv
  input.csv
  events.csv
```

The files have separate purposes:

- `samples.csv` contains Trinkey accelerometer samples using Trinkey `t_us`.
- `sync.csv` contains timestamp pairs used to map Trinkey `t_us` to Klipper
  `print_time`.
- `input.csv` contains the commanded motion segments in Klipper `print_time`.
- `events.csv` contains coarse run markers such as sync start, motion queued,
  and motion wait complete.
- `metadata.json` contains the command parameters for that frequency point.

For the Ender 3 V3 two-accelerometer layout, use `toolhead/ax_raw` for X motion
and `base/ay_raw` for Y motion. This matches the printer mechanics: the
toolhead moves in X and the bed moves in Y.

The commanded sinusoid is:

```text
x_cmd(t) = A * sin(2*pi*f*t)
a_cmd(t) = -(2*pi*f)^2 * A * sin(2*pi*f*t)
```

The sweep holds commanded acceleration amplitude constant. Therefore the
commanded displacement amplitude is lower at higher frequency:

```text
A = commanded_accel_amplitude / (2*pi*frequency_hz)^2
```

The runner rejects a sweep point if the requested fixed acceleration would need
more than 2 mm displacement amplitude or exceed the configured motion limits.
Lower the acceleration amplitude or raise the start frequency if this happens.

## Downloading Klipper Logs

Yes, the vibration data can be downloaded through Moonraker if
`trinkey_log_dir` is inside Moonraker's `logs` root. The default path
`~/printer_data/logs/vibration_tests` is chosen for that reason.

Check the registered Moonraker roots:

```sh
curl http://<printer-host>:7125/server/files/roots
```

List the vibration log directory:

```sh
curl "http://<printer-host>:7125/server/files/directory?path=logs/vibration_tests"
```

Download one file:

```sh
curl -o samples.csv \
  "http://<printer-host>:7125/server/files/logs/vibration_tests/<remote_run_id>/samples.csv"
```

For downloading a complete run, create a ZIP archive from the remote log
directories and then download that archive. Moonraker's `logs` root is normally
read-only, so write the ZIP file to a writable root such as `config`:

```sh
curl -X POST http://<printer-host>:7125/server/files/zip \
  -H "Content-Type: application/json" \
  -d '{
    "dest": "config/vibration_logs.zip",
    "items": [
      "logs/vibration_tests/<remote_run_id_1>",
      "logs/vibration_tests/<remote_run_id_2>"
    ],
    "store_only": false
  }'

curl -o vibration_logs.zip \
  "http://<printer-host>:7125/server/files/config/vibration_logs.zip"
```

The current Klipper-logged orchestrator records the `remote_run_id` values but
does not yet download the files automatically. A later update can add a
Moonraker download step using the same ZIP endpoint.

## Legacy Local-Serial Vibration Sweep

This older runner also assumes that the Trinkey is connected to the computer
running the orchestrator.

Run a short dry plan first:

```sh
python orchestrator/run_vibration_sweep.py --dry-run --freq-start 1 --freq-end 3
```

Run the default X/Y 1-100 Hz sweep at 70 mm/s^2 commanded acceleration
amplitude:

```sh
python orchestrator/run_vibration_sweep.py
```

Run only one axis, or choose a different input acceleration amplitude:

```sh
python orchestrator/run_vibration_sweep.py --axis X --accel-amplitude 100
```

The sweep runner creates:

```text
data/raw/<timestamp>_xy_frf_sweep/
  metadata.json
  x_001Hz.csv
  x_002Hz.csv
  ...
```

Each frequency CSV contains `event`, `sample`, and `raw` rows. Use `sample` rows for acceleration data. Event rows mark `pre_roll_start`, `moonraker_send`, `moonraker_return`, `post_roll_start`, and `file_complete`.

For the Ender 3 V3 two-accelerometer layout, the sweep metadata includes
`axis_sensor_map`. Use `toolhead/ax_raw` for X motion, `base/ay_raw` for Y
motion.

The commanded sinusoid is reconstructed from metadata:

```text
x_cmd(t) = A * sin(2*pi*f*t)
a_cmd(t) = -(2*pi*f)^2 * A * sin(2*pi*f*t)
```

The sweep holds commanded acceleration amplitude constant. Therefore the
commanded displacement amplitude is lower at higher frequency:

```text
A = commanded_accel_amplitude / (2*pi*frequency_hz)^2
```

The runner rejects a sweep point if the requested fixed acceleration would
need more than 2 mm displacement amplitude or exceed the configured motion
limits. Lower the acceleration amplitude or raise the start frequency if this
happens.
