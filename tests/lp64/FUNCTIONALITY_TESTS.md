# Inferno (LP64) userspace functionality tests

Living record of exercising Inferno OS **graphically and interactively** on the
dual-ABI LP64 port, feature by feature, fixing crashes/hangs as they surface.

- Harness: `tests/lp64/scenario.sh` (headless deterministic GUI runner, JSON
  verdict) and `tests/lp64/gui_sweep.sh` (compile + launch sweep). Diagnosis
  loop + host setup: the `inferno-autonomy` skill.
- Branch: `lp64-fault-observability`. **Fixes** are isolated, cherry-pickable
  commits (destined for master); observability/harness tooling stays on-branch.
- Repro convention: `DEPTH=24` (real depth; many LP64 faults are 24-bit only),
  and `ASLR=on` to *provoke* high-address truncation bugs (ASLR-off masks them).

Status legend: ✅ pass · ❌ fail (bug) · 🔧 fix in progress · ⏳ not yet tested ·
🟡 partial / caveat.

## Summary

| Area | Status | Notes |
|---|---|---|
| wm/wm desktop | ✅ | renders, taskbar, windows (16- & 24-bit) |
| wm/clock | ✅ | renders + runs (self-test) |
| acme (editor) | ✅ | **was crashing at 24-bit; fixed** (BUG-1). Fully interactive at 24-bit: renders tag/columns/dir-listing, opens files via button-3 (verified opening Makefile), no fault under xdotool input. Needs a writable /tmp (now default, below) |
| wm apps (20) | ✅ | gui_sweep launch @24-bit: about/bounce/clock/coffee/colors/collide/memory/polyhedra/reversi/snake/stopwatch/sweeper/task/tetris/mand/pen/view/edit/brutus/calendar all ok |
| charon (browser) | 🟡 | launches clean (gui_sweep); interactive browsing not yet exercised |
| sh (shell) | ✅ | echo, pipes, `` `{} `` cmd-substitution, multi-cmd scripts |
| filesystem | ✅ | `ls /` (host tree via `-r`), `cat`, `/dev/user`→tyler, `/dev/sysname`, `pwd` |
| process mgmt | ✅ | `ps` lists procs with state/mem (e.g. `1 ready Ps[$Sys]`) |
| namespace | ✅ | `ns` shows full bind/mount: `#U` hostfs, `#c` cons, `#p` prog, `#d` fd, `#I` ip, `#e` env |
| networking (dial/styx) | 🟡 | headless tests/lp64/30_styxnet pass (TCP loopback + 9P); GUI net apps untested |
| crypto / keyring | 🟡 | headless cunit + 20_crypto pass; GUI tools untested |

(The headless TAP suites in `tests/lp64/suites/` already cover VM/lang/concur/
crypto/styx/loader — see `tests/lp64/README.md`. This document is about the
**graphical/interactive** surface those suites never touch.)

## Findings / bugs

### BUG-1 — acme crashes at 24-bit (LP64 heap corruption)  🔧
- **Symptom:** acme over VNC at 24-bit depth crashes/freezes; 16-bit is clean.
- **Repro (on demand):** `ASLR=on DEPTH=24 tests/lp64/scenario.sh /dis/acme/acme.dis`
  → CRASH on first attempt, `EMUCRASH` core dropped. (ASLR-off masks it.)
- **Pinned (gdb MCP on the core):** SIGSEGV in `dopoolalloc` walking the pool
  free-tree on a non-canonical link `x3=0xf900067ff80106a0` (garbage high 16
  bits). Path `dopoolalloc←poolalloc←malloc←cnewc←srvwrite←…←Sys_fprint←mcall←
  xec←vmachine`. Fault addr `0x67ff80106a8` is **deterministic** (matches the
  original `String`/IRET observation). Victim ≠ culprit: a free-tree link was
  corrupted earlier.
- **Root cause (found):** **missing release barrier in `unlock()` on aarch64.**
  `emu/port/lock.c` `unlock()` is `coherence(); l->val = 0;`, but
  `emu/Linux/os.c` sets `coherence = nofence` (a no-op). `_tas()` (acquire) has
  proper `dmb ish` barriers, but the **release** side has none — so on aarch64's
  weakly-ordered memory a thread's critical-section writes (e.g. `pooladd`
  updating the free-tree `root`/links) can become visible to the next
  lock-acquirer *after* it sees the lock free. The acquirer then walks a **stale
  free tree → corruption** (`root` left pointing at an allocated block). Systemic
  (every `Lock`), but surfaces as rare, flaky, timing/layout-dependent corruption
  — which is why it's 24-bit/ASLR/contention-sensitive and masked by any rebuild
  or instrumentation. Matches the original "race or GC-interaction" guess.
- **Fix (DONE):** `emu/Linux/os.c` — on `LINUX_AARCH64`, point `coherence` at a
  real full barrier (`__sync_synchronize()` → `dmb ish`) instead of `nofence`.
  Pure addition of a memory barrier (release fence in `unlock()`); cannot change
  userspace semantics, only removes the race. x86 keeps `nofence` (TSO).
- **Validation:** TAP suites 178/178 (incl. 10_concur GC churn); cunit all pass;
  gui_sweep @24-bit 22/22 launch ok, 0 crashes; **interactive** acme @24-bit
  driven with xdotool keyboard input stayed alive with no fault/core. NOTE: a
  clean dynamic before/after on acme isn't possible — any rebuild perturbs layout
  and masks the flaky race (pristine rebuild was already 0/20), so the proof is
  the static correctness argument + zero userspace regressions. 32-bit ARM Linux
  emu has the same latent bug (its `_tas` has DMB but `coherence` is `nofence`);
  the fix could extend there if/when that target is exercised.

### Note: writable /tmp for GUI apps  ✅ (done) + plumber 🟡 (optional)
A bare `wm/wm /dis/acme/acme.dis` had no writable `/tmp`, so acme couldn't
create its scratch files. **Fixed in the harness:** `scenario.sh` now defaults
to `TMPFS=1`, mounting a fresh in-memory `/tmp` (`memfs /tmp`) under a wm shell
before the app — apps that need scratch space (acme, downloads) work like a real
desktop. (`TMPFS=0` keeps the bare direct-launch path for crash repro.) Recipe
for a manual run: `wm/wm /dis/sh.dis -c 'memfs /tmp; /dis/acme/acme.dis'`.
Remaining `can't read /chan/plumb.edit` is just the **plumber** not running —
only affects inter-window plumbing (right-click-to-open across windows still
works), not basic editing. `scripts/headless_vnc.sh`'s full desktop starts it.

## Method notes

- Interactive input via `xdotool` into the Xvfb display (see `gui-test-xvfb`
  skill) for click/keystroke-driven features.
- Each feature: launch → screenshot/observe → exercise → record verdict +
  evidence path. Crash/hang ⇒ open a BUG-N entry, diagnose, fix, re-verify.
