# Sine-print tracking analysis package

This analysis compares the no-compensation and standard filtered-B-spline
(FBF) prints at the nominal 10 Hz and 35 Hz conditions. It reads the combined
base/toolhead stream produced by `scripts/motan_lightweight`, checks capture
integrity, finds the six sinusoidal passes automatically, and analyzes the
central 80% of each pass.

`sine_tracking_analysis.m` is the public entry point.
`motan_lightweight_load.m` is its format-specific loader and may also be called
directly when inspecting one raw lightweight capture.

The comparison script currently expects the four already collected
uncompensated/standard-FBF conditions. Hybrid captures can already be opened
with `motan_lightweight_load`; add them to the comparison only after real
hybrid runs exist, so the existing analysis remains reproducible.

## Run it

Place captures in `data/motan` using these names, where the largest run number
is the newest:

```text
sine10_uncomp_rN.json.gz
sine10_comp_rN.json.gz
sine35_uncomp_rN.json.gz
sine35_comp_rN.json.gz
```

The `.index.gz` files should still be preserved with the experiment, although
the MATLAB loader reads the `.json.gz` stream directly. From the repository
root, run:

```matlab
addpath("analysis/matlab/sine_tracking");
report = sine_tracking_analysis();
```

Or from a shell with MATLAB installed:

```sh
matlab -batch 'addpath("analysis/matlab/sine_tracking"); sine_tracking_analysis();'
```

Results are written to `data/processed/sine_tracking`:

- `sine_tracking_capture_review.csv` records run selection, rejected captures,
  missing samples, logger diagnostics, and whether a selected run is clean;
- `sine_tracking_pass_metrics.csv` contains one row per evaluated sine pass;
- `sine_tracking_summary.csv` contains the six-pass mean and standard
  deviation for each condition; and
- two figures show the acceleration-error histories and the per-pass
  acceleration NRMSE comparison.

When a new clean 35 Hz uncompensated capture is added, give it the next run
number and rerun the same command. The analyzer will select it automatically.

## Inspect hybrid controller status

New lightweight logs retain the controller mode and flattened X/Y hybrid
status in `capture.events`. The column order for each eight-value axis row is
stored alongside the data, so it does not have to be remembered:

```matlab
capture = motan_lightweight_load("data/motan/sine10_hybrid_r1.json.gz");
capture.hybrid_status_columns
capture.events(:, ["event_time", "filtered_bspline_mode", ...
    "hybrid_x_status", "hybrid_y_status", ...
    "hybrid_python_observation_errors"])
```

For an accepted hybrid run, find an event where both axes have `active = 1`
and `hybrid_solves > 0`. Measurement errors, solve fallbacks, and Python
observation errors should be zero. The final event may be disabled because the
G-code turns the controller off after the evaluated motion; the completed-run
counters deliberately remain available.

## What is used as the reference

The lightweight logger samples Klipper's nominal TrapQ acceleration only at
the genuine accelerometer timestamps. The G-code approximates every spatial
sine cycle with 24 straight chords, so its TrapQ acceleration is a sparse
junction pulse train. It is useful for locating each pass and determining the
executed fundamental frequency and phase, but its sampled peak is not the
continuous desired acceleration amplitude.

The analysis reconstructs the desired acceleration from the known 0.5 mm
G-code position amplitude:

```text
a_reference(t) = A * omega^2 * cos(omega*t + phase_command)
A = 0.5 mm
```

The command fundamental is fitted by ordinary least squares to obtain the
executed phase. Phase uses the same equivalent cosine-form convention as the
FRF workflow. The measured acceleration is not reduced to a fitted sinusoid;
the full measured signal within each selected steady interval is compared with
the reconstructed reference. Tracking error uses the dissertation convention,
desired minus measured. The current sensor mounting makes the toolhead BNO055
X axis opposite to printer X, so `analysisConfiguration()` applies
`toolhead_x_sign = -1`. Recheck that setting if the accelerometer is remounted.

The script searches near the nominal file frequency rather than assuming that
Klipper executed it exactly. This is especially important at 35 Hz, where
motion-planning constraints can make the executed frequency differ from the
nominal file name.

## Metrics and interpretation

The script deliberately reports only two tracking metrics:

- RMS acceleration error, which includes the target-frequency mismatch and
  other measured vibration in the retained sensor bandwidth; and
- acceleration NRMSE, which divides RMS error by desired acceleration RMS and
  therefore supports a relative comparison between 10 Hz and 35 Hz.

For each selected sample, the calculation is

```text
acceleration_error = desired_acceleration - measured_acceleration
RMS = sqrt(mean(acceleration_error^2))
NRMSE = RMS / sqrt(mean(desired_acceleration^2))
```

For the dissertation, label these quantities explicitly as "measured
acceleration tracking error." The script does not estimate position tracking
error. New captures include the shared observer's model-assisted position
estimate, but that estimate is not independent displacement ground truth and
must not be presented as such. The dynamic result should therefore be
considered together with the printed specimen quality.

Keep sensor rate, bandwidth, mounting, and processing identical between paired
conditions. The current captures contain approximately 250 samples/s, so
content above the 125 Hz Nyquist limit cannot be evaluated.

The six passes in one capture measure within-specimen repeatability; they are
not six independent experiments. Final claims about repeatability should use
multiple complete prints per condition and report variation between prints.
