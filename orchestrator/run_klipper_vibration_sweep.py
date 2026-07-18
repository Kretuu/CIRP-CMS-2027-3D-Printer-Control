#!/usr/bin/env python3
"""Run X/Y FRF sweeps using Klipper-side Trinkey logging.

This is the orchestrator for the newer workflow where Klipper opens the Trinkey
USB serial port and writes samples.csv, sync.csv, input.csv, events.csv, and
metadata.json on the printer host. The local machine only sends Moonraker G-code
commands and records where the remote logs were written.
"""

from __future__ import annotations

import argparse
import json
import math
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

try:
    import requests
except ModuleNotFoundError as exc:
    raise SystemExit(
        "Missing orchestrator Python dependency. Run:\n"
        "  source orchestrator/.venv/bin/activate\n"
        "  python -m pip install -r orchestrator/requirements.txt"
    ) from exc


REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "data" / "raw"

DEFAULT_MOONRAKER_URL = "http://192.168.0.2:7125"
MOONRAKER_TIMEOUT_SECONDS = 120.0

DEFAULT_AXES = ("X", "Y")
DEFAULT_FREQ_START_HZ = 1.0
DEFAULT_FREQ_END_HZ = 100.0
DEFAULT_FREQ_STEP_HZ = 1.0
DEFAULT_COMMANDED_ACCEL_AMPLITUDE_MM_S2 = 3000.0
DEFAULT_SYNC_COUNT = 20

MAX_ACCEL_MM_S2 = 7500.0
MAX_VELOCITY_MM_S = 500.0
MAX_DISPLACEMENT_AMPLITUDE_MM = 100.0
MOTION_LIMIT_HEADROOM = 0.98

TEST_CYCLES = 8.0
MIN_DURATION_SECONDS = 2.0
MAX_DURATION_SECONDS = 8.0
RAMP_CYCLES = 2.0

SEGMENTS_PER_CYCLE = 32
MAX_SEGMENT_RATE = 6000.0
CHUNK_TIME_SECONDS = 0.250

SETUP_FEEDRATE_MM_MIN = 6000
SAFE_Z_MM = 20.0
CENTER_X_MM = 110.0
CENTER_Y_MM = 110.0

AXIS_SENSOR_MAP = {
    "X": {"trinkey_chip": "toolhead", "accel_column": "ax_raw"},
    "Y": {"trinkey_chip": "base", "accel_column": "ay_raw"},
}


@dataclass(frozen=True)
class SweepPoint:
    axis: str
    frequency_hz: float
    displacement_amplitude_mm: float
    commanded_accel_amplitude_mm_s2: float
    velocity_amplitude_mm_s: float
    duration_s: float
    ramp_time_s: float
    sensor_chip: str
    sensor_column: str


@dataclass
class PointResult:
    axis: str
    frequency_hz: float
    remote_run_id: str
    started_monotonic_s: float | None = None
    completed_monotonic_s: float | None = None
    moonraker_response: object | None = None
    error: str | None = None


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


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


def displacement_amplitude_for_frequency(
    frequency_hz: float,
    commanded_accel_amplitude_mm_s2: float,
) -> float:
    omega = 2.0 * math.pi * frequency_hz
    return commanded_accel_amplitude_mm_s2 / (omega * omega)


def velocity_amplitude_for_frequency(
    frequency_hz: float,
    displacement_amplitude_mm: float,
) -> float:
    return 2.0 * math.pi * frequency_hz * displacement_amplitude_mm


def duration_for_frequency(frequency_hz: float) -> float:
    return clamp(
        TEST_CYCLES / frequency_hz,
        MIN_DURATION_SECONDS,
        MAX_DURATION_SECONDS,
    )


def ramp_time_for_frequency(duration_s: float, frequency_hz: float) -> float:
    return min(duration_s * 0.25, RAMP_CYCLES / frequency_hz)


