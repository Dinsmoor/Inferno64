#!/bin/sh
#
# tests/lint/run.sh — clang -Wshorten-64-to-32 narrowing lint for the LP64 port.
#
# The LP64 bug class is "a 64-bit value silently narrowed to 32 bits crossing a
# boundary".  clang's -Wshorten-64-to-32 *is* that bug class as a compile-time
# warning; gcc (the production compiler) has no equivalent.  This runs clang as
# a pure analysis pass over exactly the source the real build compiles, using
# the real per-file flags (extracted from `mk -n -a`, so includes/defines match
# byte-for-byte), and diffs the result against a curated baseline so that NEW
# narrowings stand out from the large set of pre-existing (mostly benign) ones.
#
# Usage:
#   sh tests/lint/run.sh            # report NEW narrowings vs baseline; nonzero if any
#   sh tests/lint/run.sh --update   # regenerate the baseline from current sources
#   sh tests/lint/run.sh --all      # print every narrowing (no baseline diff)
#
# Honors ROOT/SYSHOST/SYSTARG/OBJTYPE from the environment (the Makefile sets
# them); falls back to sensible defaults for a standalone run.

set -u

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
SYSHOST=${SYSHOST:-Linux}
SYSTARG=${SYSTARG:-$SYSHOST}
OBJTYPE=${OBJTYPE:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/aarch64/')}
MK=${MK:-$ROOT/$SYSTARG/$OBJTYPE/bin/mk}
CLANG=${CLANG:-clang}

LINTDIR=$ROOT/tests/lint
OUTDIR=$LINTDIR/.out
BASELINE=$LINTDIR/baseline.txt
mkdir -p "$OUTDIR"

mode=diff
case "${1:-}" in
	--update) mode=update ;;
	--all)    mode=all ;;
	"")       mode=diff ;;
	*) echo "usage: $0 [--update|--all]" >&2; exit 2 ;;
esac

if ! command -v "$CLANG" >/dev/null 2>&1; then
	echo "lint: $CLANG not found; install clang (e.g. apt install clang)" >&2
	exit 2
fi
if [ ! -x "$MK" ]; then
	echo "lint: mk not found at $MK; build the tree first (make emu)" >&2
	exit 2
fi

# Source directories whose C feeds the host build (libs + emu).
DIRS="lib9 libbio libmp libsec libmath libdraw libmemdraw libmemlayer
      libinterp libtk libkeyring libfreetype emu/$SYSTARG"

MKARGS="ROOT=$ROOT SYSHOST=$SYSHOST SYSTARG=$SYSTARG OBJTYPE=$OBJTYPE CONF=emu"

raw=$OUTDIR/raw.txt
: > "$raw"

echo "lint: clang -Wshorten-64-to-32 over the host build ($SYSTARG/$OBJTYPE)" >&2

for d in $DIRS; do
	[ -f "$ROOT/$d/mkfile" ] || continue
	cd "$ROOT/$d" || continue
	# `mk -n -a` prints every compile command (assume-all-out-of-date, no exec)
	# with the exact flags the real build uses.  We replay each .c compile with
	# clang in -fsyntax-only mode, all warnings off except the one we want.
	# mk prints recipe lines indented with a tab in some dirs (emu) and flush
	# in others (libs); match either. Leading whitespace is dropped by the
	# unquoted `set -- $line` word split below.
	"$MK" -n -a $MKARGS 2>/dev/null | grep -E '^[[:space:]]*gcc -c' | while read -r line; do
		# last token is the source file; keep -I/-D/-U flags, drop -c/-o/-march.
		# mk emits -DKERNDATE with embedded quotes (e.g. '-DKERNDATE='123); drop
		# all single quotes so the token parses as a normal -D flag.
		line=$(printf '%s' "$line" | tr -d "'")
		set -- $line
		src=""
		flags=""
		skipnext=0
		for tok in "$@"; do
			if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
			case "$tok" in
				gcc|-c) ;;
				-o) skipnext=1 ;;
				-march=*) ;;
				-W*|-O*) ;;                 # drop gcc warning/opt flags
				-I*|-D*|-U*) flags="$flags $tok" ;;
				*.c) src="$tok" ;;
				*) ;;                        # ignore anything else
			esac
		done
		[ -n "$src" ] || continue
		[ -f "$src" ] || continue           # generated source not present; skip
		"$CLANG" -fsyntax-only -march=armv8-a $flags \
			-Wno-everything -Wshorten-64-to-32 "$ROOT/$d/$src" 2>>"$raw"
	done
done

# Normalize: keep only the warning lines, strip the absolute ROOT prefix and the
# column number (line moves enough; column is noise), drop the carat context.
norm=$OUTDIR/current.txt
grep -h ' warning: .*\[-Wshorten-64-to-32\]' "$raw" 2>/dev/null \
	| sed "s#$ROOT/##; s#emu/[^/]*/\.\./port/#emu/port/#; s#^\.\./port/#emu/port/#; s/:[0-9]*:[0-9]*: warning:/: warning:/" \
	| sort -u > "$norm"

n=$(wc -l < "$norm" | tr -d ' ')

case "$mode" in
all)
	echo "lint: $n narrowing site(s):" >&2
	cat "$norm"
	exit 0
	;;
update)
	cp "$norm" "$BASELINE"
	echo "lint: baseline updated — $n narrowing site(s) recorded in $BASELINE" >&2
	exit 0
	;;
diff)
	if [ ! -f "$BASELINE" ]; then
		echo "lint: no baseline yet; run '$0 --update' to create one ($n sites found)" >&2
		exit 2
	fi
	new=$(comm -13 "$BASELINE" "$norm")
	fixed=$(comm -23 "$BASELINE" "$norm")
	if [ -n "$fixed" ]; then
		echo "lint: $(printf '%s\n' "$fixed" | wc -l | tr -d ' ') baseline site(s) no longer warn (consider --update):" >&2
		printf '%s\n' "$fixed" | sed 's/^/  - /' >&2
	fi
	if [ -n "$new" ]; then
		echo "lint: NEW 64->32 narrowing(s) introduced:" >&2
		printf '%s\n' "$new" | sed 's/^/  + /' >&2
		exit 1
	fi
	echo "lint: OK — no new narrowings ($n sites, all in baseline)" >&2
	exit 0
	;;
esac
