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

### Prerequisites

- CMake 3.13 or newer.
- A Make-compatible build tool, or another CMake generator such as Ninja.
- Python 3, used by the Pico SDK build tools.
- A complete Arm GNU embedded toolchain for `arm-none-eabi`, including newlib and `nosys.specs`.

On macOS Apple Silicon, use Arm's full GNU toolchain bundle. The Homebrew `arm-none-eabi-gcc` formula provides the compiler, but not the full embedded C library/spec files required by this Pico SDK build.

```sh
mkdir -p "$HOME/.local/toolchains"
curl -L \
  https://developer.arm.com/-/media/Files/downloads/gnu/13.2.rel1/binrel/arm-gnu-toolchain-13.2.rel1-darwin-arm64-arm-none-eabi.tar.xz \
  -o /tmp/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi.tar.xz
tar -xJf /tmp/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi.tar.xz \
  -C "$HOME/.local/toolchains"
```

Then configure CMake with `PICO_TOOLCHAIN_PATH` pointing at the extracted toolchain root:

```sh
cmake -S . -B build \
  -DPICO_TOOLCHAIN_PATH="$HOME/.local/toolchains/arm-gnu-toolchain-13.2.Rel1-darwin-arm64-arm-none-eabi"
cmake --build build
```

The first configure/build may download and build Pico SDK helper tools such as `picotool` and `pioasm`, so it needs network access unless those tools are already available locally.

The firmware target is `trinkey_bno055`. The existing `flash_trinkey_bno055` target is kept in `firmware/trinkey_bno055/CMakeLists.txt`.

## Orchestrator

See `orchestrator/README.md` for the first PC-side experiment runner.
