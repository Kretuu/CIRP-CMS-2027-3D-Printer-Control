# Orchestrator

This folder contains the first PC-side experiment runner for the Trinkey QT2040 BNO055 firmware.

`run_experiment.py` opens the Trinkey USB serial port, logs each received line with a PC monotonic timestamp, sends a selected G-code file to Moonraker, and writes metadata JSON beside the CSV log.

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

Check the serial port. The default is `/dev/ttyACM0`; update `SERIAL_PORT` at the top of `run_experiment.py` if the Trinkey appears on a different device.

Check the Moonraker URL. The default is `http://localhost:7125`; update `MOONRAKER_URL` if Moonraker runs elsewhere.

Choose the G-code file. Bare `GCODE_FILE` filenames are loaded from `trajectories/gcode/`. Generated trajectories can be selected with a relative path from `trajectories/`, for example `GCODE_FILE = "generated/stationary_10s.gcode"`.

Run the experiment:

```sh
python orchestrator/run_experiment.py
```

Logs are written to `data/raw/`, which is ignored by Git except for its `.gitkeep` placeholder.
