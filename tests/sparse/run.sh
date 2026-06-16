#!/bin/sh
#
# tests/sparse/run.sh — sparse semantic check for the LP64 pointer-width and
# Dis-address-space bug classes.
#
# The corruption-bug class of the LP64 port is "a host pointer (8 bytes) and a
# Dis WORD (4 bytes) get confused": a pointer truncated through a WORD-typed
# cast, or a VM/userspace-supplied address dereferenced as a trusted host
# pointer.  These are *valid C* — the compiler cannot see them — so neither gcc
# nor clang -Wshorten-64-to-32 catches the cast forms.  sparse does:
#
#   * "non size-preserving pointer to integer cast"  — pointer narrowed to WORD
#   * "non size-preserving integer to pointer cast"  — WORD widened to pointer
#   * "cast truncates bits from constant value"
#   * "... different address spaces"                 — a __dis (Dis/userspace)
#                                                      pointer used where a host
#                                                      pointer is required (see
#                                                      include/disptr.h)
#
# This replays sparse over exactly the source the host build compiles, using the
# real per-file flags (from `mk -n -a`), and diffs the high-signal warnings
# against a curated baseline so NEW issues stand out.  Mirrors tests/lint/run.sh.
#
# Usage:
#   sh tests/sparse/run.sh            # NEW high-signal warnings vs baseline; nonzero if any
#   sh tests/sparse/run.sh --update   # regenerate the baseline
#   sh tests/sparse/run.sh --all      # print every high-signal warning (no baseline)
#   sh tests/sparse/run.sh --raw      # dump ALL sparse output (debug; unfiltered)
#
# Honors ROOT/SYSHOST/SYSTARG/OBJTYPE; SPARSE=<path> overrides the checker.

set -u

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
SYSHOST=${SYSHOST:-Linux}
SYSTARG=${SYSTARG:-$SYSHOST}
OBJTYPE=${OBJTYPE:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/aarch64/')}
MK=${MK:-$ROOT/$SYSTARG/$OBJTYPE/bin/mk}

SPARSEDIR=$ROOT/tests/sparse
SPARSE=${SPARSE:-}
if [ -z "$SPARSE" ]; then
	SPARSE=$(command -v sparse 2>/dev/null || true)
fi
if [ -z "$SPARSE" ] || [ ! -x "$SPARSE" ]; then
	SPARSE=$(sh "$SPARSEDIR/build-sparse.sh") || {
		echo "sparse: no checker; build it with sh tests/sparse/build-sparse.sh" >&2
		exit 2
	}
fi

OUTDIR=$SPARSEDIR/.out
BASELINE=$SPARSEDIR/baseline.txt
mkdir -p "$OUTDIR"

mode=diff
case "${1:-}" in
	--update) mode=update ;;
	--all)    mode=all ;;
	--raw)    mode=raw ;;
	"")       mode=diff ;;
	*) echo "usage: $0 [--update|--all|--raw]" >&2; exit 2 ;;
esac

if [ ! -x "$MK" ]; then
	echo "sparse: mk not found at $MK; build the tree first (make emu)" >&2
	exit 2
fi

# glibc's aarch64 <bits/math-vector.h> declares SVE/Neon vector math using gcc
# builtin vector types sparse cannot parse.  We never call vector math; neutralise
# those builtin types so the header parses.  (x86-64 glibc does not need this but
# the extra -D's are harmless there.)
SHIM='-D__Float32x4_t=int -D__Float64x2_t=int -D__SVFloat32_t=int -D__SVFloat64_t=int -D__SVBool_t=int'

# Source directories whose C feeds the host build (same set as tests/lint).
DIRS="lib9 libbio libmp libsec libmath libdraw libmemdraw libmemlayer
      libinterp libtk libkeyring emu/$SYSTARG"

MKARGS="ROOT=$ROOT SYSHOST=$SYSHOST SYSTARG=$SYSTARG OBJTYPE=$OBJTYPE CONF=emu"

raw=$OUTDIR/raw.txt
: > "$raw"

echo "sparse: $("$SPARSE" --version 2>/dev/null) over the host build ($SYSTARG/$OBJTYPE)" >&2

for d in $DIRS; do
	[ -f "$ROOT/$d/mkfile" ] || continue
	cd "$ROOT/$d" || continue
	"$MK" -n -a $MKARGS 2>/dev/null | grep -E '^[[:space:]]*gcc -c' | while read -r line; do
		line=$(printf '%s' "$line" | tr -d "'")
		set -- $line
		src=""; flags=""; skipnext=0
		for tok in "$@"; do
			if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
			case "$tok" in
				gcc|-c) ;;
				-o) skipnext=1 ;;
				-march=*) ;;
				-W*|-O*|-g) ;;
				-I*|-D*|-U*) flags="$flags $tok" ;;
				*.c) src="$tok" ;;
				*) ;;
			esac
		done
		[ -n "$src" ] || continue
		[ -f "$src" ] || continue
		printf '\n@@@ %s/%s\n' "$d" "$src" >> "$raw"
		# -Wcast-truncate / -Wbitwise are on by default; name them for clarity.
		"$SPARSE" $SHIM $flags -Wcast-truncate -Wbitwise \
			"$ROOT/$d/$src" >> "$raw" 2>&1
	done
done

if [ "$mode" = raw ]; then
	cat "$raw"
	exit 0
fi

# High-signal categories only: pointer<->int width casts and address-space
# violations.  Everything else sparse emits here (non-static decls, missing
# braces, plain-int-NULL) is Plan 9 dialect noise, dropped.
norm=$OUTDIR/current.txt
grep -hE 'non size-preserving|truncates bits|address space' "$raw" 2>/dev/null \
	| grep -vE '/usr/include|libm-simd' \
	| sed "s#$ROOT/##; s#emu/[^/]*/\.\./port/#emu/port/#; s#^\.\./port/#emu/port/#; s/:[0-9]*:[0-9]*:/:/" \
	| sort -u > "$norm"

n=$(wc -l < "$norm" | tr -d ' ')

case "$mode" in
all)
	echo "sparse: $n high-signal warning(s):" >&2
	cat "$norm"
	exit 0
	;;
update)
	cp "$norm" "$BASELINE"
	echo "sparse: baseline updated — $n site(s) recorded in $BASELINE" >&2
	exit 0
	;;
diff)
	if [ ! -f "$BASELINE" ]; then
		echo "sparse: no baseline yet; run '$0 --update' to create one ($n sites found)" >&2
		exit 2
	fi
	new=$(comm -13 "$BASELINE" "$norm")
	fixed=$(comm -23 "$BASELINE" "$norm")
	if [ -n "$fixed" ]; then
		echo "sparse: $(printf '%s\n' "$fixed" | wc -l | tr -d ' ') baseline site(s) no longer warn (consider --update):" >&2
		printf '%s\n' "$fixed" | sed 's/^/  - /' >&2
	fi
	if [ -n "$new" ]; then
		echo "sparse: NEW pointer-width / address-space warning(s):" >&2
		printf '%s\n' "$new" | sed 's/^/  + /' >&2
		exit 1
	fi
	echo "sparse: OK — no new width/address-space warnings ($n sites, all in baseline)" >&2
	exit 0
	;;
esac
