# Physical specimen evidence

Original files were copied byte-for-byte from the author's dissertation archive.
`provenance.json` maps each selected capture to its original HEIC photograph,
existing PNG and exact JPEG crop used in the conference paper. No image
conversion, retouching or cropping was performed during release preparation.
The original measurement sheet is preserved in full, including earlier specimens.

## Author-approved analysis selection

On 17 October 2026 the author approved retaining the first ten recorded readings
for each of the six selected specimens. The source sheet has eleven readings
for 35 Hz standard r2 and hybrid r4; their final 3.96 mm readings are excluded
from this analysis, not erased from the record or classified as invalid.
This reconstructs the dissertation's reported means. The historical reason for
the original selection is not independently established, and the rule is not
claimed to have been specified before data collection.

- `measurements/Fresh runs (mm).md`: unchanged original measurement sheet.
- `measurements/source_specimen_readings.csv`: original transcription of all
  62 readings for the six selected specimens; status labels reflect the initial
  archive audit, before the selection decision.
- `measurements/selected_specimen_readings.csv`: 60 retained readings used in
  the conference paper, ten per specimen.
- `measurements/excluded_specimen_readings.csv`: the two excluded source entries.
- `measurements/width_summary.csv`: selected means and sample SDs (denominator
  n−1), with unrounded and three-decimal reporting values.
- `measurements/reconciliation.csv`: all-recorded and selected-first-ten
  statistics, retained to make the selection's effect inspectable.

The selected standard-r2 sample SD is 0.062503333 mm, correctly reported as
**0.063 mm**. The conference paper corrects the dissertation's 0.062 mm value.
All other selected width means and rounded SDs agree with the dissertation.
The FRF and dynamic tracking results are unaffected.

Reproduce and check the selected width statistics from the repository root:

```sh
python3 data/releases/cirp-cms-2027/physical/verify_widths.py
```

`source_reading_number` preserves list order, not registered measurement
positions. Readings are locations on a single specimen, not independent print
replicates. Photographic lighting was not standardised for quantitative
comparison. No video, presentation or unrelated archive material is included.
