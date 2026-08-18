# MEng Dissertation Code

Embedded data-acquisition and experiment orchestration code for the dissertation project.

## Repository Layout

- `firmware/trinkey_bno055/` - firmware for the Adafruit Trinkey QT2040 and two BNO055 IMUs. It supports the original buffered CSV capture and continuous timestamped binary batches.
- `orchestrator/` - PC-side experiment runner. The first skeleton logs Trinkey serial output and sends a configured G-code script to Moonraker.
- `analysis/` - MATLAB and Python post-processing code for logged experiments.
- `trajectories/` - reference and generated G-code trajectories for test runs.
- `data/` - raw and processed experiment logs. Contents are ignored by Git except placeholder files.
- `klipper_extensions/` - notes and patches for later Klipper-side modifications.
- `tools/klipper-c-helper/` - reproducible Docker build for the Creality host's MIPS `c_helper.so`.
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

## Klipper MIPS C helper build

The Creality host uses 32-bit little-endian MIPS code. A normal Linux x86-64,
Windows, or macOS build of `klippy/chelper/c_helper.so` is not compatible, and
the printer's minimal Buildroot installation does not contain the compiler and
sysroot needed to build it safely. Build the helper on a development computer
with Docker instead.

The builder supports Docker Engine on Linux and Docker Desktop on macOS
(including Apple Silicon) and Windows; Docker Compose V2 is required. It runs
an amd64 Linux container so that the pinned Bootlin cross-toolchain can execute,
then targets the printer's little-endian MIPS, o32, NaN2008, hard-float FP64,
glibc ABI. Compilation is limited to MIPS32r2 instructions, which are supported
by the printer's MIPS32r5 Ingenic X2000 host. The toolchain archive is verified
against its published SHA-256 checksum during the image build.

