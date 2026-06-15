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
# Positional args are filter words ('make check kernel dis'): only cells whose
# name contains a word run; the rest print as '---' and never gate.  A filtered
# run also skips the release link-check, the debug restore, and any build cell
# no selected test needs.
#
# Phasing (fixed, regardless of manifest order):
#   1. debug builds   -- `make all` (emu+dis), then targeted relinks of other CONFs
#   2. tests          -- light cells in parallel lanes (lane_of), kernel cells serial
#   3. release builds -- PROFILE=release link-check (clobbers emu to release)
#   4. restore        -- if any release ran, rebuild debug emu (.dis is ABI-identical
#                        across profiles, so it is left intact)
#   5. docs           -- (todo) doc-coverage checks
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
export PATH="$BIN:$PATH"   # so limbo/mk/emu resolve whether run.sh is invoked
                           # directly or via `make check` (which sets PATH itself)
MANIFEST="$ROOT/tests/check/platforms/$PLAT.manifest"
MAKE=${MAKE:-make}
MFLAGS="ROOT=$ROOT SYSTARG=$SYSTARG OBJTYPE=$OBJTYPE"
FILTER=("$@")   # selective run: only cells whose name contains a filter word

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

# --- selective run ('make check <word>...'): a cell runs iff its name contains
# a filter word.  No filter (or the word 'all') means the whole matrix. ---
filtering() {
	[ ${#FILTER[@]} -eq 0 ] && return 1
	case " ${FILTER[*]} " in *" all "*) return 1;; esac
	return 0
}
selected() {  # <cell>
	filtering || return 0
	local f; for f in "${FILTER[@]}"; do case "$1" in *"$f"*) return 0;; esac; done
	return 1
}

# Is <conf>'s binary required by a selected test cell?  Lets a filtered run build
# only what it needs (e.g. `make check cunit` skips the emu-g relink, while
# `make check dis` still gets it).  Only meaningful while filtering.
conf_needed() {  # <conf>
	local c=$1 i s cf
	for i in $(seq 0 $((N-1))); do
		[ "${R_CHECK[$i]}" = test ] && [ "${R_STATUS[$i]}" = require ] || continue
		selected "${R_CELL[$i]}" || continue
		IFS=/ read -r s cf _ <<<"${R_CELL[$i]}"
		case "$s" in dis|web) [ "$cf" = "$c" ] && return 0;; esac
	done
	return 1
}

