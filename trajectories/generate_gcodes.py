#!/usr/bin/env python3
"""Generate the printable sinusoidal compensator-evaluation G-code."""

from __future__ import annotations

import math
from pathlib import Path


OUTPUT_DIR = Path(__file__).resolve().parent / "generated"

# Reconstruction of Part A in Figures 6 and 7 of Chou, Duan, and Okwudire
# (IEEE Access, 2023).  The paper publishes the 0.5 mm wavelength, 10/35 Hz
# frequencies, three-straight/three-sine topology (in the figure), and width
# measurement procedure, but it does not publish the G-code or numerical
# amplitude, line width, length, layer count, temperatures, or extrusion model.
#
# The remaining spatial values below are inferred jointly from the full-size
# figure: A=0.5 mm and six 0.4 mm-pitch paths produce the approximately 3.4 mm
# envelope shown in Figure 6.  Length is not specified in the paper; 50 mm is
# used here to make the specimen easier to handle and measure.
#
# Each sinusoidal pass is parameterised in time so that its Y velocity, rather
# than its total path speed, remains fixed:
#
#   x(t) = x_c + A cos(2*pi*f*t),  y(t) = y_0 +/- f*lambda*t
#
# Twenty-four chords per wavelength keep the maximum chordal deviation below
# 0.0043 mm while limiting the 35 Hz file to 840 G1 commands per second during
# each sinusoidal pass.
BENCHMARK_FREQUENCIES_HZ = (10.0, 35.0)
BENCHMARK_WAVELENGTH_MM = 0.5
BENCHMARK_AMPLITUDE_MM = 0.5
BENCHMARK_SEGMENTS_PER_CYCLE = 24
BENCHMARK_LENGTH_MM = 50.0
BENCHMARK_NOMINAL_WIDTH_MM = 3.4
BENCHMARK_LINEAR_PASS_COUNT = 3
BENCHMARK_SINE_PASS_COUNT = 3
BENCHMARK_TOOLPATH_PITCH_MM = 0.4
BENCHMARK_LAYER_HEIGHT_MM = 0.2
BENCHMARK_LAYER_COUNT = 2
BENCHMARK_LINE_WIDTH_MM = 0.4
BENCHMARK_FILAMENT_DIAMETER_MM = 1.75
BENCHMARK_NOZZLE_TEMPERATURE_C = 220
BENCHMARK_BED_TEMPERATURE_C = 60
# The continuous sine needs 24,181 mm/s^2 at 35 Hz.  The piecewise-linear
# Klipper representation needs additional per-chord acceleration headroom as
# its chord speed and direction change at each G1 junction.
BENCHMARK_MAX_ACCEL_MM_S2 = 32000
BENCHMARK_RESTORE_MAX_ACCEL_MM_S2 = 8000
BENCHMARK_DEFAULT_ACCEL_TO_DECEL_MM_S2 = 2500
BENCHMARK_SQUARE_CORNER_VELOCITY_MM_S = 20
BENCHMARK_RESTORE_SQUARE_CORNER_VELOCITY_MM_S = 5
BENCHMARK_TRAVEL_SPEED_MM_S = 100.0
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


