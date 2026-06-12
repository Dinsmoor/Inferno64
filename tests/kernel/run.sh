#!/usr/bin/env bash
#
# run.sh - end-to-end suite for native kernels, one board at a time.
#
# HWTARG picks the board (default virt64); the board's
# os/boards/<board>/qemu.json profile says which qemu binary and machine
# to boot.  Boots the built image once per test and drives the serial
# console: boot, networking, DNS, kfs persistence, TLS verification,
# import/export against a hosted emu, and a QMP-screendump check that
# the wm desktop actually renders.  TAP output (see ktests.py).
#
# Usage:  tests/kernel/run.sh [name...]     # substring-match test names
#   e.g.  tests/kernel/run.sh               # everything (~4 min)
#         tests/kernel/run.sh dns tls       # just those
#         HWTARG=bpi-r4 tests/kernel/run.sh # another board (needs its qemu.json)
#
# Knobs:  HWTARG=<board>  KERNEL=/path/to/i<board>.elf  EMU=/path/to/hosted/emu
#
# The image is rebuilt first if missing or stale (cheap: the kernel
# build is ~20s clean, no-op when current).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HWTARG="${HWTARG:-virt64}"
export HWTARG

PROFILE="$ROOT/os/boards/$HWTARG/qemu.json"
[ -f "$PROFILE" ] || {
	echo "1..0 # SKIP board $HWTARG has no qemu test profile ($PROFILE)"; exit 0; }

ARCH=$(python3 -c "import json;print(json.load(open('$PROFILE'))['arch'])")
QEMU=$(python3 -c "import json;print(json.load(open('$PROFILE'))['qemu'])")

command -v "$QEMU" >/dev/null || {
	echo "Bail out! $QEMU not installed"; exit 1; }

# keep the image fresh — a stale kernel is a false verdict (the web
# suite learned this the hard way).  Parallelism comes from native.mk's
# default (-j nproc-1, the tree-wide formula).
( cd "$ROOT/os/$ARCH" && make --quiet HWTARG="$HWTARG" ) || {
	echo "Bail out! kernel build failed (cd os/$ARCH && make HWTARG=$HWTARG)"; exit 1; }

exec python3 "$HERE/ktests.py" "$@"
