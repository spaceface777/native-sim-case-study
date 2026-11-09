#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Stage 2: assemble firmware objects into one statically linked simulator executable.
#
#   scripts/assemble.sh [--nct B] [--nce B] [--coro P] <output dir> <simulator.c> <firmware dir>...
#
# One <firmware dir> (from build-firmware.sh) per instance, in instance order. Repeating a
# directory reuses its image. NCT/NCE backends B: pthreads (upstream, default) or coroutines.
# Coroutine primitive P: asm (default), ucontext or longjmp. Coroutine NCE needs coroutine NCT.
#
# Per distinct firmware:
#  1. Build the upstream native simulator runner (runner.a) with cosmocc, using the
#     firmware's nsi_config. Optionally replace its NCT/NCE with the coroutine versions.
#  2. Localize the firmware's hidden symbols, as the native simulator normally does.
#  3. Partially link firmware + runner. The runner linker script bounds the NSI task and
#     HW event registration sections inside this image (Zephyr's own iterable sections
#     were already bounded when zephyr.elf was prelinked).
#  4. Localize every remaining symbol. The image keeps only undefined references to the
#     C library, and its instance_api table in the "instances" section.
# Then every instance is a copy of its image, and the final link (cosmocc, Cosmopolitan
# Libc) concatenates the "instances" sections, in command line order, into one array.
set -e -o pipefail
nct=pthreads nce=pthreads coro=asm
while [[ $1 == --* ]]; do
	case $1 in
	--nct) nct=$2 ;;
	--nce) nce=$2 ;;
	--coro) coro=$2 ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
[[ $nct =~ ^(pthreads|coroutines)$ && $nce =~ ^(pthreads|coroutines)$ ]] || { echo "bad NCT/NCE backend" >&2; exit 2; }
[[ $coro =~ ^(asm|ucontext|longjmp)$ ]] || { echo "bad coroutine primitive $coro" >&2; exit 2; }
[[ $nce == pthreads || $nct == coroutines ]] || { echo "coroutine NCE requires coroutine NCT" >&2; exit 2; }
out=$1 simulator=$2
shift 2
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/scripts/cosmocc.sh"
: "${ZEPHYR_BASE:?Set ZEPHYR_BASE to the Zephyr checkout the firmware was built with}"
nsi=$ZEPHYR_BASE/scripts/native_simulator
cflags=(${CFLAGS:--O3})
mkdir -p "$out"
out=$(cd "$out" && pwd)

"${COSMO_PREFIX}gcc" -x c -E -P "$nsi/common/other/linker_script.pre.ld" -o "$out/runner.ld"

# build_image <firmware dir> <work dir>: produce <work dir>/image.o
build_image() {
	local fw=$1 dir=$2 config=$1/nsi_config
	get() { sed -n "s/^$1:=//p" "$config"; }
	mkdir -p "$dir"

	# 1. The runner, built by the native simulator's own Makefile, but with cosmocc.
	make -s -f "$nsi/Makefile" runner_lib "NSI_CONFIG_FILE=$config" "NSI_BUILD_PATH=$dir/nsi" \
		"NSI_CC=$COSMO_CC" "NSI_AR=${COSMO_PREFIX}ar" "NSI_OBJCOPY=${COSMO_PREFIX}objcopy"
	cp "$dir/nsi/runner.a" "$dir/runner.a"
	if [[ $nct == coroutines ]]; then
		local flags=(-std=c11 -g -Wall -DNSI_RUNNER_BUILD "-DNSI_N_CPUS=$(get NSI_N_CPUS)"
			-ffunction-sections -fdata-sections $(get NSI_BUILD_OPTIONS)
			"-I$nsi/common/src/include" "-I$nsi/common/src" "-I$root/runner/coro")
		[[ $nce == coroutines ]] || flags+=(-DNSI_NCE_BACKEND_PTHREADS)
		local sources=(nct_coro.c nsi_coro_ctx.c) objects=()
		[[ $nce == pthreads ]] || sources+=(nce_coro.c)
		case $coro in
		asm) sources+=(nsi_coro.S) ;;
		*) sources+=(nsi_coro_$coro.c) ;;
		esac
		for source in "${sources[@]}"; do
			objects+=("$dir/${source%.*}.o")
			"$COSMO_CC" "${flags[@]}" -c "$root/runner/coro/$source" -o "${objects[-1]}"
		done
		"${COSMO_PREFIX}ar" d "$dir/runner.a" nct.o
		[[ $nce == pthreads ]] || "${COSMO_PREFIX}ar" d "$dir/runner.a" nce.o
		"${COSMO_PREFIX}ar" r "$dir/runner.a" "${objects[@]}"
	fi

	# 2. Hide the firmware's internals, exactly as the native simulator Makefile does.
	"${COSMO_PREFIX}objcopy" --localize-hidden "$fw/firmware.o" "$dir/firmware.o" \
		-w --localize-symbol='_*' $(get NSI_LOCALIZE_OPTIONS)
	# On AArch64, cosmocc post-processes every object to read TLS from x28, not tpidr_el0.
	# (On x86-64, fixupobj only merges patchable-entry NOPs, which the firmware lacks.)
	[[ $COSMO_ARCH != aarch64 ]] || "$COSMOCC/bin/fixupobj" "$dir/firmware.o"

	# 3. One relocatable image: firmware + its private runner + bounded registrations.
	"${COSMO_PREFIX}ld.bfd" -r -o "$dir/linked.o" --whole-archive "$dir/firmware.o" \
		"$dir/runner.a" --no-whole-archive -T "$out/runner.ld"

	# 4. Make everything private, then check that nothing is left to collide.
	"${COSMO_PREFIX}objcopy" -w --localize-symbol='*' "$dir/linked.o" "$dir/image.o"
	local leaked
	leaked=$("${COSMO_PREFIX}nm" -g --defined-only "$dir/image.o")
	[[ -z $leaked ]] || { echo "$dir/image.o still defines global symbols:" >&2; echo "$leaked" >&2; exit 1; }
	[[ $("${COSMO_PREFIX}readelf" -SW "$dir/image.o") == *" instances "* ]] ||
		{ echo "$dir/image.o has no instance table" >&2; exit 1; }
}

declare -A images
instances=()
for fw in "$@"; do
	fw=$(cd "$fw" && pwd)
	if [[ -z ${images[$fw]} ]]; then
		images[$fw]=$out/image-${#images[@]}
		build_image "$fw" "${images[$fw]}"
	fi
	instances+=("$out/instance_${#instances[@]}.o")
	ln -f "${images[$fw]}/image.o" "${instances[-1]}"
done

"$COSMO_CC" "${cflags[@]}" "-I$root" "$simulator" "${instances[@]}" -o "$out/simulator.com"
echo "$out/simulator.com: ${#instances[@]} instances, NCT $nct, NCE $nce$([[ $nct == pthreads ]] || echo ", $coro")"
