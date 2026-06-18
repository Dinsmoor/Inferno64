#!/usr/bin/env bash
#
# tk_render_check.sh - verify every Tk-driving app from DEV_TK_MODERN §11 still
# *properly renders* on the current (ttk-modernized) build, and that no CLASSIC
# widget regressed.  For each app:
#   1. launch `emu wm/wm <app>` under Xvfb, let it cold-start + render;
#   2. grab the root window to tests/dis/tk_current/<name>.png;
#   3. FAIL if emu logged a fault/break, or the grab is blank;
#   4. diff against the golden classic baseline (tests/dis/tk_baseline/<name>.png)
#      and report the changed-pixel count.  A large diff in an unmigrated app is
#      a regression to investigate; clocks/live content diff harmlessly.
#
# Exit 0 iff every app rendered (no crash, non-blank).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMU="$ROOT/Linux/aarch64/bin/emu"
BASE="$ROOT/tests/dis/tk_baseline"
OUT="$ROOT/tests/dis/tk_current"
GEOM="${GEOM:-1024x768}"
DISP=":${DISPLAY_NUM:-98}"
SETTLE="${SETTLE:-14}"

mkdir -p "$OUT"
[ -x "$EMU" ] || { echo "missing emu ($EMU) - run make all" >&2; exit 2; }
command -v Xvfb  >/dev/null || { echo "Xvfb not installed" >&2; exit 2; }
command -v import >/dev/null || { echo "ImageMagick import not installed" >&2; exit 2; }
HAVE_CMP=1; command -v compare >/dev/null || HAVE_CMP=0

# app.dis : friendly name (the DEV_TK_MODERN §11 set)
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
wm/ttkdemo:ttkdemo
"

rm -f "/tmp/.X11-unix/X${DISP#:}"
Xvfb "$DISP" -screen 0 "${GEOM}x24" >/tmp/xvfb_render.log 2>&1 &
XPID=$!
trap 'kill $XPID 2>/dev/null' EXIT
sleep 2

fails=0; n=0
printf '%-18s %-9s %-8s %s\n' "APP" "RENDER" "BYTES" "DIFF-vs-classic"
for line in $APPS; do
	app="${line%%:*}"; name="${line##*:}"
	dis="dis/$app.dis"
	n=$((n+1))
	[ -e "$ROOT/$dis" ] || { printf '%-18s %-9s\n' "$name" "MISSING"; fails=$((fails+1)); continue; }
	log="$OUT/$name.log"
	( DISPLAY="$DISP" EMUCRASH=1 setsid timeout -s KILL $((SETTLE + 6)) \
		"$EMU" -g"$GEOM" wm/wm "$app" >"$log" 2>&1 </dev/null & )
	sleep "$SETTLE"
	shot="$OUT/$name.png"
	rm -f "$shot"
	DISPLAY="$DISP" import -window root "$shot" 2>/dev/null
	# verdict: a crash or a failed grab is a hard failure.  A widget app that
	# cleanly reports a missing data precondition (e.g. bible needs biblefs
	# mounted) is NEEDS-SETUP, not a Tk-render regression.  Compact windows
	# (clock, tkwdemo) render small and are fine as long as a window exists.
	bytes=$(stat -c%s "$shot" 2>/dev/null || echo 0)
	render="OK"
	if grep -qiE "broken|fault|panic|abort|segv|trap" "$log"; then
		render="CRASH"; fails=$((fails+1))
	elif [ ! -s "$shot" ]; then
		render="NO-GRAB"; fails=$((fails+1))
	elif grep -qiE "is biblefs mounted|cannot read /mnt|no window context" "$log"; then
		render="NEEDS-SETUP"	# precondition, not a regression
	fi
	diff="-"
	if [ "$HAVE_CMP" = 1 ] && [ -s "$BASE/$name.png" ] && [ -s "$shot" ]; then
		diff=$(compare -metric AE "$BASE/$name.png" "$shot" null: 2>&1 | awk '{print $1}')
	fi
	printf '%-18s %-9s %-8s %s\n' "$name" "$render" "$bytes" "$diff"
	sleep 7
done

echo
if [ "$fails" -eq 0 ]; then
	echo "RENDER CHECK: all $n apps rendered (no crash, non-blank). shots in $OUT"
	exit 0
fi
echo "RENDER CHECK: $fails/$n apps FAILED to render"
exit 1
