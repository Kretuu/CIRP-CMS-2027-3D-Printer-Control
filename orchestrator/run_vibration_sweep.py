#!/usr/bin/env python3
"""Run Klipper sinusoidal vibration sweeps while logging Trinkey acceleration."""

from __future__ import annotations

import argparse
import csv
import json
import math
import time
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

try:
    import requests
    import serial
except ModuleNotFoundError as exc:
    raise SystemExit(
        "Missing orchestrator Python dependency. Run:\n"
        "  source orchestrator/.venv/bin/activate\n"
        "  python -m pip install -r orchestrator/requirements.txt"
    ) from exc


REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "data" / "raw"

DEFAULT_SERIAL_PORT = "/dev/tty.usbmodem13301"
DEFAULT_SERIAL_BAUDRATE = 115200
SERIAL_TIMEOUT_SECONDS = 0.050

DEFAULT_MOONRAKER_URL = "http://192.168.0.100:7125"
MOONRAKER_TIMEOUT_SECONDS = 30.0

DEFAULT_AXES = ("X",)
DEFAULT_FREQ_START_HZ = 1.0
DEFAULT_FREQ_END_HZ = 100.0
DEFAULT_FREQ_STEP_HZ = 1.0

ACCEL_PER_HZ = 70.0
MAX_ACCEL_MM_S2 = 7500.0
MAX_VELOCITY_MM_S = 500.0
MAX_AMPLITUDE_MM = 2.0

TEST_CYCLES = 8.0
MIN_DURATION_SECONDS = 2.0
MAX_DURATION_SECONDS = 8.0
RAMP_CYCLES = 2.0
PRE_ROLL_SECONDS = 0.500
POST_ROLL_SECONDS = 0.500

SEGMENTS_PER_CYCLE = 32
MAX_SEGMENT_RATE = 6000.0
CHUNK_TIME_SECONDS = 0.250

SETUP_FEEDRATE_MM_MIN = 6000
SAFE_Z_MM = 20.0
CENTER_X_MM = 110.0
CENTER_Y_MM = 110.0

CSV_HEADER = [
    "row_type",
    "pc_monotonic_s",
    "axis",
    "frequency_hz",
    "amplitude_mm",
    "target_accel_mm_s2",
    "duration_s",
    "ramp_time_s",
    "event",
    "trinkey_chip",
    "sample",
    "t_us",
    "ax_raw",
    "ay_raw",
    "az_raw",
    "raw_line",
]


@dataclass(frozen=True)
class SweepPoint:
    axis: str
    frequency_hz: float
    amplitude_mm: float
    target_accel_mm_s2: float
    duration_s: float
    ramp_time_s: float


@dataclass
class PointResult:
    point: SweepPoint
    csv_path: str
    command: str
    started_monotonic_s: float | None = None
    completed_monotonic_s: float | None = None
    moonraker_response: object | None = None
    error: str | None = None


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def monotonic_string() -> str:
    return f"{time.monotonic():.6f}"


def frequency_label(frequency_hz: float) -> str:
    if abs(frequency_hz - round(frequency_hz)) < 0.000001:
        return f"{int(round(frequency_hz)):03d}Hz"
    return f"{frequency_hz:07.3f}Hz".replace(".", "p")


def frequency_range(start_hz: float, end_hz: float, step_hz: float) -> Iterable[float]:
    if step_hz <= 0.0:
        raise ValueError("Frequency step must be positive")
    freq = start_hz
    while freq <= end_hz + step_hz * 0.001:
        yield round(freq, 6)
        freq += step_hz


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def target_accel_for_frequency(frequency_hz: float) -> float:
    return min(ACCEL_PER_HZ * frequency_hz, MAX_ACCEL_MM_S2)


def amplitude_for_frequency(frequency_hz: float, target_accel_mm_s2: float) -> float:
    omega = 2.0 * math.pi * frequency_hz
    accel_limited_amplitude = target_accel_mm_s2 / (omega * omega)
    velocity_limited_amplitude = MAX_VELOCITY_MM_S / omega
    return min(MAX_AMPLITUDE_MM, accel_limited_amplitude, velocity_limited_amplitude)


