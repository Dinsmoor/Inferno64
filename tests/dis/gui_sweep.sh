#!/bin/bash
#
# LP64 GUI sweep: compile every Limbo GUI application, then launch each one
# headless and watch for VM-level crashes.
#
# Why this exists: the TAP suites in tests/dis/suites exercise the Dis VM and
# the language, but never open a window.  The LP64 port's GUI-only bugs (e.g.
# the imported-global Modlink.MP truncation that crashed acme and charon on
# launch -- see suites/80_modglobal.b) only surface when a real graphical app
# runs.  This script is the standing net for that class:
#
#   Phase 1 (compile): run `limbo` over every .b under the GUI app trees and
#                      flag compile errors / compiler crashes.
#   Phase 2 (launch):  start each top-level GUI app under Xvfb + wm/wm with the
#                      graphical emu, give it a few seconds, and FAIL it if the
#                      emu log shows an LP64 fault / segfault / VM break /
#                      illegal instruction / panic.
#
# A clean compile + a fault-free launch is a pass.  Apps that exit cleanly or
# stay alive without a fault both pass; only a VM crash fails.  Benign
# environment noise (no /tmp, no plumber, no network) is ignored on purpose --
# we are hunting C-level VM crashes, which is where the LP64 bugs live.
#
# Usage:  tests/dis/gui_sweep.sh [-c|-l] [name-glob]
#   -c          compile phase only
#   -l          launch phase only
#   name-glob   restrict to apps whose basename matches (e.g. acme, charon)
#
# Env knobs:  DISPLAY_NUM (default 99), GEOM (1024x768), LAUNCH_SECS (5).
#
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 2

EMU_G="$ROOT/Linux/aarch64/bin/emu-g"      # headless build (compile checks)
EMU="$ROOT/Linux/aarch64/bin/emu"          # graphical build (launch checks)
LIMBO="$ROOT/Linux/aarch64/bin/limbo"
BUILD="$ROOT/tests/dis/_build/gui"
DISP=":${DISPLAY_NUM:-99}"
GEOM=${GEOM:-1024x768}
LAUNCH_SECS=${LAUNCH_SECS:-5}

[ -x "$LIMBO" ] || { echo "missing limbo ($LIMBO) - run 'make all' first" >&2; exit 2; }

phase_c=1 phase_l=1
case "${1:-}" in
	-c) phase_l=0; shift;;
	-l) phase_c=0; shift;;
esac
glob="${1:-}"

# Crash signatures in an emu log (C-level VM faults, not Limbo-level errors).
CRASH_RE='LP64 fault|[Ss]egmentation violation|Broken:|illegal dis|bad address|[Pp]anic|assertion'

# GUI application source trees (every .b under these is compile-checked).
GUI_DIRS="appl/wm appl/acme appl/charon appl/ebook appl/demo appl/spree appl/tiny appl/math/spin appl/collab"

