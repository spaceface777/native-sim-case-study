#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Stage 1: compile one Zephyr application, once, into a reusable firmware object.
#
#   scripts/build-firmware.sh <app dir> <output dir> [extra CMake arguments...]
#
# Uses upstream Zephyr's native_sim/native/64 board with CONFIG_BUILD_OUTPUT_EXE=n
# (set by the app). The output directory receives:
#   firmware.o   Zephyr's prelinked relocatable image (zephyr.elf), not yet localized
#   nsi_config   the native simulator runner configuration matching that image
# Nothing here depends on the runner backend or the number of instances.
set -e -o pipefail
app=$(cd "$1" && pwd)
out=$2
shift 2
source "$(dirname "$0")/cosmocc.sh"
: "${ZEPHYR_BASE:?Set ZEPHYR_BASE to an upstream Zephyr checkout}"

mkdir -p "$out"
out=$(cd "$out" && pwd)
# ZEPHYR_MODULES= : the firmware uses no west modules, so do not depend on a west workspace.
cmake -S "$app" -B "$out/zephyr-build" -GNinja -DBOARD=native_sim/native/64 \
	-DZEPHYR_MODULES= "-DCOSMOCC=$COSMOCC" "$@"
cmake --build "$out/zephyr-build"
cp "$out/zephyr-build/zephyr/zephyr.elf" "$out/firmware.o"
cp "$out/zephyr-build/zephyr/NSI/nsi_config" "$out/nsi_config"