def benchmark_x_positions() -> tuple[list[float], list[float]]:
    """Return straights outer-to-inner and sine baselines inner-to-outer."""
    first_straight = (
        BENCHMARK_X_CENTER_MM
        - 0.5 * BENCHMARK_NOMINAL_WIDTH_MM
        + 0.5 * BENCHMARK_LINE_WIDTH_MM
    )
    straight = [
        first_straight + index * BENCHMARK_TOOLPATH_PITCH_MM
        for index in range(BENCHMARK_LINEAR_PASS_COUNT)
    ]
    first_sine = (
        straight[-1]
        + BENCHMARK_TOOLPATH_PITCH_MM
        + BENCHMARK_AMPLITUDE_MM
    )
    sine = [
        first_sine + index * BENCHMARK_TOOLPATH_PITCH_MM
        for index in range(BENCHMARK_SINE_PASS_COUNT)
    ]
    outside_width = (
        sine[-1]
        + BENCHMARK_AMPLITUDE_MM
        - straight[0]
        + BENCHMARK_LINE_WIDTH_MM
    )
    if not math.isclose(
        outside_width, BENCHMARK_NOMINAL_WIDTH_MM, abs_tol=1e-12
    ):
        raise ValueError("Toolpath does not produce the requested outside width")
    return straight, sine


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
    """Generate one sinusoidal pass at constant-magnitude Y-axis velocity."""
    y_distance = y_end - y_start
    if not math.isclose(abs(y_distance), BENCHMARK_LENGTH_MM, abs_tol=1e-9):
        raise ValueError("A benchmark sine pass must span the complete part length")
    y_direction = 1.0 if y_distance > 0.0 else -1.0

    cycle_count = BENCHMARK_LENGTH_MM / BENCHMARK_WAVELENGTH_MM
    if not math.isclose(cycle_count, round(cycle_count), abs_tol=1e-12):
        raise ValueError("Benchmark length must contain an integer wavelength count")
    segment_count = int(round(cycle_count)) * BENCHMARK_SEGMENTS_PER_CYCLE
    dt = 1.0 / (frequency_hz * BENCHMARK_SEGMENTS_PER_CYCLE)
    extrusion_per_mm = benchmark_extrusion_per_mm()

    def x_at(y: float) -> float:
        phase = 2.0 * math.pi * (y - BENCHMARK_Y_MIN_MM) / BENCHMARK_WAVELENGTH_MM
        # Starting at a cosine maximum gives a vertical tangent at both end caps.
        return x_base + BENCHMARK_AMPLITUDE_MM * math.cos(phase)

    lines: list[str] = []
    previous_x = x_at(y_start)
    previous_y = y_start
    for index in range(1, segment_count + 1):
        y = y_start + y_direction * index * BENCHMARK_LENGTH_MM / segment_count
        x = x_at(y)
        dx = x - previous_x
        dy = y - previous_y
        distance = math.hypot(dx, dy)
        feedrate = 60.0 * distance / dt
        extrusion = extrusion_per_mm * distance
        lines.append(benchmark_xy_e_move(x, y, extrusion, feedrate))
        previous_x = x
        previous_y = y

    return lines


def benchmark_header(frequency_hz: float, compensated: bool) -> list[str]:
    mode = "standard FBF (filtered B-spline)" if compensated else "no compensation"
    y_velocity = frequency_hz * BENCHMARK_WAVELENGTH_MM
    peak_x_accel = (
        (2.0 * math.pi * frequency_hz) ** 2 * BENCHMARK_AMPLITUDE_MM
    )
    return [
        "; -----------------------------------------------------------------------------",
        f"; Chou et al. Part-A reconstruction: {frequency_hz:g} Hz, {mode}",
        "; Generated by trajectories/generate_gcodes.py",
        f"; 3 straight + 3 sine passes; wavelength/amplitude "
        f"{BENCHMARK_WAVELENGTH_MM:g}/{BENCHMARK_AMPLITUDE_MM:g} mm; "
        f"pitch {BENCHMARK_TOOLPATH_PITCH_MM:g} mm.",
        f"; Length {BENCHMARK_LENGTH_MM:g} mm; {BENCHMARK_LAYER_COUNT} layers; "
        f"outside width {BENCHMARK_NOMINAL_WIDTH_MM:g} mm.",
        f"; Y speed {y_velocity:g} mm/s; peak X acceleration "
        f"{peak_x_accel:.1f} mm/s^2.",
        f"; PLA temperatures: nozzle {BENCHMARK_NOZZLE_TEMPERATURE_C} C, "
        f"bed {BENCHMARK_BED_TEMPERATURE_C} C",
        f"; Motion limits: acceleration {BENCHMARK_MAX_ACCEL_MM_S2} mm/s^2; "
        f"SCV {BENCHMARK_SQUARE_CORNER_VELOCITY_MM_S} mm/s.",
        "; IMPORTANT: [input_shaper] must not be configured during this experiment.",
        "; Run the elevated dry file first; evaluate the central region of the print.",
        "; -----------------------------------------------------------------------------",
    ]


