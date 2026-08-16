# MATLAB analysis

The MATLAB code is divided by experimental workflow. Add only the directory
needed for the current task; the folders are deliberately ordinary MATLAB
directories rather than `+package` namespaces, so the established function
names remain unchanged.

| Directory | Purpose | Main entry point |
|---|---|---|
| [`frf/`](frf/) | Vibration-sweep alignment, FRF extraction, model identification, and point inspection | `frf_sweep_analysis` |
| [`state_space_observer/`](state_space_observer/) | Plant-based Luenberger observer design from the identified FBF models | `state_space_observer_design` |
| [`sine_tracking/`](sine_tracking/) | Lightweight-Motan validation and compensated/uncompensated sine-print comparison | `sine_tracking_analysis` |
| [`diss_figures/`](diss_figures/) | Self-contained scripts and generated assets for dissertation diagrams | individual scripts |

Every directory has its own `README.md` with the required data, commands,
outputs, and interpretation notes. Run commands from the repository root so
the documented relative paths resolve consistently.

For an interactive session that needs more than one workflow, add both paths
explicitly:

```matlab
addpath("analysis/matlab/frf");
addpath("analysis/matlab/state_space_observer");
addpath("analysis/matlab/sine_tracking");
```

Using `addpath(genpath("analysis/matlab"))` also works, but targeted paths make
it clearer which workflow a script depends on.