def build_sweep_point(
    axis: str,
    frequency_hz: float,
    commanded_accel_amplitude_mm_s2: float,
) -> SweepPoint:
    if frequency_hz <= 0.0:
        raise ValueError("Frequency must be positive")
    if commanded_accel_amplitude_mm_s2 <= 0.0:
        raise ValueError("Acceleration amplitude must be positive")

    axis = axis.upper()
    displacement_amplitude = displacement_amplitude_for_frequency(
        frequency_hz, commanded_accel_amplitude_mm_s2)
    velocity_amplitude = velocity_amplitude_for_frequency(
        frequency_hz, displacement_amplitude)
    duration = duration_for_frequency(frequency_hz)
    ramp_time = ramp_time_for_frequency(duration, frequency_hz)
    sensor = AXIS_SENSOR_MAP[axis]
    return SweepPoint(
        axis=axis,
        frequency_hz=frequency_hz,
        displacement_amplitude_mm=displacement_amplitude,
        commanded_accel_amplitude_mm_s2=commanded_accel_amplitude_mm_s2,
        velocity_amplitude_mm_s=velocity_amplitude,
        duration_s=duration,
        ramp_time_s=ramp_time,
        sensor_chip=sensor["trinkey_chip"],
        sensor_column=sensor["accel_column"],
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


def build_remote_run_id(local_run_id: str, point: SweepPoint) -> str:
    return f"{local_run_id}_{point.axis.lower()}_{frequency_label(point.frequency_hz)}"


def build_vibration_command(
    point: SweepPoint,
    remote_run_id: str,
    trinkey_port: str | None,
    remote_log_dir: str | None,
    sync_count: int,
) -> str:
    parts = [
        "RUN_VIBRATION_TEST",
        f"AXIS={point.axis}",
        f"FREQUENCY={point.frequency_hz:.6f}",
        f"AMPLITUDE={point.displacement_amplitude_mm:.6f}",
        f"DURATION={point.duration_s:.6f}",
        f"RAMP_CYCLES={RAMP_CYCLES:.6f}",
        f"SEGMENTS_PER_CYCLE={SEGMENTS_PER_CYCLE}",
        f"MAX_SEGMENT_RATE={MAX_SEGMENT_RATE:.3f}",
        f"CHUNK_TIME={CHUNK_TIME_SECONDS:.6f}",
        f"MAX_VELOCITY={MAX_VELOCITY_MM_S:.3f}",
        f"MAX_ACCEL={MAX_ACCEL_MM_S2:.3f}",
        "INPUT_SHAPING=0",
        "WAIT=1",
        "TRINKEY=1",
        f"RUN_ID={remote_run_id}",
        f"SYNC_COUNT={sync_count}",
    ]
    if trinkey_port:
        parts.append(f"TRINKEY_PORT={trinkey_port}")
    if remote_log_dir:
        parts.append(f"LOG_DIR={remote_log_dir}")
    return " ".join(parts)


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


def run_sweep_point(
    moonraker_url: str,
    local_run_id: str,
    point: SweepPoint,
    trinkey_port: str | None,
    remote_log_dir: str | None,
    sync_count: int,
) -> PointResult:
    remote_run_id = build_remote_run_id(local_run_id, point)
    command = build_vibration_command(
        point, remote_run_id, trinkey_port, remote_log_dir, sync_count)
    result = PointResult(
        axis=point.axis,
        frequency_hz=point.frequency_hz,
        remote_run_id=remote_run_id,
    )
    result.started_monotonic_s = time.monotonic()
    try:
        result.moonraker_response = send_gcode_script(moonraker_url, command)
    except Exception as exc:
        result.completed_monotonic_s = time.monotonic()
        result.error = repr(exc)
        raise
    result.completed_monotonic_s = time.monotonic()
    return result


def parse_axes(raw_axes: list[str] | None) -> list[str]:
    if not raw_axes:
        return list(DEFAULT_AXES)
    axes: list[str] = []
    for raw_axis in raw_axes:
        for axis in raw_axis.split(","):
            axis = axis.strip().upper()
            if axis not in AXIS_SENSOR_MAP:
                raise ValueError("Only X and Y sweeps are supported")
            axes.append(axis)
    return axes


def validate_sweep_points(points: list[SweepPoint]) -> None:
    errors: list[str] = []
    for point in points:
        if point.displacement_amplitude_mm > MAX_DISPLACEMENT_AMPLITUDE_MM:
            errors.append(
                f"{point.axis} {point.frequency_hz:g} Hz requires "
                f"{point.displacement_amplitude_mm:.3f} mm displacement "
                f"amplitude; limit is {MAX_DISPLACEMENT_AMPLITUDE_MM:.3f} mm")
        if point.velocity_amplitude_mm_s > MAX_VELOCITY_MM_S * MOTION_LIMIT_HEADROOM:
            errors.append(
                f"{point.axis} {point.frequency_hz:g} Hz requires "
                f"{point.velocity_amplitude_mm_s:.3f} mm/s velocity "
                f"amplitude; limit is {MAX_VELOCITY_MM_S:.3f} mm/s")
        if (point.commanded_accel_amplitude_mm_s2 >
                MAX_ACCEL_MM_S2 * MOTION_LIMIT_HEADROOM):
            errors.append(
                f"{point.axis} {point.frequency_hz:g} Hz requests "
                f"{point.commanded_accel_amplitude_mm_s2:.3f} mm/s^2 "
                f"acceleration amplitude; limit is {MAX_ACCEL_MM_S2:.3f} mm/s^2")
    if errors:
        raise ValueError("Invalid sweep plan:\n  " + "\n  ".join(errors))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run X/Y FRF sweeps using Klipper-side Trinkey logging."
    )
    parser.add_argument("--moonraker-url", default=DEFAULT_MOONRAKER_URL)
    parser.add_argument("--trinkey-port", default=None,
                        help="Trinkey USB serial path on the Klipper host.")
    parser.add_argument("--remote-log-dir", default=None,
                        help="Log directory on the Klipper host. If omitted, "
                             "[vibration_test] trinkey_log_dir is used.")
    parser.add_argument("--sync-count", type=int, default=DEFAULT_SYNC_COUNT,
                        help="Number of pre and post sync requests per point.")
    parser.add_argument("--axis", action="append",
                        help="Axis to sweep: X or Y. Repeat or use comma separated values.")
    parser.add_argument("--freq-start", type=float, default=DEFAULT_FREQ_START_HZ)
    parser.add_argument("--freq-end", type=float, default=DEFAULT_FREQ_END_HZ)
    parser.add_argument("--freq-step", type=float, default=DEFAULT_FREQ_STEP_HZ)
    parser.add_argument("--accel-amplitude", type=float,
                        default=DEFAULT_COMMANDED_ACCEL_AMPLITUDE_MM_S2,
                        help="Commanded acceleration amplitude in mm/s^2.")
    parser.add_argument("--run-id", default=None,
                        help="Local run id prefix. Defaults to a UTC timestamp.")
    parser.add_argument("--skip-setup", action="store_true",
                        help="Do not move to the configured center point first.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Write metadata and print commands without sending them.")
    return parser.parse_args()


