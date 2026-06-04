#!/usr/bin/env bash
#
# scenario.sh - run ONE Inferno GUI app headless, deterministically, and emit a
# structured JSON verdict (CRASH / HANG / CLEAN) plus an artifact bundle.
#
# This is the closed-loop debugging harness for the LP64 port.  Unlike
# gui_sweep.sh (which scrapes the emu log across many apps for crash text), this
# runs a single app under the full fault-observability stack and is meant to be
# invoked repeatedly to chase a flaky bug, then have its JSON parsed by tooling
# (or an agent) and its core handed to gdb.
#
# What it sets up:
#   * deterministic address layout      : setarch -R (no ASLR)  -> reproducible
#   * real cores to a readable path      : ulimit -c unlimited + kernel
#                                          core_pattern=/tmp/inferno-cores/...
#   * crash-hard fault mode              : EMUCRASH=1   (wild fault -> core)
#   * VM hang watchdog                   : EMUWATCHDOG=<secs>
#   * JVM-style thread dump on wedge     : kill -USR2 (captured into the log)
#
# Detection (checked every SHOT_INTERVAL while the app runs):
#   CRASH  - a core dropped, OR a fault/panic/break signature in the emu log,
#            OR the process died on a signal.
#   HANG   - the watchdog fired in the log, OR the framebuffer is frozen while
#            emu burns CPU (busy-spin/livelock the watchdog can't see).
#   CLEAN  - the app exited 0, or stayed alive to RUN_SECS with no fault.
#
# Usage:
#   tests/lp64/scenario.sh [app.dis]            # default /dis/acme/acme.dis
#   DEPTH=16 tests/lp64/scenario.sh /dis/wm/clock.dis
#
# Env knobs (all optional):
#   DEPTH=24            X colour depth (the acme bug is 24-bit only)
#   GEOM=1024x768       screen geometry WxH
#   RUN_SECS=20         how long to let the app run before declaring CLEAN(alive)
#   WATCHDOG=10         EMUWATCHDOG seconds (0 disables); default min(10,RUN_SECS)
#   SHOT_INTERVAL=1     seconds between screenshots / polls
#   FREEZE_SAMPLES=5    consecutive identical+busy frames to call a busy-spin HANG
#   DISPLAY_NUM=        force display :N (default: first free in 80..120)
#   CRASHMODE=1         EMUCRASH value (set 0 to keep faults as Dis exceptions)
#   KEEP_RUNNING=0      if 1, leave emu/Xvfb up after verdict (for manual poking)
#   ASLR=off            'off' (default) runs under setarch -R for a fixed, low
#                       address layout (reproducible).  'on' leaves ASLR enabled
#                       -- needed to PROVOKE bugs whose trigger is a high address
#                       being truncated (e.g. the flaky 24-bit acme IRET fault),
#                       since a fixed low layout can mask them.
#
# Output: a JSON object on stdout (also written to <artifacts>/verdict.json).
# Human-readable progress goes to stderr.  Exit status: 0 CLEAN, 3 HANG, 4 CRASH,
# 2 setup error.
#
set -u

# ---- locate tree + binaries -------------------------------------------------
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || { echo "cannot cd $ROOT" >&2; exit 2; }
case "$(uname -m)" in aarch64|arm64) ARCH=aarch64;; x86_64|amd64) ARCH=amd64;; *) ARCH=$(uname -m);; esac
EMU="$ROOT/Linux/$ARCH/bin/emu"
[ -x "$EMU" ] || { echo "graphical emu not found: $EMU (build CONF=emu)" >&2; exit 2; }
for t in Xvfb import compare setarch; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

# ---- config -----------------------------------------------------------------
APP=${1:-/dis/acme/acme.dis}
DEPTH=${DEPTH:-24}
GEOM=${GEOM:-1024x768}
RUN_SECS=${RUN_SECS:-20}
SHOT_INTERVAL=${SHOT_INTERVAL:-1}
FREEZE_SAMPLES=${FREEZE_SAMPLES:-5}
CRASHMODE=${CRASHMODE:-1}
KEEP_RUNNING=${KEEP_RUNNING:-0}
WATCHDOG=${WATCHDOG:-$(( RUN_SECS < 10 ? RUN_SECS : 10 ))}
COREDIR=/tmp/inferno-cores
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
# busy-spin threshold: >50% of one core of CPU consumed across the freeze window
BUSY_JIFFIES=$(( HZ * SHOT_INTERVAL * FREEZE_SAMPLES / 2 ))

appbase=$(basename "$APP" .dis)
ts=$(date +%Y%m%d-%H%M%S)
ART="$ROOT/tests/lp64/_build/scenarios/${ts}_${appbase}_d${DEPTH}"
mkdir -p "$ART"
EMULOG="$ART/emu.log"

say() { printf '%s\n' "$*" >&2; }

