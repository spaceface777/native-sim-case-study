#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build, check and time the 20-device world for this host's OS and CPU:
#   ./run.sh [build] [check] [bench] [zephyr]     default: build check bench
# build and zephyr need ZEPHYR_BASE: upstream Zephyr v4.5.0 with zephyr.patch applied.
# bench runs SAMPLES (5) worlds of SIM_US (60000000) microseconds per backend.
# zephyr runs Zephyr's own samples and test suites below with twister, built with cosmocc.
# COSMOCC_PORTABLE=1 builds portable executables. RUNNER_CFLAGS=-DCORO_SAVE_CONTEXT gives
# each coroutine its own errno, floating-point environment and C++ exception state.
set -e -o pipefail
cd "$(dirname "$0")"
build=${BUILD:-$PWD/build}
steps=${*:-build check bench}
backends='pthreads coroutines'
cosmocc=$build/cosmocc-4.0.2 # GCC 14 and GNU binutils for Cosmopolitan Libc

# Download and unpack cosmocc, once.
cosmocc_setup() {
	[[ ! -d $cosmocc ]] || return 0
	mkdir -p "$build"
	[[ -f $cosmocc.zip ]] || curl -fsSL -o "$cosmocc.zip" \
		https://github.com/jart/cosmopolitan/releases/download/4.0.2/cosmocc-4.0.2.zip
	{ sha256sum "$cosmocc.zip" 2>/dev/null || shasum -a 256 "$cosmocc.zip"; } |
		grep -q ^85b8c37a406d862e656ad4ec14be9f6ce474c1b436b9615e91a55208aced3f44 ||
		{ echo "$cosmocc.zip: wrong SHA-256" >&2; exit 1; }
	rm -rf "$cosmocc.part" && unzip -q "$cosmocc.zip" -d "$cosmocc.part" && mv "$cosmocc.part" "$cosmocc"
}

# Build a Zephyr application for native_sim with Zephyr's cosmocc toolchain, no west modules.
zephyr_build() {
	{
		cmake -S "$1" -B "$2" -GNinja -DBOARD=native_sim/native/64 -DZEPHYR_MODULES= \
			-DZEPHYR_TOOLCHAIN_VARIANT=cosmocc -DCOSMOCC_TOOLCHAIN_PATH="$cosmocc"
		cmake --build "$2"
	} >"$2.log" 2>&1
}

if [[ $steps == *build* ]]; then
	cosmocc_setup
	# The firmware, compiled once.
	zephyr_build app "$build/firmware" || { tail -n 30 "$build/firmware.log"; exit 1; }
	instances=$(sed -n 's/^#define INSTANCES *//p' app/api.h)
	for backend in $backends; do
		scripts/assemble.sh "$build/firmware" "$instances" "$build/$backend" $backend
	done
fi

if [[ $steps == *check* ]]; then
	for backend in $backends; do
		for reference in reference/*.txt; do
			"$build/$backend/simulator.exe" "$(basename "$reference" .txt)" | cmp - "$reference"
		done
		# Entering every device on every tick, instead of only busy ones, changes nothing.
		"$build/$backend/simulator.exe" 60000000 always | cmp - reference/60000000.txt
		echo "$backend: output matches $(echo reference/*.txt)"
	done
fi

if [[ $steps == *bench* ]]; then
	samples=${SAMPLES:-5} us=${SIM_US:-60000000} TIMEFORMAT=%3R
	echo "Median of $samples runs of $us simulated microseconds on $(uname -s) $(uname -m):"
	echo '| Backend | Wall s | RT | Speedup |'
	echo '|---|---:|---:|---:|'
	for backend in $backends; do
		wall=$(for ((i = 0; i < samples; i++)); do
			{ time "$build/$backend/simulator.exe" "$us" >/dev/null; } 2>&1
		done | sort -n | awk '{v[NR] = $1} END {print v[int((NR + 1) / 2)]}')
		first=${first:-$wall}
		awk -v b=$backend -v w="$wall" -v us="$us" -v p="$first" \
			'BEGIN {printf "| %s | %.3f | %.0fx | %.2fx |\n", b, w, us / 1e6 / w, p / w}'
	done
fi

if [[ $steps == *zephyr* ]]; then
	cosmocc_setup
	# Zephyr's own samples and test suites, run by twister as ordinary native_sim executables.
	tests=(samples/hello_world samples/synchronization samples/philosophers tests/ztest/base
		tests/kernel/common tests/kernel/threads/thread_apis tests/kernel/sched/schedule_api
		tests/kernel/timer/timer_api tests/kernel/sleep tests/kernel/mutex/mutex_api
		tests/kernel/semaphore/semaphore tests/kernel/msgq/msgq_api tests/kernel/fifo/fifo_api
		tests/kernel/events/event_api tests/kernel/poll tests/kernel/workq/work
		tests/kernel/mem_slab/mslab_api tests/lib/c_lib/common tests/boards/native_sim/cpu_wait)
	# Windows: deep build directories would exceed its path length limit.
	[[ $(uname -s) != MINGW* ]] || short=--short-build-path
	ZEPHYR_TOOLCHAIN_VARIANT=cosmocc COSMOCC_TOOLCHAIN_PATH=$cosmocc \
		python "$ZEPHYR_BASE/scripts/twister" -p native_sim/native/64 --outdir "$build/twister" \
		--inline-logs ${short:-} $(printf -- "-T $ZEPHYR_BASE/%s " "${tests[@]}")
fi
