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

MOONRAKER_URL = "http://localhost:7125"
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "data" / "raw"

GCODE_SCRIPT = """
G90
G1 X10 F1200
G1 X0 F1200
""".strip()

LOG_DURATION_SECONDS = 30.0
MOONRAKER_TIMEOUT_SECONDS = 10.0


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def send_gcode_script() -> dict:
    url = f"{MOONRAKER_URL.rstrip('/')}/printer/gcode/script"
    response = requests.post(
        url,
        json={"script": GCODE_SCRIPT},
        timeout=MOONRAKER_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    if response.content:
        return response.json()
    return {}


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    run_id = utc_stamp()
    csv_path = OUTPUT_DIR / f"{run_id}_trinkey_accel.csv"
    metadata_path = OUTPUT_DIR / f"{run_id}_metadata.json"

    metadata = {
        "run_id": run_id,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "serial_port": SERIAL_PORT,
        "serial_baudrate": SERIAL_BAUDRATE,
        "moonraker_url": MOONRAKER_URL,
        "gcode_script": GCODE_SCRIPT,
        "log_duration_seconds": LOG_DURATION_SECONDS,
        "csv_path": str(csv_path),
        "moonraker_response": None,
        "error": None,
        "completed_utc": None,
    }

    try:
        with serial.Serial(
            SERIAL_PORT,
            SERIAL_BAUDRATE,
            timeout=SERIAL_TIMEOUT_SECONDS,
        ) as trinkey, csv_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.writer(csv_file)
            writer.writerow(["pc_monotonic_s", "trinkey_line"])

            trinkey.reset_input_buffer()

            print(f"Logging serial data from {SERIAL_PORT} to {csv_path}")
            metadata["moonraker_response"] = send_gcode_script()
            print("Sent G-code script to Moonraker")

            end_time = time.monotonic() + LOG_DURATION_SECONDS
            while time.monotonic() < end_time:
                raw_line = trinkey.readline()
                if not raw_line:
                    continue

                pc_timestamp = time.monotonic()
                line = raw_line.decode("utf-8", errors="replace").strip()
                writer.writerow([f"{pc_timestamp:.6f}", line])

    except KeyboardInterrupt:
        metadata["error"] = "Interrupted by user"
        print("Interrupted")
    except Exception as exc:
        metadata["error"] = repr(exc)
        raise
    finally:
        metadata["completed_utc"] = datetime.now(timezone.utc).isoformat()
        metadata_path.write_text(
            json.dumps(metadata, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Wrote metadata to {metadata_path}")


if __name__ == "__main__":
    main()
