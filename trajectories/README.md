# Trajectories

This directory contains motion-only G-code trajectories for vibration measurement experiments.

- `gcode/` contains manually written or static reference G-code.
- `generated/` contains G-code produced by `generate_gcodes.py`.
- `generated/` may also contain transient generated artifacts, but only `.gcode` files and `.gitkeep` are intended to be tracked.

Regenerate the standard test trajectories from the repository root:

```sh
python trajectories/generate_gcodes.py
```

Generated files are conservative first-stage vibration tests intended for accelerometer logging. They assume the printer has already been homed and do not include extrusion, heating, or automatic homing commands.

Klipper acceleration and velocity limits affect the actual motion produced by these files. Start with `stationary_10s.gcode` for sensor baseline/noise capture, then step excitation, then speed sweeps and zigzag tests. The generated trajectories use conservative Ender-3-style bounds around X/Y 80-140 mm and Z 20 mm.
