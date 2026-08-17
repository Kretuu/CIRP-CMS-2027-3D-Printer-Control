# Trajectories

This directory contains the printable sinusoidal parts used for the final compensator evaluation.

- `gcode/` contains manually maintained legacy/reference G-code; it is not generated or part of the final print comparison.
- `generated/` contains the uncompensated, standard-FBF, and hybrid-FBF Part-A
  print files at both frequencies, together with an elevated dry-run version of
  each file.

Regenerate the sine-print evaluation files from the repository root:

```sh
python trajectories/generate_gcodes.py
```

## Printable Part-A reconstruction

The `sine_*` files reconstruct Part A from Figures 6 and 7 of Chou, Duan, and Okwudire, ["A Physics-Guided Data-Driven Feedforward Tracking Controller for Systems With Unmodeled Dynamics—Applied to 3D Printing"](https://doi.org/10.1109/ACCESS.2023.3244194), IEEE Access, 2023.

The paper explicitly reports:

- a linear portion and a sinusoidal portion, with the full-resolution Figure 6 showing three passes of each;
- a 0.5 mm spatial wavelength;
- 10 Hz and 35 Hz excitation, obtained from `frequency = Y speed / wavelength`;
- width `a` measured at 10 locations using a vernier caliper, followed by its mean and standard deviation;
- X tracking-error RMS derived from accelerometer measurements through a 5 Hz Luenberger position observer.

The paper and its arXiv source do **not** provide G-code or numerical amplitude, line width, specimen length, layer count, temperatures, extrusion settings, or an explicit start marker. The generator therefore labels the remaining values as a reconstruction, not as directly reported parameters. The selected 0.5 mm amplitude and six 0.4 mm-pitch paths yield the approximately 3.4 mm outside envelope shown in Figure 6. Following the connectivity visible in the original figure, each layer is one continuous inner-to-outer path: inner straight, inner sine, middle straight, middle sine, outer straight, then outer sine. The exposed outer sinusoidal edge is therefore deposited last; the figure itself does not prove travel direction. The transitions at alternating ends are extruded, as in the continuous path drawn in Figure 6(a); measurements must exclude these end connectors.

The specimen is **50 mm** long, giving 100 complete wavelengths per pass. Length is not specified by the paper; 50 mm is used here to make the specimen easier to handle and measure. It does not change the wavelength, excitation frequency, or width metric. The reconstruction uses two 0.2 mm layers (0.4 mm total height) because the paper does not report a layer count. This limits cumulative Z stacking error while leaving enough material to remove and measure. Every layer repeats the same continuous inner-to-outer path. PLA cooling is enabled after the separate prime line and before the densely spaced benchmark paths begin.

All 10 Hz and 35 Hz files use the same 0.5 mm amplitude and the same
spatial/extrusion payload. Only their feed rates differ, so the 10 Hz and 35 Hz
physical comparisons test the same geometry. For each frequency, the
`uncompensated`, `filtered_bspline`, and `hybrid` files are motion-for-motion
identical; only `SET_FILTERED_BSPLINE` differs. In this experiment,
`filtered_bspline` is the paper's **standard FBF** condition and `hybrid` uses
the online residual learner after its configured standard-FBF warm-up.

The three commands are:

```gcode
SET_FILTERED_BSPLINE ENABLE=0
SET_FILTERED_BSPLINE ENABLE=1 MODE=STANDARD
SET_FILTERED_BSPLINE ENABLE=1 MODE=HYBRID
```

Hybrid mode requires `[trinkey_accel]` and valid X/Y observer output. Start the
lightweight Motan logger before the file if the same raw and observed data are
also required for evaluation. Motan and the hybrid controller subscribe to the
same shared calculation; they do not run two observers.

The files deliberately use:

- three inner-to-outer straight/sinusoid pairs per layer;
- 24 chords per wavelength;
- `max_accel = max_accel_to_decel = 32000 mm/s^2` during the part;
- `square_corner_velocity = 20 mm/s` during the part;
- 220 C nozzle and 60 C bed temperatures for PLA;
- 0.4 mm path pitch/line width, two 0.2 mm layers, and 1.75 mm filament.

At 35 Hz, the reconstructed 0.5 mm-amplitude command requires approximately 24,181 mm/s² peak continuous X acceleration and 111.3 mm/s peak path speed. Its 24-chord approximation needs additional junction/tangential acceleration headroom, so the generator selects 32,000 mm/s². This is four times the stock Ender-3 V3 KE 8,000 mm/s² acceleration specification. Treat the 35 Hz dry run as mandatory: inspect the actual `motion_report/dump_trapq` timing, listen for lost steps, and confirm position before attempting extrusion. If the printer cannot execute it faithfully, reducing amplitude creates a hardware-adapted experiment and must be reported as such; do not silently retain the `35 Hz` label after planner slow-down.

Do not configure Klipper `[input_shaper]` for these tests. Compare only steady, central portions of the longitudinal passes and exclude their turnaround endpoints. The G-code restores the local 8,000 mm/s² acceleration and 5 mm/s square-corner velocity before parking.

## Dry pass without extrusion

The generator creates a dry-run counterpart for every print file. They preserve the printable files' XYZ paths and feed rates, remove extrusion, disable the heaters and fans, and apply a 5 mm Z offset. Regenerate them whenever the benchmark geometry changes.

The automatic files should normally be used. The manual conversion below documents their construction and can be used to audit them.

To run the same XY path and timing without heating or moving filament:

1. Comment out the four heating commands near the beginning:

   ```gcode
   ; M140 S60
   ; M104 S150
   ; M190 S60
   ; M109 S220
   ```

2. Remove only the `E...` parameter from every combined XY/extrusion move. Keep the complete `G1`, `X`, `Y`, and `F` portions. For example:

   ```gcode
   ; Original
   G1 X111.590911 Y139.979167 E0.000719 F305.724

   ; Dry pass
   G1 X111.590911 Y139.979167 F305.724
   ```

3. Comment out the extrusion-only prime, retract, and unretract moves:

   ```gcode
   ; G1 E-0.8 F1800
   ; G1 E0.8 F1800
   ; G1 E-1 F1800
   ```

4. For collision clearance, add the following immediately after `G28`:

   ```gcode
   SET_GCODE_OFFSET Z=5
   ```

   This adds 5 mm to every subsequent absolute Z position while leaving the XY trajectory unchanged. Add `SET_GCODE_OFFSET Z=0` near the end, after the final parking move, to restore the normal offset without moving the toolhead.

Commands such as `M83`, `M221`, `G92 E0`, `M106`, and `M107` may remain; with all `E` parameters removed they do not cause extrusion. Do not comment out entire XY lines that contain an `E` parameter, because that would remove the sine trajectory being tested. A dry pass validates G-code parsing, queueing, limits, and the planned XY motion, but it is not a substitute for the compensated-versus-uncompensated printed-part comparison.

The previous stationary, step, speed-sweep, and zigzag files were useful for early accelerometer and motion debugging, but they are not part of this print evaluation. Frequency-response identification is performed by the direct `RUN_VIBRATION_TEST`/TrapQ workflow instead, so `generate_gcodes.py` intentionally does not recreate those files.