def point_metadata(point: SweepPoint, local_run_id: str) -> dict[str, object]:
    return {
        "axis": point.axis,
        "frequency_hz": point.frequency_hz,
        "displacement_amplitude_mm": point.displacement_amplitude_mm,
        "velocity_amplitude_mm_s": point.velocity_amplitude_mm_s,
        "duration_s": point.duration_s,
        "ramp_time_s": point.ramp_time_s,
        "sensor_chip": point.sensor_chip,
        "sensor_column": point.sensor_column,
        "remote_run_id": build_remote_run_id(local_run_id, point),
    }


def build_metadata(
    local_run_id: str,
    run_dir: Path,
    args: argparse.Namespace,
    axes: list[str],
    points: list[SweepPoint],
) -> dict[str, object]:
    return {
        "run_id": local_run_id,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "run_dir": str(run_dir),
        "experiment": "xy_fixed_accel_frf_sweep_klipper_logged",
        "printer": "Creality Ender 3 V3",
        "moonraker_url": args.moonraker_url,
        "trinkey_port": args.trinkey_port,
        "remote_log_dir": args.remote_log_dir,
        "sync_count": args.sync_count,
        "axes": axes,
        "frequency_start_hz": args.freq_start,
        "frequency_end_hz": args.freq_end,
        "frequency_step_hz": args.freq_step,
        "commanded_accel_amplitude_mm_s2": args.accel_amplitude,
        "max_displacement_amplitude_mm": MAX_DISPLACEMENT_AMPLITUDE_MM,
        "test_cycles": TEST_CYCLES,
        "min_duration_seconds": MIN_DURATION_SECONDS,
        "max_duration_seconds": MAX_DURATION_SECONDS,
        "ramp_cycles": RAMP_CYCLES,
        "segments_per_cycle": SEGMENTS_PER_CYCLE,
        "max_segment_rate": MAX_SEGMENT_RATE,
        "chunk_time_seconds": CHUNK_TIME_SECONDS,
        "axis_sensor_map": AXIS_SENSOR_MAP,
        "timebase": (
            "Input segments are logged by Klipper in print_time. Trinkey samples "
            "are logged by Klipper in Trinkey t_us, with sync.csv used to map "
            "Trinkey t_us to Klipper print_time."
        ),
        "setup_gcode": None if args.skip_setup else build_setup_command(),
        "points": [point_metadata(point, local_run_id) for point in points],
        "results": [],
        "error": None,
        "completed_utc": None,
    }


