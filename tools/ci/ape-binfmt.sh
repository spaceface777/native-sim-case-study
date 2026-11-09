#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# CI helper (Linux, needs sudo): run APE files through cosmocc's APE loader, as cosmocc's
# README recommends. Without it, another binfmt_misc handler for "MZ" files (e.g. Mono's
# or Wine's) may claim them. The newest registration is matched first.
#   tools/ci/ape-binfmt.sh <cosmocc dir>
set -e
[[ -e /proc/sys/fs/binfmt_misc/register ]] || { echo "no binfmt_misc; APE files run through their shell header"; exit 0; }
sudo install -m 755 "$1/bin/ape-$(uname -m).elf" /usr/bin/ape
for name in APE APE-jart; do
	[[ ! -e /proc/sys/fs/binfmt_misc/$name ]] || sudo sh -c "echo -1 > /proc/sys/fs/binfmt_misc/$name"
done
sudo sh -c "echo ':APE:M::MZqFpD::/usr/bin/ape:' > /proc/sys/fs/binfmt_misc/register"
sudo sh -c "echo ':APE-jart:M::jartsr::/usr/bin/ape:' > /proc/sys/fs/binfmt_misc/register"
