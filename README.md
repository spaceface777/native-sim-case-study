# 20 devices in one native_sim process

A case study for [Zephyr #120914](https://github.com/zephyrproject-rtos/zephyr/issues/120914), which proposes that native_sim can run the embedded CPU and its threads as coroutines instead of host threads.

It contains:

- **A workload** that switches context very often: a network of 20 simulated devices.
- **The proposal** as four patches for Zephyr v4.5.0, in [`zephyr-patches/`](zephyr-patches).
- **Measurements** of each patch.

## Workload

Each device is a complete native_sim image: its own Zephyr kernel, clock, hardware models and native simulator runner. [`simulator.c`](simulator.c) links 20 copies of it into one process. It runs them one after the other, one millisecond at a time, and delivers each message 1 to 10 ms after it was sent.

A device ([`app/main.c`](app/main.c)) has three threads: a heartbeat every 100 ms, one that sends events to other devices every 10 to 100 ms, and one that acknowledges the events it receives. It does very little each time it runs, so most of the run time is context switches of two kinds:

- **Hardware models to CPU and back** (NCE), each time a device has a timer or a message to handle.
- **Thread to thread** (NCT) inside a device.

Upstream does both with host threads that hand execution over through semaphores.

While conceptually similar, this does not make use of native_sim's multi-MCU support. There, the MCUs of one device share a clock and peripherals. Here, each device has its own.

## Patches

They apply to Zephyr v4.5.0, in order. Each adds options that are off by default.

| Patch | What it adds | `CONFIG_NATIVE_SIMULATOR_` |
|---|---|---|
| [0001](zephyr-patches/0001-native_simulator-allow-the-application-to-provide-NC.patch) | The runner can be built without `nce.c` or `nct.c`, so that an application provides its own. | `NCE_CUSTOM`, `NCT_CUSTOM` |
| [0002](zephyr-patches/0002-native_simulator-add-a-coroutine-NCT.patch) | Embedded threads as coroutines, switched with `swapcontext()`. Works with upstream's NCE. | `NCT_COROUTINES` |
| [0003](zephyr-patches/0003-native_simulator-add-a-coroutine-NCE.patch) | The embedded CPU as a coroutine in the hardware models' host thread. Needs a coroutine NCT. | `NCE_COROUTINES` |
| [0004](zephyr-patches/0004-native_simulator-coroutines-switch-with-siglongjmp.patch) | Switch with `siglongjmp()` instead of `swapcontext()`. | `CORO_SIGLONGJMP` |

Together they add 600 lines to Zephyr. They contain no assembly and nothing specific to a host CPU: the host C library's `ucontext` creates each coroutine.

[`nct-nce-custom-asm.c`](nct-nce-custom-asm.c) is not part of the proposal. It is this application's own NCE and NCT, built through patch 0001. Its switch is inline assembly that saves only the stack, frame and program counters.

## Results

One simulated hour on an Intel N100 (Ubuntu 26.04, GCC 15.2, glibc 2.43, bare metal), on one CPU. Each value is the median of three runs. Every run behaves identically.

| NCT | NCE | Switch | Seconds | Real time | Against upstream |
|---|---|---|---:|---:|---:|
| host threads | host threads | upstream | 99.08 | 36x | 1.0x |
| coroutines | host threads | `swapcontext()` | 56.41 | 64x | 1.8x |
| coroutines | host threads | `siglongjmp()` | 41.40 | 87x | 2.4x |
| coroutines | coroutines | `swapcontext()` | 17.49 | 206x | 5.7x |
| coroutines | coroutines | `siglongjmp()`, `CONFIG_FPU_SHARING=y` | 12.86 | 280x | 7.7x |
| coroutines | coroutines | `siglongjmp()` | 7.13 | 505x | 13.9x |
| custom | custom | inline assembly | 5.58 | 645x | 17.8x |

Real time is simulated time divided by wall time.

The same on GitHub's Linux runners, which are virtual machines ([run](https://github.com/spaceface777/native-sim-case-study/actions/runs/43482955335)). Seconds, with the gain against upstream:

| NCT | NCE | Switch | x86-64 | AArch64 |
|---|---|---|---:|---:|
| host threads | host threads | upstream | 191.29 | 80.07 |
| coroutines | host threads | `swapcontext()` | 87.90 (2.2x) | 46.83 (1.7x) |
| coroutines | host threads | `siglongjmp()` | 82.33 (2.3x) | 29.48 (2.7x) |
| coroutines | coroutines | `swapcontext()` | 20.27 (9.4x) | 19.60 (4.1x) |
| coroutines | coroutines | `siglongjmp()`, `CONFIG_FPU_SHARING=y` | 12.78 (15.0x) | 4.08 (19.6x) |
| coroutines | coroutines | `siglongjmp()` | 6.90 (27.7x) | 3.95 (20.3x) |
| custom | custom | inline assembly | 5.49 (34.8x) | 3.15 (25.4x) |

- **One CPU is upstream's best case.** `run.sh` pins each run to one CPU. Without that, in another run, upstream took 283 s and 270 s, and `siglongjmp()` with both coroutines 3.8 s and 3.9 s: about 70x ([run](https://github.com/spaceface777/native-sim-case-study/actions/runs/43480809025)).
- **NCE matters most here.** Most switches in this workload are between the hardware models and a CPU. An application with one device and many threads would gain more from the NCT alone.
- **`swapcontext()` makes a system call on every switch**, to save and restore the signal mask. `siglongjmp()` does not.

### The floating-point environment

On embedded targets, Zephyr saves each thread's floating-point context (e.g. rounding mode and the exception flags) only with `CONFIG_FPU_SHARING`. Without the option, all threads share them. Patch 0004 does the same. In other words:

| Emulation | Each thread keeps its own rounding mode |
|---|---|
| Host threads (upstream) | Always |
| Coroutines, `swapcontext()` | Always: glibc saves it in the context |
| Coroutines, `siglongjmp()` | Only with `CONFIG_FPU_SHARING=y` |

Saving it costs 5.7 s of the 12.86 s above, because glibc's `fegetenv()` and `fesetenv()` are very slow on x86-64. On AArch64 it costs almost nothing.

## Run

Linux with GCC, CMake, Ninja, and Python with Zephyr's base packages.

```sh
git clone --depth 1 -b v4.5.0 https://github.com/zephyrproject-rtos/zephyr
git -C zephyr apply "$PWD"/zephyr-patches/*.patch
export ZEPHYR_BASE=$PWD/zephyr
./run.sh
```

`run.sh` builds each variant, runs one simulated hour of it three times, and prints the table. It checks every run's output against a hash of upstream's. The output has, for each device, its acknowledged events and last heartbeat, then a hash and a count of all messages.

## What the coroutines change

With coroutines, the simulation is one host thread (or two, with upstream's NCE). The options' help texts say what follows from that:

- **Debuggers** show the embedded thread that is running, not the others.
- **Thread-local storage** of the host is shared by all embedded threads. Only errno and the C++ exception state are saved and restored on context switches. (Zephyr's own `CONFIG_THREAD_LOCAL_STORAGE` is not supported on native_sim upstream.)
- **Sanitizers and Valgrind** are not told about the switches. Kconfig refuses the address and memory sanitizers.
- **`siglongjmp()` to another stack** is not defined by any standard. glibc allows it, but its fortified `longjmp()` does not, so patch 0004 builds that one file without `_FORTIFY_SOURCE`. QEMU's coroutines do the same.

Zephyr's own samples and kernel test suites pass with each combination above, on the 64-bit and 32-bit native_sim boards (x86-64, glibc). CI runs this case study on x86-64 and AArch64.
