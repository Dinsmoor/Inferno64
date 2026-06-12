#!/usr/bin/env bash
#
# run.sh - headless harness for the Charon CSS-engine work.
#
# Compiles each tests/web/suites/*.b with the LP64 `limbo`, runs it under
# `emu-g` (no display needed), and aggregates the TAP (ok / not ok) output.
# These are the *logic* tests: CSS parsing and (later) the cascade/selector
# engine are pure computation, so they get a deterministic headless oracle here.
# Visual rendering of the fixtures is exercised separately under a live emu.
#
# It reuses the TAP helper from the sibling LP64 suite (tests/dis/lib/testing)
# rather than duplicating it; the helper's module PATH is /tests/dis/_build/...
# so we build it to that canonical location.
#
# Usage:  tests/web/run.sh [suite-glob]
#   e.g.  tests/web/run.sh             # all suites
#         tests/web/run.sh cssparse    # only suites/*cssparse*.b
#
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
case "$(uname -m)" in aarch64|arm64) ARCH=aarch64;; x86_64|amd64) ARCH=amd64;; *) ARCH=$(uname -m);; esac
# EMU / EMUFLAGS overridable for the make-check matrix driver (binary + run-mode).
EMU="${EMU:-$ROOT/Linux/$ARCH/bin/emu-g}"
EMUFLAGS="${EMUFLAGS:-}"
LIMBO="${LIMBO:-$ROOT/Linux/$ARCH/bin/limbo}"
BUILD="$ROOT/tests/web/_build"
TAPLIB="$ROOT/tests/dis/_build/lib/testing.dis"   # PATH con baked into testing.m
TIMEOUT="${TIMEOUT:-60}"

[ -x "$EMU" ]   || { echo "missing emu-g ($EMU) - run 'make all' first" >&2; exit 2; }
[ -x "$LIMBO" ] || { echo "missing limbo ($LIMBO) - run 'make all' first" >&2; exit 2; }

GLOB="${1:-}"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$(dirname "$TAPLIB")"

compile() {  # src.b -> out.dis ; echoes errors, returns limbo rc
	# appl/charon first so Charon's url.m (with Parsedurl) wins over module/url.m
	# for suites that pull common.m; the only file present in both trees.
	"$LIMBO" -I "$ROOT/appl/charon" -I "$ROOT/module" -I "$ROOT/appl/lib" -I "$ROOT/tests/dis/lib" -o "$2" "$1" 2>&1
}

# Charon modules the suites load by their installed PATH (/dis/charon/*.dis).
# Build them to that location so `load Mod Mod->PATH` resolves under emu -r$ROOT.
for dep in csseng; do
	mkdir -p "$ROOT/dis/charon"
	if ! out=$(compile "$ROOT/appl/charon/$dep.b" "$ROOT/dis/charon/$dep.dis"); then
		echo "FATAL: appl/charon/$dep.b failed to compile:" >&2; echo "$out" >&2; exit 2
	fi
done

# shared TAP helper (rebuild if missing or stale)
if [ ! -f "$TAPLIB" ] || [ "$ROOT/tests/dis/lib/testing.b" -nt "$TAPLIB" ]; then
	if ! out=$(compile "$ROOT/tests/dis/lib/testing.b" "$TAPLIB"); then
		echo "FATAL: testing.b failed to compile:" >&2; echo "$out" >&2; exit 2
	fi
fi

pass=0 fail=0 err=0
for src in "$ROOT"/tests/web/suites/*.b; do
	base=$(basename "$src" .b)
	[ -n "$GLOB" ] && case "$base" in *"$GLOB"*) ;; *) continue;; esac
	dis="$BUILD/$base.dis"
	if ! cerr=$(compile "$src" "$dis"); then
		echo "## $base: COMPILE ERROR"; echo "$cerr"; err=$((err+1)); continue
	fi
	echo "## $base"
	# shellcheck disable=SC2086  # $EMUFLAGS run-mode must word-split
	log=$(timeout "$TIMEOUT" "$EMU" $EMUFLAGS -r"$ROOT" /dis/sh.dis -c "/tests/web/_build/$base.dis" 2>&1)
	rc=$?
	echo "$log"
	# tolerate 137 (benign emu-g SIGKILL on teardown); all TAP completes first
	if [ $rc -ne 0 ] && [ $rc -ne 137 ]; then
		echo "## $base: emu exited $rc"; err=$((err+1))
	fi
	if echo "$log" | grep -q '^not ok'; then fail=$((fail+1)); else pass=$((pass+1)); fi
done

echo
echo "suites: pass=$pass fail=$fail err=$err"
[ $fail -eq 0 ] && [ $err -eq 0 ]
