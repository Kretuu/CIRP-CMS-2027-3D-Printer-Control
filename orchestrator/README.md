# Orchestrator

This folder contains PC-side experiment runners for the Trinkey QT2040 BNO055 firmware.

`run_experiment.py` opens the Trinkey USB serial port, logs each received line with a PC monotonic timestamp, sends a selected G-code file to Moonraker, and writes metadata JSON beside the CSV log.

`run_vibration_sweep.py` runs X/Y fixed-acceleration FRF sweeps through
Klipper `RUN_VIBRATION_TEST` while logging the Trinkey USB serial stream. It
writes one CSV per frequency and a `metadata.json` file for the whole sweep.

## Setup

Create and activate a virtual environment from the repository root:

```sh
python3 -m venv orchestrator/.venv
source orchestrator/.venv/bin/activate
```

Install the Python dependencies:

```sh
python -m pip install -r orchestrator/requirements.txt
```

Check the serial port. On macOS the Trinkey usually appears as `/dev/tty.usbmodem...`; pass it with `--serial-port` if it differs from the default.

Check the Moonraker URL. Pass `--moonraker-url` if Moonraker runs somewhere other than the script default.

Choose the G-code file. Bare `GCODE_FILE` filenames are loaded from `trajectories/gcode/`. Generated trajectories can be selected with a relative path from `trajectories/`, for example `GCODE_FILE = "generated/stationary_10s.gcode"`.

Run the experiment:

```sh
python orchestrator/run_experiment.py
```

Logs are written to `data/raw/`, which is ignored by Git except for its `.gitkeep` placeholder.

## Vibration Sweep

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
