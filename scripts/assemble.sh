#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Link private copies of one native_sim firmware, each with its own native simulator runner,
# into one executable:
#   scripts/assemble.sh <Zephyr build dir> <instances> <output dir> pthreads|coroutines
# The firmware's runner configuration (zephyr/NSI/nsi_config) provides everything else.
# RUNNER_CFLAGS adds runner compiler flags, e.g. -DCORO_SAVE_CONTEXT (see runner/coro.c).
set -e -o pipefail
zephyr=$1/zephyr instances=$2 out=$3 backend=$4
root=$(cd "$(dirname "$0")/.." && pwd)
config() { sed -n "s/^$1:=//p" "$zephyr/NSI/nsi_config"; }
nsi=$(config NSI_PATH)
read -r -a cc <<<"$(config NSI_CC)"         # cosmocc's driver, maybe after a launcher
read -r -a link <<<"$(config NSI_LINKER)"   # and how the toolchain links executables
objcopy=$(config NSI_OBJCOPY)
tools=${objcopy%objcopy*}                   # cosmocc's GNU binutils
rm -rf "$out" && mkdir -p "$out/runner"

# 1. The native simulator runner, compiled as its Makefile does. The coroutine backend
#    replaces the CPU and thread emulation (nce.c, nct.c), which use host threads.
sources="$(ls "$nsi"common/src/*.c "$nsi"native/src/*.c) $(config NSI_EXTRA_SRCS)"
[[ $backend == pthreads ]] ||
	sources="$(echo "$sources" | grep -v '/nc[et]\.c$') $root/runner/coro.c $root/runner/coro.S"
for source in $sources; do
	"${cc[@]}" -c "$source" -o "$out/runner/$(basename "$source").o" -std=c11 -DNSI_RUNNER_BUILD \
		-DNSI_N_CPUS="$(config NSI_N_CPUS)" -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=600 \
		-I"$nsi"common/src/include -I"$nsi"common/src -I"$nsi"native/src/include \
		$(config NSI_BUILD_OPTIONS) ${RUNNER_CFLAGS:-}
done

# 2. Hide the firmware's internals, as the native simulator does.
"${tools}objcopy" --localize-hidden -w --localize-symbol='_*' $(config NSI_LOCALIZE_OPTIONS) \
	"$zephyr/zephyr.elf" "$out/firmware.o"

# 3. One relocatable image of firmware and runner. The runner's linker script bounds its
#    registration sections in it. (Zephyr's were bounded when zephyr.elf was linked.)
"${tools}gcc" -x c -E -P "$nsi"common/other/linker_script.pre.ld -o "$out/runner.ld"
"${tools}ld.bfd" -r -o "$out/linked.o" "$out/firmware.o" "$out"/runner/*.o -T "$out/runner.ld"

# 4. Make every symbol private, so that the copies cannot collide.
"${tools}objcopy" -w --localize-symbol='*' "$out/linked.o" "$out/image.o"
[[ -z $("${tools}nm" -g --defined-only "$out/image.o") ]] ||
	{ echo "$out/image.o: global symbols remain" >&2; exit 1; }

# 5. Link the copies. Their instance tables form one array, in link order.
images=()
for ((i = 0; i < instances; i++)); do images+=("$out/image.o"); done
"${link[@]}" -O3 -I"$root" "$root/simulator.c" "${images[@]}" -o "$out/simulator.exe"
