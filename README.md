# Distributed-device native_sim case study

A case study for [Zephyr #120914](https://github.com/zephyrproject-rtos/zephyr/issues/120914): 20 independent devices in one simulated world.

Each device has its own Zephyr kernel, application state, clock, hardware models, and runner. The host and all 20 children link into one executable. No child images load at runtime.

## Workload

Each device has three threads: a 100 ms heartbeat, deterministic multicast work every 10-100 ms, and an event/ACK receiver. The host delays messages by 1-10 ms. Devices run serially. Each grant ends after equal-time hardware events. The host omits idle grants and catches up each device's clock before input delivery.

Each result contains 20 rows: acknowledged events and the last heartbeat that the world received. It also contains the complete traffic's FNV-1a hash and message count. Every timed result must match an always-ticked reference. NCT emulates Zephyr threads. NCE emulates CPU halt/wake. The four coroutine primitives share the same NCT/NCE implementation. Floating-point environment, errno, and C++ exception context preservation remain enabled.

## Run

Use the [macOS/context-backends Zephyr branch](https://github.com/spaceface777/zephyr/tree/native-sim-context-backends-pr118530), at `a97d7e5a961` for this version. Both platforms need CMake, Ninja, and Boost.Context development files. Linux also needs GCC and binutils. macOS uses Xcode command-line tools and stock Bash. No LLVM package is required.

```sh
export ZEPHYR_BASE=/path/to/patched/zephyr
./run.sh                         # all nine backends, five one-minute samples
SIM_US=3600000000 ./run.sh        # five one-hour samples
```

Linux measures CPU 0 and unpinned execution with identical binaries. macOS measures unpinned execution. The script retains samples and reference outputs under `build/<timestamp>/`. It writes the latest report to `build/results.md`. Nonstandard Boost installations can set `BOOST_ROOT` and `BOOST_LIBRARYDIR`.

Bash measures the complete process, including boot, hashing, output, and exit. There is no LTO. RT is simulated **world time divided by wall time**, not accumulated device-seconds. Linux speedups use the CPU 0 pthread/pthread baseline. Mac speedups use their batch's unpinned pthread/pthread baseline.

The minute result is `trace ff72adfdb93a52fe 143218`, checksum `1801075893`. The hour result is `trace 3f3db497f9b30aeb 8571855`, checksum `1796618671`.

## Historical one-hour measurements — pre-cleanup

These tables describe the versions before this cleanup. Each value is the median of five complete one-hour runs. All samples remain in the medians.

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
