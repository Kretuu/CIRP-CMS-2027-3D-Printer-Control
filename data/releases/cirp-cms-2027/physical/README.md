# Physical specimen evidence

Original files were copied byte-for-byte from the author's dissertation archive.
`provenance.json` maps each of the six selected captures to its original HEIC
photograph, existing PNG and exact JPEG crop used in the conference paper.
The PNGs were already present in the archive; no new image conversion,
retouching or cropping was performed during this release preparation.
The original measurement sheet is preserved in full, including earlier specimens;
only the six explicitly selected specimen groups are transcribed to the CSV.

## Measurement discrepancy — author confirmation required

The source sheet lists 11 readings for `35Hz standard r2` and `35Hz hybrid r4`.
Both end with an extra 3.96 mm entry. The dissertation and paper describe ten.
The first ten reproduce the reported means (3.842 and 3.925 mm), but for standard
r2 their sample SD is approximately 0.062503 mm, rounding to **0.063**, not the
reported 0.062 mm. Including all eleven changes the means to approximately
3.853 and 3.928 mm and sample SDs to 0.069 and 0.100 mm.

All 62 source readings for the selected specimens are retained. No reading has
been silently discarded. `reconciliation.csv` shows all-recorded statistics and
first-ten statistics solely to diagnose the discrepancy; it does not establish
which set should be used in the final paper. `source_reading_number` preserves
list order and does not imply a registered physical measurement location.
The other four selected groups contain ten readings each and reproduce the
paper's rounded means and sample SDs.

Resolve the two extra entries and the standard-r2 SD with the author before
finalising the physical-results table or claiming full numerical reproduction.
The manuscript values are unchanged pending that confirmation. The previously
verified FRF and dynamic tracking results are unaffected.

The photographs document individual specimens; lighting was not standardised
for quantitative comparison. Width readings are locations on a single specimen,
not independent print replicates. No video, presentation or unrelated archive
material is included in this release.
