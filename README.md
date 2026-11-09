# Distributed-device native_sim case study

A case study for [Zephyr #120914](https://github.com/zephyrproject-rtos/zephyr/issues/120914): 20 independent devices in one simulated world.

Each device has its own Zephyr kernel, application state, clock, hardware models, and runner. The host and all 20 children link into one statically linked executable. No child images load at runtime.

The executable is built with [Cosmopolitan Libc](https://github.com/jart/cosmopolitan)'s `cosmocc` (GCC 14 and GNU binutils), from upstream Zephyr v4.5.0 plus `zephyr.patch`. Linux, macOS and Windows build it, each for its own OS and CPU. With `COSMOCC_PORTABLE=1`, the x86-64 build is instead one file for Linux, macOS and Windows, and the AArch64 build one for Linux and macOS. Cosmopolitan does not support Windows on ARM.

## Workload

Each device has three threads: a 100 ms heartbeat, deterministic multicast work every 10-100 ms, and an event/ACK receiver. The host delays messages by 1-10 ms. Devices run serially. Each grant ends after equal-time hardware events. The host omits idle grants and catches up each device's clock before input delivery.

Each result contains 20 rows: acknowledged events and the last heartbeat that the world received. It also contains the complete traffic's FNV-1a hash and message count. The CPU and thread emulation run either on host threads (pthreads, upstream) or as coroutines on one host thread.

The minute result is `trace ff72adfdb93a52fe 143218`, checksum `1801075893`. The hour result is `trace 3f3db497f9b30aeb 8571855`, checksum `1796618671`. Both outputs are in `reference/`.

## Run

Linux or macOS, x86-64 or AArch64. Windows (Git Bash, x86-64) is meant to work too, but is untested. You need CMake, Ninja, Python with Zephyr's base packages, curl and unzip, and for `./run.sh zephyr`, twister's packages (see the workflow). `run.sh` downloads `cosmocc` 4.0.2 and checks its SHA-256.

```sh
git -C /path/to/zephyr-v4.5.0 apply "$PWD/zephyr.patch"
export ZEPHYR_BASE=/path/to/zephyr-v4.5.0
./run.sh                  # build, check, and time five one-minute worlds per backend
./run.sh check bench      # again, without rebuilding
./run.sh zephyr           # Zephyr samples and test suites, built with cosmocc, run by twister
COSMOCC_PORTABLE=1 ./run.sh build              # portable executables instead
RUNNER_CFLAGS=-DCORO_SAVE_CONTEXT ./run.sh build   # coroutines with per-thread errno, FP and C++ state
```

With the patch, a native_sim application builds the usual way, e.g. `cmake -S samples/hello_world -B build -GNinja -DBOARD=native_sim/native/64 -DZEPHYR_TOOLCHAIN_VARIANT=cosmocc -DCOSMOCC_TOOLCHAIN_PATH=<cosmocc> && cmake --build build`. The result is `build/zephyr/zephyr.exe`, with its symbols in `zephyr.exe.dbg`. Twister runs native_sim tests with `ZEPHYR_TOOLCHAIN_VARIANT=cosmocc`.

The case study's executable is `build/<backend>/simulator.exe`. `.github/workflows/build-and-run.yml` builds, checks and times it, and runs the Zephyr tests, on every GitHub runner OS and CPU.

## How it works

**Zephyr** (`zephyr.patch`) gains a `cosmocc` toolchain variant:
- It selects cosmocc's GCC and binutils for the host's CPU, with Cosmopolitan's ABI flags.
- It builds the native simulator runner with cosmocc's driver, for Cosmopolitan Libc.
- Zephyr's own code uses Zephyr's minimal C library, with native_sim's usual 16 KiB heap. cosmocc has no freestanding `stddef.h` or `stdarg.h`, so the variant adds them where GCC looks for its own headers.
- Executables are for the build host only, in its format:
  - **Linux:** ELF, from cosmocc's Linux-only (`-moptlinux`) libraries.
  - **Windows:** PE.
  - **macOS:** cosmocc cannot make Mach-O executables that macOS accepts. `zephyr.exe` is a script that starts `zephyr.exe.dbg` through Cosmopolitan's loader.
  - **`COSMOCC_PORTABLE`:** Actually Portable Executables instead.
- Outside Windows, CMake cannot start Cosmopolitan's tools directly: the variant adds shell launchers to the cosmocc tree.
- Zephyr also accepts macOS and Windows build hosts when the target host is explicit, as with cosmocc.
- For the usual single-image `zephyr.exe`:
  - The native simulator passes its `INSERT` linker scripts with `-Wl,-T`, so that they precede cosmocc's own script.
  - Its board script keeps only allocated `symbol_to_keep` sections: an empty, unallocated one had pulled other empty sections into the middle of memory.
  - The init-priority check reads `zephyr.exe.dbg`.
  - `nsi_errno.c`'s table is no longer `const`, because Cosmopolitan's errno values are variables.
- Twister builds native_sim with the variant when selected, and runs it on macOS and Windows too.

`CONFIG_BUILD_OUTPUT_EXE=n` leaves the firmware as `zephyr.elf`: a partially linked object, with Zephyr's iterable sections already bounded.

**Assembly** (`scripts/assemble.sh`) reads the firmware's runner configuration, `zephyr/NSI/nsi_config`:
1. Compile the upstream native simulator runner and `app/runner.c`. The coroutine backend replaces `nce.c` and `nct.c` with `runner/coro.c` and `runner/coro.S`.
2. Localize the firmware's hidden symbols, as the native simulator does.
3. Link firmware and runner into one relocatable image with `ld -r`. The runner's linker script bounds the NSI registration sections inside the image.
4. Localize every symbol, and fail if any global definition remains.
5. Link the image 20 times with `simulator.c`. The linker collects the 20 `instances` tables into one array, and `simulator.c` checks that there are 20.

**Coroutines** (`runner/coro.c`, `runner/coro.S`). The CPU and each Zephyr thread are stackful coroutines on the host thread. A switch saves the callee-saved registers. By default, all coroutines share the host thread's errno, floating-point environment and C++ exception state:
- If firmware changes the rounding mode, exception masks or flush-to-zero, that change also affects every other thread and device.
- Exception flags are shared.
- Zephyr's own errno is per thread, so the shared host errno does not affect it.

`-DCORO_SAVE_CONTEXT` restores the strict behaviour of host threads: each coroutine saves and restores its own errno, floating-point environment and C++ exception state, inheriting its creator's.

**Guest adapter** (`app/runner.c`). Each device exports `boot`, `now`, `advance`, `attach`, `interrupt` and `state`. `simulator.c` decides when devices run, catches idle devices up, and delivers input.

## Checks

`./run.sh check` requires byte-identical output to both references, for both backends. The minute is also checked in the always-ticked reference mode. This has passed on Linux x86-64 (Intel N100), Linux AArch64 and macOS AArch64 (Apple M1). Windows has not been run yet.

`./run.sh zephyr` runs twister on 3 samples and 16 ztest suites (kernel threads, scheduling, timers, synchronization, queues, work queues, memory slabs, C library, and more): 62 test configurations. All executed configurations and test cases passed:
- **macOS AArch64**, built on macOS: 47 configurations, 1,119 test cases.
- **Linux AArch64 and x86-64**: 45 configurations, 1,039 test cases.

Twister filtered the rest, for example picolibc variants.

## Measurements

Previous: this repository's earlier `run.sh`, app and `simulator.c`, with Zephyr fork `a97d7e5a961` and host GCC or Clang at `-march=native`/`-mcpu=native`. Its coroutine column is the assembly primitive, which also saved the floating-point environment and errno on every switch. Cosmopolitan: these builds, at generic `-O3`. Each value is the median wall time of five 10-minute worlds, run interleaved. All 40 outputs per machine were identical.

| Machine | Backend | Previous s | Cosmopolitan s | RT | Previous / Cosmopolitan |
|---|---|---:|---:|---:|---:|
| Intel N100, Linux, CPU 0 | pthreads | 16.677 | 17.122 | 35x | 0.97x |
| Intel N100, Linux, CPU 0 | coroutines | 1.915 | 1.049 | 572x | **1.83x** |
| Intel N100, Linux, unpinned | pthreads | 20.996 | 21.047 | 29x | 1.00x |
| Intel N100, Linux, unpinned | coroutines | 1.918 | 1.050 | 571x | **1.83x** |
| Apple M1, macOS, unpinned | pthreads | 10.865 | 9.679 | 62x | 1.12x |
| Apple M1, macOS, unpinned | coroutines | 0.619 | 0.538 | 1115x | **1.15x** |

RT is simulated world time divided by wall time. The N100 also ran an idle Windows virtual machine. These Cosmopolitan builds were portable executables.

Build options, on the N100 pinned to CPU 0, with the same method:

| Build | pthreads s | coroutines s |
|---|---:|---:|
| Default: Linux-only ELF (`-moptlinux`) | 17.220 | 1.045 |
| `COSMOCC_PORTABLE=1` | 17.330 | 1.050 |
| `RUNNER_CFLAGS=-DCORO_SAVE_CONTEXT` | — | 1.550 |

The Linux-only libraries gain less than 1%. Saving the floating-point environment on every switch costs 48% on x86-64, because `fegetenv` and `fesetenv` are slow there. Even so, the strict coroutines remain 1.24x faster than the previous implementation's, which did the same. On the M1, they cost 5%.

## Notes

- **64-bit only.** cosmocc builds 64-bit programs: use `native_sim/native/64`. Zephyr's code uses its minimal C library; picolibc would need more freestanding headers.
- **Single-OS builds.** Only Linux has an OS-specific Cosmopolitan Libc (`-moptlinux`). On macOS and Windows, the executable has the host's format, but its library still contains the code for the other operating systems.
- **Cosmopolitan 4.0.2 on x86-64.** `fenv_t` is 8 bytes, but `fegetenv()` writes 32. A resumed `swapcontext()` returns a stale `%rax` instead of 0. This code calls neither. The 2026-11-09 nightly has both bugs, still lacks Windows on ARM, and was no faster.
- **Rosetta.** Cosmopolitan x86-64 programs crash under Docker Desktop's Rosetta for Linux. Under macOS Rosetta, pthread backends never finish.

## Historical one-hour measurements — before Cosmopolitan

These tables describe the patched-Zephyr versions that preceded the Cosmopolitan build, measured with the original `run.sh` (`git show ccfcaee:run.sh`). Each value is the median of five complete one-hour runs. All samples remain in the medians.

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
