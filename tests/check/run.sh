#!/usr/bin/env bash
#
# tests/check/run.sh -- the platform pre-push gate driver.
#
# Reads the capability manifest for the active platform
# (tests/check/platforms/<SYSTARG>-<OBJTYPE>.manifest) and runs every declared
# cell -- build configs (incl. a release link-check), test suites
# (suite x CONF x run-mode), and doc checks -- then prints a PASS/FAIL/SKIP/TODO
# matrix.  Exit status is nonzero iff a cell marked `require` FAILED.  `skip`
# and `todo` cells are never run but are always printed, so untested surface
# stays visible instead of silently rotting (the emu-g-broke-and-nobody-noticed
# failure mode this gate exists to prevent).
#
# Invoked by `make check`.  Honors env: ROOT, SYSTARG, OBJTYPE, MAKE (else derived).
#
# Phasing (fixed, regardless of manifest order):
#   1. debug builds   -- `make all` (emu+dis), then targeted relinks of other CONFs
#   2. tests          -- run against the debug binaries just built
#   3. release builds  -- full PROFILE=release rebuild link-check (clobbers to release)
#   4. restore         -- if any release build ran, `make all` to return to debug
#   5. docs            -- (todo) doc-coverage checks
set -u

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
SYSTARG=${SYSTARG:-Linux}
if [ -z "${OBJTYPE:-}" ]; then
	case "$(uname -m)" in
	aarch64|arm64) OBJTYPE=aarch64;;
	x86_64|amd64)  OBJTYPE=amd64;;
	*)             OBJTYPE=$(uname -m);;
	esac
fi
PLAT="$SYSTARG-$OBJTYPE"
OBJDIR="$SYSTARG/$OBJTYPE"
BIN="$ROOT/$OBJDIR/bin"
MK="$BIN/mk"
MANIFEST="$ROOT/tests/check/platforms/$PLAT.manifest"
MAKE=${MAKE:-make}
MFLAGS="ROOT=$ROOT SYSTARG=$SYSTARG OBJTYPE=$OBJTYPE"

[ -f "$MANIFEST" ] || { echo "make check: no manifest for $PLAT ($MANIFEST)" >&2; exit 2; }
cd "$ROOT" || exit 2

# ---- parse manifest into parallel arrays (manifest order) ----
declare -a R_CHECK R_CELL R_STATUS R_VERDICT R_DETAIL
N=0
while IFS= read -r line; do
	trimmed=${line#"${line%%[![:space:]]*}"}      # strip leading whitespace
	case "$trimmed" in ''|'#'*) continue;; esac
	read -r c cell st rest <<<"$line"
	[ -z "$c" ] && continue
	R_CHECK[N]=$c; R_CELL[N]=$cell; R_STATUS[N]=$st
	R_VERDICT[N]=""; R_DETAIL[N]=$rest
	N=$((N+1))
done < "$MANIFEST"
[ "$N" -gt 0 ] || { echo "make check: empty manifest $MANIFEST" >&2; exit 2; }

gate_fail=0
base_built=0   # 0=not yet, 1=ok, 2=failed

up()      { case "$1" in skip) echo SKIP;; todo) echo TODO;; *) echo "$1";; esac; }
runflag() { case "$1" in jit) echo "-c1";; jitB) echo "-c1 -B";; *) echo "";; esac; }
note()    { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

set_v() {  # <idx> <verdict> [detail]
	local idx=$1 v=$2 d=${3:-}
	R_VERDICT[$idx]=$v
	[ -n "$d" ] && R_DETAIL[$idx]=$d
	[ "$v" = FAIL ] && [ "${R_STATUS[$idx]}" = require ] && gate_fail=1
	return 0
}

# `make all` (debug emu + coherent .dis tree). Idempotent within one run.
ensure_base() {
	[ "$base_built" = 1 ] && return 0
	[ "$base_built" = 2 ] && return 1
	note "base build: make all (debug)"
	if "$MAKE" $MFLAGS all; then base_built=1; return 0; fi
	base_built=2; return 1
}

# Relink one CONF's emu binary reusing the already-built (debug) libs -- much
# cheaper than `make CONF=x emu` (which nukes & rebuilds every lib).
relink_debug_conf() {  # <conf>
	local conf=$1
	( cd "$ROOT/emu/$SYSTARG" && "$MK" ROOT="$ROOT" SYSHOST="$SYSTARG" SYSTARG="$SYSTARG" OBJTYPE="$OBJTYPE" CONF="$conf" clean ) && \
	( cd "$ROOT/emu/$SYSTARG" && "$MK" ROOT="$ROOT" SYSHOST="$SYSTARG" SYSTARG="$SYSTARG" OBJTYPE="$OBJTYPE" CONF="$conf" install )
}

# ---- phase 1: debug builds ----
for i in $(seq 0 $((N-1))); do
	[ "${R_CHECK[$i]}" = build ] || continue
	cell=${R_CELL[$i]}; st=${R_STATUS[$i]}
	conf=$cell; mode=debug
	case "$cell" in */release) conf=${cell%/release}; mode=release;; esac
	[ "$mode" = release ] && continue                      # phase 3
	if [ "$st" != require ]; then set_v "$i" "$(up "$st")"; continue; fi
	note "build $cell (debug)"
	if [ "$conf" = emu ]; then
		if ensure_base; then set_v "$i" PASS; else set_v "$i" FAIL "make all failed"; fi
	elif ensure_base; then
		if relink_debug_conf "$conf"; then set_v "$i" PASS; else set_v "$i" FAIL "relink failed"; fi
	else
		set_v "$i" FAIL "base build failed"
	fi
