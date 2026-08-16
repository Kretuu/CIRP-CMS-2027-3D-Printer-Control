# FRF identification package

This directory processes the buffered `RUN_VIBRATION_TEST` sweeps. It aligns
the commanded TrapQ acceleration and BNO055 output in Klipper print time,
selects the steady interval, fits one complex frequency-response point per
test, and identifies continuous- and discrete-time printer models.

## Required data

Each sweep directory must contain the orchestrator `metadata.json` and all
frequency-point directories downloaded from the printer. Optional
`analysis_metadata.json` provides experimentally observed frequency cut-offs.
See [`orchestrator/README.md`](../../../orchestrator/README.md) for acquisition
and download instructions.

Model identification uses MATLAB's Signal Processing Toolbox (`invfreqs` and
`freqs`) and Control System Toolbox (`tf`, `c2d`, and `isstable`).

## Inspect one frequency point

From the repository root:

```matlab
addpath("analysis/matlab/frf");
inspect = frf_sweep_inspect_point("data/raw/<run-id>", "X", 35);
```

This plots the aligned command and acceleration samples together with the
ramp, guard, and fitted steady-state regions. Use it to validate timing and
signal sign before relying on a complete sweep.

## Analyze and identify models

For one 3 m/s^2 sweep:

```matlab
addpath("analysis/matlab/frf");
[results, models] = frf_sweep_analysis("data/raw/<3000-run-id>");
```

To compare all collected acceleration levels while identifying the model from
the required 3 m/s^2 run:

```matlab
runDirs = [
    "data/raw/<1500-run-id>"
    "data/raw/<2000-run-id>"
    "data/raw/<2500-run-id>"
    "data/raw/<3000-run-id>"
];
[results, models] = frf_sweep_analysis(runDirs);
```

The function plots measured X/Y magnitude and phase, identifies the model at
3 m/s^2, prints fit error, and prints the discrete numerator and denominator in
Klipper configuration syntax. The returned `results` retains every measured
FRF point and the returned `models` contains the X/Y continuous and controller
models.

The public entry points are `frf_sweep_analysis` and
`frf_sweep_inspect_point`. Files with names such as `frf_align_signals` and
`frf_extract_point` are shared implementation helpers and normally do not need
to be called directly.
