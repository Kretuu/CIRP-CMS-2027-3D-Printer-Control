# Raw experimental data and provenance

The paper's exact dataset is listed in
[`../releases/cirp-cms-2027/README.md`](../releases/cirp-cms-2027/README.md),
with a file manifest, SHA-256 hashes and reproduction commands. Do not select
paper inputs solely by date or by the largest run number.

| Location | Status and use |
| --- | --- |
| `frf_sweeps/2026-08-11_*` | Final filtered sweep acquisition at four acceleration levels; used for the paper's frequency-response comparison. Nominal model fitting uses the **3 m/s²** sweep only. |
| `frf_sweeps/2026-07-16_*`, `2026-07-20_*` | Superseded acquisition; excluded from the final identification. The author reports that the earlier acquisitions lacked the intended low-pass filtering. August point metadata explicitly records 250 Hz bandwidth and 500 Hz buffered sampling; older metadata does not record that configuration. |
| `final_evaluation/` | Contains both selected and earlier attempts. Only the six captures listed below underpin the paper's final comparison. |
| `final_evaluation/unpaired/` | Includes a valid later 35 Hz hybrid r5 capture without the matching physical specimen evidence; excluded from the paper's paired dynamic/physical comparison. |
| `motan_fresh/` | Developmental, exploratory and unsuccessful runs. Excluded from the final three-controller comparison, but not uniformly invalid: `sine35_comp_test5` is used for the documented offline observer comparison. |
| `../motan/` | Legacy captures already tracked in Git; not the final paper dataset. Changing ignore rules does not remove these from Git history. |

## Selected final evaluation

| Nominal frequency | Controller | Capture basename | Paper RMS (µm) |
| --- | --- | --- | ---: |
| 10 Hz | Uncompensated | `sine10_uncomp_r6` | 193.6 |
| 10 Hz | Standard FBF | `sine10_standard_r1` | 21.8 |
| 10 Hz | Hybrid FBF | `sine10_hybrid_r3` | 5.2 |
| 35 Hz | Uncompensated | `sine35_uncomp_r5` | 613.2 |
| 35 Hz | Standard FBF | `sine35_standard_r2` | 81.1 |
| 35 Hz | Hybrid FBF | `sine35_hybrid_r4` | 24.8 |

The 35 Hz hybrid selection is **r4**, because its capture, photograph and
caliper measurements refer to the same specimen. The later unpaired r5 is
not a failed acquisition and must not be labelled invalid merely because it
was excluded from this comparison.

Each selected capture's `.json.gz` and `.index.gz` files are tracked. MATLAB
reads `.json.gz` directly; the index is retained with it. Whole printer/kernel
logs, other attempts and unpaired captures remain in the local archive and
are not part of this selected release. The four August sweep folders retain
all acquisition files, including retries: `metadata.json` selects the actual
200 X/Y frequency points, and `analysis_metadata.json` plus the MATLAB
step-resolution rule determine retained frequencies.

## Interpreting quality flags

The six retained captures are usable over their evaluated intervals, not
necessarily flawless over their entire recording. Some have whole-capture
sequence/gap or diagnostic warnings outside the evaluated intervals. Consult
the capture-review and pass-metrics tables rather than interpreting
`clean = 0` as rejection. All six selected captures have zero gaps in the
evaluated passes. Initial invalid observer/reference rows are not themselves
evidence of a failed print. The metric pools the central 80% of six sine passes
and remains observer-derived, not independent displacement ground truth.

The generic sine-analysis function searches newest-first and stops at the
first usable capture; its review CSV does not exhaustively classify all older
attempts. To reproduce the frozen paper selection, use the release script,
which isolates the six named captures before invoking that analyzer.

## Git and completeness

Only the documented selection is newly allowlisted; do not remove all raw-data
ignore rules. Previously tracked metadata, processed results and legacy captures
remain tracked. The local `data/processed/` directory may contain another
analysis revision; use the release's frozen reference tables for this paper.

The release also includes [original physical evidence](../releases/cirp-cms-2027/physical/README.md)
from the dissertation archive: six specimen photographs and the measurement
sheet. The author approved retaining the first ten readings per specimen;
original notes and the two extra entries are preserved separately. The selected
standard-r2 sample SD is corrected to 0.063 mm.