def write_metadata(path: Path, metadata: dict[str, object]) -> None:
    path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def run() -> None:
    args = parse_args()
    if args.sync_count < 0:
        raise ValueError("SYNC_COUNT must be non-negative")

    axes = parse_axes(args.axis)
    frequencies = list(frequency_range(args.freq_start, args.freq_end, args.freq_step))
    if not frequencies:
        raise ValueError("Frequency range produced no sweep points")
    points = [
        build_sweep_point(axis, frequency, args.accel_amplitude)
        for axis in axes
        for frequency in frequencies
    ]
    validate_sweep_points(points)

    local_run_id = args.run_id or f"{utc_stamp()}_klipper_xy_frf_sweep"
    run_dir = OUTPUT_ROOT / local_run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    metadata_path = run_dir / "metadata.json"
    metadata = build_metadata(local_run_id, run_dir, args, axes, points)
    write_metadata(metadata_path, metadata)

    print(f"Local metadata directory: {run_dir}")
    print(f"Sweep points: {len(points)}")
    if args.remote_log_dir:
        print(f"Remote Klipper log directory: {args.remote_log_dir}")
    else:
        print("Remote Klipper log directory: [vibration_test] trinkey_log_dir")

    try:
        if not args.skip_setup:
            setup = build_setup_command()
            if args.dry_run:
                print("\n# setup")
                print(setup)
            else:
                print("Moving printer to sweep center")
                send_gcode_script(args.moonraker_url, setup)

        for index, point in enumerate(points, start=1):
            remote_run_id = build_remote_run_id(local_run_id, point)
            command = build_vibration_command(
                point, remote_run_id, args.trinkey_port, args.remote_log_dir,
                args.sync_count)
            print(
                f"[{index}/{len(points)}] {point.axis} "
                f"{point.frequency_hz:.3f} Hz, "
                f"A={point.displacement_amplitude_mm:.6f} mm, "
                f"accel={point.commanded_accel_amplitude_mm_s2:.1f} mm/s^2, "
                f"remote_run_id={remote_run_id}"
            )
            if args.dry_run:
                print(command)
                continue
            result = run_sweep_point(
                args.moonraker_url,
                local_run_id,
                point,
                args.trinkey_port,
                args.remote_log_dir,
                args.sync_count,
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