# Per-app extra include dirs (besides -I module -I appl/lib).
incdirs() {
	case "$1" in
	*/appl/acme/*)   echo "-I $ROOT/appl/acme";;
	*/appl/charon/*) echo "-I $ROOT/appl/charon";;
	*/appl/spree/*)  echo "-I $ROOT/appl/spree -I $ROOT/appl/spree/lib";;
	esac
}

rm -rf "$BUILD"; mkdir -p "$BUILD"
c_ok=0 c_err=0 c_errlist=""

compile_phase() {
	printf '\n=== Phase 1: compile every GUI app source ===\n'
	printf '%-44s %s\n' "SOURCE" "RESULT"
	printf '%-44s %s\n' "------" "------"
	for d in $GUI_DIRS; do
		[ -d "$ROOT/$d" ] || continue
		for src in "$ROOT/$d"/*.b; do
			[ -e "$src" ] || continue
			base=$(basename "$src" .b)
			rel=${src#$ROOT/}
			if [ -n "$glob" ] && [[ "$base" != *"$glob"* ]]; then continue; fi
			out="$BUILD/$(echo "$rel" | tr / _).dis"
			if err=$("$LIMBO" -I "$ROOT/module" -I "$ROOT/appl/lib" $(incdirs "$src") -o "$out" "$src" 2>&1); then
				c_ok=$((c_ok+1))
			else
				c_err=$((c_err+1))
				c_errlist="$c_errlist $rel"
				printf '%-44s %s\n' "$rel" "COMPILE-ERR"
				printf '%s\n' "$err" | sed 's/^/    /' | head -4
			fi
		done
	done
	printf 'compile: ok=%d err=%d\n' "$c_ok" "$c_err"
}

# --- launch phase ------------------------------------------------------------
# The apps we actually start as a wm client.  These take a Draw->Context; the
# rest of dis/wm (libraries, the toolbar, network/mail tools) are not launched.
LAUNCH_APPS="
/dis/acme/acme.dis
/dis/charon.dis
/dis/wm/about.dis
/dis/wm/bounce.dis
/dis/wm/calculator.dis
/dis/wm/clock.dis
/dis/wm/coffee.dis
/dis/wm/colors.dis
/dis/wm/collide.dis
/dis/wm/memory.dis
/dis/wm/polyhedra.dis
/dis/wm/reversi.dis
/dis/wm/snake.dis
/dis/wm/stopwatch.dis
/dis/wm/sweeper.dis
/dis/wm/task.dis
/dis/wm/tetris.dis
/dis/wm/mand.dis
/dis/wm/pen.dis
/dis/wm/view.dis
/dis/wm/edit.dis
/dis/wm/brutus.dis
/dis/wm/calendar.dis
"

xvfb_pid=""
start_xvfb() {
	[ -x "$EMU" ] || { echo "missing graphical emu ($EMU) - build CONF=emu" >&2; exit 2; }
	command -v Xvfb >/dev/null || { echo "Xvfb not installed; skipping launch phase" >&2; return 1; }
	if ! xdpyinfo -display "$DISP" >/dev/null 2>&1; then
		Xvfb "$DISP" -screen 0 "${GEOM}x24" >/dev/null 2>&1 &
		xvfb_pid=$!
		sleep 2
	fi
	return 0
}
stop_xvfb() { [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null; }

l_ok=0 l_crash=0 l_skip=0 l_crashlist=""

launch_phase() {
	printf '\n=== Phase 2: launch each GUI app headless (%ss each) ===\n' "$LAUNCH_SECS"
	start_xvfb || { echo "(launch phase skipped)"; return; }
	printf '%-26s %s\n' "APP" "RESULT"
	printf '%-26s %s\n' "---" "------"
	for app in $LAUNCH_APPS; do
		base=$(basename "$app" .dis)
		if [ -n "$glob" ] && [[ "$base" != *"$glob"* ]]; then continue; fi
		if [ ! -e "$ROOT/${app#/}" ]; then
			printf '%-26s %s\n' "$base" "MISSING-DIS"; l_skip=$((l_skip+1)); continue
		fi
		log="$BUILD/launch_$base.log"
		# timeout (SIGKILL after LAUNCH_SECS) bounds the run; do NOT pkill --
		# `pkill -f` would match this script's own command line and kill it.
		( DISPLAY="$DISP" setsid timeout -s KILL "$LAUNCH_SECS" \
			"$EMU" -g"$GEOM" wm/wm "$app" >"$log" 2>&1 </dev/null & )
		sleep $((LAUNCH_SECS + 2))
		if grep -qE "$CRASH_RE" "$log" 2>/dev/null; then
			l_crash=$((l_crash+1)); l_crashlist="$l_crashlist $base"
			printf '%-26s %s\n' "$base" "CRASH"
			grep -E "$CRASH_RE" "$log" 2>/dev/null | sed 's/^/    /' | head -2
		else
			l_ok=$((l_ok+1))
			printf '%-26s %s\n' "$base" "ok"
		fi
	done
	stop_xvfb
	printf 'launch: ok=%d crash=%d skip=%d\n' "$l_ok" "$l_crash" "$l_skip"
}

[ "$phase_c" = 1 ] && compile_phase
[ "$phase_l" = 1 ] && launch_phase

echo "----------------------------------------------"
rc=0
[ "$phase_c" = 1 ] && { printf 'COMPILE  ok=%d err=%d%s\n' "$c_ok" "$c_err" "${c_errlist:+  (fail:$c_errlist)}"; [ "$c_err" -ne 0 ] && rc=1; }
[ "$phase_l" = 1 ] && { printf 'LAUNCH   ok=%d crash=%d%s\n' "$l_ok" "$l_crash" "${l_crashlist:+  (crash:$l_crashlist)}"; [ "$l_crash" -ne 0 ] && rc=1; }
exit $rc