def generate_printable_sine_benchmark(
    frequency_hz: float,
    compensated: bool,
) -> list[str]:
    """Generate the reconstructed six-pass Part-A printable benchmark."""
    if frequency_hz not in BENCHMARK_FREQUENCIES_HZ:
        raise ValueError(f"Unsupported benchmark frequency: {frequency_hz}")

    omega = 2.0 * math.pi * frequency_hz
    peak_x_accel = BENCHMARK_AMPLITUDE_MM * omega * omega
    if peak_x_accel > BENCHMARK_MAX_ACCEL_MM_S2 * BENCHMARK_ACCEL_HEADROOM:
        raise ValueError(
            f"{frequency_hz:g} Hz benchmark needs {peak_x_accel:.1f} mm/s^2, "
            "which does not retain the configured acceleration headroom"
        )

    # The first sine reaches the last straight bead at every inward peak.  The
    # repeated contacts remove the continuous central slot of the old two-wall
    # benchmark and reproduce the connected strip visible in Figure 6.
    linear_x, sine_x_base = benchmark_x_positions()
    pass_pairs = list(zip(reversed(linear_x), sine_x_base))
    first_x = pass_pairs[0][0]
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
            "M107 ; fan off while priming",
            "",
            "; Prime beside the benchmark with compensation disabled.",
            f"G1 Z5 F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            f"G1 X100 Y75 F{BENCHMARK_TRAVEL_SPEED_MM_S * 60:.0f}",
            f"G1 Z{format_signal(BENCHMARK_LAYER_HEIGHT_MM)} "
            f"F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            "G1 X100 Y145 E2.4 F600",
            "G1 E-0.8 F1800",
            f"G1 Z2 F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            f"G1 X{format_signal(first_x)} Y{format_signal(y_min)} "
            f"F{BENCHMARK_TRAVEL_SPEED_MM_S * 60:.0f}",
            f"G1 Z{format_signal(BENCHMARK_LAYER_HEIGHT_MM)} "
            f"F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
            "G1 E0.8 F1800",
            "M106 S255 ; cool the densely spaced PLA paths",
            "M400 ; begin the measured print from an empty motion queue",
            f"SET_VELOCITY_LIMIT ACCEL={BENCHMARK_MAX_ACCEL_MM_S2} "
            f"ACCEL_TO_DECEL={BENCHMARK_MAX_ACCEL_MM_S2} "
            f"SQUARE_CORNER_VELOCITY={BENCHMARK_SQUARE_CORNER_VELOCITY_MM_S}",
            f"SET_FILTERED_BSPLINE ENABLE={controller_value}",
            "",
        ]
    )

    linear_feedrate = frequency_hz * BENCHMARK_WAVELENGTH_MM * 60.0
    straight_extrusion = extrusion_per_mm * BENCHMARK_LENGTH_MM
    for layer in range(BENCHMARK_LAYER_COUNT):
        z = BENCHMARK_LAYER_HEIGHT_MM * (layer + 1)
        if layer:
            lines.extend(
                [
                    "G1 E-0.4 F1800",
                    f"G1 Z{format_signal(z)} "
                    f"F{BENCHMARK_Z_SPEED_MM_S * 60:.0f}",
                    f"G1 X{format_signal(first_x)} Y{format_signal(y_min)} "
                    f"F{BENCHMARK_TRAVEL_SPEED_MM_S * 60:.0f}",
                    "G1 E0.4 F1800",
                ]
            )
        lines.append(f"; layer {layer + 1}/{BENCHMARK_LAYER_COUNT}")
        current_x = first_x
        current_y = y_min

        for pair_index, (straight_x, sine_base) in enumerate(pass_pairs):
            if pair_index:
                connector_length = abs(straight_x - current_x)
                lines.append(
                    benchmark_xy_e_move(
                        straight_x,
                        current_y,
                        extrusion_per_mm * connector_length,
                        linear_feedrate,
                    )
                )
                current_x = straight_x
            next_y = y_max if current_y == y_min else y_min
            lines.append(
                benchmark_xy_e_move(
                    straight_x, next_y, straight_extrusion, linear_feedrate,
                )
            )
            current_x = straight_x
            current_y = next_y
            sine_end_x = sine_base + BENCHMARK_AMPLITUDE_MM
            connector_length = abs(sine_end_x - current_x)
            lines.append(
                benchmark_xy_e_move(
                    sine_end_x,
                    current_y,
                    extrusion_per_mm * connector_length,
                    linear_feedrate,
                )
            )
            current_x = sine_end_x
            next_y = y_min if current_y == y_max else y_max
            lines.extend(
                benchmark_sine_wall(
                    frequency_hz, sine_base, current_y, next_y
                )
            )
            current_y = next_y

        if current_y != y_min:
            raise ValueError("Six-pass Part-A layer did not return to its start edge")
    lines.extend(
        [
            "",
            "M400 ; complete all evaluated motion before changing controller state",
            "SET_FILTERED_BSPLINE ENABLE=0",
            f"SET_VELOCITY_LIMIT ACCEL={BENCHMARK_RESTORE_MAX_ACCEL_MM_S2} "
            f"ACCEL_TO_DECEL={BENCHMARK_DEFAULT_ACCEL_TO_DECEL_MM_S2} "
            f"SQUARE_CORNER_VELOCITY="
            f"{BENCHMARK_RESTORE_SQUARE_CORNER_VELOCITY_MM_S}",
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


def generate_dry_movement_test(printable_lines: list[str]) -> list[str]:
    """Convert a printable benchmark into the tracked, elevated dry run."""
    dry_lines: list[str] = []
    for line in printable_lines:
        if line.startswith("; Chou et al. Part-A reconstruction:"):
            dry_lines.extend(
                [
                    line,
                    "; DRY MOVEMENT TEST: heaters, extrusion, and fans are disabled.",
                ]
            )
            continue
        if line == "G28 ; home all axes":
            dry_lines.extend([line, "SET_GCODE_OFFSET Z=5"])
            continue
        if line == "G1 X0 Y220 F6000":
            dry_lines.extend([line, "SET_GCODE_OFFSET Z=0"])
            continue
        if line in ("M104 S0", "M140 S0"):
            dry_lines.append(line)
            continue
        if line.startswith(("M104 ", "M109 ", "M140 ", "M190 ", "M106", "M107")):
            dry_lines.append(f"; DRY RUN disabled: {line}")
            continue
        if line.startswith("G1 "):
            words = line.split()
            if any(word.startswith("E") for word in words):
                if any(word.startswith(("X", "Y", "Z")) for word in words):
                    dry_lines.append(
                        " ".join(word for word in words if not word.startswith("E"))
                    )
                else:
                    dry_lines.append(f"; DRY RUN removed: {line}")
                continue
        if line == "; End of printable sine benchmark":
            line = "; End of dry movement test"
        dry_lines.append(line)
    return dry_lines


def main() -> None:
    for frequency_hz in BENCHMARK_FREQUENCIES_HZ:
        frequency_label = f"{frequency_hz:g}".replace(".", "p")
        for compensated, mode_label in (
            (False, "uncompensated"),
            (True, "filtered_bspline"),
        ):
            name = f"sine_{frequency_label}hz_{mode_label}.gcode"
            printable_lines = generate_printable_sine_benchmark(
                frequency_hz, compensated
            )
            write_gcode_file(name, printable_lines)
            write_gcode_file(
                name.replace(".gcode", "_dry.gcode"),
                generate_dry_movement_test(printable_lines),
            )


if __name__ == "__main__":
    main()
