# MEng Dissertation Code

Embedded data-acquisition and experiment orchestration code for the dissertation project.

## Repository Layout

- `firmware/trinkey_bno055/` - firmware for the Adafruit Trinkey QT2040 and two BNO055 IMUs. It supports the original buffered CSV capture and continuous timestamped binary batches.
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

The buffered-v1 and streaming-v2 firmware protocols are documented in
[`firmware/trinkey_bno055/README.md`](firmware/trinkey_bno055/README.md).

## Continuous Klipper and Motan logging

Copy `external/klipper/klippy/extras/trinkey_accel.py` into the matching Klipper
installation (or use this repository's Klipper tree). Copy
`klipper_extensions/trinkey_accel.cfg` into the printer's Klipper configuration
directory, replace its `REPLACE_WITH_TRINKEY_USB_ID` placeholder, and add this
line to `printer.cfg`:

```ini
[include trinkey_accel.cfg]
```

The included fragment contains the complete `[trinkey_accel]` configuration.
Motan discovers that section through Klipper's status API and automatically
subscribes to every sensor listed by its `sensors` option. No separate Motan
section is required in `printer.cfg` or `moonraker.conf`.

The Klipper Python environment must contain `pyserial`. Restart Klipper after
installing the extra. The stream starts on demand when the first API client
subscribes and stops after the final client disconnects.

This repository's Motan logger automatically subscribes to both configured
sensors:

```sh
python3 external/klipper/scripts/motan/data_logger.py \
  ~/printer_data/comms/klippy.sock \
  ~/printer_data/logs/motan/trinkey_run
```

The exact Klipper socket path depends on the printer installation. Motan writes
`trinkey_run.json.gz` and `trinkey_run.index.gz`. Each acceleration row retains:

- mapped Klipper `print_time`;
- original 64-bit Trinkey microsecond timestamp;
- firmware sample sequence;
- raw BNO055 axes;
- scaled axes in mm/s²;
- validity flags and stream diagnostics.

While Motan is connected, run `TRINKEY_ACCEL_STATUS` in the Fluidd console to
inspect reader health, synchronization timeouts, firmware overruns, transport
drops, I²C read durations, host sequence errors, and clock-fit quality. Start
the logger before starting printer motion; initial device configuration and
clock synchronization briefly block the Klipper reactor, whereas steady-state
sync exchanges are asynchronous.

Motan datasets include `trinkey_accel(base,x)` and
`trinkey_accel(toolhead,y)`, with `_raw`, `device_time_us`, `sequence`, and
`flags` selections also available. MATLAB may use the mapped print time or
repeat the linear clock fit from the preserved device timestamps and sync
diagnostics.

The continuous streamer and `RUN_VIBRATION_TEST` both own the same USB serial
port and are therefore intentionally mutually exclusive for now. Stop the Motan
logger before starting a buffered vibration sweep. A later hybrid-controller
integration should use `start_internal_client(sensor)` instead of opening the
serial port itself. The API helper supports multiple subscribers, so Motan and a
hybrid controller may consume the same sensor data concurrently. The first
subscriber starts one physical acquisition stream and it remains active until
the final subscriber disconnects.

## Orchestrator

See `orchestrator/README.md` for the first PC-side experiment runner.
