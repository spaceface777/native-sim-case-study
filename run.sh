#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build, validate and time the case study with Cosmopolitan Libc, for this host's CPU.
#
#   ./run.sh [build] [validate] [bench] [report]      (default: build validate bench)
#
# build     Linux (x86-64 or AArch64) only: compile the firmware once, then assemble one
#           simulator per runner backend. Needs ZEPHYR_BASE (upstream Zephyr v4.5.0).
# validate  scripts/validate.sh for every backend. Linux or macOS.
# bench     SAMPLES runs of SIM_US world microseconds per backend, interleaved. Linux or
#           macOS. BASELINE=<dir> also times <dir>/<backend>/simulator[.com] in the same
#           interleaved order: the previous run.sh's builds, or another cosmocc's.
# report    Print the median table of RESULTS=<dir> (default: the latest bench).
# Environment: BUILD (default ./build), OPT (default -O3), SIM_US (default one minute),
# SAMPLES (default 5), PIN (bench command prefix, e.g. "taskset -c 0"), COSMOCC (optional
# prepared toolchain).
set -e -o pipefail
cd "$(dirname "$0")"
export LC_ALL=C BUILD=${BUILD:-$PWD/build}
SIM_US=${SIM_US:-60000000}
SAMPLES=${SAMPLES:-5}
OPT=${OPT:--O3}
source scripts/cosmocc.sh
steps=${*:-build validate bench}

# Name, NCT, NCE, coroutine primitive, display label.
backends=(
	'pthreads     pthreads   pthreads   -        —'
	'ucontext-nct coroutines pthreads   ucontext ucontext'
	'longjmp-nct  coroutines pthreads   longjmp  makecontext + _longjmp'
	'asm-nct      coroutines pthreads   asm      Assembly'
	'ucontext     coroutines coroutines ucontext ucontext'
	'longjmp      coroutines coroutines longjmp  makecontext + _longjmp'
	'asm          coroutines coroutines asm      Assembly'
)
firmware=$BUILD/firmware/case-study
simulator() { echo "$BUILD/$COSMO_ARCH/$1/simulator.com"; }

if [[ $steps == *build* ]]; then
	[[ $(uname -s) == Linux ]] || { echo "Build on Linux (see tools/container), then run: $0 validate bench" >&2; exit 1; }
	echo "Building the firmware ($COSMO_ARCH, $OPT)"
	scripts/build-firmware.sh app "$firmware" "-DCONFIG_COMPILER_OPT=\"$OPT\"" >"$BUILD/firmware.log" 2>&1 ||
		{ tail -n 30 "$BUILD/firmware.log"; exit 1; }
	instances=$(sed -n 's/^#define INSTANCES *\([0-9]*\).*/\1/p' app/api.h)
	firmwares=()
	for ((i = 0; i < instances; i++)); do firmwares+=("$firmware"); done
	for row in "${backends[@]}"; do
		read -r backend nct nce coro label <<<"$row"
		out=$(dirname "$(simulator "$backend")")
		mkdir -p "$out"
		CFLAGS=$OPT scripts/assemble.sh --nct "$nct" --nce "$nce" --coro "${coro/-/asm}" \
			"$out" simulator.c "${firmwares[@]}" >"$out.log" 2>&1 || { tail -n 30 "$out.log"; exit 1; }
		tail -n 1 "$out.log"
	done
fi

if [[ $steps == *validate* ]]; then
	for row in "${backends[@]}"; do
		read -r backend nct nce rest <<<"$row"
		threads=pthreads
		[[ $nce == pthreads ]] || threads=single
		scripts/validate.sh "$(simulator "$backend")" "$threads"
	done
fi

