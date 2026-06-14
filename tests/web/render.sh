#!/usr/bin/env bash
#
# render.sh - launch live Charon against a URL and screenshot it.
#
# The logic suites (run.sh) prove the CSS/DOM *engine* in isolation; this proves
# the actual *paint*.  It boots the graphical emu under wm/wm running Charon
# pointed at a URL, lets it load, and grabs a PNG of the framebuffer.  By default
# it renders on the shared VNC display (:3) so a human can co-watch on :5903.
#
# Usage:  tests/web/render.sh [URL] [outpng]
#   URL     default https://nicecrew.digital
#   outpng  default /tmp/charon-render.png
#
# Env knobs:
#   DISP=:3        X display to render on (must already have an Xvfb)
#   GEOM=1280x800  emu screen geometry
#   LOADSECS=25    seconds to wait for the page to load before the screenshot
#   KEEP=1         leave emu running after the shot (re-screenshot with import)
#
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
case "$(uname -m)" in aarch64|arm64) ARCH=aarch64;; x86_64|amd64) ARCH=amd64;; *) ARCH=$(uname -m);; esac
EMU="$ROOT/Linux/$ARCH/bin/emu"

URL=${1:-https://nicecrew.digital}
OUT=${2:-/tmp/charon-render.png}
DISP=${DISP:-:3}
GEOM=${GEOM:-1280x800}
LOADSECS=${LOADSECS:-25}
KEEP=${KEEP:-1}
LOG=/tmp/charon-render.log

[ -x "$EMU" ] || { echo "no graphical emu at $EMU" >&2; exit 2; }

# reap any prior render emu.  The marker is on the command line (wm/wm
# /dis/charon.dis ...) so pkill -f matches it; never touches a foreign emu/wm.
PIDF=/tmp/charon-render.pid
[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
pkill -f 'wm/wm /dis/charon.dis' 2>/dev/null
rm -f "$LOG"

echo "[render] launching Charon -> $URL on $DISP ($GEOM)" >&2
# CARGS: extra Charon options inserted before the URL (e.g. CARGS="dbg=dw").
( DISPLAY="$DISP" EMUCRASH=1 \
  "$EMU" -r"$ROOT" -g"$GEOM" wm/wm /dis/charon.dis ${CARGS:-} "$URL" >"$LOG" 2>&1 ) &
EMU_PID=$!
echo "$EMU_PID" > "$PIDF"
echo "[render] emu pid=$EMU_PID; waiting ${LOADSECS}s for load" >&2

# wait for load, but bail early if emu dies
for i in $(seq 1 "$LOADSECS"); do
	kill -0 "$EMU_PID" 2>/dev/null || { echo "[render] emu exited early" >&2; cat "$LOG" >&2; exit 4; }
	sleep 1
done

DISPLAY="$DISP" import -window root "$OUT" 2>/dev/null && echo "[render] wrote $OUT" >&2
echo "[render] --- emu log tail ---" >&2
tail -20 "$LOG" >&2

if [ "$KEEP" != 1 ]; then
	kill "$EMU_PID" 2>/dev/null
fi
echo "$OUT"
