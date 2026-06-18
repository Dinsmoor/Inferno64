#!/usr/bin/env bash
#
# tk_baseline_shots.sh - capture a clean "before" screenshot of each Tk-driving
# userspace app, as the golden correctness reference for the Tk/ttk
# modernization (docs/DEV_TK_MODERN.md).  A pixel change in a CLASSIC widget
# after modernization is a compatibility regression by definition; these shots
# are the baseline to diff against.
#
# Each app is launched the same way gui_sweep.sh does -- `emu -gWxH wm/wm <app>`
# under its own Xvfb -- then the root window is grabbed with ImageMagick import.
# One emu instance per app keeps shots clean and avoids cross-app interference.
#
# Output: tests/dis/tk_baseline/<app>.png
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMU="$ROOT/Linux/aarch64/bin/emu"
OUT="$ROOT/tests/dis/tk_baseline"
GEOM="${GEOM:-1024x768}"
DISP=":${DISPLAY_NUM:-97}"
SETTLE="${SETTLE:-15}"     # seconds to let emu cold-start + JIT + wm + app render

mkdir -p "$OUT"
[ -x "$EMU" ] || { echo "missing graphical emu ($EMU) - run make all" >&2; exit 2; }
command -v Xvfb  >/dev/null || { echo "Xvfb not installed" >&2; exit 2; }
command -v import >/dev/null || { echo "ImageMagick import not installed" >&2; exit 2; }

# app.dis : friendly name for the file
APPS="
wm/tkwdemo:tkwdemo
wm/sh:shell
acme:acme
wm/edit:edit
charon:charon
wm/pleromussy:pleromussy
wm/bible:bible
wm/man:man
wm/ftree:ftree
wm/deb:debugger
wm/rt:module-manager
wm/task:task-manager
wm/memory:memory-monitor
wm/about:about
wm/colors:colours
wm/date:clock
wm/vt:vt-terminal
wm/tetris:tetris
"

if ! xdpyinfo -display "$DISP" >/dev/null 2>&1; then
	Xvfb "$DISP" -screen 0 "${GEOM}x24" >/dev/null 2>&1 &
	XVFB_PID=$!
	sleep 2
else
	XVFB_PID=""
fi
trap '[ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null' EXIT

printf '%-22s %s\n' "APP" "RESULT"
for line in $APPS; do
	app="${line%%:*}"; name="${line##*:}"
	dis="dis/$app.dis"
	[ -e "$ROOT/$dis" ] || { printf '%-22s %s\n' "$name" "MISSING-DIS"; continue; }
	log="$OUT/$name.log"
	# launch this app over wm/wm; bound the life with timeout (no pkill -- it
	# would match other emu instances / this script).
	( DISPLAY="$DISP" setsid timeout -s KILL $((SETTLE + 6)) \
		"$EMU" -g"$GEOM" wm/wm "$app" >"$log" 2>&1 </dev/null & )
	sleep "$SETTLE"
	if DISPLAY="$DISP" import -window root "$OUT/$name.png" 2>/dev/null; then
		printf '%-22s %s\n' "$name" "shot -> $name.png"
	else
		printf '%-22s %s\n' "$name" "GRAB-FAILED"
	fi
	# let this instance's timeout reap it before the next launch
	sleep 7
done

echo "baseline shots in $OUT"
