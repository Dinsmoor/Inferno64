#!/bin/bash
#
# JIT vs interpreter equivalence + micro-benchmark for native aarch64 FP.
#
# Compiles the FP exercise (fp.b) once, then runs the SAME .dis under:
#   emu -c0   (interpreter)
#   emu -c1   (JIT — native FP path in libinterp/comp-aarch64.c)
# Compares the value output (stdout) for bit-for-bit equivalence and reports
# the hot-loop wall time of each (stderr "TIME ... ms=N").
#
# usage: tests/jitperf/run.sh [iters]
#
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 2

EMU="$ROOT/Linux/aarch64/bin/emu-g"
LIMBO="$ROOT/Linux/aarch64/bin/limbo"
SRC="$ROOT/tests/jitperf/fp.b"
DIS="$ROOT/tests/jitperf/fp.dis"
ITERS="${1:-4000000}"
TIMEOUT="${TIMEOUT:-120}"

[ -x "$EMU" ]   || { echo "missing emu-g ($EMU) - run 'make all' first" >&2; exit 2; }
[ -x "$LIMBO" ] || { echo "missing limbo ($LIMBO) - run 'make all' first" >&2; exit 2; }

if ! cerr=$("$LIMBO" -I "$ROOT/module" -o "$DIS" "$SRC" 2>&1); then
	echo "COMPILE FAILED:" >&2; echo "$cerr" >&2; exit 2
fi

V0=$(mktemp); V1=$(mktemp); E0=$(mktemp); E1=$(mktemp)
trap 'rm -f "$V0" "$V1" "$E0" "$E1"' EXIT

# emu routes the Limbo TIME line (fd 2) onto the host stdout, so capture
# everything per run, then split: ms= for timing, the rest for the value diff.
timeout "$TIMEOUT" "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "/tests/jitperf/fp.dis $ITERS" >"$E0" 2>&1
timeout "$TIMEOUT" "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "/tests/jitperf/fp.dis $ITERS" >"$E1" 2>&1

ms0=$(grep -oE 'ms=[0-9]+' "$E0" | head -1 | cut -d= -f2)
ms1=$(grep -oE 'ms=[0-9]+' "$E1" | head -1 | cut -d= -f2)

# value channel = everything except the (timing) TIME line
grep -v '^TIME ' "$E0" >"$V0"
grep -v '^TIME ' "$E1" >"$V1"

echo "=== values: interpreter (-c0) ==="
cat "$V0"

if diff -q "$V0" "$V1" >/dev/null 2>&1; then
	echo
	echo "EQUIVALENCE: PASS  (-c0 and -c1 stdout identical)"
	eq=0
else
	echo
	echo "EQUIVALENCE: FAIL  (-c0 vs -c1 differ)"
	diff "$V0" "$V1" | sed 's/^/    /'
	eq=1
fi

echo
printf 'TIMING (hot loop, iters=%s):  interp=%sms  jit=%sms' "$ITERS" "${ms0:-?}" "${ms1:-?}"
if [ -n "${ms0:-}" ] && [ -n "${ms1:-}" ] && [ "${ms1:-0}" -gt 0 ]; then
	# speedup with one decimal place, via awk
	awk -v a="$ms0" -v b="$ms1" 'BEGIN{printf "  speedup=%.2fx\n", a/b}'
else
	echo
fi

# non-empty stderr other than the TIME line indicates a fault
for e in "$E0" "$E1"; do
	if grep -qiE 'broken|panic|segmentation|illegal dis|fail:' "$e"; then
		echo "FAULT in run (see below):" >&2
		grep -iE 'broken|panic|segmentation|illegal dis|fail:' "$e" >&2
		eq=1
	fi
done

exit $eq
