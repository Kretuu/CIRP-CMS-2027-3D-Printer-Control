# Trajectories

This directory contains the printable sinusoidal parts used for the final compensator evaluation.

- `gcode/` contains manually maintained legacy/reference G-code; it is not generated or part of the final print comparison.
- `generated/` contains the four sine-print G-code files produced by `generate_gcodes.py`.

Regenerate the sine-print evaluation files from the repository root:

```sh
python trajectories/generate_gcodes.py
```

## Printable sinusoidal benchmarks

The `sine_*` files are self-contained printable PLA benchmarks inspired by Figure 6 of Chou, Duan, and Okwudire. They print a 60 mm long, nominally 3.4 mm wide, 4 mm high two-wall part. One wall is straight and the other has a 0.5 mm spatial wavelength and 0.12 mm X amplitude. The sinusoidal wall is traversed with constant Y-axis velocity at either 10 Hz or 35 Hz.

For each frequency there is an uncompensated file and a filtered-B-spline file. Both are generated from the same motion and extrusion payload; only the `SET_FILTERED_BSPLINE` state differs. The files home and prime with compensation disabled, select the experimental controller immediately before the part, and disable it again before parking.

The files deliberately use:

- 24 chords per wavelength;
- `max_accel = max_accel_to_decel = 8000 mm/s^2` during the part;
- `square_corner_velocity = 5 mm/s`;
- 220 C nozzle and 60 C bed temperatures for PLA;
- 0.45 mm line width, 0.2 mm layers, and 1.75 mm filament.

Do not configure Klipper `[input_shaper]` for these tests. Verify the actual planned trajectory using `motion_report/dump_trapq` before collecting final results, and compare the central part of the sinusoidal wall so that the real end-cap corner transients are excluded.

## Dry pass without extrusion

Make a temporary copy of the required `sine_*` file and modify the copy; keep the generated evaluation file unchanged. To run the same XY path and timing without heating or moving filament:

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