# ---- pick a free display ----------------------------------------------------
pick_display() {
	if [ -n "${DISPLAY_NUM:-}" ]; then echo "$DISPLAY_NUM"; return; fi
	local n
	for n in $(seq 80 120); do
		[ -S "/tmp/.X11-unix/X$n" ] || { echo "$n"; return; }
	done
	echo "error: no free X display in :80..:120" >&2; exit 2
}
N=$(pick_display); DISP=":$N"

# ---- start Xvfb -------------------------------------------------------------
say "[scenario] app=$APP depth=$DEPTH geom=$GEOM display=$DISP watchdog=${WATCHDOG}s"
Xvfb "$DISP" -screen 0 "${GEOM}x${DEPTH}" >"$ART/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 50); do
	xdpyinfo -display "$DISP" >/dev/null 2>&1 && break
	kill -0 "$XVFB_PID" 2>/dev/null || { say "Xvfb died"; cat "$ART/xvfb.log" >&2; exit 2; }
	sleep 0.1
done

# ---- teardown ---------------------------------------------------------------
EMU_PID=""
kill_tree() {  # reap the whole emu thread group (kproc pthreads share one tgid)
	local p=$1 i t
	[ -n "$p" ] || return 0
	kill "$p" 2>/dev/null
	for i in $(seq 1 15); do [ -d "/proc/$p/task" ] || return 0; sleep 0.2; done
	kill -9 "$p" 2>/dev/null
	for i in $(seq 1 15); do [ -d "/proc/$p/task" ] || return 0; sleep 0.2; done
	for t in $(ls "/proc/$p/task" 2>/dev/null); do kill -9 "$t" 2>/dev/null; done
}
cleanup() {
	[ "$KEEP_RUNNING" = 1 ] && { say "[scenario] KEEP_RUNNING=1: leaving emu pid=$EMU_PID and Xvfb on $DISP up"; return; }
	[ -n "$EMU_PID" ] && kill_tree "$EMU_PID"
	kill "$XVFB_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ---- helpers ----------------------------------------------------------------
cpu_jiffies() {  # utime+stime of the whole thread group (sum over tasks)
	local p=$1 sum=0 t u s rest
	for t in $(ls "/proc/$p/task" 2>/dev/null); do
		# fields 14 (utime) 15 (stime); comm may contain spaces/parens -> cut after ')'
		read -r _ rest < "/proc/$p/task/$t/stat" 2>/dev/null || continue
		set -- ${rest#*) }            # drop "(comm) "; now $1=state(f3) .. so f14/f15 = $12/$13
		u=${12:-0}; s=${13:-0}        # utime, stime
		sum=$(( sum + u + s ))
	done
	echo "$sum"
}
shot() { import -display "$DISP" -window root "$1" 2>/dev/null; }
identical() {  # 0 (true) if two PNGs are pixel-identical
	local ae
	ae=$(compare -metric AE "$1" "$2" null: 2>&1)
	[ "${ae%% *}" = "0" ]
}

# ---- launch emu deterministically -------------------------------------------
record_existing_cores() { ls "$COREDIR"/core.emu.* 2>/dev/null | sort > "$ART/.cores.before"; }
new_core() {  # echo path of a core that appeared since launch for our pid (or "")
	local c
	for c in "$COREDIR"/core.emu."$EMU_PID".* ; do [ -e "$c" ] && { echo "$c"; return; }; done
	echo ""
}
record_existing_cores

ASLR=${ASLR:-off}
if [ "$ASLR" = on ]; then ASLRWRAP=""; else ASLRWRAP="setarch -R"; fi
( ulimit -c unlimited
  exec env DISPLAY="$DISP" EMUCRASH="$CRASHMODE" EMUWATCHDOG="$WATCHDOG" \
       $ASLRWRAP "$EMU" -r"$ROOT" -g"$GEOM" wm/wm "$APP" ) \
  >"$EMULOG" 2>&1 </dev/null &
EMU_PID=$!
say "[scenario] emu pid=$EMU_PID (EMUCRASH=$CRASHMODE EMUWATCHDOG=$WATCHDOG, ASLR=$ASLR)"

CRASH_RE='LP64 fault|[Ss]egmentation|Broken:|illegal dis|bad address|[Pp]anic|assert|SIGSEGV|SIGILL|SIGBUS'
HANG_RE='EMU(WATCHDOG|HANG)|watchdog|HANG:|lost wakeup|no runnable'

# ---- monitor loop -----------------------------------------------------------
VERDICT=""; DETAIL=""; FAULTLINE=""; SIGNAL=""; EXITCODE=""; CORE=""
prev=""; cur="$ART/shot_0001.png"; FIRSTSHOT=""; LASTSHOT=""
frames=0; changed=0; frozen_run=0
cpu_prev=$(cpu_jiffies "$EMU_PID")
start=$(date +%s); polls=$(( RUN_SECS / SHOT_INTERVAL )); [ "$polls" -lt 1 ] && polls=1

for ((k=1; k<=polls; k++)); do
	sleep "$SHOT_INTERVAL"

	# 1) core dropped?
	CORE=$(new_core); if [ -n "$CORE" ]; then VERDICT=CRASH; DETAIL=core; break; fi

	# 2) hang signature in log? (watchdog / lost-wakeup invariant)
	if line=$(grep -aE "$HANG_RE" "$EMULOG" 2>/dev/null | head -1) && [ -n "$line" ]; then
		VERDICT=HANG; DETAIL=watchdog; FAULTLINE=$line; break
	fi
	# 3) fault/panic/break signature in log?
	if line=$(grep -aE "$CRASH_RE" "$EMULOG" 2>/dev/null | head -1) && [ -n "$line" ]; then
		VERDICT=CRASH; DETAIL=fault-log; FAULTLINE=$line; break
	fi

	# 4) process exited?
	if ! kill -0 "$EMU_PID" 2>/dev/null; then
		wait "$EMU_PID"; st=$?
		CORE=$(new_core)
		if [ -n "$CORE" ]; then VERDICT=CRASH; DETAIL=core
		elif [ "$st" -gt 128 ]; then VERDICT=CRASH; DETAIL=signal; SIGNAL=$(( st - 128 ))
		else VERDICT=CLEAN; DETAIL=exited; EXITCODE=$st; fi
		break
	fi

	# screenshot + freeze/CPU sampling
	shot "$cur"
	[ -z "$FIRSTSHOT" ] && FIRSTSHOT="$cur"
	frames=$((frames+1)); LASTSHOT="$cur"
	if [ -n "$prev" ] && [ -s "$cur" ] && [ -s "$prev" ]; then
		if identical "$prev" "$cur"; then frozen_run=$((frozen_run+1)); else changed=$((changed+1)); frozen_run=0; fi
	fi

	# 5) busy-spin HANG: framebuffer frozen for FREEZE_SAMPLES while burning CPU
	if [ "$frozen_run" -ge "$FREEZE_SAMPLES" ]; then
		cpu_now=$(cpu_jiffies "$EMU_PID"); dcpu=$(( cpu_now - cpu_prev ))
		if [ "$dcpu" -ge "$BUSY_JIFFIES" ]; then
			VERDICT=HANG; DETAIL=busy-spin
			FAULTLINE="framebuffer static for ${frozen_run}x${SHOT_INTERVAL}s while emu used ${dcpu} jiffies (>=${BUSY_JIFFIES})"
			break
		fi
	fi
	cpu_prev=$(cpu_jiffies "$EMU_PID")
	prev="$cur"; cur="$ART/shot_$(printf '%04d' $((k+1))).png"
done

# survived the whole window with no event -> alive (a pass for persistent apps)
[ -z "$VERDICT" ] && { VERDICT=CLEAN; DETAIL=alive; }

# ---- on a wedge, grab a USR2 thread dump before teardown --------------------
if [ "$VERDICT" = HANG ] && kill -0 "$EMU_PID" 2>/dev/null; then
	say "[scenario] HANG: sending SIGUSR2 for a thread dump"
	kill -USR2 "$EMU_PID" 2>/dev/null; sleep 1
fi

# final screenshot
FINAL="$ART/shot_final.png"; shot "$FINAL"; [ -s "$FINAL" ] && LASTSHOT="$FINAL"
[ -n "$CORE" ] && ln -sf "$CORE" "$ART/core" 2>/dev/null
elapsed=$(( $(date +%s) - start ))

# ---- emit JSON verdict ------------------------------------------------------
jq -n \
  --arg app "$APP" --arg verdict "$VERDICT" --arg detail "$DETAIL" \
  --arg fault "$FAULTLINE" --arg core "${CORE:-}" --arg art "$ART" \
  --arg first "${FIRSTSHOT:-}" --arg last "${LASTSHOT:-}" --arg disp "$DISP" \
  --argjson depth "$DEPTH" --argjson pid "${EMU_PID:-0}" \
  --argjson frames "$frames" --argjson changed "$changed" --argjson elapsed "$elapsed" \
  --argjson signal "${SIGNAL:-null}" --argjson exitcode "${EXITCODE:-null}" \
  --argjson watchdog "$WATCHDOG" --argjson crashmode "$CRASHMODE" --arg aslr "$ASLR" \
  '{scenario:$app, depth:$depth, display:$disp, verdict:$verdict, detail:$detail,
    emu_pid:$pid, watchdog:$watchdog, crashmode:$crashmode, aslr:$aslr,
    signal:$signal, exitcode:$exitcode, core:(if $core=="" then null else $core end),
    fault_line:(if $fault=="" then null else $fault end),
    frames_captured:$frames, frames_changed:$changed, elapsed_secs:$elapsed,
    artifacts:$art, shot_first:$first, shot_last:$last}' \
  | tee "$ART/verdict.json"

case "$VERDICT" in
	CLEAN) exit 0;;
	HANG)  exit 3;;
	CRASH) exit 4;;
	*)     exit 2;;
esac
