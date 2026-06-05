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
| charon (browser) | ✅ | renders a local HTML page at 24-bit (H1 heading, bold/italic inline, bulleted list, toolbar + URL bar), no crash. UTF-8 chars mojibake (`café`→`cafÃ©`) — that's the separate `charon-modernization` branch's UTF-8 work, not an LP64 defect on this branch |
| sh (shell) | ✅ | echo, pipes, `` `{} `` cmd-substitution, multi-cmd scripts |
| filesystem | ✅ | `ls /` (host tree via `-r`), `cat`, `/dev/user`→tyler, `/dev/sysname`, `pwd` |
| process mgmt | ✅ | `ps` lists procs with state/mem (e.g. `1 ready Ps[$Sys]`) |
| namespace | ✅ | `ns` shows full bind/mount: `#U` hostfs, `#c` cons, `#p` prog, `#d` fd, `#I` ip, `#e` env |
| networking (IP/styx) | ✅ | `/net` stack live (arp/tcp/udp/ndb); `cat /net/tcp/clone` allocates a conn; emu reaches external hosts (TCP+UDP dial to 8.8.8.8/1.1.1.1); + headless 30_styxnet TCP loopback + 9P pass |
| DNS resolution | 🟡 | network + raw/headers-mode DNS-over-UDP **work** (resolves example.com end-to-end); root-caused the resolver hang to a **scheduler VM-token deadlock** in `acquire()` after the host-resolver bridge's `release()`+`getaddrinfo`+`acquire()` (BUG-3, open — scheduler fix held for review) |
| plumber | ✅ | **was failing for non-"inferno" users; fixed** (BUG-2). Desktop plumber now runs (2 procs) with all ports (`/chan/plumb.{edit,web,view,dir,man,auplay,input}`) |
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

### BUG-2 — plumber fails to start for non-"inferno" users  ✅ FIXED
- **Symptom:** acme/charon log `can't read /chan/plumb.edit`; no plumber, no
  `/chan/plumb.*`. The desktop's `wmsetup` runs `plumber`, but it exited.
- **Root cause:** `Plumbing.init` (appl/lib/plumbing.b) tried `/usr/$user/plumbing`
  then `/usr/$user/lib/plumbing` and errored if neither existed — and the distro
  only ships `/usr/inferno/lib/plumbing`. Any other user (e.g. `tyler`) → no rules
  → plumber dies.
- **Fix (commit `4141ddc7`, cherry-picked to master `112158da`):** add a
  system-wide default `/lib/plumbing` and fall back to it. Per-user files still
  win. Rebuild `appl/lib/plumbing.b` → `/dis/lib/plumbing.dis`.
- **Verified:** desktop plumber runs (2 Plumber procs), all ports created; the
  `plumb` command connects and sends without error. (Full message-payload
  round-trip read was inconclusive due to test-harness buffering, but the daemon
  is functional and acme's `plumb.edit` now exists.)

### BUG-3 — DNS hangs in a scheduler VM-token deadlock (NOT getaddrinfo)  ❌ OPEN (root-caused)
- **Symptom:** `ndb/dnsquery`/`ndb/csquery` never return; charon/dial can't
  resolve names.
- **Every network/DNS/srv primitive is PROVEN working** (so NOT a port/LP64/
  network/file2chan bug): TCP+UDP dial to external hosts (`dialtest`); connected-
  UDP DNS to 8.8.8.8 returns a valid answer (`udptest`); **headers-mode UDP** —
  the exact mechanism dns uses — resolves example.com end-to-end (`hdrudp`,
  `ancount=2`); `file2chan` data round-trip (`f2cecho` `ROUNDTRIP-OK`).
- **Root cause (gdb on the hung emu, ptrace_scope=0):** the dns query path goes
  `dnslookup → srv->iph2a` ("try host's map first"), a C builtin `Srv_iph2a`
  (`emu/port/srv.c`) that does `release()` (drop the VM token) → `getaddrinfo()`
  (the host resolver, which **completes fine**) → **`acquire()`** to re-take the
  token. The backtrace of the hung thread is `osblock ← acquire ← Srv_iph2a ←
  mcall ← xec ← vmachine` — it's **stuck forever in `acquire()`/`osblock()`
  (sem_wait) re-acquiring the VM token.** Live `isched` state: `idle=0` (token
  "taken") yet `runhd != nil` (a prog is **runnable**) and `vmq`+`idlevmq` have
  waiting procs — but **no thread is running `vmachine`**. That's a scheduler
  **VM-token hand-off / lost-token deadlock** in `release()`/`acquire()`
  (`emu/port/dis.c`), triggered by the `release`+blocking-host-call+`acquire`
  pattern. Same concurrency class as BUG-1 (the aarch64 barrier), distinct race.
- **Fix:** a careful scheduler-concurrency fix in `release()`/`acquire()`/the
  `creating`/`idle` token hand-off (high blast radius — must not be done blind).
  Held for review. `EMUWATCHDOG` detects this stall; `schedidlecheck` does not
  (it only checks `runhd==nil`, and here `runhd!=nil`).
- (Test programs `dialtest`/`udptest`/`hdrudp`/`f2cecho`/`srvtest` in `tests/lp64/_build/`.)

## Method notes

- Interactive input via `xdotool` into the Xvfb display (see `gui-test-xvfb`
  skill) for click/keystroke-driven features.
- Each feature: launch → screenshot/observe → exercise → record verdict +
  evidence path. Crash/hang ⇒ open a BUG-N entry, diagnose, fix, re-verify.
