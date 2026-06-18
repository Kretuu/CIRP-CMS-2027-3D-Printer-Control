# MEng Dissertation Code

Embedded data-acquisition and experiment orchestration code for the dissertation project.

## Repository Layout

- `firmware/trinkey_bno055/` - firmware for the Adafruit Trinkey QT2040. It initializes USB serial, the onboard NeoPixel, the STEMMA QT I2C bus, and a BNO055 IMU, then streams acceleration readings as CSV.
- `orchestrator/` - PC-side experiment runner. The first skeleton logs Trinkey serial output and sends a configured G-code script to Moonraker.
- `analysis/` - MATLAB and Python post-processing code for logged experiments.
- `trajectories/` - reference and generated G-code trajectories for test runs.
- `data/` - raw and processed experiment logs. Contents are ignored by Git except placeholder files.
- `klipper_extensions/` - notes and patches for later Klipper-side modifications.
- `external/pico-sdk/` - Pico SDK checkout used by the root CMake project.

## Firmware Build

The root `CMakeLists.txt` uses the local Pico SDK at `external/pico-sdk` and adds the Trinkey firmware target.

```sh
cmake -S . -B build
cmake --build build
```

The firmware target is `trinkey_bno055`. The existing `flash_trinkey_bno055` target is kept in `firmware/trinkey_bno055/CMakeLists.txt`.

## Orchestrator

See `orchestrator/README.md` for the first PC-side experiment runner.