def duration_for_frequency(frequency_hz: float) -> float:
    return clamp(
        TEST_CYCLES / frequency_hz,
        MIN_DURATION_SECONDS,
        MAX_DURATION_SECONDS,
    )


def ramp_time_for_frequency(duration_s: float, frequency_hz: float) -> float:
    return min(duration_s * 0.25, RAMP_CYCLES / frequency_hz)


def build_sweep_point(axis: str, frequency_hz: float) -> SweepPoint:
    target_accel = target_accel_for_frequency(frequency_hz)
    amplitude = amplitude_for_frequency(frequency_hz, target_accel)
    duration = duration_for_frequency(frequency_hz)
    ramp_time = ramp_time_for_frequency(duration, frequency_hz)
    return SweepPoint(
        axis=axis.upper(),
        frequency_hz=frequency_hz,
        amplitude_mm=amplitude,
        target_accel_mm_s2=target_accel,
        duration_s=duration,
        ramp_time_s=ramp_time,
    )


def build_vibration_command(point: SweepPoint) -> str:
    return (
        "RUN_VIBRATION_TEST "
        f"AXIS={point.axis} "
        f"FREQUENCY={point.frequency_hz:.6f} "
        f"AMPLITUDE={point.amplitude_mm:.6f} "
        f"DURATION={point.duration_s:.6f} "
        f"RAMP_CYCLES={RAMP_CYCLES:.6f} "
        f"SEGMENTS_PER_CYCLE={SEGMENTS_PER_CYCLE} "
        f"MAX_SEGMENT_RATE={MAX_SEGMENT_RATE:.3f} "
        f"CHUNK_TIME={CHUNK_TIME_SECONDS:.6f} "
        f"MAX_VELOCITY={MAX_VELOCITY_MM_S:.3f} "
        f"MAX_ACCEL={MAX_ACCEL_MM_S2:.3f} "
        "INPUT_SHAPING=0 "
        "WAIT=1"
    )


def build_setup_command() -> str:
    return "\n".join(
        [
            "G90",
            f"G1 Z{SAFE_Z_MM:.3f} F{SETUP_FEEDRATE_MM_MIN}",
            f"G1 X{CENTER_X_MM:.3f} Y{CENTER_Y_MM:.3f} F{SETUP_FEEDRATE_MM_MIN}",
            "M400",
        ]
    )


