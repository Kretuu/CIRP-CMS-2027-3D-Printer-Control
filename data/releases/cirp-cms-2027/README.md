# CIRP CMS 2027: frozen identification and tracking dataset

This selection supports the frequency-response and observer-derived tracking
results in the six-page paper. It is a local Git release preparation, not proof
that a public deposit has occurred. A paper citation should identify the actual
publicly accessible repository URL and immutable commit/tag after publication.
A separate archival deposit with a persistent identifier can also be made.

See [raw-data provenance](../../raw/README.md) for exact selected runs,
superseded datasets, quality-flag interpretation and the valid-but-unpaired
35 Hz hybrid r5 exclusion. `selection.json` fixes the inputs; `SHA256SUMS`
records hashes relative to the repository root. No raw acquisition bytes were
edited. Entire August sweep folders are retained, including retries and points
subsequently excluded by documented frequency cut-offs.

## Reproduce

Requirements: MATLAB with Signal Processing Toolbox and Control System Toolbox.
From the repository root, first verify the frozen input/reference files:

```sh
sha256sum -c data/releases/cirp-cms-2027/SHA256SUMS
```

Then in MATLAB:

```matlab
run("data/releases/cirp-cms-2027/reproduce.m");
```

The script creates a temporary directory containing only the six selected
capture pairs, runs the existing analysis there, and writes outputs under the
ignored `build/cirp-cms-2027-reproduction/` directory. It checks the identified
model fit errors, retained model frequency limits, selected capture names and
RMS values against the paper's reference results. Existing local processed
results are not overwritten. Plot appearance can vary with the checked-out
plotting code; the checked numerical results define the comparison.

`reference_results/` contains snapshots of the existing final capture-review,
pass-metrics and summary tables. The selected captures are usable within the
evaluated intervals even where whole-capture quality flags report warnings.
These tables are not independent experimental replicates.

## Limits

This archive covers identification and dynamic tracking. It does not yet contain
the original physical-width measurement sheet or specimen photographs. No
license or public availability is asserted by this file. Confirm the public
release terms and add the physical evidence before claiming complete access
to all underlying paper data. Older development data remain documented but
are not included in this selection.