# A "lane" is a build directory that cells contend for: cells in the same lane
# must run serially, different lanes run in parallel.  cunit and its cross
# canaries all `mk` in the shared lib source dirs; the two dis run-modes share
# tests/dis/_build; web and jitperf each own their own dir.
lane_of() {  # <cell> -> lane key
	case "$1" in
	cunit*)  echo cunit;;
	dis/*)   echo dis;;
	web/*)   echo web;;
	*)       echo "${1%%/*}";;
	esac
}

# Run one test cell by index: prints its own output, returns its exit status.
# Used by both the parallel lanes and the serial kernel pass.
do_test_cell() {  # <idx>
	local i=$1 suite conf rm
	IFS=/ read -r suite conf rm <<<"${R_CELL[$i]}"
	case "$suite" in
	cunit)
		if [ -n "$conf" ]; then bash "$ROOT/tests/cunit/cross.sh" "$conf"
		else "$MAKE" $MFLAGS test_all_unit; fi;;
	jitperf)
		"$MAKE" $MFLAGS test_jitperf;;
	kernel)
		HWTARG="${conf:-virt64}" bash "$ROOT/tests/kernel/run.sh";;
	crossjit)
		bash "$ROOT/tests/check/amd64jit.sh";;
	dis|web)
		local emubin="$BIN/$conf"
		[ -x "$emubin" ] || { echo "binary $conf missing" >&2; return 2; }
		EMU="$emubin" EMUFLAGS="$(runflag "$rm")" bash "$ROOT/tests/$suite/run.sh";;
	*)
		echo "unknown suite '$suite'" >&2; return 3;;
	esac
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
	# under a filter, build only the base emu plus confs a selected test needs
	if filtering && [ "$conf" != emu ] && ! selected "$cell" && ! conf_needed "$conf"; then
		set_v "$i" --- "not needed by filter"; continue
	fi
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
# Light cells are bucketed into lanes (lane_of) and the lanes run in parallel,
# serial within a lane.  Kernel cells boot qemu and are load-sensitive (TCG
# cross-boot flakes under contention), so they form a serial pass afterwards.
LIGHT=(); HEAVY=()
for i in $(seq 0 $((N-1))); do
	[ "${R_CHECK[$i]}" = test ] || continue
	cell=${R_CELL[$i]}; st=${R_STATUS[$i]}
	if [ "$st" != require ]; then set_v "$i" "$(up "$st")"; continue; fi
	if ! selected "$cell"; then set_v "$i" --- "filtered out"; continue; fi
	# kernel + crossjit boot qemu / cross-build + rebuild the host tree, so they
	# are load-sensitive and contend for the shared source dirs -- run serially.
	case "${cell%%/*}" in kernel|crossjit) HEAVY+=("$i");; *) LIGHT+=("$i");; esac
done

# every suite reads the debug tree from phase 1; ensure it once here, before any
# lane forks -- concurrent base builds would race.
if [ $(( ${#LIGHT[@]} + ${#HEAVY[@]} )) -gt 0 ] && ! ensure_base; then
	for i in ${LIGHT[@]+"${LIGHT[@]}"} ${HEAVY[@]+"${HEAVY[@]}"}; do set_v "$i" FAIL "base build failed"; done
	LIGHT=(); HEAVY=()
fi

if [ ${#LIGHT[@]} -gt 0 ]; then
	declare -A LANE=()
	for i in "${LIGHT[@]}"; do
		k=$(lane_of "${R_CELL[$i]}"); LANE[$k]="${LANE[$k]:-} $i"
	done
	note "tests: ${#LANE[@]} lane(s) in parallel (${!LANE[*]})"
	RESDIR=$(mktemp -d)
	for k in "${!LANE[@]}"; do
		( for i in ${LANE[$k]}; do
			do_test_cell "$i" >"$RESDIR/$i.log" 2>&1; echo $? >"$RESDIR/$i.rc"
		  done ) &
	done
	wait
	for i in "${LIGHT[@]}"; do   # replay logs + record verdicts in manifest order
		note "test ${R_CELL[$i]}"
		cat "$RESDIR/$i.log" 2>/dev/null
		[ "$(cat "$RESDIR/$i.rc" 2>/dev/null)" = 0 ] && set_v "$i" PASS || set_v "$i" FAIL
	done
	rm -rf "$RESDIR"
fi

for i in ${HEAVY[@]+"${HEAVY[@]}"}; do
	note "test ${R_CELL[$i]}"
	if do_test_cell "$i"; then set_v "$i" PASS; else set_v "$i" FAIL; fi
done

# ---- phase 3: release builds (clobber to release; restored after) ----
released=0
for i in $(seq 0 $((N-1))); do
	[ "${R_CHECK[$i]}" = build ] || continue
	cell=${R_CELL[$i]}; st=${R_STATUS[$i]}
	case "$cell" in */release) ;; *) continue;; esac
	conf=${cell%/release}
	if [ "$st" != require ]; then set_v "$i" "$(up "$st")"; continue; fi
	if ! selected "$cell"; then set_v "$i" --- "filtered out"; continue; fi
	note "build $cell (release link-check, instrumentation off)"
	if "$MAKE" $MFLAGS PROFILE=release CONF="$conf" emu FORCE=1; then set_v "$i" PASS; else set_v "$i" FAIL; fi
	released=1
done
if [ "$released" = 1 ]; then
	# Only the C side was clobbered to release; the .dis tree is ABI-identical
	# across profiles (debug/release differ in C optimisation/instrumentation
	# only), so restoring it is a needless recompile of thousands of Limbo
	# files.  Rebuild emu (debug) and leave the existing valid .dis tree.
	note "restore debug build (emu only; .dis tree is ABI-identical)"
	"$MAKE" $MFLAGS emu FORCE=1 || echo "WARN: debug restore failed -- run 'make all' before using emu" >&2
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
scope=""; filtering && scope=" [filter: ${FILTER[*]} -- '---' cells were not run]"
if [ "$gate_fail" = 0 ]; then
	echo "make check: PASS ($PLAT)$scope -- all run 'require' cells green"
	exit 0
fi
echo "make check: FAIL ($PLAT)$scope -- a 'require' cell failed (see matrix above)"
exit 1