def send_gcode_script(moonraker_url: str, gcode_script: str) -> object:
    url = f"{moonraker_url.rstrip('/')}/printer/gcode/script"
    response = requests.post(
        url,
        json={"script": gcode_script},
        timeout=MOONRAKER_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    if not response.content:
        return {}
    return response.json()


def empty_row(point: SweepPoint, row_type: str) -> dict[str, object]:
    return {
        "row_type": row_type,
        "pc_monotonic_s": monotonic_string(),
        "axis": point.axis,
        "frequency_hz": f"{point.frequency_hz:.6f}",
        "amplitude_mm": f"{point.amplitude_mm:.9f}",
        "target_accel_mm_s2": f"{point.target_accel_mm_s2:.6f}",
        "duration_s": f"{point.duration_s:.6f}",
        "ramp_time_s": f"{point.ramp_time_s:.6f}",
        "event": "",
        "trinkey_chip": "",
        "sample": "",
        "t_us": "",
        "ax_raw": "",
        "ay_raw": "",
        "az_raw": "",
        "raw_line": "",
    }


def write_event(writer: csv.DictWriter, point: SweepPoint, event: str) -> None:
    row = empty_row(point, "event")
    row["event"] = event
    writer.writerow(row)


def parse_trinkey_sample(line: str) -> tuple[str, int, int, int, int, int] | None:
    parts = [part.strip() for part in line.split(",")]
    if len(parts) != 6:
        return None
    chip = parts[0]
    if chip == "chip_id":
        return None
    try:
        sample = int(parts[1])
        t_us = int(parts[2])
        ax_raw = int(parts[3])
        ay_raw = int(parts[4])
        az_raw = int(parts[5])
    except ValueError:
        return None
    return chip, sample, t_us, ax_raw, ay_raw, az_raw


def write_serial_line(writer: csv.DictWriter, point: SweepPoint, line: str) -> None:
    parsed = parse_trinkey_sample(line)
    if parsed is None:
        row = empty_row(point, "raw")
        row["raw_line"] = line
        writer.writerow(row)
        return

    chip, sample, t_us, ax_raw, ay_raw, az_raw = parsed
    row = empty_row(point, "sample")
    row["trinkey_chip"] = chip
    row["sample"] = sample
    row["t_us"] = t_us
    row["ax_raw"] = ax_raw
    row["ay_raw"] = ay_raw
    row["az_raw"] = az_raw
    writer.writerow(row)


def read_serial_once(trinkey: serial.Serial, writer: csv.DictWriter, point: SweepPoint) -> bool:
    raw_line = trinkey.readline()
    if not raw_line:
        return False
    line = raw_line.decode("utf-8", errors="replace").strip()
    if line:
        write_serial_line(writer, point, line)
    return True


def log_for_duration(
    trinkey: serial.Serial,
    writer: csv.DictWriter,
    point: SweepPoint,
    duration_s: float,
) -> None:
    end_time = time.monotonic() + duration_s
    while time.monotonic() < end_time:
        read_serial_once(trinkey, writer, point)


def log_while_future_runs(
    trinkey: serial.Serial,
    writer: csv.DictWriter,
    point: SweepPoint,
    future: Future,
) -> object:
    while not future.done():
        read_serial_once(trinkey, writer, point)
    return future.result()


def run_sweep_point(
    trinkey: serial.Serial,
    executor: ThreadPoolExecutor,
    run_dir: Path,
    moonraker_url: str,
    point: SweepPoint,
) -> PointResult:
    filename = f"{point.axis.lower()}_{frequency_label(point.frequency_hz)}.csv"
    csv_path = run_dir / filename
    command = build_vibration_command(point)
    result = PointResult(point=point, csv_path=str(csv_path), command=command)

    with csv_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=CSV_HEADER)
        writer.writeheader()

        write_event(writer, point, "pre_roll_start")
        trinkey.reset_input_buffer()
        log_for_duration(trinkey, writer, point, PRE_ROLL_SECONDS)

        write_event(writer, point, "moonraker_send")
        result.started_monotonic_s = time.monotonic()
        future = executor.submit(send_gcode_script, moonraker_url, command)
        try:
            result.moonraker_response = log_while_future_runs(
                trinkey, writer, point, future)
            result.completed_monotonic_s = time.monotonic()
            write_event(writer, point, "moonraker_return")
        except Exception as exc:
            result.completed_monotonic_s = time.monotonic()
            result.error = repr(exc)
            write_event(writer, point, "moonraker_error")
            raise

        write_event(writer, point, "post_roll_start")
        log_for_duration(trinkey, writer, point, POST_ROLL_SECONDS)
        write_event(writer, point, "file_complete")

    return result


def parse_axes(raw_axes: list[str] | None) -> list[str]:
    if not raw_axes:
        return list(DEFAULT_AXES)
    axes: list[str] = []
    for raw_axis in raw_axes:
        for axis in raw_axis.split(","):
            axis = axis.strip().upper()
            if axis not in ("X", "Y", "Z"):
                raise ValueError(f"Invalid axis: {axis}")
            axes.append(axis)
    return axes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run RUN_VIBRATION_TEST sweeps and log Trinkey CSV data."
    )
    parser.add_argument("--serial-port", default=DEFAULT_SERIAL_PORT)
    parser.add_argument("--serial-baudrate", type=int, default=DEFAULT_SERIAL_BAUDRATE)
    parser.add_argument("--moonraker-url", default=DEFAULT_MOONRAKER_URL)
    parser.add_argument("--axis", action="append",
                        help="Axis to sweep. Repeat or use comma separated values.")
    parser.add_argument("--freq-start", type=float, default=DEFAULT_FREQ_START_HZ)
    parser.add_argument("--freq-end", type=float, default=DEFAULT_FREQ_END_HZ)
    parser.add_argument("--freq-step", type=float, default=DEFAULT_FREQ_STEP_HZ)
    parser.add_argument("--skip-setup", action="store_true",
                        help="Do not move to the configured center point first.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Write metadata plan without opening serial or Moonraker.")
    return parser.parse_args()


