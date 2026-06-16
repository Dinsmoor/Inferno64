#!/bin/sh
#
# tests/sparse/selfcheck.sh -- prove the __dis address-space gate works.
#
# Runs sparse over selfcheck/disptr-demo.c and asserts the BAD patterns warn
# (deref of a userspace address; leaking it as a host pointer) and that the
# GOOD, laundered pattern does not.  Fails nonzero if the gate has rotted.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

SPARSE=${SPARSE:-}
[ -z "$SPARSE" ] && SPARSE=$(command -v sparse 2>/dev/null || true)
if [ -z "$SPARSE" ] || [ ! -x "$SPARSE" ]; then
	SPARSE=$(sh "$HERE/build-sparse.sh") || { echo "selfcheck: no sparse" >&2; exit 2; }
fi

out=$("$SPARSE" -I"$ROOT/include" "$HERE/selfcheck/disptr-demo.c" 2>&1)

fail=0
expect() {  # <regex> <human>
	if printf '%s' "$out" | grep -qE "$1"; then
		echo "  ok   : $2"
	else
		echo "  FAIL : expected but missing -- $2"; fail=1
	fi
}
reject() {  # <line-substr> <human>  -- assert no warning mentions this line tag
	if printf '%s' "$out" | grep -E 'warning|error' | grep -q "$1"; then
		echo "  FAIL : unexpected warning on $2"; fail=1
	else
		echo "  ok   : clean -- $2"
	fi
}

echo "sparse __dis gate self-check:"
expect 'deref.*noderef|noderef expression' 'deref of a __dis address warns'
expect 'different address space'            'leaking a __dis pointer warns'
# the GOOD path (deref_good) is laundered; ensure no noderef/address-space gripe
# attributable to it.  (We check the whole file is otherwise clean of these.)
n=$(printf '%s' "$out" | grep -E 'warning:' | grep -cE 'noderef|different address space')
if [ "$n" -eq 2 ]; then
	echo "  ok   : exactly the 2 intended violations (good path clean)"
else
	echo "  FAIL : expected 2 violations, sparse reported $n"; fail=1
	printf '%s\n' "$out"
fi

[ "$fail" -eq 0 ] && echo "selfcheck: PASS" || echo "selfcheck: FAIL"
exit $fail
