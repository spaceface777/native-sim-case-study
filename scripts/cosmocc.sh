# SPDX-License-Identifier: Apache-2.0
# Source this file: it provides a ready cosmocc toolchain for the host CPU.
#
# Inputs:  BUILD (default: <repo>/build), COSMOCC (optional, a prepared toolchain),
#          COSMOCC_VERSION/COSMOCC_ZIP/COSMOCC_SHA256 (optional, another cosmocc archive),
#          COSMO_ARCH (optional: cross-build for x86_64 or aarch64 instead of the host CPU)
# Exports: COSMOCC, COSMO_ARCH (x86_64|aarch64), COSMO_PREFIX (<COSMOCC>/bin/<arch>-linux-cosmo-),
#          COSMO_CC (cosmocc's <arch>-unknown-cosmo-cc wrapper), and cosmo_exec() which runs
#          a simulator built by this toolchain on the current host.

# The pinned release. To try another build (e.g. a nightly artifact), set COSMOCC_VERSION
# to a new name, COSMOCC_ZIP to its local archive, and COSMOCC_SHA256 to that file's hash.
if [[ -z ${COSMOCC_VERSION:-} ]]; then
	COSMOCC_VERSION=4.0.2
	COSMOCC_SHA256=85b8c37a406d862e656ad4ec14be9f6ce474c1b436b9615e91a55208aced3f44
fi
COSMOCC_URL=${COSMOCC_URL:-https://github.com/jart/cosmopolitan/releases/download/$COSMOCC_VERSION/cosmocc-$COSMOCC_VERSION.zip}

_cosmo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD=${BUILD:-$_cosmo_root/build}

# Target the host's CPU. COSMO_ARCH=x86_64|aarch64 overrides it, only to cross-build tests.
case ${COSMO_ARCH:-$(uname -m)} in
x86_64 | amd64) COSMO_ARCH=x86_64 ;;
aarch64 | arm64) COSMO_ARCH=aarch64 ;;
*) echo "cosmocc supports x86_64 and aarch64 hosts only, not $(uname -m)" >&2; return 1 ;;
esac

_cosmo_sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# Prepare $1 from the pinned release: download, verify, extract, then make it usable.
_cosmo_install() (
	set -e
	dir=$1 zip=${COSMOCC_ZIP:-$BUILD/dl/cosmocc-$COSMOCC_VERSION.zip}
	: "${COSMOCC_SHA256:?Set COSMOCC_SHA256 for cosmocc $COSMOCC_VERSION}"
	mkdir -p "$BUILD/dl"
	if [[ ! -f $zip ]]; then
		echo "Downloading $COSMOCC_URL" >&2
		curl -fsSL --retry 3 -o "$zip.part" "$COSMOCC_URL"
		mv "$zip.part" "$zip"
	fi
	sum=$(_cosmo_sha256 "$zip")
	[[ $sum == "$COSMOCC_SHA256" ]] || { echo "$zip: SHA-256 $sum, expected $COSMOCC_SHA256" >&2; exit 1; }
	rm -rf "$dir.part"
	mkdir -p "$dir.part"
	unzip -q "$zip" -d "$dir.part"

	# CMake, make and Python exec() the tools directly. Without an APE binfmt_misc handler,
	# Linux refuses APE files (ENOEXEC), so convert them to native ELF in this private copy.
	# (A binfmt_misc handler for "MZ" files, e.g. Mono's or Wine's, would also be wrong.)
	if [[ $(uname -s) == Linux ]] && ! python3 -c '
import subprocess, sys
try:
    r = subprocess.run([sys.argv[1], "--version"], capture_output=True)
except OSError:
    sys.exit(1)
sys.exit(0 if r.returncode == 0 and b"GCC" in r.stdout else 1)' "$dir.part/bin/$COSMO_ARCH-linux-cosmo-gcc"; then
		echo "Converting cosmocc's APE tools to native ELF (no APE binfmt_misc handler)" >&2
		cp "$dir.part/bin/assimilate" "$BUILD/dl/assimilate"
		for tool in "$dir.part"/bin/* "$dir.part"/libexec/gcc/*/*/*; do
			[[ -f $tool ]] && [[ $(head -c 6 "$tool" | tr -d '\0') == MZqFpD ]] || continue
			sh "$BUILD/dl/assimilate" -c "$tool" >/dev/null
		done
		rm -f "$BUILD/dl/assimilate"
	fi

	# cosmocc ships no compiler-private headers. A freestanding Zephyr build needs some.
	for arch in x86_64 aarch64; do
		for gcc in "$dir.part"/libexec/gcc/$arch-linux-cosmo/*; do
			mkdir -p "$dir.part/lib/gcc/$arch-linux-cosmo/${gcc##*/}/include"
			cp "$_cosmo_root"/cosmo/freestanding/*.h "$dir.part/lib/gcc/$arch-linux-cosmo/${gcc##*/}/include/"
		done
	done
	mv "$dir.part" "$dir"
)

if [[ -z ${COSMOCC:-} ]]; then
	COSMOCC=$BUILD/cosmocc-$COSMOCC_VERSION
	[[ -d $COSMOCC ]] || _cosmo_install "$COSMOCC" || return 1
fi
COSMO_PREFIX=$COSMOCC/bin/$COSMO_ARCH-linux-cosmo-
COSMO_CC=$COSMOCC/bin/$COSMO_ARCH-unknown-cosmo-cc
export COSMOCC COSMO_ARCH COSMO_PREFIX COSMO_CC

# Run a cosmocc-built program. x86-64 output is an APE. AArch64 output is an ELF file:
# Linux runs it directly, and macOS runs it through the APE loader.
# cosmo_loader prints the loader to put in front of the program (nothing if none is needed).
cosmo_loader() {
	if [[ $(uname -s) == Darwin && $COSMO_ARCH == aarch64 ]]; then
		# Apple Silicon needs a native APE loader, built once from cosmocc's source.
		[[ -x $BUILD/ape-m1 ]] || cc -O2 -o "$BUILD/ape-m1" "$COSMOCC/bin/ape-m1.c" || return
		echo "$BUILD/ape-m1"
	fi
}
cosmo_exec() {
	local loader
	loader=$(cosmo_loader) || return
	if [[ -n $loader ]]; then "$loader" "$@"; else "$@"; fi
}