def build_metadata(
    run_id: str,
    run_dir: Path,
    args: argparse.Namespace,
    axes: list[str],
    points: list[SweepPoint],
) -> dict[str, object]:
    return {
        "run_id": run_id,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "run_dir": str(run_dir),
        "serial_port": args.serial_port,
        "serial_baudrate": args.serial_baudrate,
        "moonraker_url": args.moonraker_url,
        "axes": axes,
        "frequency_start_hz": args.freq_start,
        "frequency_end_hz": args.freq_end,
        "frequency_step_hz": args.freq_step,
        "accel_per_hz": ACCEL_PER_HZ,
        "max_accel_mm_s2": MAX_ACCEL_MM_S2,
        "max_velocity_mm_s": MAX_VELOCITY_MM_S,
        "max_amplitude_mm": MAX_AMPLITUDE_MM,
        "test_cycles": TEST_CYCLES,
        "min_duration_seconds": MIN_DURATION_SECONDS,
        "max_duration_seconds": MAX_DURATION_SECONDS,
        "ramp_cycles": RAMP_CYCLES,
        "pre_roll_seconds": PRE_ROLL_SECONDS,
        "post_roll_seconds": POST_ROLL_SECONDS,
        "segments_per_cycle": SEGMENTS_PER_CYCLE,
        "max_segment_rate": MAX_SEGMENT_RATE,
        "chunk_time_seconds": CHUNK_TIME_SECONDS,
        "setup_gcode": None if args.skip_setup else build_setup_command(),
        "points": [asdict(point) for point in points],
        "results": [],
        "error": None,
        "completed_utc": None,
    }


def write_metadata(path: Path, metadata: dict[str, object]) -> None:
    path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def run() -> None:
    args = parse_args()
    axes = parse_axes(args.axis)
    frequencies = list(frequency_range(args.freq_start, args.freq_end, args.freq_step))
    points = [
        build_sweep_point(axis, frequency)
        for axis in axes
        for frequency in frequencies
    ]

    run_id = f"{utc_stamp()}_vibration_sweep"
    run_dir = OUTPUT_ROOT / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    metadata_path = run_dir / "metadata.json"
    metadata = build_metadata(run_id, run_dir, args, axes, points)
    write_metadata(metadata_path, metadata)

    print(f"Run directory: {run_dir}")
    print(f"Sweep points: {len(points)}")

    if args.dry_run:
        print(f"Dry run metadata written to {metadata_path}")
        return

    try:
        with serial.Serial(
            args.serial_port,
            args.serial_baudrate,
            timeout=SERIAL_TIMEOUT_SECONDS,
        ) as trinkey, ThreadPoolExecutor(max_workers=1) as executor:
            trinkey.reset_input_buffer()

            if not args.skip_setup:
                print("Moving printer to sweep center")
                send_gcode_script(args.moonraker_url, build_setup_command())

            for index, point in enumerate(points, start=1):
                print(
                    f"[{index}/{len(points)}] {point.axis} "
                    f"{point.frequency_hz:.3f} Hz, "
                    f"A={point.amplitude_mm:.6f} mm, "
                    f"duration={point.duration_s:.3f} s"
                )
                result = run_sweep_point(
                    trinkey,
                    executor,
                    run_dir,
                    args.moonraker_url,
                    point,
                )
                metadata["results"].append(asdict(result))
                write_metadata(metadata_path, metadata)
    except KeyboardInterrupt:
        metadata["error"] = "Interrupted by user"
        raise
    except Exception as exc:
        metadata["error"] = repr(exc)
        raise
    finally:
        metadata["completed_utc"] = datetime.now(timezone.utc).isoformat()
        write_metadata(metadata_path, metadata)
        print(f"Metadata written to {metadata_path}")


if __name__ == "__main__":
    run()