done

# ---- phase 2: tests (against debug binaries) ----
for i in $(seq 0 $((N-1))); do
	[ "${R_CHECK[$i]}" = test ] || continue
	cell=${R_CELL[$i]}; st=${R_STATUS[$i]}
	if [ "$st" != require ]; then set_v "$i" "$(up "$st")"; continue; fi
	note "test $cell"
	if ! ensure_base; then set_v "$i" FAIL "base build failed"; continue; fi
	IFS=/ read -r suite conf rm <<<"$cell"
	case "$suite" in
	cunit)
		if "$MAKE" $MFLAGS test_all_unit; then set_v "$i" PASS; else set_v "$i" FAIL; fi;;
	jitperf)
		if "$MAKE" $MFLAGS test_jitperf; then set_v "$i" PASS; else set_v "$i" FAIL; fi;;
	lp64|web)
		emubin="$BIN/$conf"
		if [ ! -x "$emubin" ]; then set_v "$i" FAIL "binary $conf missing"; continue; fi
		if EMU="$emubin" EMUFLAGS="$(runflag "$rm")" bash "$ROOT/tests/$suite/run.sh"; then
			set_v "$i" PASS; else set_v "$i" FAIL; fi;;
	*)
		set_v "$i" FAIL "unknown suite '$suite'";;
	esac
done

# ---- phase 3: release builds (clobber to release; restored after) ----
released=0
for i in $(seq 0 $((N-1))); do
	[ "${R_CHECK[$i]}" = build ] || continue
	cell=${R_CELL[$i]}; st=${R_STATUS[$i]}
	case "$cell" in */release) ;; *) continue;; esac
	conf=${cell%/release}
	if [ "$st" != require ]; then set_v "$i" "$(up "$st")"; continue; fi
	note "build $cell (release link-check, instrumentation off)"
	if "$MAKE" $MFLAGS PROFILE=release CONF="$conf" emu FORCE=1; then set_v "$i" PASS; else set_v "$i" FAIL; fi
	released=1
done
if [ "$released" = 1 ]; then
	note "restore debug build (make all)"
	"$MAKE" $MFLAGS all || echo "WARN: debug restore failed -- run 'make all' before using emu" >&2
fi

# ---- phase 4: docs ----
for i in $(seq 0 $((N-1))); do
	[ "${R_CHECK[$i]}" = doc ] || continue
	st=${R_STATUS[$i]}
	case "$st" in
	require) set_v "$i" FAIL "no doc-checker wired yet";;
	*)       set_v "$i" "$(up "$st")";;
	esac
done

# ---- matrix ----
echo
echo "================= make check: $PLAT ================="
printf '%-6s %-22s %-8s %-7s  %s\n' CHECK CELL STATUS VERDICT NOTE
printf '%-6s %-22s %-8s %-7s  %s\n' "------" "----------------------" "--------" "-------" "----"
for i in $(seq 0 $((N-1))); do
	printf '%-6s %-22s %-8s %-7s  %s\n' \
		"${R_CHECK[$i]}" "${R_CELL[$i]}" "${R_STATUS[$i]}" "${R_VERDICT[$i]:-?}" "${R_DETAIL[$i]}"
done
echo
if [ "$gate_fail" = 0 ]; then
	echo "make check: PASS ($PLAT) -- all 'require' cells green"
	exit 0
fi
echo "make check: FAIL ($PLAT) -- a 'require' cell failed (see matrix above)"
exit 1
