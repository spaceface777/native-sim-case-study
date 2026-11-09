#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Validate one assembled simulator on this host (Linux or macOS; bash 3.2 compatible).
#
#   scripts/validate.sh <simulator.com> [<expected threads: pthreads|single>]
#
# Checks:
#  - determinism: byte-identical output to reference/<us>.txt (the one-hour file only with
#    FULL=1), and in always-ticked mode,
#  - independent devices: every kernel's timers ran (equal heartbeats), state differs,
#  - isolation: guest, kernel and runner state exist once per instance, at distinct
#    addresses, as local symbols only,
#  - threading (Linux): coroutine NCT+NCE runs all devices on the one host thread.
set -e -o pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/scripts/cosmocc.sh"
simulator=$1 threads=${2:-}
instances=$(sed -n 's/^#define INSTANCES *\([0-9]*\).*/\1/p' "$root/app/api.h")
failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

echo "$simulator"
# The one-hour reference is checked only with FULL=1: pthread backends take minutes.
for reference in "$root"/reference/*.txt; do
	us=$(basename "$reference" .txt)
	[[ -n ${FULL:-} || $us -le 60000000 ]] || continue
	output=$(cosmo_exec "$simulator" "$us")
	if [[ $output == "$(cat "$reference")" ]]; then pass "$us us matches reference ($(tail -n 1 "$reference"))"; else fail "$us us differs from reference"; fi
done
us=60000000
output=$(cosmo_exec "$simulator" $us)
if [[ $(cosmo_exec "$simulator" $us always) == "$output" ]]; then pass "always-ticked run matches"; else fail "always-ticked run differs"; fi
rows=$(echo "$output" | grep -vc '^trace')
heartbeats=$(echo "$output" | grep -v '^trace' | cut -d' ' -f2 | sort -u)
states=$(echo "$output" | grep -v '^trace' | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
if [[ $rows == "$instances" && $heartbeats == 59900 ]]; then pass "$rows devices, every kernel's 100 ms timer reached 59900 ms"; else fail "rows $rows, heartbeats $heartbeats"; fi
if ((states > 1)); then pass "$states distinct per-device acknowledgement counts"; else fail "devices share state"; fi

# Symbol isolation, from the linked executable's symbol table (<simulator>.dbg).
# cosmocc's nm on Linux, else any nm that reads ELF (macOS has one; Git Bash does not).
nm=
if [[ $(uname -s) == Linux ]] && "${COSMO_PREFIX}nm" --version >/dev/null 2>&1; then
	nm=${COSMO_PREFIX}nm
elif command -v nm >/dev/null; then
	nm=nm
fi
if [[ -z $nm || ! -f $simulator.dbg ]] || ! symbols=$("$nm" "$simulator.dbg" 2>/dev/null); then
	echo "  skip  symbol isolation: no nm for ELF, or no $simulator.dbg"
	symbols=
fi
for symbol in _kernel z_main_thread _k_thread_obj_heartbeat_tid rpc_queue acknowledged instance_id \
	boundary_time nsi_hws_get_time __nsi_tasks_start __nsi_hw_events_start nct_instances nce_instances; do
	[[ -n $symbols ]] || break
	copies=$(echo "$symbols" | awk -v s="$symbol" '$3 == s' | grep -vc ' [A-Z] ' || true)
	globals=$(echo "$symbols" | awk -v s="$symbol" '$3 == s && $2 ~ /^[A-Z]$/' | wc -l | tr -d ' ')
	addresses=$(echo "$symbols" | awk -v s="$symbol" '$3 == s {print $1}' | sort -u | wc -l | tr -d ' ')
	if [[ $copies == "$instances" && $addresses == "$instances" && $globals == 0 ]]; then
		pass "$symbol: $copies private copies"
	elif [[ $copies == 0 && $globals == 0 ]]; then
		pass "$symbol: not present in this build"
	else
		fail "$symbol: $copies local, $globals global, $addresses addresses"
	fi
done

# Host threads, sampled while a long world runs (Linux only).
if [[ -n $threads && $(uname -s) == Linux ]]; then
	"$simulator" 100000000000 >/dev/null & # Linux runs it directly: $! is the simulator.
	pid=$!
	sleep 1
	count=$(awk '/^Threads:/ {print $2}' "/proc/$pid/status")
	kill $pid
	wait $pid 2>/dev/null || true
	if [[ $threads == single && $count == 1 ]] || [[ $threads == pthreads && $count -gt $instances ]]; then
		pass "$count host thread(s) while running"
	else
		fail "$count host threads, expected $threads"
	fi
fi
((failures == 0))
