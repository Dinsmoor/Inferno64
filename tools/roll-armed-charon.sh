#!/usr/bin/env bash
# roll-armed-charon.sh -- relaunch the ILP64 emu on a display until the heap arena
# maps with bit 36 SET ("armed"), then leave it up for you to drive into the
# bit-36 free-tree corruption (see the charon-close heap-corruption notes).
#
# Why roll: the corruption only MANIFESTS when a real heap pointer has bit 36
# (the 64 GiB bit) set -- a ~50% ASLR coin-flip per launch. On an unarmed launch
# the stray bit-clear is a silent no-op, so driving it is wasted effort. This
# rolls until armed (read from the EMUPOOLPARANOID arming probe in the console).
#
# EMUPOOLPARANOID=1: the per-op free-tree audit ABORTS at the first detection, so
# when you drive charon into the bug it crashes with a "POOLPARANOID[...]" line
# naming the victim free block + the stray (bit-36-cleared) pointer. That line
# (plus what you did right before) is what to copy back.
#
# Usage:   tools/roll-armed-charon.sh [url]
#   DISP=:3   display to use (default :3 -- the shared VNC desktop)
#   GEOM=1280x800   MAX=40 (max rolls)   LOG=/tmp/armed-emu.log
set -u
ROOT=/home/tyler/inferno-os
DISP=${DISP:-:3}
GEOM=${GEOM:-1280x800}
URL=${1:-file:///tests/web/fixtures/_bounce_heavy.html}
LOG=${LOG:-/tmp/armed-emu.log}
MAX=${MAX:-40}
EMU="$ROOT/Linux/aarch64/bin/emu"
cd "$ROOT"

[ -x "$EMU" ] || { echo "no emu at $EMU -- build first (make all)"; exit 2; }
DISPLAY="$DISP" xdpyinfo >/dev/null 2>&1 || { echo "display $DISP not up"; exit 2; }

# clear any installed-emu (comm=emu) already on THIS display; leave gdb's o.emu
# and emus on other displays alone.
for p in $(pgrep -x emu); do
	d=$(tr '\0' '\n' </proc/$p/environ 2>/dev/null | sed -n 's/^DISPLAY=//p')
	[ "$d" = "$DISP" ] && { echo "killing existing emu $p on $DISP"; kill -9 "$p" 2>/dev/null; }
done
sleep 1

i=0
while [ "$i" -lt "$MAX" ]; do
	i=$((i+1))
	: > "$LOG"
	before=$(pgrep -x emu | sort)
	setsid sh -c "ulimit -c unlimited; tail -f /dev/null | EMUPOOLPARANOID=1 EMUCRASH=1 DISPLAY=$DISP \
		'$EMU' -r'$ROOT' -g$GEOM wm/wm /dis/sh.dis \
		-c 'memfs /tmp; charon $URL'" >>"$LOG" 2>&1 &
	# identify the new emu pid, then wait for the arming line (printed early in boot)
	pid=""; bit=""; j=0
	while [ "$j" -lt 30 ]; do
		sleep 0.5; j=$((j+1))
		[ -z "$pid" ] && pid=$(comm -13 <(echo "$before") <(pgrep -x emu | sort) | head -1)
		bit=$(sed -n 's/.*arming pool main .* bit36=\([01]\).*/\1/p' "$LOG" | head -1)
		[ -n "$bit" ] && break
	done
	if [ "$bit" = 1 ]; then
		echo
		echo "=== ARMED on roll $i (bit36=1) -- emu pid $pid on $DISP ==="
		# the initial heavy render is intermittent: it may self-trip the bug, or
		# render clean and sit waiting. Watch briefly to find out which.
		k=0
		while [ "$k" -lt 16 ]; do
			grep -q 'POOLPARANOID\[' "$LOG" && break
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.5; k=$((k+1))
		done
		if grep -q 'POOLPARANOID\[' "$LOG"; then
			echo ">>> SELF-TRIPPED on render -- captured without driving:"
			grep 'POOLPARANOID\[' "$LOG" | head -3
			echo "(emu aborted; core in /tmp/inferno-cores if any.) Re-run me for a"
			echo "fresh armed instance to drive, or we analyze this hit."
			exit 0
		fi
		echo "page: $URL rendered CLEAN -- emu pid $pid is UP and waiting on $DISP."
		echo "DRIVE it (VNC $DISP): scroll, click links, reload, resize, then CLOSE"
		echo "the window -- until it aborts with a 'POOLPARANOID[...]' line."
		echo "watch/copy:  tail -f $LOG"
		echo "tell me what you did right before it crashed (that bisects the writer)."
		exit 0
	fi
	echo "roll $i: bit36=${bit:-?} unarmed -- killing emu ${pid:-?}"
	[ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
	sleep 0.5
done
echo "no arming in $MAX rolls (unlucky ASLR streak) -- just re-run me"
exit 1
