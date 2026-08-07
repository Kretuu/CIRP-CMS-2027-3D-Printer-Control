#!/usr/bin/env python3
"""Generate the printable sinusoidal compensator-evaluation G-code."""

from __future__ import annotations

import math
from pathlib import Path


OUTPUT_DIR = Path(__file__).resolve().parent / "generated"

# Figure-6-style printable benchmark.  The sinusoidal wall is parameterised in
# time so that its Y velocity, rather than its total path speed, remains fixed:
#
#   x(t) = x_c + A cos(2*pi*f*t),  y(t) = y_0 +/- f*lambda*t
#
# Twenty-four chords per wavelength keep the maximum chordal deviation below
# 0.0011 mm at the configured amplitude while limiting the 35 Hz file to 840
# G1 commands per second during the sinusoidal wall.
BENCHMARK_FREQUENCIES_HZ = (10.0, 35.0)
BENCHMARK_WAVELENGTH_MM = 0.5
BENCHMARK_AMPLITUDE_MM = 0.12
BENCHMARK_SEGMENTS_PER_CYCLE = 24
BENCHMARK_LENGTH_MM = 60.0
BENCHMARK_NOMINAL_WIDTH_MM = 3.4
BENCHMARK_LAYER_HEIGHT_MM = 0.2
BENCHMARK_LAYER_COUNT = 20
BENCHMARK_LINE_WIDTH_MM = 0.45
BENCHMARK_FILAMENT_DIAMETER_MM = 1.75
BENCHMARK_NOZZLE_TEMPERATURE_C = 220
BENCHMARK_BED_TEMPERATURE_C = 60
BENCHMARK_MAX_ACCEL_MM_S2 = 8000
BENCHMARK_DEFAULT_ACCEL_TO_DECEL_MM_S2 = 2500
BENCHMARK_SQUARE_CORNER_VELOCITY_MM_S = 5
BENCHMARK_TRAVEL_SPEED_MM_S = 100.0
BENCHMARK_CAP_SPEED_MM_S = 20.0
BENCHMARK_Z_SPEED_MM_S = 10.0
BENCHMARK_X_CENTER_MM = 110.0
BENCHMARK_Y_MIN_MM = 80.0
BENCHMARK_Y_MAX_MM = BENCHMARK_Y_MIN_MM + BENCHMARK_LENGTH_MM
BENCHMARK_ACCEL_HEADROOM = 0.9


def format_signal(value: float, places: int = 6) -> str:
    """Format dense trajectory coordinates without losing sub-step detail."""
    return f"{value:.{places}f}".rstrip("0").rstrip(".")


