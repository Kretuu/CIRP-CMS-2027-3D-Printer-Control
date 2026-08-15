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

MOONRAKER_URL = "http://192.168.0.2:7125"
MOONRAKER_TIMEOUT_SECONDS = 120.0
DEFAULT_POINT_RETRIES = 2
POINT_RETRY_DELAY_SECONDS = 2.0

RETRYABLE_ACQUISITION_ERRORS = (
    "Incomplete Trinkey dump",
    "buffer_dropped=",
    "sampling_overruns=",
    "missing=",
    "duplicates=",
)

AXES = ("X", "Y")
MIN_FREQUENCY_HZ = 1
MAX_FREQUENCY_HZ = 100
SYNC_COUNT = 20

MAX_ACCEL_MM_S2 = 7500.0
MAX_VELOCITY_MM_S = 500.0
MAX_DISPLACEMENT_AMPLITUDE_MM = 100.0
MOTION_LIMIT_HEADROOM = 0.98

TEST_CYCLES = 8.0
MIN_DURATION_SECONDS = 2.0

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
    attempt: int
    started_monotonic_s: float | None = None
    completed_monotonic_s: float | None = None
    moonraker_response: object | None = None
    error: str | None = None
    retryable: bool = False


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def frequency_label(frequency_hz: float) -> str:
    return f"{int(frequency_hz):03d}Hz"


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
    return max(MIN_DURATION_SECONDS, TEST_CYCLES / frequency_hz)


def ramp_time_for_frequency(frequency_hz: float) -> float:
    # Use a two-period ramp at every excitation frequency.
    return 2.0 / frequency_hz


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
    ramp_time = ramp_time_for_frequency(frequency_hz)
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


def build_remote_run_id(
    local_run_id: str,
    point: SweepPoint,
    attempt: int = 1,
) -> str:
    run_id = (
        f"{local_run_id}_{point.axis.lower()}_"
        f"{frequency_label(point.frequency_hz)}"
    )
    if attempt > 1:
        run_id += f"_retry{attempt - 1:02d}"
    return run_id


def build_vibration_command(
    point: SweepPoint,
    remote_run_id: str,
) -> str:
    return " ".join([
        "RUN_VIBRATION_TEST",
        f"AXIS={point.axis}",
        f"FREQUENCY={point.frequency_hz:.6f}",
        f"AMPLITUDE={point.displacement_amplitude_mm:.6f}",
        f"DURATION={point.duration_s:.6f}",
        f"RAMP_TIME={point.ramp_time_s:.17g}",
        f"RUN_ID={remote_run_id}",
    ])


def send_gcode_script(gcode_script: str) -> object:
    url = f"{MOONRAKER_URL}/printer/gcode/script"
    response = requests.post(
        url,
        json={"script": gcode_script},
        timeout=MOONRAKER_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    if not response.content:
        return {}
    return response.json()


def exception_detail(exc: Exception) -> str:
    """Include the Moonraker response body in a recorded request failure."""
    parts = [repr(exc)]
    response = getattr(exc, "response", None)
    if response is not None:
        body = response.text.strip()
        if body:
            parts.append(body)
    return "\n".join(parts)


def is_retryable_acquisition_error(detail: str) -> bool:
    """Return whether a failed point should be repeated automatically."""
    return any(marker in detail for marker in RETRYABLE_ACQUISITION_ERRORS)


def run_sweep_point(
    local_run_id: str,
    point: SweepPoint,
    attempt: int,
) -> PointResult:
    remote_run_id = build_remote_run_id(local_run_id, point, attempt)
    command = build_vibration_command(point, remote_run_id)
    result = PointResult(
        axis=point.axis,
        frequency_hz=point.frequency_hz,
        remote_run_id=remote_run_id,
        attempt=attempt,
    )
    result.started_monotonic_s = time.monotonic()
    try:
        result.moonraker_response = send_gcode_script(command)
    except Exception as exc:
        result.completed_monotonic_s = time.monotonic()
        result.error = exception_detail(exc)
        result.retryable = is_retryable_acquisition_error(result.error)
        return result
    result.completed_monotonic_s = time.monotonic()
    return result


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
    parser.add_argument("--freq-start", type=int, default=MIN_FREQUENCY_HZ)
    parser.add_argument("--freq-end", type=int, default=MAX_FREQUENCY_HZ)
    parser.add_argument("--accel-amplitude", type=float, required=True,
                        help="Commanded acceleration amplitude in mm/s^2.")
    parser.add_argument(
        "--point-retries", type=int, default=DEFAULT_POINT_RETRIES,
        help=(
            "Retries after a point fails Trinkey acquisition validation "
            f"(default: {DEFAULT_POINT_RETRIES})."
        ),
    )
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
    points: list[SweepPoint],
) -> dict[str, object]:
    return {
        "run_id": local_run_id,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "run_dir": str(run_dir),
        "experiment": "xy_fixed_accel_frf_sweep_klipper_logged",
        "printer": "Creality Ender 3 V3",
        "moonraker_url": MOONRAKER_URL,
        "sync_count": SYNC_COUNT,
        "axes": list(AXES),
        "frequency_start_hz": args.freq_start,
        "frequency_end_hz": args.freq_end,
        "frequency_step_hz": 1,
        "commanded_accel_amplitude_mm_s2": args.accel_amplitude,
        "max_displacement_amplitude_mm": MAX_DISPLACEMENT_AMPLITUDE_MM,
        "test_cycles": TEST_CYCLES,
        "min_duration_seconds": MIN_DURATION_SECONDS,
        "segments_per_cycle": SEGMENTS_PER_CYCLE,
        "max_segment_rate": MAX_SEGMENT_RATE,
        "chunk_time_seconds": CHUNK_TIME_SECONDS,
        "point_retries": args.point_retries,
        "point_retry_delay_seconds": POINT_RETRY_DELAY_SECONDS,
        "axis_sensor_map": AXIS_SENSOR_MAP,
        "timebase": (
            "Input segments are logged by Klipper in print_time. Trinkey samples "
            "are logged by Klipper in Trinkey t_us, with sync.csv used to map "
            "Trinkey t_us to Klipper print_time."
        ),
        "setup_gcode": build_setup_command(),
        "points": [point_metadata(point, local_run_id) for point in points],
        "results": [],
        "error": None,
        "completed_utc": None,
    }


