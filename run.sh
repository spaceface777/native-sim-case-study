#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SIM_US: world duration (default 1 minute). Five samples per backend.
# Linux measures CPU 0 and unpinned with the same binaries. macOS is unpinned.
set -e -o pipefail
cd "$(dirname "$0")"
export LC_ALL=C ZEPHYR_TOOLCHAIN_VARIANT=host
SIM_US=${SIM_US:-60000000}
nsi=$ZEPHYR_BASE/scripts/native_simulator
# Name, NCT, NCE, implementation, display label.
backends=(
    'pthreads     PTHREADS   PTHREADS   PTHREADS      —'
    'ucontext-nct COROUTINES PTHREADS   UCONTEXT      ucontext'
    'longjmp-nct  COROUTINES PTHREADS   LONGJMP       makecontext + siglongjmp'
    'boost-nct    COROUTINES PTHREADS   BOOST_CONTEXT Boost.Context'
    'asm-nct      COROUTINES PTHREADS   ASM           Assembly'
    'ucontext     COROUTINES COROUTINES UCONTEXT      ucontext'
    'longjmp      COROUTINES COROUTINES LONGJMP       makecontext + siglongjmp'
    'boost        COROUTINES COROUTINES BOOST_CONTEXT Boost.Context'
    'asm          COROUTINES COROUTINES ASM           Assembly'
)
flags=(-O3 -march=native)
options=(-DBoost_USE_STATIC_LIBS=ON)
modes=(0 all)
if [[ $(uname -s) == Darwin ]]; then
    cc=clang
    options+=(-DNATIVE_SIM_EXPERIMENTAL_MACOS=ON)
    link=("-Wl,-dead_strip,-U,___cxa_get_globals")
    modes=(all)
else
    cc=gcc
    export BOOST_ROOT=${BOOST_ROOT:-/usr}
    link=(-no-pie)
fi

# Build one private firmware/runner image, copy it 20 times, then link the host.
for row in "${backends[@]}"; do
    read -r backend nct nce implementation label <<<"$row"
    build=$PWD/build/$backend
    config=("-DCONFIG_NATIVE_SIMULATOR_NCT_BACKEND_$nct=y" "-DCONFIG_NATIVE_SIMULATOR_NCE_BACKEND_$nce=y")
    [[ $backend == pthreads ]] || config+=("-DCONFIG_NATIVE_SIMULATOR_COROUTINE_IMPLEMENTATION_$implementation=y")
    mkdir -p "$build"
    echo "Building $backend"
    (
        cmake -S app -B "$build" -GNinja -DBOARD=native_sim/native/64 \
            "-DCONFIG_COMPILER_OPT=\"${flags[*]}\"" "${options[@]}" "${config[@]}"
        cmake --build "$build" -j4
        [[ $cc != clang ]] || cmake --build "$build" --target macho_iterable_sections_native_simulator_bounds
        guest=$build/zephyr/NSI$build/zephyr/zephyr.elf.loc_cpusw.o
        make -f "$nsi/Makefile" runner_lib "$guest" "NSI_CONFIG_FILE=$build/zephyr/NSI/nsi_config"
        extra=()
        if [[ $cc == clang ]]; then
            order=$build/zephyr/NSI/nsi_entries.order
            make -f "$nsi/Makefile" "$order" "NSI_CONFIG_FILE=$build/zephyr/NSI/nsi_config"
            # Bind section bounds to labels, so every copy can use the same section names.
            nm -m "$build/zephyr/NSI/runner.a" | awk '
                $1 == "(indirect)" {sub(/\)$/, "", $5); print $3, $5}
            ' >"$build/aliases.txt"
            cp "$build/zephyr/NSI/runner.a" "$build/runner.a"
            ar -d "$build/runner.a" macho_ranges.o macho_image_bounds.o
            # A zero-size start label shares the first event's atom. Put priority 0 first.
            ar -mb hw_counter.o "$build/runner.a" timer_model.o
            awk '$2 !~ /^section\$/ {print $2, $1}' "$build/aliases.txt" >"$build/tasks.aliases"
            for side in start end; do
                awk -v side="$side" '
                    $2 ~ ("^section\\$" side "\\$") {
                        split($2, s, "\\$")
                        print ".section " s[3] "," s[4] "\n.globl " $1 "\n" $1 ":"
                    }
                    END {print ".subsections_via_symbols"}
                ' "$build/aliases.txt" >"$build/$side.s"
                "$cc" -c "$build/$side.s" -o "$build/$side.o"
            done
            "$cc" -nostdlib -Wl,-r,-S,-alias_list,"$build/tasks.aliases" "$build/start.o" "$guest" \
                -Wl,-force_load,"$build/runner.a" "$build/end.o" -o "$build/image.o"
            nmedit -s /dev/null "$build/image.o" -o "$build/local.o"
            # Enclose every iterable entry, including static threads, in its own copy's bounds.
            {
                awk '$2 ~ /^section\$start\$/ {print $1}' "$build/aliases.txt"
                grep -v '^#' "$order"
                awk 'NR == FNR {
                    if ($2 ~ /^section\$/) {split($2, s, "\\$"); sections["(" s[3] "," s[4] ")"] = 1}
                    bounds[$1] = 1; next
                }
                $2 in sections && !($NF in bounds) && $NF !~ /^ltmp/ {print $NF}
                ' "$build/aliases.txt" <(nm -m -n "$build/image.o")
                awk '$2 ~ /^section\$end\$/ {print $1}' "$build/aliases.txt"
            } | awk '!seen[$0]++ {entries[++n] = $0}
                END {for (id = 0; id < 20; id++) for (i = 1; i <= n; i++) print "instance_" id ".o:" entries[i]}
            ' >"$build/instances.order"
            extra+=("-Wl,-order_file,$build/instances.order")
        else
            "$cc" -E -P -x c "$nsi/common/other/linker_script.pre.ld" -o "$build/runner.ld"
            "$cc" -nostdlib -no-pie -Wl,-r,--whole-archive "$guest" "$build/zephyr/NSI/runner.a" \
                -Wl,--no-whole-archive,-T,"$build/runner.ld" -o "$build/image.o"
            objcopy -w --localize-symbol='*' "$build/image.o" "$build/local.o"
        fi
        copies=()
        for id in {0..19}; do
            cp "$build/local.o" "$build/instance_$id.o"
            copies+=("$build/instance_$id.o")
        done
        if [[ $implementation == BOOST_CONTEXT ]]; then
            extra+=("$(awk -F':=' '/^NSI_BOOST_CONTEXT_LIB:/{print $2}' "$build/zephyr/NSI/nsi_config")")
        fi
        "$cc" "${flags[@]}" simulator.c "${copies[@]}" "${extra[@]}" "${link[@]}" -pthread -lm -o "$build/simulator"
    ) >"$build/build.log" 2>&1
