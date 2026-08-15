# FRF Sweep Orchestrator

`run_klipper_vibration_sweep.py` runs the fixed experimental FRF protocol used
for the dissertation. The local computer sends commands through Moonraker;
Klipper generates the motion, communicates with the Trinkey and writes the
time-critical input, output and synchronisation data on the printer host.

## Setup

Create the Python environment from the repository root:

```sh
python3 -m venv orchestrator/.venv
source orchestrator/.venv/bin/activate
python -m pip install -r orchestrator/requirements.txt
```

Configure the Klipper extension:

```ini
[vibration_test]
trinkey_port: /dev/serial/by-id/<trinkey-usb-id>
trinkey_log_dir: ~/printer_data/logs/vibration_tests
```

The Klipper Python environment must contain `pyserial`.

The current firmware uses a 250 Hz BNO055 accelerometer bandwidth with 500 Hz
buffered acquisition. `RUN_VIBRATION_TEST` reads only the moving-axis sensor
(toolhead for X and base/bed for Y), and this configuration supports the sweep
through 100 Hz without placing the target frequency at the filter boundary. If
the continuous `[trinkey_accel]` Motan logger is configured, stop its client
before running a sweep because buffered-v1 and streaming-v2 deliberately use
exclusive firmware modes and share one USB serial port.

## Running a Sweep

The acceleration amplitude is required and is specified in mm/s². For example,
the 1.5 m/s² experiment is:

```sh
python orchestrator/run_klipper_vibration_sweep.py --accel-amplitude 1500
```

Each frequency/axis point is retried up to two times by default when the
Trinkey dump reports an overrun, dropped sample, missing sample, or duplicate.
Retry attempts use distinct remote run directories, and the local sweep
metadata points analysis at the successful attempt.  Change the retry count
with `--point-retries`; use `--point-retries 0` to disable retries.  Motion,
configuration, connection, and request-timeout failures still stop the sweep.

The fixed protocol tests X followed by Y at every integer frequency from 1 to
100 Hz. The start and end frequencies may be restricted for testing:

```sh
python orchestrator/run_klipper_vibration_sweep.py \
  --accel-amplitude 1500 --freq-start 1 --freq-end 3
```

Use `--dry-run` to create the local plan and print the commands without moving
the printer:

```sh
python orchestrator/run_klipper_vibration_sweep.py \
  --accel-amplitude 1500 --freq-start 1 --freq-end 3 --dry-run
```

The experiment uses the following fixed settings:

- X and Y axes, in that order;
- integer frequency increments;
- eight requested periods with a minimum duration of 2 s;
- a two-period quintic ramp at each end;
- 32 constant-acceleration segments per period;
- 20 clock-synchronisation requests before and after the motion;
- 0.25 s Klipper motion-queue chunks;
- input shaping disabled during the test;
- a setup position of X=110 mm, Y=110 mm and Z=20 mm.

The Moonraker address is `http://192.168.0.2:7125`. The script validates the
planned displacement, velocity and acceleration before sending any motion.
Klipper independently checks homing, travel, kinematic and motion limits.

## Logged Data

The local orchestrator writes its plan and completion status to:

```text
data/raw/<timestamp>_klipper_xy_frf_sweep/metadata.json
```

Klipper normally writes one directory per frequency point under:

```text
~/printer_data/logs/vibration_tests/<remote_run_id>/
  metadata.json
  samples.csv
  sync.csv
  input.csv
  events.csv
```

- `samples.csv` contains Trinkey accelerometer samples and Trinkey timestamps.
- `sync.csv` contains the timestamp pairs used to map Trinkey time to Klipper
  print time.
- `input.csv` contains the exact motion segments queued by Klipper.
- `events.csv` records the acquisition and motion sequence.
- `metadata.json` records the parameters and limits used for the point.

For X motion, analysis uses `toolhead/ax_raw`. For Y motion, it uses
`base/ay_raw`.

## Excitation

For frequency \(f\) and requested acceleration amplitude \(a^\star\), the
displacement amplitude is

```text
A = a_star / (2*pi*f)^2
```

The duration and ramp duration are

```text
T   = max(2, 8/f)
T_r = 2/f
```

Klipper applies the quintic envelope to the displacement sinusoid and logs the
piecewise-constant-acceleration approximation actually executed.

## Downloading Logs

When `trinkey_log_dir` is inside Moonraker's `logs` root, files can be listed
and downloaded through Moonraker:

```sh
curl "http://<printer-host>:7125/server/files/directory?path=logs/vibration_tests"

curl -o samples.csv \
  "http://<printer-host>:7125/server/files/logs/vibration_tests/<remote_run_id>/samples.csv"
```

A complete run can be archived to a writable Moonraker root and downloaded:

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