if [[ $steps == *bench* ]]; then
	results=$BUILD/results/$(date '+%Y%m%d-%H%M%S')
	runs=()
	for row in "${backends[@]}"; do
		read -r backend rest <<<"$row"
		runs+=("cosmo/$backend $(simulator "$backend")")
		for binary in "${BASELINE:-/nonexistent}/$backend"/simulator{,.com}; do
			[[ ! -x $binary ]] || { runs+=("baseline/$backend $binary"); break; }
		done
	done
	loader=$(cosmo_loader)
	expected=reference/$SIM_US.txt
	[[ -f $expected ]] || expected=$results/expected.txt
	mkdir -p "$results"
	TIMEFORMAT='%3R'
	for ((repeat = 0; repeat < SAMPLES; repeat++)); do
		# Alternate the order between samples, so drift affects every binary alike.
		for ((i = 0; i < ${#runs[@]}; i++)); do
			j=$i
			((repeat % 2 == 0)) || j=$((${#runs[@]} - 1 - i))
			read -r name binary <<<"${runs[$j]}"
			mkdir -p "$results/$name"
			command=("$binary")
			[[ $binary != *.com || -z $loader ]] || command=("$loader" "$binary")
			command=(${PIN:-} "${command[@]}")
			output=$results/$name/run-$repeat.txt
			{ time "${command[@]}" "$SIM_US" >"$output"; } 2>>"$results/$name/times.txt"
			# Every run must reproduce the first one, and the stored reference if there is one.
			[[ -f $expected ]] || cp "$output" "$expected"
			cmp -s "$output" "$expected" || { echo "$output differs from $expected" >&2; exit 1; }
		done
	done
	cp "$expected" "$results/expected.txt" 2>/dev/null || true
	echo "$SIM_US $SAMPLES $(uname -s) $(uname -m) ${PIN:-unpinned}" >"$results/meta"
	RESULTS=$results
fi

# Report medians from a results directory (default: the latest one).
if [[ $steps == *bench* || $steps == *report* ]]; then
	results=${RESULTS:-$(ls -d "$BUILD"/results/*/ | tail -n 1)}
	results=${results%/}
	read -r sim_us samples os cpu pin <"$results/meta"
	median() { sort -n "$1" | awk '{v[NR] = $1} END {print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2}'; }
	reference=$(median "$results/cosmo/pthreads/times.txt")
	baseline=
	[[ ! -d $results/baseline ]] || baseline=1
	{
		echo "$samples runs of $sim_us simulated microseconds; $os $cpu; ${pin:-unpinned}; medians in seconds"
		echo "Result: $(tail -n 1 "$results/expected.txt"), output checksum $(cksum <"$results/expected.txt" | cut -d' ' -f1)"
		echo
		if [[ -n $baseline ]]; then
			echo '| NCT | NCE | Primitive | Baseline s | Cosmopolitan s | Cosmopolitan RT | Cosmopolitan speedup | Baseline / Cosmopolitan |'
			echo '|---|---|---|---:|---:|---:|---:|---:|'
		else
			echo '| NCT | NCE | Primitive | Wall s | RT | Speedup |'
			echo '|---|---|---|---:|---:|---:|'
		fi
		for row in "${backends[@]}"; do
			read -r backend nct nce coro label <<<"$row"
			wall=$(median "$results/cosmo/$backend/times.txt")
			rt=$(awk -v s="$sim_us" -v w="$wall" 'BEGIN {printf "%.1fx", s / 1000000 / w}')
			speedup=$(awk -v r="$reference" -v w="$wall" 'BEGIN {printf "%.2fx", r / w}')
			if [[ -z $baseline ]]; then
				printf '| %s | %s | %s | %.3f | %s | **%s** |\n' "$nct" "$nce" "$label" "$wall" "$rt" "$speedup"
			elif [[ -f $results/baseline/$backend/times.txt ]]; then
				previous=$(median "$results/baseline/$backend/times.txt")
				ratio=$(awk -v p="$previous" -v w="$wall" 'BEGIN {printf "%.2fx", p / w}')
				printf '| %s | %s | %s | %.3f | %.3f | %s | %s | **%s** |\n' "$nct" "$nce" "$label" "$previous" "$wall" "$rt" "$speedup" "$ratio"
			else
				printf '| %s | %s | %s | — | %.3f | %s | %s | — |\n' "$nct" "$nce" "$label" "$wall" "$rt" "$speedup"
			fi
		done
	} | tee "$results/results.md" "$BUILD/results-$os-$cpu.md"
fi