done

# Time the whole process. Retain every sample in a new directory.
results=build/$(date '+%Y%m%d-%H%M%S')
baseline_dir=$results/${modes[0]}/pthreads
reference=$baseline_dir/run-0.txt
TIMEFORMAT='%3R'
for mode in "${modes[@]}"; do
    pin=()
    [[ $mode == all ]] || pin=(taskset -c "$mode")
    for row in "${backends[@]}"; do read -r backend rest <<<"$row"; mkdir -p "$results/$mode/$backend"; done
    for ((repeat=0; repeat<5; repeat++)); do
        direction=1
        ((repeat % 2 == 0)) || direction=-1
        for ((i=0; i<9; i++)); do
            read -r backend rest <<<"${backends[$(((repeat + direction*i + 9) % 9))]}"
            output=$results/$mode/$backend
            { time "${pin[@]}" "build/$backend/simulator" "$SIM_US" >"$output/run-$repeat.txt"; } 2>>"$output/times.txt"
            cmp "$reference" "$output/run-$repeat.txt"
        done
    done
    # Always-ticked references check the idle-grant optimization.
    for row in "${backends[@]}"; do
        read -r backend rest <<<"$row"
        output=$results/$mode/$backend
        "${pin[@]}" "build/$backend/simulator" "$SIM_US" always >"$output/run-always.txt"
        cmp "$reference" "$output/run-always.txt"
    done
done
median() { sort -n "$1" | awk 'NR == 3 {print}'; }
baseline=$(median "$baseline_dir/times.txt")
{
    echo "5 runs; $SIM_US simulated microseconds of world time"
    echo "Result: $(tail -n 1 "$reference"), output checksum $(cksum <"$reference" | cut -d' ' -f1)"
    for mode in "${modes[@]}"; do
        echo
        echo "CPU affinity: $mode (all = unpinned)"
        echo '| NCT | NCE | Primitive | Wall s | RT | Speedup |'
        echo '|---|---|---|---:|---:|---:|'
        for row in "${backends[@]}"; do
            read -r backend nct nce implementation label <<<"$row"
            wall=$(median "$results/$mode/$backend/times.txt")
            awk -v nct="$nct" -v nce="$nce" -v primitive="$label" -v wall="$wall" \
                -v baseline="$baseline" -v simulated="$SIM_US" 'BEGIN {
                    printf "| %s | %s | %s | %.3f | %.1fx | **%.2fx** |\n", tolower(nct), tolower(nce), primitive, wall, simulated/1000000/wall, baseline/wall
                }'
        done
    done
} | tee "$results/results.md" build/results.md
