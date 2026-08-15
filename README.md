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
a representative new symbol:

```sh
/usr/share/klippy-env/bin/python3 -c 'p="/tmp/c_helper.so.new"; h=open(p,"rb").read(20); assert h[:4] == b"\x7fELF" and h[4] == 1 and h[5] == 1 and int.from_bytes(h[18:20], "little") == 8, "not ELF32 little-endian MIPS"; print("ELF32 little-endian MIPS")'

/usr/share/klippy-env/bin/python3 -c \
  'import cffi; f=cffi.FFI(); f.cdef("void *filtered_bspline_controller_alloc(void);"); lib=f.dlopen("/tmp/c_helper.so.new"); print(lib.filtered_bspline_controller_alloc)'
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

The `vibration_test.py` and `trinkey_accel.py` extensions are Python-only and
do not themselves require a rebuilt helper. Rebuild and deploy `c_helper.so`
when changing files in `klippy/chelper`, such as
`kin_filtered_bspline.c`, or the C declarations/source list in its
`__init__.py`.

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

The stock Motan logger automatically subscribes to both configured sensors and
all standard Motan motion/status sources:

```sh
python3 external/klipper/scripts/motan/data_logger.py \
  ~/printer_data/comms/klippy.sock \
  ~/printer_data/logs/motan/trinkey_run
```

For the high-density 35 Hz G-code experiments, use the independent lightweight
copy instead:

```sh
python3 external/klipper/scripts/motan_lightweight/data_logger.py \
  /usr/data/printer_data/comms/klippy.sock \
  /usr/data/printer_data/logs/motan/sine_35_comp_r1
```

It logs the base and toolhead Trinkey streams, nominal toolhead acceleration
evaluated at each genuine sensor timestamp, and a small diagnostic status
subset. It does not export the full high-density toolhead or extruder TrapQ,
step queues, ADXL/angle streams, or unrelated status objects. The stock
`scripts/motan` directory is retained unchanged. If either required sensor is
silent for five seconds, the lightweight process warns but remains connected;
validate sample continuity and the loss counters after the run.

The exact Klipper socket path depends on the printer installation. Motan writes
`trinkey_run.json.gz` and `trinkey_run.index.gz`. Each acceleration row retains:

- mapped Klipper `print_time`;
- original 64-bit Trinkey microsecond timestamp;
- firmware sample sequence;
- raw BNO055 axes;
- scaled axes in mm/s²;
- the relevant nominal TrapQ acceleration (`command_x` for toolhead and
  `command_y` for base), evaluated at that row's mapped print time;
- a command-reference validity flag;
- validity flags and stream diagnostics.

While Motan is connected, run `TRINKEY_ACCEL_STATUS` in the Fluidd console to
inspect reader health, synchronization timeouts, firmware overruns, transport
drops, I²C read durations, host sequence errors, and clock-fit quality. Start
the logger before starting printer motion; initial device configuration and
clock synchronization briefly block the Klipper reactor, whereas steady-state
sync exchanges are asynchronous.

The main comparison datasets are `trinkey_accel(toolhead,x)` against
`trinkey_accel(toolhead,command_x)`, and `trinkey_accel(base,y)` against
`trinkey_accel(base,command_y)`. The `_raw`, `device_time_us`, `sequence`,
`flags`, and `reference_valid` selections are also available. MATLAB may use
the mapped print time or repeat the linear clock fit from the preserved device
timestamps and sync diagnostics.

The continuous streamer and `RUN_VIBRATION_TEST` both own the same USB serial
port and are therefore intentionally mutually exclusive for now. Stop the Motan
logger before starting a buffered vibration sweep. A later hybrid controller
should consume measurements through an internal Klipper path, never through
the non-real-time Motan socket. Its 1 kHz prediction/reference path remains
separate from this sampled evaluation stream. The first
subscriber starts one physical acquisition stream and it remains active until
the final subscriber disconnects.

## Orchestrator

See `orchestrator/README.md` for the first PC-side experiment runner.
