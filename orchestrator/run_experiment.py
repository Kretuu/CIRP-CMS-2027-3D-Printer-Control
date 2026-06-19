#!/usr/bin/env python3
"""First-pass PC-side experiment runner for Trinkey + Moonraker tests."""

from __future__ import annotations

import csv
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import serial


SERIAL_PORT = "/dev/ttyACM0"
SERIAL_BAUDRATE = 115200
SERIAL_TIMEOUT_SECONDS = 1.0

REPO_ROOT = Path(__file__).resolve().parent.parent
MOONRAKER_URL = "http://localhost:7125"
OUTPUT_DIR = REPO_ROOT / "data" / "raw"
GCODE_DIR = REPO_ROOT / "trajectories" / "gcode"
GCODE_FILE = "simple_x_sweep.gcode"

LOG_DURATION_SECONDS = 30.0
MOONRAKER_TIMEOUT_SECONDS = 10.0


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def gcode_path() -> Path:
    return GCODE_DIR / GCODE_FILE


def load_gcode_script() -> str:
    path = gcode_path()
    script = path.read_text(encoding="utf-8").strip()
    if not script:
        raise ValueError(f"G-code file is empty: {path}")
    return script


def send_gcode_script(gcode_script: str) -> dict:
    url = f"{MOONRAKER_URL.rstrip('/')}/printer/gcode/script"
    response = requests.post(
        url,
        json={"script": gcode_script},
        timeout=MOONRAKER_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    if response.content:
        return response.json()
    return {}


def create_run_paths() -> tuple[str, Path, Path]:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    run_id = utc_stamp()
    csv_path = OUTPUT_DIR / f"{run_id}_trinkey_accel.csv"
    metadata_path = OUTPUT_DIR / f"{run_id}_metadata.json"
    return run_id, csv_path, metadata_path


def build_metadata(
    run_id: str,
    csv_path: Path,
    selected_gcode_path: Path,
    gcode_script: str,
) -> dict[str, object]:
    return {
        "run_id": run_id,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "serial_port": SERIAL_PORT,
        "serial_baudrate": SERIAL_BAUDRATE,
        "moonraker_url": MOONRAKER_URL,
        "gcode_file": GCODE_FILE,
        "gcode_path": str(selected_gcode_path),
        "gcode_script": gcode_script,
        "log_duration_seconds": LOG_DURATION_SECONDS,
        "csv_path": str(csv_path),
        "moonraker_response": None,
        "error": None,
        "completed_utc": None,
    }


def log_serial_lines(trinkey, writer) -> None:
    end_time = time.monotonic() + LOG_DURATION_SECONDS
    while time.monotonic() < end_time:
        raw_line = trinkey.readline()
        if not raw_line:
            continue

        pc_timestamp = time.monotonic()
        line = raw_line.decode("utf-8", errors="replace").strip()
        writer.writerow([f"{pc_timestamp:.6f}", line])


def run_experiment(csv_path: Path, selected_gcode_path: Path, gcode_script: str) -> dict:
    with serial.Serial(
        SERIAL_PORT,
        SERIAL_BAUDRATE,
        timeout=SERIAL_TIMEOUT_SECONDS,
    ) as trinkey, csv_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(["pc_monotonic_s", "trinkey_line"])

        trinkey.reset_input_buffer()

        print(f"Logging serial data from {SERIAL_PORT} to {csv_path}")
        moonraker_response = send_gcode_script(gcode_script)
        print(f"Sent G-code script to Moonraker: {selected_gcode_path}")

        log_serial_lines(trinkey, writer)
        return moonraker_response


def write_metadata(metadata_path: Path, metadata: dict[str, object]) -> None:
    metadata["completed_utc"] = datetime.now(timezone.utc).isoformat()
    metadata_path.write_text(
        json.dumps(metadata, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote metadata to {metadata_path}")


def main() -> None:
    run_id, csv_path, metadata_path = create_run_paths()
    selected_gcode_path = gcode_path()
    gcode_script = load_gcode_script()
    metadata = build_metadata(run_id, csv_path, selected_gcode_path, gcode_script)

    try:
        metadata["moonraker_response"] = run_experiment(
            csv_path,
            selected_gcode_path,
            gcode_script,
        )
    except KeyboardInterrupt:
        metadata["error"] = "Interrupted by user"
        print("Interrupted")
    except Exception as exc:
        metadata["error"] = repr(exc)
        raise
    finally:
        write_metadata(metadata_path, metadata)


if __name__ == "__main__":
    main()
