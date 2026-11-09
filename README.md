# Distributed-device native_sim case study

A case study for [Zephyr #120914](https://github.com/zephyrproject-rtos/zephyr/issues/120914): 20 independent devices in one simulated world.

Each device has its own Zephyr kernel, application state, clock, hardware models, and runner. The host and all 20 children link into one statically linked executable. No child images load at runtime.

The executable is built with [Cosmopolitan Libc](https://github.com/jart/cosmopolitan)'s `cosmocc` (GCC 14 and GNU binutils) from **unmodified upstream Zephyr v4.5.0**. Each build targets the CPU of the machine that builds it. An x86-64 build is one APE file for Linux, macOS and Windows. An AArch64 build serves Linux and macOS: Cosmopolitan does not support Windows on ARM. [Platform status](#platform-status) lists what has been verified.

## Workload

Each device has three threads: a 100 ms heartbeat, deterministic multicast work every 10-100 ms, and an event/ACK receiver. The host delays messages by 1-10 ms. Devices run serially. Each grant ends after equal-time hardware events. The host omits idle grants and catches up each device's clock before input delivery.

Each result contains 20 rows: acknowledged events and the last heartbeat that the world received. It also contains the complete traffic's FNV-1a hash and message count. Every timed result must match an always-ticked reference. NCT emulates Zephyr threads. NCE emulates CPU halt/wake. The three coroutine primitives share the same NCT/NCE implementation. Floating-point environment, errno, and C++ exception context preservation remain enabled.

The minute result is `trace ff72adfdb93a52fe 143218`, checksum `1801075893`. The hour result is `trace 3f3db497f9b30aeb 8571855`, checksum `1796618671`. Both are in `reference/`.

## Run

Build on Linux, x86-64 or AArch64. The build needs CMake, Ninja, GNU make, Python with Zephyr's base packages, curl and unzip. `cosmocc` supplies the compiler and binutils: `scripts/cosmocc.sh` downloads the pinned release from GitHub and verifies its SHA-256. Use a plain upstream Zephyr v4.5.0 checkout. No west modules are needed.

```sh
export ZEPHYR_BASE=/path/to/zephyr-v4.5.0
./run.sh                          # build, validate, five one-minute samples per backend
./run.sh build                    # Linux only
./run.sh validate bench           # Linux or macOS, with the binaries built above
SIM_US=600000000 BASELINE=/old/build ./run.sh bench   # also time the previous run.sh's binaries
```

`build/<arch>/<backend>/simulator.com` is the executable. On x86-64 it is an APE file: run it directly on Linux, macOS or Windows. On AArch64, Cosmopolitan produces an ELF file: Linux runs it directly, and macOS runs it through Cosmopolitan's APE loader (`run.sh` builds it from `ape-m1.c`). On macOS, build in Linux, for example with `tools/container/Dockerfile` and the host's native platform, then run `validate` and `bench` on macOS.

Bash measures the complete process, including boot, hashing, output, and exit. There is no LTO. RT is simulated **world time divided by wall time**, not accumulated device-seconds.

## Build pipeline

```
 app/ (firmware sources, prj.conf: CONFIG_BUILD_OUTPUT_EXE=n)
   │  stage 1  scripts/build-firmware.sh — once per application
   ▼
 firmware.o (Zephyr's prelinked zephyr.elf)  +  nsi_config (its runner configuration)
   │  stage 2  scripts/assemble.sh — once per runner backend
   │    runner.a      upstream native simulator runner + app/runner.c, built by cosmocc
   │                  (optionally with runner/coro replacing nct.o/nce.o)
   │    firmware.o    hidden symbols localized (as the native simulator does)
   │    image.o       ld -r firmware + runner, NSI registration sections bounded inside,
   │                  then every symbol localized
   │    instance_N.o  one copy per device
   ▼
 simulator.com = cosmocc simulator.c instance_0.o … instance_19.o
```

1. **Toolchain** (`scripts/cosmocc.sh`, `cosmo/`). `cosmocc` 4.0.2. The host CPU selects `x86_64-linux-cosmo-` or `aarch64-linux-cosmo-` tools. Two adjustments to the private copy:
   - `cosmocc` ships no GCC-private headers. Its own `stddef.h` and `stdarg.h` include the whole C library. Zephyr builds freestanding, so `cosmo/freestanding/` restores minimal versions in GCC's normal place, `lib/gcc/<arch>-linux-cosmo/14.1.0/include`. Zephyr's `--print-file-name=include/stddef.h` probe then works unchanged.
   - CMake and make exec tools directly. Without an APE `binfmt_misc` handler, Linux refuses APE files, so the tools are converted with `cosmocc`'s `assimilate`.
2. **Firmware** (`scripts/build-firmware.sh`, `cosmo/cosmo.cmake`). Zephyr already supports `ZEPHYR_TOOLCHAIN_VARIANT=cross-compile` with `NATIVE_TARGET_HOST` for native_sim. `cosmo.cmake` selects `CROSS_COMPILE=<cosmocc>/bin/<arch>-linux-cosmo-` with it. It adds Cosmopolitan's ABI flags to every Zephyr object:
   - x86-64: `-mno-red-zone -mno-tls-direct-seg-refs`.
   - AArch64: `-ffixed-x18 -ffixed-x28 -fsigned-char`.
   The firmware uses Zephyr's minimal libc, as before. The firmware is compiled with `cosmocc`'s GCC, not with the `cosmocc` wrapper: the wrapper's Cosmopolitan include path would replace Zephyr's libc headers. `CONFIG_BUILD_OUTPUT_EXE=n` already leaves exactly the required artifact, `zephyr.elf`: a relocatable partial link of all Zephyr code, with Zephyr's iterable sections bounded and the runner interface undefined.
3. **Assembly** (`scripts/assemble.sh`). The upstream native simulator Makefile builds the runner (`runner_lib`). Its compiler is the `cosmocc` wrapper, `<arch>-unknown-cosmo-cc`, so the runner uses Cosmopolitan Libc. Localization and the partial link use the native simulator's own options and linker script, with `cosmocc`'s `objcopy` and `ld.bfd`. The script fails if an image still defines a global symbol, or if it lacks its instance table. The final `cosmocc` link concatenates the 20 `instances` sections. `simulator.c` checks the linker-generated bounds before booting.

The firmware build does not depend on the backend or on the number of instances. Assembly takes one firmware directory per instance, so different applications can share one world.

## Design

**Zephyr changes: none.** Upstream v4.5.0 provides everything: the cross-compile toolchain variant for native_sim, `CONFIG_BUILD_OUTPUT_EXE=n`, `NSI_NO_MAIN`, and a Makefile whose tool variables can be overridden. Cosmopolitan performs the host OS adaptation that the previous fork did in Zephyr and the native simulator (Mach-O sections, constructors, symbol localization, semaphores). The previous fork changed 78 files.

**Coroutines live in the case study.** Upstream v4.5.0 has only the pthread NCT/NCE. `runner/coro/` carries the coroutine NCT/NCE and three primitives from the previous branch. Assembly replaces `nct.o`, and with coroutine NCE also `nce.o`, in a copy of the upstream `runner.a`. Each instance still has its own private runner. Changes from the previous branch:
- The Mach-O and i386 assembly were removed: Cosmopolitan objects are always ELF.
- The AArch64 assembly primitive now starts each coroutine with its creator's `x28`. Cosmopolitan keeps the TLS pointer there. A zero `x28` crashed at the first `errno` access.
- Two Cosmopolitan 4.0.2 x86-64 bugs are worked around (see [below](#cosmopolitan-issues-found)): the saved floating-point environment has 64 bytes of room, and `swapcontext()`'s result is not checked.
- Boost.Context is not built: Cosmopolitan has no Boost package, and the assembly primitive covers the same ground.

**Minimal guest adapter.** `app/runner.c` exports generic controls: `boot`, `now`, `advance`, `attach`, `interrupt` and `state`, plus the mailbox that the firmware uses. `simulator.c` now owns the orchestration: catching up idle devices, input visibility and the RPC interrupt.

**Portable code generation.** The previous builds used `-march=native`/`-mcpu=native`. These builds use `-O3` only (`OPT`), because the executable is meant to run on other machines.

## Validation

`scripts/validate.sh` checks every backend. `run.sh validate` runs it for all seven:
- **Determinism.** Output is byte-identical to `reference/60000000.txt`, and to `reference/3600000000.txt` with `FULL=1`. The always-ticked run is identical too.
- **Kernel scheduling and timers.** Every device's heartbeat reached 59 900 ms, and the acknowledgement counts differ per device.
- **Symbol isolation.** Each of these symbols exists 20 times, at 20 distinct addresses, all local, and never global: Zephyr kernel state (`_kernel`, `z_main_thread`, static thread objects), application state, the RPC message queue, runner state, NSI registration bounds, and NCT/NCE instances. Assembly also checks that each image defines no global symbol.
- **Threading (Linux).** The host thread count while running: pthreads 81 (main + 20 × (CPU + 3 threads)), coroutine NCT 21 (main + 20 CPU threads), coroutine NCT and NCE 1.

## Platform status

| Platform | Build | Result |
|---|---|---|
| Linux x86-64 (Intel N100, Ubuntu 26.04) | native | all 7 backends pass `validate`, including the one-hour reference |
| Linux AArch64 (Apple M1, Docker, Ubuntu 24.04) | native | all 7 backends pass `validate`, including the one-hour reference |
| macOS AArch64 (Apple M1, macOS 27.2) | Linux AArch64 build, APE loader | all 7 backends pass `validate` (no thread count on macOS) |
| macOS x86-64 under Rosetta 2 | Linux x86-64 build | coroutine NCE backends match the reference; pthread NCE backends spin and never finish |
| Windows x86-64 | Linux x86-64 build | not yet run: see `.github/workflows/cosmopolitan.yml` |
| Windows on ARM | — | no native build: Cosmopolitan 4.0.2 supports only Linux, macOS and FreeBSD on AArch64 (`libc/dce.h`), and its AArch64 output is ELF. CI runs the x86-64 APE under x64 emulation, labeled and non-blocking |

Linux under Docker Desktop's Rosetta (`linux/amd64` on Apple Silicon) cannot run any Cosmopolitan x86-64 program, not even `cosmocc`'s own tools: they segfault at start.

## Measurements

Each value is the median of five complete runs of a 10-minute world, alternating the order between samples. "Previous" is the pre-Cosmopolitan implementation: this repository's previous `run.sh`, app and `simulator.c`, Zephyr fork `a97d7e5a961`, host GCC or Clang with `-march=native`/`-mcpu=native`. Its outputs were byte-identical to the Cosmopolitan builds. Boost.Context is not in either column. **Previous / Cosmopolitan** above 1 means the Cosmopolitan build is faster.

### Linux: Intel N100, Ubuntu 26.04, GCC 15.2 (previous) and cosmocc GCC 14.1

The other load was an idle Windows guest VM. Pinned to CPU 0 (`PIN="taskset -c 0"`):

| NCT | NCE | Primitive | Previous s | Cosmopolitan s | Cosmopolitan RT | Cosmopolitan speedup | Previous / Cosmopolitan |
|---|---|---|---:|---:|---:|---:|---:|
| pthreads | pthreads | — | 16.810 | 17.319 | 34.6x | 1.00x | **0.97x** |
| coroutines | pthreads | ucontext | 10.318 | 9.708 | 61.8x | 1.78x | **1.06x** |
| coroutines | pthreads | makecontext + _longjmp | 8.803 | 8.229 | 72.9x | 2.10x | **1.07x** |
| coroutines | pthreads | Assembly | 7.602 | 7.432 | 80.7x | 2.33x | **1.02x** |
| coroutines | coroutines | ucontext | 3.810 | 2.985 | 201.0x | 5.80x | **1.28x** |
| coroutines | coroutines | makecontext + _longjmp | 2.166 | 1.725 | 347.8x | 10.04x | **1.26x** |
| coroutines | coroutines | Assembly | 1.913 | 1.516 | 395.8x | 11.42x | **1.26x** |

Unpinned:

| NCT | NCE | Primitive | Previous s | Cosmopolitan s | Cosmopolitan RT | Cosmopolitan speedup | Previous / Cosmopolitan |
|---|---|---|---:|---:|---:|---:|---:|
| pthreads | pthreads | — | 20.962 | 20.989 | 28.6x | 1.00x | **1.00x** |
| coroutines | pthreads | ucontext | 12.141 | 11.615 | 51.7x | 1.81x | **1.05x** |
| coroutines | pthreads | makecontext + _longjmp | 11.075 | 10.633 | 56.4x | 1.97x | **1.04x** |
| coroutines | pthreads | Assembly | 10.897 | 10.550 | 56.9x | 1.99x | **1.03x** |
| coroutines | coroutines | ucontext | 3.807 | 2.994 | 200.4x | 7.01x | **1.27x** |
| coroutines | coroutines | makecontext + _longjmp | 2.168 | 1.726 | 347.6x | 12.16x | **1.26x** |
| coroutines | coroutines | Assembly | 1.915 | 1.518 | 395.3x | 13.83x | **1.26x** |

The previous column reproduces the historical one-hour table below: 16.81 s per 10 minutes against 99.96 s per hour for pinned pthreads, and 1.91 s against 11.80 s for Assembly.

### macOS: Apple M1, macOS 27.2, Apple Clang (previous) and cosmocc GCC 14.1

Native arm64, unpinned. The Cosmopolitan build is the Linux AArch64 executable, run through the APE loader. Other applications ran throughout.

| NCT | NCE | Primitive | Previous s | Cosmopolitan s | Cosmopolitan RT | Cosmopolitan speedup | Previous / Cosmopolitan |
|---|---|---|---:|---:|---:|---:|---:|
| pthreads | pthreads | — | 11.021 | 10.344 | 58.0x | 1.00x | **1.07x** |
| coroutines | pthreads | ucontext | 8.127 | 6.228 | 96.3x | 1.66x | **1.30x** |
| coroutines | pthreads | makecontext + _longjmp | 5.786 | 5.584 | 107.4x | 1.85x | **1.04x** |
| coroutines | pthreads | Assembly | 5.588 | 5.453 | 110.0x | 1.90x | **1.02x** |
| coroutines | coroutines | ucontext | 4.478 | 1.847 | 324.9x | 5.60x | **2.42x** |
| coroutines | coroutines | makecontext + _longjmp | 0.773 | 0.678 | 885.0x | 15.26x | **1.14x** |
| coroutines | coroutines | Assembly | 0.645 | 0.577 | 1039.9x | 17.93x | **1.12x** |

### Linux AArch64: Apple M1, Docker Desktop, Ubuntu 24.04, GCC 13.3 (previous) and cosmocc GCC 14.1

One-minute worlds. Docker's virtual machine makes the pthread backends syscall-bound.

| NCT | NCE | Primitive | Previous s | Cosmopolitan s | Cosmopolitan RT | Cosmopolitan speedup | Previous / Cosmopolitan |
|---|---|---|---:|---:|---:|---:|---:|
| pthreads | pthreads | — | 7.508 | 7.512 | 8.0x | 1.00x | **1.00x** |
| coroutines | pthreads | ucontext | 4.151 | 3.914 | 15.3x | 1.92x | **1.06x** |
| coroutines | pthreads | makecontext + _longjmp | 3.774 | 3.751 | 16.0x | 2.00x | **1.01x** |
| coroutines | pthreads | Assembly | 3.715 | 3.780 | 15.9x | 1.99x | **0.98x** |
| coroutines | coroutines | ucontext | 0.308 | 0.196 | 306.1x | 38.33x | **1.57x** |
| coroutines | coroutines | makecontext + _longjmp | 0.093 | 0.072 | 833.3x | 104.33x | **1.29x** |
| coroutines | coroutines | Assembly | 0.073 | 0.063 | 952.4x | 119.24x | **1.16x** |

### Cosmopolitan nightly

The nightly `cosmocc` of 2026-11-09 (master `aefad27`, GCC 14.1.0) changes none of the above:
- Its AArch64 support is still Linux, macOS and FreeBSD only, so there is no Windows on ARM build.
- Both x86-64 bugs below still occur.
- It passes every check, including the one-hour reference on x86-64.
- It is not faster. Against 4.0.2 (10-minute worlds, five samples, the 4.0.2 build as the baseline column): N100 pinned to CPU 0, 0.93-0.97x with pthread NCE and 0.98-1.00x with coroutine NCE; M1 macOS 0.96-1.00x.

So `scripts/cosmocc.sh` stays pinned to the 4.0.2 release, which anyone can download without GitHub authentication. Another archive can be tried with `COSMOCC_VERSION=<name> COSMOCC_ZIP=<archive> COSMOCC_SHA256=<hash>`.

## Cosmopolitan issues found

Both are in Cosmopolitan Libc 4.0.2 and in the 2026-11-09 nightly, on x86-64 only. Both are worked around in `runner/coro/`:
- `fenv_t` is declared as `void *` (8 bytes), but `fegetenv()` stores 32 bytes (`fnstenv` plus `stmxcsr`). The coroutine context reserves 64 bytes for it. Without that, every coroutine backend crashed. AArch64 stores exactly 8 bytes.
- A resumed `swapcontext()` returns the `%rax` value of its original call, not 0. `getcontext` saves `%rax`, and `__tailcontext` restores it. The ucontext primitive no longer checks the result.

## Continuous integration

`.github/workflows/cosmopolitan.yml` builds and validates on six Ubuntu runners: 22.04, 24.04 and 26.04, each on x86-64 and on ARM. Then it validates and times the Ubuntu 24.04 builds on every runner OS: Ubuntu, Windows 2022/2025, Windows 11 on ARM (emulated x86-64, non-blocking), macOS 15/26 on Intel and on Apple Silicon, and Xcode 27. A final job lists each build host's executable hashes. `workflow_dispatch` with `full` also checks the 10-minute and one-hour references.

## Limitations

- **Build host.** Building needs Linux. Upstream `arch/posix/CMakeLists.txt` rejects other hosts, even though `cosmocc` itself runs on macOS and Windows. Allowing macOS hosts for the cross-compile variant would be a one-line upstream change.
- **CPU.** One build serves one CPU architecture: no fat binaries. Windows on ARM has no native build.
- **Boost.Context.** Not available: there is no Cosmopolitan build of Boost.
- **Portable code generation.** The previous column had `-march=native`. These builds are generic `-O3`. Set `OPT` to choose otherwise.

## Historical one-hour measurements — before Cosmopolitan

These tables describe the patched-Zephyr versions that preceded the Cosmopolitan build, measured with the previous `run.sh` (`git show ccfcaee:run.sh`). Each value is the median of five complete one-hour runs. All samples remain in the medians.

### Linux: Intel N100, Ubuntu 26.04, GCC 15.2

Source: Zephyr `edfabfddfac`. Linux RT uses the CPU 0 wall-time column. All 90 measured results and 18 always-ticked references matched. This version used `_setjmp()`/`_longjmp()` for its libc primitive.

| NCT | NCE | Primitive | Unpinned | Pinned | RT | Speedup |
|---|---|---|---:|---:|---:|---:|
| pthreads | pthreads | — | 121.690 | 99.964 | 36.0x | **1.00x** |
| coroutines | pthreads | `ucontext` | 71.403 | 61.828 | 58.2x | **1.62x** |
| coroutines | pthreads | `makecontext` + `_longjmp` | 65.204 | 52.647 | 68.4x | **1.90x** |
| coroutines | pthreads | Boost.Context | 66.105 | 54.279 | 66.3x | **1.84x** |
| coroutines | pthreads | Assembly | 63.469 | 48.518 | 74.2x | **2.06x** |
| coroutines | coroutines | `ucontext` | 23.126 | 23.155 | 155.5x | **4.32x** |
| coroutines | coroutines | `makecontext` + `_longjmp` | 13.283 | 13.260 | 271.5x | **7.54x** |
| coroutines | coroutines | Boost.Context | 13.049 | 13.244 | 271.8x | **7.55x** |
| coroutines | coroutines | Assembly | 12.205 | 11.796 | 305.2x | **8.47x** |

### macOS: Apple M1, macOS 27.0.1, Apple Clang 21.0.0

Source: Zephyr `a97d7e5a961` and application checkpoint `bbeeada`. Native arm64, `-O3 -mcpu=native`, one executable, static Boost.Context, no CPU pinning. All 45 measured results and nine always-ticked references matched Linux.

| NCT | NCE | Primitive | Wall s | RT | Speedup |
|---|---|---|---:|---:|---:|
| pthreads | pthreads | — | 67.165 | 53.6x | **1.00x** |
| coroutines | pthreads | `ucontext` | 50.331 | 71.5x | **1.33x** |
| coroutines | pthreads | `makecontext` + `siglongjmp` | 35.719 | 100.8x | **1.88x** |
| coroutines | pthreads | Boost.Context | 35.163 | 102.4x | **1.91x** |
| coroutines | pthreads | Assembly | 34.767 | 103.5x | **1.93x** |
| coroutines | coroutines | `ucontext` | 26.205 | 137.4x | **2.56x** |
| coroutines | coroutines | `makecontext` + `siglongjmp` | 4.099 | 878.3x | **16.39x** |
| coroutines | coroutines | Boost.Context | 3.980 | 904.5x | **16.88x** |
| coroutines | coroutines | Assembly | 3.858 | 933.1x | **17.41x** |

The Mac batch ran on 2026-10-10, 17:51:40-18:21:31 +0200, on AC power with charge at 37%-63%. Other applications ran throughout. No system sleep occurred. These are busy-machine measurements, not controlled cross-machine comparisons. These measurements do not isolate the linking change.