def write_metadata(path: Path, metadata: dict[str, object]) -> None:
    path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def run() -> None:
    args = parse_args()
    if not (MIN_FREQUENCY_HZ <= args.freq_start <= args.freq_end
            <= MAX_FREQUENCY_HZ):
        raise ValueError("Frequency range must satisfy 1 <= start <= end <= 100")
    if args.point_retries < 0:
        raise ValueError("Point retries must be zero or greater")

    frequencies = range(args.freq_start, args.freq_end + 1)
    points = [
        build_sweep_point(axis, frequency, args.accel_amplitude)
        for axis in AXES
        for frequency in frequencies
    ]
    validate_sweep_points(points)

    local_run_id = f"{utc_stamp()}_klipper_xy_frf_sweep"
    run_dir = OUTPUT_ROOT / local_run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    metadata_path = run_dir / "metadata.json"
    metadata = build_metadata(local_run_id, run_dir, args, points)
    write_metadata(metadata_path, metadata)

    print(f"Local metadata directory: {run_dir}")
    print(f"Sweep points: {len(points)}")
    print("Remote Klipper log directory: [vibration_test] trinkey_log_dir")

    try:
        setup = build_setup_command()
        if args.dry_run:
            print("\n# setup")
            print(setup)
        else:
            print("Moving printer to sweep center")
            send_gcode_script(setup)

        for index, point in enumerate(points, start=1):
            if args.dry_run:
                remote_run_id = build_remote_run_id(local_run_id, point)
                command = build_vibration_command(point, remote_run_id)
                print(
                    f"[{index}/{len(points)}] {point.axis} "
                    f"{point.frequency_hz:.3f} Hz, "
                    f"A={point.displacement_amplitude_mm:.6f} mm, "
                    f"accel={point.commanded_accel_amplitude_mm_s2:.1f} "
                    f"mm/s^2, remote_run_id={remote_run_id}"
                )
                print(command)
                continue

            max_attempts = args.point_retries + 1
            for attempt in range(1, max_attempts + 1):
                remote_run_id = build_remote_run_id(
                    local_run_id, point, attempt)
                print(
                    f"[{index}/{len(points)}] {point.axis} "
                    f"{point.frequency_hz:.3f} Hz, "
                    f"A={point.displacement_amplitude_mm:.6f} mm, "
                    f"accel={point.commanded_accel_amplitude_mm_s2:.1f} "
                    f"mm/s^2, attempt={attempt}/{max_attempts}, "
                    f"remote_run_id={remote_run_id}"
                )
                result = run_sweep_point(local_run_id, point, attempt)
                metadata["results"].append(asdict(result))
                write_metadata(metadata_path, metadata)

                if result.error is None:
                    metadata["points"][index - 1]["remote_run_id"] = (
                        result.remote_run_id
                    )
                    write_metadata(metadata_path, metadata)
                    break
                if not result.retryable:
                    raise RuntimeError(
                        f"Non-retryable vibration point failure: "
                        f"{result.error}"
                    )
                if attempt == max_attempts:
                    raise RuntimeError(
                        f"Vibration point failed acquisition validation "
                        f"after {max_attempts} attempts: {result.error}"
                    )

                print(
                    "Trinkey acquisition validation failed; retrying point "
                    f"after {POINT_RETRY_DELAY_SECONDS:.1f} s"
                )
                time.sleep(POINT_RETRY_DELAY_SECONDS)
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