def write_gcode_file(name: str, lines: list[str]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUTPUT_DIR / name
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {path}")


def benchmark_extrusion_per_mm() -> float:
    """Return filament length per path millimetre for one deposited line."""
    # Approximate the deposited line as a rectangle with semicircular sides.
    line_area = (
        BENCHMARK_LAYER_HEIGHT_MM
        * (BENCHMARK_LINE_WIDTH_MM - BENCHMARK_LAYER_HEIGHT_MM)
        + math.pi * (0.5 * BENCHMARK_LAYER_HEIGHT_MM) ** 2
    )
    filament_area = math.pi * (0.5 * BENCHMARK_FILAMENT_DIAMETER_MM) ** 2
    return line_area / filament_area


def benchmark_xy_e_move(
    x: float,
    y: float,
    extrusion_mm: float,
    feedrate_mm_min: float,
) -> str:
    return (
        f"G1 X{format_signal(x)} Y{format_signal(y)} "
        f"E{format_signal(extrusion_mm)} F{format_signal(feedrate_mm_min, 3)}"
    )


def benchmark_sine_wall(
    frequency_hz: float,
    x_base: float,
    y_start: float,
    y_end: float,
) -> list[str]:
    """Generate one downward sinusoidal wall at constant Y-axis velocity."""
    if y_start <= y_end:
        raise ValueError("The benchmark sine wall must run towards decreasing Y")

    cycle_count = BENCHMARK_LENGTH_MM / BENCHMARK_WAVELENGTH_MM
    if not math.isclose(cycle_count, round(cycle_count), abs_tol=1e-12):
        raise ValueError("Benchmark length must contain an integer wavelength count")
    segment_count = int(round(cycle_count)) * BENCHMARK_SEGMENTS_PER_CYCLE
    dt = 1.0 / (frequency_hz * BENCHMARK_SEGMENTS_PER_CYCLE)
    y_velocity = frequency_hz * BENCHMARK_WAVELENGTH_MM
    extrusion_per_mm = benchmark_extrusion_per_mm()

    def x_at(y: float) -> float:
        phase = 2.0 * math.pi * (y - BENCHMARK_Y_MIN_MM) / BENCHMARK_WAVELENGTH_MM
        # Starting at a cosine maximum gives a vertical tangent at both end caps.
        return x_base + BENCHMARK_AMPLITUDE_MM * math.cos(phase)

    lines: list[str] = []
    previous_x = x_at(y_start)
    previous_y = y_start
    for index in range(1, segment_count + 1):
        y = y_start - index * BENCHMARK_LENGTH_MM / segment_count
        x = x_at(y)
        dx = x - previous_x
        dy = y - previous_y
        distance = math.hypot(dx, dy)
        feedrate = 60.0 * distance / dt
        extrusion = extrusion_per_mm * distance
        lines.append(benchmark_xy_e_move(x, y, extrusion, feedrate))
        previous_x = x
        previous_y = y

    if not math.isclose(previous_y, y_end, abs_tol=1e-9):
        raise ValueError("Generated sine wall did not end at the requested Y")
    if not math.isclose(
        BENCHMARK_LENGTH_MM / (segment_count * dt), y_velocity,
        rel_tol=1e-12,
    ):
        raise ValueError("Generated sine timing does not produce the requested Y speed")
    return lines


def benchmark_header(frequency_hz: float, compensated: bool) -> list[str]:
    mode = "filtered B-spline compensation" if compensated else "no compensation"
    y_velocity = frequency_hz * BENCHMARK_WAVELENGTH_MM
    peak_x_velocity = 2.0 * math.pi * frequency_hz * BENCHMARK_AMPLITUDE_MM
    peak_x_accel = (
        (2.0 * math.pi * frequency_hz) ** 2 * BENCHMARK_AMPLITUDE_MM
    )
    peak_path_speed = math.hypot(y_velocity, peak_x_velocity)
    segment_rate = frequency_hz * BENCHMARK_SEGMENTS_PER_CYCLE
    return [
        "; -----------------------------------------------------------------------------",
        f"; Figure-6-style printable sine benchmark: {frequency_hz:g} Hz, {mode}",
        "; Generated by trajectories/generate_gcodes.py",
        "; The controller-off/on files at a given frequency have identical motion and E.",
        f"; Spatial wavelength: {BENCHMARK_WAVELENGTH_MM:g} mm",
        f"; X amplitude: {BENCHMARK_AMPLITUDE_MM:g} mm",
        f"; Constant sinusoidal-wall Y velocity: {y_velocity:g} mm/s",
        f"; Peak X velocity: {peak_x_velocity:.3f} mm/s",
        f"; Peak X acceleration: {peak_x_accel:.3f} mm/s^2",
        f"; Peak geometric path speed: {peak_path_speed:.3f} mm/s",
        f"; Segments per wavelength: {BENCHMARK_SEGMENTS_PER_CYCLE}",
        f"; Sinusoidal-wall G1 rate: {segment_rate:.0f} commands/s",
        f"; Nominal outside width: {BENCHMARK_NOMINAL_WIDTH_MM:g} mm",
        f"; Length / printed height: {BENCHMARK_LENGTH_MM:g} / "
        f"{BENCHMARK_LAYER_HEIGHT_MM * BENCHMARK_LAYER_COUNT:g} mm",
        f"; Line width / layer height: {BENCHMARK_LINE_WIDTH_MM:g} / "
        f"{BENCHMARK_LAYER_HEIGHT_MM:g} mm",
        f"; PLA temperatures: nozzle {BENCHMARK_NOZZLE_TEMPERATURE_C} C, "
        f"bed {BENCHMARK_BED_TEMPERATURE_C} C",
        "; IMPORTANT: [input_shaper] must not be configured during this experiment.",
        "; Evaluate the central region; end caps deliberately contain real 90-degree corners.",
        "; Verify the actual TrapQ trajectory before collecting final print results.",
        "; -----------------------------------------------------------------------------",
    ]


def generate_printable_sine_benchmark(
    frequency_hz: float,
    compensated: bool,
) -> list[str]:
    """Generate a self-contained, narrow two-wall printable benchmark."""
    if frequency_hz not in BENCHMARK_FREQUENCIES_HZ:
        raise ValueError(f"Unsupported benchmark frequency: {frequency_hz}")

    omega = 2.0 * math.pi * frequency_hz
    peak_x_accel = BENCHMARK_AMPLITUDE_MM * omega * omega
    if peak_x_accel > BENCHMARK_MAX_ACCEL_MM_S2 * BENCHMARK_ACCEL_HEADROOM:
        raise ValueError(
            f"{frequency_hz:g} Hz benchmark needs {peak_x_accel:.1f} mm/s^2, "
            "which does not retain the configured acceleration headroom"
        )

    # Centreline separation is reduced by one line width so the nominal outside
    # width of the two-wall part is BENCHMARK_NOMINAL_WIDTH_MM.
    centreline_separation = (
        BENCHMARK_NOMINAL_WIDTH_MM - BENCHMARK_LINE_WIDTH_MM
    )
    x_left = BENCHMARK_X_CENTER_MM - 0.5 * centreline_separation
    x_right_base = BENCHMARK_X_CENTER_MM + 0.5 * centreline_separation
    x_right_end = x_right_base + BENCHMARK_AMPLITUDE_MM
    y_min = BENCHMARK_Y_MIN_MM
    y_max = BENCHMARK_Y_MAX_MM
    extrusion_per_mm = benchmark_extrusion_per_mm()
    controller_value = 1 if compensated else 0

    lines = benchmark_header(frequency_hz, compensated)
    lines.extend(
        [
            "G21 ; millimetres",
            "G90 ; absolute XYZ coordinates",
            "M83 ; relative extrusion",
            "M220 S100 ; disable feed-rate override",
            "M221 S100 ; disable extrusion override",
            "SET_FILTERED_BSPLINE ENABLE=0 ; home and prepare without compensation",
            f"M140 S{BENCHMARK_BED_TEMPERATURE_C} ; start heating bed",
            "M104 S150 ; reduce oozing while homing",
            "G28 ; home all axes",
            f"M190 S{BENCHMARK_BED_TEMPERATURE_C} ; wait for bed",
            f"M109 S{BENCHMARK_NOZZLE_TEMPERATURE_C} ; wait for nozzle",
            "G92 E0",
            "M107 ; fan off for first layer",
            "",
            "; Prime beside the benchmark with compensation disabled.",
            f"G1 Z5 F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            f"G1 X100 Y75 F{BENCHMARK_TRAVEL_SPEED_MM_S * 60:.0f}",
            f"G1 Z{format_signal(BENCHMARK_LAYER_HEIGHT_MM)} "
            f"F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            "G1 X100 Y145 E2.4 F600",
            "G1 E-0.8 F1800",
            f"G1 Z2 F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            f"G1 X{format_signal(x_left)} Y{format_signal(y_min)} "
            f"F{BENCHMARK_TRAVEL_SPEED_MM_S * 60:.0f}",
            f"G1 Z{format_signal(BENCHMARK_LAYER_HEIGHT_MM)} "
            f"F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            "G1 E0.8 F1800",
            "M400 ; begin the measured print from an empty motion queue",
            f"SET_VELOCITY_LIMIT ACCEL={BENCHMARK_MAX_ACCEL_MM_S2} "
            f"ACCEL_TO_DECEL={BENCHMARK_MAX_ACCEL_MM_S2} "
            f"SQUARE_CORNER_VELOCITY={BENCHMARK_SQUARE_CORNER_VELOCITY_MM_S}",
            f"SET_FILTERED_BSPLINE ENABLE={controller_value}",
            "",
        ]
    )

    linear_feedrate = frequency_hz * BENCHMARK_WAVELENGTH_MM * 60.0
    cap_feedrate = BENCHMARK_CAP_SPEED_MM_S * 60.0
    straight_extrusion = extrusion_per_mm * BENCHMARK_LENGTH_MM
    top_cap_distance = x_right_end - x_left
    cap_extrusion = extrusion_per_mm * top_cap_distance

    for layer in range(BENCHMARK_LAYER_COUNT):
        z = BENCHMARK_LAYER_HEIGHT_MM * (layer + 1)
        if layer:
            lines.append(
                f"G1 Z{format_signal(z)} F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}"
            )
        lines.append(f"; layer {layer + 1}/{BENCHMARK_LAYER_COUNT}")
        lines.append(
            benchmark_xy_e_move(
                x_left, y_max, straight_extrusion, linear_feedrate,
            )
        )
        lines.append(
            benchmark_xy_e_move(
                x_right_end, y_max, cap_extrusion, cap_feedrate,
            )
        )
        lines.extend(
            benchmark_sine_wall(frequency_hz, x_right_base, y_max, y_min)
        )
        lines.append(
            benchmark_xy_e_move(
                x_left, y_min, cap_extrusion, cap_feedrate,
            )
        )
        if layer == 0:
            lines.append("M106 S255 ; full part cooling after first layer")

    lines.extend(
        [
            "",
            "M400 ; complete all evaluated motion before changing controller state",
            "SET_FILTERED_BSPLINE ENABLE=0",
            f"SET_VELOCITY_LIMIT ACCEL={BENCHMARK_MAX_ACCEL_MM_S2} "
            f"ACCEL_TO_DECEL={BENCHMARK_DEFAULT_ACCEL_TO_DECEL_MM_S2} "
            f"SQUARE_CORNER_VELOCITY={BENCHMARK_SQUARE_CORNER_VELOCITY_MM_S}",
            "G1 E-1 F1800",
            "G91",
            "G1 Z5 F600",
            "G90",
            "G1 X0 Y220 F6000",
            "M107",
            "M104 S0",
            "M140 S0",
            "M84",
            "; End of printable sine benchmark",
        ]
    )
    return lines


def main() -> None:
    for frequency_hz in BENCHMARK_FREQUENCIES_HZ:
        frequency_label = f"{frequency_hz:g}".replace(".", "p")
        for compensated, mode_label in (
            (False, "uncompensated"),
            (True, "filtered_bspline"),
        ):
            name = f"sine_{frequency_label}hz_{mode_label}.gcode"
            write_gcode_file(
                name,
                generate_printable_sine_benchmark(frequency_hz, compensated),
            )


if __name__ == "__main__":
    main()
