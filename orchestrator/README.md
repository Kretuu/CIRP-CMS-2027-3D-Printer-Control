# Orchestrator

This folder contains PC-side experiment runners for the Trinkey QT2040 BNO055 firmware.

`run_experiment.py` opens the Trinkey USB serial port, logs each received line with a PC monotonic timestamp, sends a selected G-code file to Moonraker, and writes metadata JSON beside the CSV log.

`run_vibration_sweep.py` runs Klipper `RUN_VIBRATION_TEST` commands through Moonraker while logging the Trinkey USB serial stream. It writes one CSV per frequency and a `metadata.json` file for the whole sweep.

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
python orchestrator/run_vibration_sweep.py --dry-run --axis X --freq-start 1 --freq-end 3
```

Run the default X-axis 1-100 Hz sweep:

```sh
python orchestrator/run_vibration_sweep.py --axis X
```

Run both X and Y:

```sh
python orchestrator/run_vibration_sweep.py --axis X --axis Y
```

The sweep runner creates:

```text
data/raw/<timestamp>_vibration_sweep/
  metadata.json
  x_001Hz.csv
  x_002Hz.csv
  ...
```

Each frequency CSV contains `event`, `sample`, and `raw` rows. Use `sample` rows for acceleration data. Event rows mark `pre_roll_start`, `moonraker_send`, `moonraker_return`, `post_roll_start`, and `file_complete`.

The commanded sinusoid is reconstructed from metadata:

```text
a_cmd(t) = -(2*pi*f)^2 * A * sin(2*pi*f*t)
```

Amplitude is reduced with frequency using Klipper-style acceleration scaling:

```text
target_accel = min(70 * frequency_hz, 7500) mm/s^2
amplitude = target_accel / (2*pi*frequency_hz)^2
```
