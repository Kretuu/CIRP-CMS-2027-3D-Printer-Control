# Dissertation figure package

This directory contains self-contained MATLAB scripts and their exported
dissertation assets. Run a script from the repository root with `run`; scripts
that export files resolve this directory from their own location.

```matlab
run("analysis/matlab/diss_figures/plot_fbf_window_basis.m");
run("analysis/matlab/diss_figures/plot_fbf_history_coordinates.m");
run("analysis/matlab/diss_figures/plot_fbf_matrix_construction_figures.m");
run("analysis/matlab/diss_figures/input_shaping.m");
run("analysis/matlab/diss_figures/bsplines.m");
```

The scripts produce:

- `plot_fbf_window_basis.m` → `fbf-window-basis.png`;
- `plot_fbf_history_coordinates.m` → `fbf-history-coordinates.png`;
- `plot_fbf_matrix_construction_figures.m` →
  `fbf-retained-columns.png` and `fbf-historical-basis-support.png`;
- `input_shaping.m` → `input-shaping-cancellation.pdf` and `.png`; and
- `bsplines.m` → `bspline-functions.png` and `bsplines-sum.png`.

`Measured and identified FRFs.png` and `X 1 Hz sweep point.png` are retained
exports from the FRF workflow rather than outputs of the figure-only scripts.
Generated images are kept beside the source so they can be inserted into the
dissertation without depending on MATLAB at document-build time.

`filtered-bspline-preview-advance.svg` is the large-font, presentation-scale
vector source for the Standard limited-preview FBF slide. Its companion 4K PNG
and PDF exports are provided for software that cannot import SVG reliably.