The toolchain is Bootlin's
[`mips32r5el--glibc--bleeding-edge-2018.11-1`](https://toolchains.bootlin.com/releases_mips32r5el.html),
selected to match the Creality host ABI. The build flags follow the documented
[Nebula Pad MIPS helper build](https://github.com/salami738/ender3-v3-ke-klipper-mainline/blob/main/klipper/c_helper/build-chelper.sh),
with this repository's source list and additional ABI validation.

From the repository root, run:

```sh
docker compose run --rm --build klipper-c-helper
```

The first build downloads the Docker base image and approximately 70 MB MIPS
toolchain. Later builds reuse Docker's image cache. On Apple Silicon and other
Arm hosts, the amd64 builder runs through Docker's CPU emulation and is
therefore slower than a native amd64 build.

The build script reads `SOURCE_FILES` directly from
`external/klipper/klippy/chelper/__init__.py`, so new helper sources do not need
to be added to a second manifest. It validates the output architecture and core
symbols, including the filtered B-spline symbols when that source is present,
and rejects binaries requiring a glibc version newer than the printer's 2.28.
The resulting deployment artifact is:

```text
build/klipper-c-helper/c_helper.so
```

It deliberately does not overwrite
`external/klipper/klippy/chelper/c_helper.so`. The builder performs the required
ABI and symbol checks itself. On macOS, Linux, or Windows through WSL/Git Bash,
the result can also be inspected manually before uploading it:

```sh
file build/klipper-c-helper/c_helper.so
strings build/klipper-c-helper/c_helper.so | grep filtered_bspline
```

`file` must report an ELF 32-bit, little-endian MIPS shared object. A result
containing `x86-64`, `ARM`, `aarch64`, or `Mach-O` must not be installed on the
printer.

On native Linux hosts, preserve build artifact ownership by supplying the local
user and group IDs to Compose:

```sh
LOCAL_UID=$(id -u) LOCAL_GID=$(id -g) \
  docker compose run --rm --build klipper-c-helper
```

### Safe installation on the printer

The paths and service command below apply to the Creality Buildroot Klipper
installation used by this repository. Upload the new helper under a temporary
name first:

```sh
scp -O build/klipper-c-helper/c_helper.so \
  root@PRINTER_IP:/tmp/c_helper.so.new
```

The desktop build already validates the target architecture. The Creality
image does not normally include the `file` utility, so the first command below
checks the ELF header with the printer's Python instead. It must report
`ELF32 little-endian MIPS`. The second command loads the candidate and resolves
both dissertation-specific helper interfaces:

```sh
/usr/share/klippy-env/bin/python3 -c 'p="/tmp/c_helper.so.new"; h=open(p,"rb").read(20); assert h[:4] == b"\x7fELF" and h[4] == 1 and h[5] == 1 and int.from_bytes(h[18:20], "little") == 8, "not ELF32 little-endian MIPS"; print("ELF32 little-endian MIPS")'

/usr/share/klippy-env/bin/python3 -c \
  'import cffi; f=cffi.FFI(); f.cdef("void *filtered_bspline_controller_alloc(void); int filtered_bspline_add_observation(void *, char, double, double); void *state_space_observer_alloc(int, double[], double[], double[], double[], double[], double[]); int stepcompress_find_past_positions(void *, unsigned long long[], long long[], int);"); lib=f.dlopen("/tmp/c_helper.so.new"); print(lib.filtered_bspline_controller_alloc, lib.filtered_bspline_add_observation, lib.state_space_observer_alloc, lib.stepcompress_find_past_positions)'
```

If both checks succeed, keep a recovery copy, stop only Klipper, and install
the new file:

```sh
[ -e /usr/data/c_helper.so.stock ] || \
  cp -p /usr/share/klipper/klippy/chelper/c_helper.so \
    /usr/data/c_helper.so.stock

/etc/init.d/S55klipper_service stop
cp /tmp/c_helper.so.new /usr/share/klipper/klippy/chelper/c_helper.so
chmod 755 /usr/share/klipper/klippy/chelper/c_helper.so

/usr/share/klippy-env/bin/python3 -c 'import os; from pathlib import Path; d=Path("/usr/share/klipper/klippy/chelper"); so=d/"c_helper.so"; m=max(p.stat().st_mtime for p in d.rglob("*") if p.is_file() and p != so); os.utime(str(so), (m + 1, m + 1)); print("c_helper.so is newer than its sources")'

/etc/init.d/S55klipper_service start
```

Copy the binary after copying any changed C sources. Klipper decides whether to
rebuild the helper using modification times. The printer's clock may reset to
2020 during boot, so a plain `touch c_helper.so` is not reliable when uploaded
sources have later timestamps. The Python command above sets the helper one
second later than the newest file in `klippy/chelper`, preventing the printer
from trying to invoke its unavailable native `gcc`.

Check `/usr/data/printer_data/logs/klippy.log` after starting the service. If
Klipper does not start, SSH remains independent of it; restore the saved helper:

```sh
cp /usr/data/c_helper.so.stock /usr/share/klipper/klippy/chelper/c_helper.so
/usr/share/klippy-env/bin/python3 -c 'import os; from pathlib import Path; d=Path("/usr/share/klipper/klippy/chelper"); so=d/"c_helper.so"; m=max(p.stat().st_mtime for p in d.rglob("*") if p.is_file() and p != so); os.utime(str(so), (m + 1, m + 1))'
/etc/init.d/S55klipper_service restart
```

### Troubleshooting helper startup

This Klipper log sequence means that the installed helper is older than at
least one helper source, not necessarily that the binary is damaged:

```text
Building C code module c_helper.so
Unable to build C code module (error=32512)
```

The encoded status `32512` normally corresponds to shell status 127: Klipper
tried to run the compiler, but the compiler is absent. List the files that are
forcing the rebuild with:

```sh
find /usr/share/klipper/klippy/chelper -type f \
  -newer /usr/share/klipper/klippy/chelper/c_helper.so -print
```

After installing a matching cross-compiled helper and running the timestamp
command from the installation procedure, that `find` command should print
nothing. Then restart Klipper and inspect only its useful startup transitions:

```sh
/etc/init.d/S55klipper_service restart

grep -E 'Starting Klippy|Building C code|Unable to build|Traceback|undefined symbol|Printer is ready' \
  /usr/data/printer_data/logs/klippy.log | tail -n 30
```

Restoring only an old `c_helper.so` is not a complete rollback when the helper
sources or C declarations have also changed. Restore the matching old sources
as well, or install the Docker-built helper produced from the current checkout.

`vibration_test.py` remains Python-only. The shared observer used by
`trinkey_accel.py` is implemented in `state_space_observer.c`, so deploy the
matching `klippy/chelper` sources and rebuild `c_helper.so` when installing this
version. The same rule applies to the filtered B-spline module set
(`kin_filtered_bspline.c`, `filtered_bspline_core.c`,
`filtered_bspline_hybrid.c`, and `filtered_bspline_internal.h`) and changes to
the C declarations/source list in `klippy/chelper/__init__.py`.

## Continuous Klipper and Motan logging

Deploy the matching `trinkey_accel.py`, `filtered_bspline.py`,
`motion_report.py`, `stepper.py`, C-helper sources/declarations, and the
cross-compiled `c_helper.so` from this checkout as one version. Copy
`klipper_extensions/trinkey_accel.cfg` and
`klipper_extensions/filtered_bspline.cfg` into the printer's Klipper
configuration directory, replace the Trinkey serial placeholder, remove or
comment the existing `[input_shaper]` section, and add these lines to
`printer.cfg`:

```ini
[include filtered_bspline.cfg]
[include trinkey_accel.cfg]
```

The included fragments contain the complete controller and Trinkey
configuration. Lightweight Motan validates the configured sensors and opens
one combined experiment subscription. No separate Motan section is required in
`printer.cfg` or `moonraker.conf`.

The Klipper Python environment must contain `pyserial`. Restart Klipper after
installing the extra. The stream starts on demand when the first API client
subscribes and stops after the final client disconnects.

The filtered B-spline controller now provides three experiment states:

```gcode
SET_FILTERED_BSPLINE ENABLE=0
SET_FILTERED_BSPLINE ENABLE=1 MODE=STANDARD
SET_FILTERED_BSPLINE ENABLE=1 MODE=HYBRID
```

Hybrid mode starts an internal client of the same combined observer stream used
by lightweight Motan. It uses standard FBF during the configured warm-up and
then enables the learned residual correction. Deploy
`external/klipper/klippy/extras/filtered_bspline.py`, the matching C helper and
C declarations, `klipper_extensions/filtered_bspline.cfg`, and
`klipper_extensions/trinkey_accel.cfg` together.

The generated hybrid evaluation files enable HYBRID at Z=2, acquire the static
accelerometer bias, and run a non-extruding sinusoidal warm-up sketch before
the measured specimen. They then execute `WAIT_FILTERED_BSPLINE_READY`, which
requires both residual learners to be active and aborts instead of silently
measuring the standard-FBF fallback. Upload regenerated hybrid G-code together
with the updated `filtered_bspline.py`; older files do not contain this guard.

Use the lightweight logger for the high-density 35 Hz G-code experiments:

```sh
python3 external/klipper/scripts/motan_lightweight/data_logger.py \
  /usr/data/printer_data/comms/klippy.sock \
  /usr/data/printer_data/logs/motan/sine35_comp_r1
```

It logs raw base and toolhead data, nominal TrapQ motion, final motor commands,
the shared observer estimate, and a small diagnostic status subset. Every value
is evaluated at a genuine sensor timestamp. It does not export the full
high-density toolhead or extruder TrapQ, step queues, ADXL/angle streams, or
unrelated status objects. The stock `scripts/motan` directory does not support
the Trinkey stream. If either required sensor is silent for five seconds, the
lightweight process warns but remains connected; validate sample continuity
and the loss counters after the run.

The exact Klipper socket path depends on the printer installation. Motan writes
`trinkey_run.json.gz` and `trinkey_run.index.gz`. Each row retains:

- mapped Klipper `print_time`;
- original 64-bit Trinkey microsecond timestamp;
- firmware sample sequence;
- raw BNO055 axes;
- scaled axes in mm/s²;
- nominal TrapQ position and acceleration;
- final motor position reconstructed from generated step history and the
  backward-difference velocity supplied to the observer;
- estimated physical position and signed, bias-corrected acceleration;
- observer and command-reference validity flags;
- validity flags and stream diagnostics.

While Motan is connected, run `TRINKEY_ACCEL_STATUS` in the Fluidd console to
inspect reader health, synchronization timeouts, firmware overruns, transport
drops, I²C read durations, host sequence errors, clock-fit quality, observer
resets, and motion-history lookup errors. Start the logger before starting
printer motion and keep the printer still for at least 0.4 seconds while the
observer measures static accelerometer bias. Initial device configuration and
clock synchronization briefly block the Klipper reactor, whereas steady-state
sync exchanges are asynchronous.

The main position datasets are `desired_position`, `motor_position`, and
`observed_position` for both `toolhead` (X) and `base` (Y). Acceleration,
`_raw`, `device_time_us`, `sequence`, `flags`, `observer_valid`, and
`reference_valid` selections are also available. The MATLAB loader retains
`command_x` and `command_y` aliases in its result structure for the existing
sine-analysis code. MATLAB may use the mapped print time or repeat the linear
clock fit from the preserved device timestamps and sync diagnostics.

The sine-print MATLAB analysis and its metric definitions are documented in
[`analysis/matlab/sine_tracking/README.md`](analysis/matlab/sine_tracking/README.md).
It reads lightweight logs directly, reviews the newest run for each condition,
and writes pass-level tables, summaries, and comparison figures.

The continuous streamer and `RUN_VIBRATION_TEST` both own the same USB serial
port and are therefore intentionally mutually exclusive for now. Stop the Motan
logger and disable hybrid FBF before starting a buffered vibration sweep. The
hybrid controller uses `trinkey_accel.start_observer_client()` inside Klipper,
never the non-real-time Motan socket. The desired reference and final motor
input are kept separate in each shared sample. The first
subscriber starts one physical acquisition stream and it remains active until
the final subscriber disconnects.

## Orchestrator

See `orchestrator/README.md` for the first PC-side experiment runner.
