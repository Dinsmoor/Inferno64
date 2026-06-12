#!/usr/bin/env bash
#
# run.sh - end-to-end suite for the native aarch64 kernel.
#
# Boots the built image (os/aarch64/ivirt64.elf) under qemu -M virt once
# per test and drives the serial console: boot, networking, DNS, kfs
# persistence, TLS verification, import/export against a hosted emu,
# and a QMP-screendump check that the wm desktop actually renders.
# TAP output (see ktests.py).
#
# Usage:  tests/kernel/run.sh [name...]     # substring-match test names
#   e.g.  tests/kernel/run.sh               # everything (~4 min)
#         tests/kernel/run.sh dns tls       # just those
#
# Knobs:  KERNEL=/path/to/i<board>.elf  EMU=/path/to/hosted/emu
#
# The image is rebuilt first if missing or stale (cheap: the kernel
# build is ~20s clean, no-op when current).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

command -v qemu-system-aarch64 >/dev/null || {
	echo "Bail out! qemu-system-aarch64 not installed"; exit 1; }

# keep the image fresh — a stale kernel is a false verdict (the web
# suite learned this the hard way)
( cd "$ROOT/os/aarch64" && make -j"$(nproc)" --quiet ) || {
	echo "Bail out! kernel build failed (cd os/aarch64 && make)"; exit 1; }

exec python3 "$HERE/ktests.py" "$@"
