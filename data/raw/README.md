# Raw experimental data

The raw data is grouped by experiment type:

- `frf_sweeps/` contains the dated X/Y vibration sweeps used for FRF
  identification and observer design;
- `final_evaluation/` contains the final uncompensated, standard-FBF, and
  hybrid-FBF sine-print evaluation runs; and
- `motan_fresh/` contains exploratory, unsuccessful, and earlier Motan runs
  retained for diagnostics and the observer comparison.

Large experimental payloads are intentionally ignored by Git. Small
`analysis_metadata.json` files remain commit-visible to document the local
datasets and their analysis entry points.
