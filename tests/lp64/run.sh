#!/bin/bash
#
# LP64 headless test-suite runner for the Inferno Dis VM + Limbo.
#
# Compiles every Limbo test program under tests/lp64/suites/ with the host
# `limbo` (the C compiler that produces the XMAGIC8 LP64 .dis tree), then runs
# each under `emu-g` and aggregates the TAP (ok/not ok) output.
#
# Usage:  tests/lp64/run.sh [suite-glob]
#   e.g.  tests/lp64/run.sh            # all suites
#         tests/lp64/run.sh concur     # only suites/concur*.b
#
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 2

EMU="$ROOT/Linux/aarch64/bin/emu-g"
LIMBO="$ROOT/Linux/aarch64/bin/limbo"
BUILD="$ROOT/tests/lp64/_build"        # inferno path: /tests/lp64/_build
TIMEOUT=${TIMEOUT:-60}

[ -x "$EMU" ]   || { echo "missing emu-g ($EMU) - run 'make all' first" >&2; exit 2; }
[ -x "$LIMBO" ] || { echo "missing limbo ($LIMBO) - run 'make all' first" >&2; exit 2; }

rm -rf "$BUILD"
mkdir -p "$BUILD/lib"

compile() {  # src.b -> out.dis ; echoes errors, returns limbo rc
	"$LIMBO" -I "$ROOT/module" -I "$ROOT/tests/lp64/lib" -o "$2" "$1" 2>&1
}

# Build the shared helper first; every test loads it by absolute inferno path.
if ! out=$(compile "$ROOT/tests/lp64/lib/testing.b" "$BUILD/lib/testing.dis"); then
	echo "FATAL: testing.b failed to compile:" >&2
	echo "$out" >&2
	exit 2
fi

glob="${1:-}"
total_ok=0 total_notok=0 total_err=0 suites=0

printf '%-28s %6s %6s %6s\n' "SUITE" "ok" "FAIL" "err"
printf '%-28s %6s %6s %6s\n' "-----" "--" "----" "---"

for src in "$ROOT"/tests/lp64/suites/*.b; do
	[ -e "$src" ] || continue
	base=$(basename "$src" .b)
	if [ -n "$glob" ] && [[ "$base" != *"$glob"* ]]; then
		continue
	fi
	suites=$((suites+1))
	dis="$BUILD/$base.dis"

	if ! cerr=$(compile "$src" "$dis"); then
		printf '%-28s %6s %6s %6s\n' "$base" "-" "-" "COMPILE"
		echo "$cerr" | sed 's/^/    /'
		total_err=$((total_err+1))
		continue
	fi

	# Run under emu-g; emu root is the repo root so /tests/... maps here.
	log=$(timeout "$TIMEOUT" "$EMU" -r"$ROOT" /dis/sh.dis -c "/tests/lp64/_build/$base.dis" 2>&1)
	rc=$?

	nok=$(printf '%s\n' "$log" | grep -c '^ok ')
	nno=$(printf '%s\n' "$log" | grep -c '^not ok ')

	# Accepted exit codes:
	#   0   clean
	#   1   a command in the script raised "fail:..." (logic failure -> TAP shows it)
	#   137 SIGKILL on emu teardown — pre-existing benign emu-g shutdown behaviour
	#       (reproduces for a bare `echo hi`; all output completes first).
	flag=""
	if [ $rc -eq 124 ]; then flag="TIMEOUT"; total_err=$((total_err+1)); fi
	if [ $rc -ne 0 ] && [ $rc -ne 124 ] && [ $rc -ne 1 ] && [ $rc -ne 137 ]; then
		flag="rc=$rc"; total_err=$((total_err+1));
	fi

	printf '%-28s %6d %6d %6s\n' "$base" "$nok" "$nno" "$flag"
	# Echo diagnostics (TAP comments + not-ok lines) for failing suites.
	if [ "$nno" -ne 0 ] || [ -n "$flag" ]; then
		printf '%s\n' "$log" | grep -E '^(not ok|#|panic|.*[Ss]egmentation|.*illegal dis)' | sed 's/^/    /'
	fi

	total_ok=$((total_ok+nok))
	total_notok=$((total_notok+nno))
done

echo "----------------------------------------------"
printf 'TOTAL  suites=%d  ok=%d  FAIL=%d  err=%d\n' "$suites" "$total_ok" "$total_notok" "$total_err"

if [ "$total_notok" -ne 0 ] || [ "$total_err" -ne 0 ]; then
	exit 1
fi
exit 0
