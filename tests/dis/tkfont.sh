#!/usr/bin/env bash
#
# tkfont.sh - compile and run the Tk `after' functional test headlessly.
#
# Tk toplevels need a real display, so this spins up its own Xvfb, runs the
# test under the graphical emu, and turns the emitted TAP into an exit status
# (0 = all ok, 1 = a failure, 2 = setup/compile error).
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "$(uname -m)" in aarch64|arm64) ARCH=aarch64;; x86_64|amd64) ARCH=amd64;; *) ARCH=$(uname -m);; esac
EMU="$ROOT/Linux/$ARCH/bin/emu"
LIMBO="$ROOT/Linux/$ARCH/bin/limbo"
SRC="$ROOT/tests/dis/tkfont.b"
DIS="$ROOT/dis/tests/tkfont.dis"
DISP=":${DISPLAY_NUM:-91}"

[ -x "$EMU" ]   || { echo "missing graphical emu ($EMU) - run make all" >&2; exit 2; }
[ -x "$LIMBO" ] || { echo "missing limbo ($LIMBO)" >&2; exit 2; }
command -v Xvfb >/dev/null || { echo "Xvfb not installed" >&2; exit 2; }

mkdir -p "$ROOT/dis/tests"
"$LIMBO" -I "$ROOT/module" -o "$DIS" "$SRC" || { echo "compile failed" >&2; exit 2; }

rm -f "/tmp/.X11-unix/X${DISP#:}"
Xvfb "$DISP" -screen 0 640x480x24 >/tmp/xvfb_tkfont.log 2>&1 &
XPID=$!
trap 'kill $XPID 2>/dev/null' EXIT
sleep 1

OUT=$(DISPLAY=$DISP EMUCRASH=1 timeout 40 "$EMU" -r"$ROOT" -g320x240 /dis/tests/tkfont.dis 2>&1)
echo "$OUT"

if echo "$OUT" | grep -q "^not ok"; then exit 1; fi
echo "$OUT" | grep -q "^1\.\." || { echo "no TAP plan emitted - test did not complete" >&2; exit 1; }
exit 0
