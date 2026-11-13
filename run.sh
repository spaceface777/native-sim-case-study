#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the 20-device world with each CPU and thread emulation, and time one simulated hour.
# Linux, with the system's GCC. ZEPHYR_BASE: Zephyr v4.5.0 with zephyr-patches/ applied.
set -e -o pipefail
cd "$(dirname "$0")"
mkdir -p build

# What every variant must print: upstream's output, as a SHA-256.
expected=2aec6a5530876283d4bde6a54dae3f12a7795ecd103f1c8f608b3afe2aa008d6

nct=-DCONFIG_NATIVE_SIMULATOR_NCT_COROUTINES=y
nce=-DCONFIG_NATIVE_SIMULATOR_NCE_COROUTINES=y
siglongjmp=-DCONFIG_NATIVE_SIMULATOR_CORO_SIGLONGJMP=y
# Each one's name, then the Kconfig options which select it. The first is upstream's.
variants=(
	"pthreads"
	"swapcontext-nct $nct"
	"swapcontext     $nct $nce"
	"siglongjmp-nct  $nct $siglongjmp"
	"siglongjmp      $nct $nce $siglongjmp"
	"siglongjmp-fpu  $nct $nce $siglongjmp -DCONFIG_FPU=y -DCONFIG_FPU_SHARING=y"
	"custom-asm      -DCONFIG_NATIVE_SIMULATOR_NCT_CUSTOM=y -DCONFIG_NATIVE_SIMULATOR_NCE_CUSTOM=y"
)

build() {
	local out=$PWD/build/$1 zephyr=$PWD/build/$1/zephyr
	# Without the variant, Zephyr requires its SDK, which native_sim does not use.
	cmake -S app -B "$out" -GNinja -DBOARD=native_sim/native/64 -DZEPHYR_TOOLCHAIN_VARIANT=host \
		"${@:2}" >"$out.log" 2>&1 &&
		cmake --build "$out" >>"$out.log" 2>&1 || { tail -n 30 "$out.log"; exit 1; }
	# One device: the firmware and its own native simulator runner, as Zephyr built them,
	# in one object with every symbol private.
	ld -r -o "$out/device.o" "$zephyr/NSI$zephyr/zephyr.elf.loc_cpusw.o" \
		--whole-archive "$zephyr/NSI/runner.a" -T "$zephyr/NSI/linker_script.ld"
	objcopy -w --localize-symbol='*' "$out/device.o"
	# The world: 20 copies of it.
	gcc -O3 -no-pie simulator.c $(yes "$out/device.o" | head -n 20) -o "$out/simulator" -lm
}

# The median wall time of three runs, each with the expected output. They run on one CPU:
# across several, host threads hand over more slowly, which would favor the coroutines.
run() {
	for _ in 1 2 3; do
		{ time taskset -c 0 "build/$1/simulator" >build/output; } 2>&1
		sha256sum build/output | grep -q $expected || { echo "$1: wrong output" >&2; exit 1; }
	done | sort -n | sed -n 2p
}

echo '| Emulation | Seconds | Real time | Against pthreads |'
echo '|---|---:|---:|---:|'
TIMEFORMAT=%3R
for variant in "${variants[@]}"; do
	build $variant
	seconds=$(run $variant)
	pthreads=${pthreads:-$seconds}
	awk -v n="${variant%% *}" -v s="$seconds" -v p="$pthreads" \
		'BEGIN {printf "| %s | %.2f | %.0fx | %.1fx |\n", n, s, 3600 / s, p / s}'
done
