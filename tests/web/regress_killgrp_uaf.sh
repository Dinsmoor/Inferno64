#!/bin/sh
# Regression guard for the killgrp() proc-group use-after-free -- the long-hunted
# bit-36 free-tree heap corruption (root cause + fix: emu/port/dis.c; see
# docs/ON_EMU_DEBUG.md "LIMBRULFENCEMEMSIZE" and the charon-close notes).
#
# How it guards deterministically: LIMBRULFENCEMEMSIZE=128 routes the 128-byte
# pool class (the proc-group block) through the electric-fence arena, so if the
# UAF ever returns, charon's per-navigation teardown faults SYNCHRONOUSLY -- no
# ASLR "arming" lottery needed (the bug was only *visible* ~50% of runs without
# the fence). probe_mbounce.html just meta-refresh-bounces, firing killgrp on
# every navigation. PASS = it bounces clean under the fence for the window.
#
# Reuses tests/dis/scenario.sh (headless Xvfb + crash detection). Exit codes are
# scenario.sh's: 0 CLEAN(pass), 4 CRASH(UAF regressed), 3 HANG, 2 setup error.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export LIMBRULFENCEMEMSIZE=128
RUN_SECS=${RUN_SECS:-30} ASLR=${ASLR:-off} \
	exec "$ROOT/tests/dis/scenario.sh" \
		'charon file:///tests/web/fixtures/probe_mbounce.html'
