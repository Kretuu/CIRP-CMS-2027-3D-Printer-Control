# Sine-print position-tracking analysis

This package compares uncompensated, standard filtered B-spline (FBF), and
hybrid FBF prints at the nominal 10 Hz and 35 Hz conditions. It reads the
toolhead stream produced by `scripts/motan_lightweight`, checks
capture integrity, finds the six evaluated sinusoidal passes automatically,
and analyzes the central 80% of each pass.

The primary quantity follows Figure 7 and Section IV-C of the core paper:

```text
x_tracking_error = desired_x_position - observed_x_position
```

The paper explicitly treats its observer estimate as true position and reports
overall RMS tracking error. This package performs the same calculation, but the
dissertation must call it **observer-derived** or **model-assisted position
tracking error**. It is not independent encoder ground truth.

The package is split by responsibility:

- `sine_tracking_analysis.m` is the public entry point and produces the report;
- `sine_tracking_analyze_capture.m` performs validation, pass detection,
  frequency estimation, and RMS calculation;
- `sine_tracking_plot_position_error.m` creates the two presentation figures;
  and
- `motan_lightweight_load.m` decodes one raw Motan capture.

Only `sine_tracking_analysis.m` normally needs to be called directly.

## Required files

Final evaluation captures are kept in `data/raw/final_evaluation`. Use these
names, where the largest run number is the newest:

```text
sine10_uncomp_rN.json.gz
sine10_standard_rN.json.gz
sine10_hybrid_rN.json.gz
sine35_uncomp_rN.json.gz
sine35_standard_rN.json.gz
sine35_hybrid_rN.json.gz
```

Keep each matching `.index.gz`, Klippy log, and diagnostic text file in the
experiment archive, although MATLAB reads the `.json.gz` file directly.
Earlier exploratory captures are retained separately in `data/raw/motan_fresh`.
They are not considered by the sine-tracking analysis. The six selected paper
capture pairs are now tracked in Git; other raw attempts remain ignored unless
already tracked. For the exact frozen selection and reproduction script, see
[`data/releases/cirp-cms-2027/README.md`](../../../data/releases/cirp-cms-2027/README.md).
In particular, the paper uses `sine35_hybrid_r4`, paired with the measured and
photographed specimen, rather than the later capture in `unpaired/`.

Each row must contain at least:

```text
time
device_time_us
sample_sequence
flags
desired_x_position
desired_x_acceleration
observed_x_position
observer_valid
reference_valid
```

These columns are produced by the current
`trinkey_accel/dump_experiment` endpoint. The loader reads the header stored in
each capture, so column order may change without breaking the analysis.

## Run it

From the repository root:

```matlab
addpath("analysis/matlab/sine_tracking");
report = sine_tracking_analysis();
```

To use another directory:

```matlab
report = sine_tracking_analysis( ...
    "/path/to/final/evaluation/captures", ...
    "data/processed/sine_tracking");
```

Results are written to `data/processed/sine_tracking`:

- `sine_tracking_capture_review.csv` records run selection, rejected captures,
  missing samples, logger diagnostics, and warnings;
- `sine_tracking_pass_metrics.csv` contains one row per evaluated sine pass;
- `sine_tracking_summary.csv` contains condition-level position-error results;
- `sine_tracking_position_error_10hz.{png,pdf}` overlays uncompensated,
  standard FBF, and hybrid FBF tracking error for the 10 Hz experiment; and
- `sine_tracking_position_error_35hz.{png,pdf}` provides the corresponding
  comparison for the nominal 35 Hz experiment.

The two figures follow the core paper's Figure 7 presentation: all three
controllers share one plot and one vertical scale at each frequency. Each
legend entry states the controller's overall RMS tracking error, calculated
from every retained sample across all six passes. RMS is the only headline
scalar metric because it is also the quantitative tracking metric reported by
the core paper.

The exported figures use 14-point text and are produced in both PNG and vector
PDF form:

```text
sine_tracking_position_error_10hz.{png,pdf}
sine_tracking_position_error_35hz.{png,pdf}
```

The analyzer tries the newest run first and falls back to an older run only if
the newer capture is unusable. The review CSV records that decision.

## Pass detection and frequency

Pass boundaries are detected from nonzero nominal TrapQ X-acceleration events;
measured acceleration is not used in the tracking metric. This event stream is
a reliable way to distinguish the dense sine chords from positioning moves.
Short groups are rejected by duration. If a hybrid file contains cold warm-up
sine passes, the final six valid groups are selected as the printed evaluation
passes.

The executed frequency is fitted directly from desired position near the
nominal filename frequency. This matters because the nominal 35 Hz trajectory
has executed at approximately 33.1 Hz in the current experiments.

Only the central 80% of each pass is evaluated. This removes entry and exit
transients and provides equal-duration steady intervals. A capture is rejected
if any selected interval contains an invalid reference, invalid observer row,
invalid toolhead flag, or sample gap.

## Metrics

For each selected sample:

```text
e_x[k] = desired_x_position[k] - observed_x_position[k]
```

For each pass:

```text
RMS = sqrt(mean(e_x^2))
```

The pass CSV reports RMS in micrometres together with the timing, fitted
frequency, and data-quality fields needed to audit the selected interval. The
summary calculates one overall RMS from every retained sample across all six
passes; this is not merely the arithmetic mean of the six pass RMS values.

The console prints reductions for:

- standard FBF relative to no compensation;
- hybrid FBF relative to no compensation; and
- hybrid FBF relative to standard FBF.

A negative reduction means the candidate controller increased tracking error.

## Hybrid and stream validation

For hybrid-named captures, the script also requires status evidence that both
axes became active and completed hybrid preview solves. Measurement errors,
solve fallbacks, Python observation errors, and worker drops must be zero when
those fields are available. A completed hybrid G-code is also important because
the G-code aborts if its warm-up/freeze handshake fails.

The loader retains only the hybrid status fields used to validate a capture.
Inspect them with:

```matlab
capture = motan_lightweight_load( ...
    "data/raw/final_evaluation/sine10_hybrid_r1.json.gz");
capture.events(:, ["event_time", "filtered_bspline_mode", ...
    "hybrid_x_active", "hybrid_x_solves", ...
    "hybrid_y_active", "hybrid_y_solves", ...
    "hybrid_worker_drops"])
```

## Interpretation limitations

The observer combines the identified plant model, final generated motor
command, and measured acceleration. It is appropriate for reproducing the core
paper's tracking-error methodology, but model mismatch can affect the reported
position error. Use the result together with:

- raw acceleration or spectral plots as independent sensor-domain evidence;
- physical specimen width as the manufacturing outcome; and
- a clear statement that no direct displacement sensor was available.

The six passes in one capture measure within-specimen variation. They are not
six independent print experiments. Between-print repeatability requires
multiple complete prints per condition.
