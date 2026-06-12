# In-Progress — current work, deferred items, and ideas (durable LP64/dual-ABI reference is now ON_C_IN_DIS.md)

This is the **live checklist**: what we are working on right now, what is parked,
and a scratchpad for ideas/plans before they become work. Keep it brief — when an
item grows real detail, write that detail in the subsystem doc it belongs to
(`ON_C_IN_DIS.md`, `ON_CHARON.md`, `ON_JIT.md`, …) and leave a one-line
pointer here.

> The big LP64/dual-ABI port writeup that used to live in this file is now the
> durable reference **`ON_C_IN_DIS.md`** (design, every fix, the `tptr` bug
> class, the test harnesses, deferred items, the open heap bug, amd64 glue). This
> file is only the "what's active" view.

> **Dis model (2026-06-10):** `master` commits to **LP64** (Limbo `int` = 32 bits
> on every host). The **ILP64** experiment (Limbo `int` == pointer == 8) is parked
> on the **`ilp64` branch**, not master. Rationale + comparison tables:
> **`ON_C_IN_DIS.md`**. ABI-neutral work is kept in sync across both branches;
> only the `IBY2WD`=8-vs-4 delta is branch-specific.

## Active

- [ ] **Charon form controls** — full-width dark-themed search input (CSS-themed
      `<input>`); part of the ongoing Charon modern-web / CSS-rendering work
      (`ON_CHARON.md`, memory `charon-css-engine`, `charon-modernization`).

## Recently landed (move detail into the subsystem doc, then drop)

- [x] **Portability generalization + cross-ABI canaries** — `tests/lp64` →
      `tests/dis` (the suite was never LP64-specific; check-cell grammar is now
      `dis/<conf>/<runmode>`); the native-kernel make machinery hoisted into
      `os/native.mk` (arch files like `os/aarch64/Makefile` are ~10 lines);
      `tests/kernel` is board-agnostic (`HWTARG=` + per-board
      `os/boards/<board>/qemu.json`, check cell `kernel/<board>`); and
      executable 32-bit/big-endian canaries: `tests/cunit/cross.sh arm|m68k`
      cross-builds the portable C libs (Plan 9 object letters `*.5`/`*.2`, no
      collision with host `*.o`) and runs the cunit sections under qemu-user
      (`cunit/<objtype>` check cells). Detail: `tests/cunit/README.md`.
- [x] **Native aarch64 kernel: full service parity + board factoring** — boots
      qemu -M virt to the complete wm desktop with JIT, crypto builtins,
      networking (os/ip + virtio-net, ndb/cs+dns work out of the box),
      persistent storage (devsd + virtio-blk + kfs), kernel TLS (devtls +
      freestanding mbedTLS, Mozilla CA bundle baked), import/export verified
      both directions against hosted emu. Build factored into `os/aarch64/`
      (arch core) + `os/drivers/` + `os/boards/<board>/`:
      `make HWTARG=virt64 USERSPACE=full|headless`. Detail:
      `os/boards/virt64/README.md`; porting taxonomy: `ON_PORTING.md`.
- [x] **Modern TLS via mbedTLS** — DONE on master: vendored mbedTLS 3.6.2
      (`libmbedtls/`), the `#T` devtls device (`emu/port/devtls.c`, TLS 1.2/1.3),
      `dial->pushtls`/`dialtls`, and Charon's https path rewired off SSL3. Detail:
      `ON_NETWORK.md` §"Modern TLS". Was the old "Charon HTTPS via mbedTLS"
      active item.

## Parked / deferred

- [ ] **Native-kernel scheduler lockloop (flaky)** — the `kernel/virt64` check
      cell can fail on the dns/tls tests: panic `lockloop` with `ready()`'s
      `lock(runq)` (os/port/proc.c:119) as both holder and spinner, JIT
      `rmcall` in the trace, triggered by webgrab's TCP path. Timing-dependent
      (fails in streaks, passes on rerun); bisect shows it predates the
      2026-06-12 build factoring. Suspects: an interrupt path doing `wakeup()`
      outside splhi coverage, or the JIT entering the scheduler unmasked.
      Start by making taslock's lockloop report dump the holder's trace.
- [ ] **Idle-Charon heap corruption** (poolcheck abort on window close) —
      characterised, not root-caused. The bit-36 stray-free-tree-pointer bug.
      Detail: `ON_C_IN_DIS.md` §"Open runtime bug" + memory
      `charon-close-heap-corruption`. Next: static hunt for the `1<<36` /
      `-0x1000000000` pointer-arith site, or mine a fresh core.
- [ ] **Off-boot-path LP64 items** — `asm.c` `-S` `Tcasec` listing; `devprog.c`/
      `devprof.c` pointer↔text casts. Listing/debug only. `ON_C_IN_DIS.md`
      §"Deferred LP64 items".
- [ ] **amd64 (x86-64) bring-up** — glue is in-tree but UNBUILT/UNTESTED; needs a
      real build + test pass and the FP/MXCSR checks. `ON_C_IN_DIS.md`
      §"Second LP64 target".
- [ ] **AArch64 JIT** — `libinterp/comp-aarch64.c` is a working but off-by-default
      LP64 JIT (`emu -c1`); remaining ops punted. `ON_JIT.md`,
      `ON_C_IN_DIS.md` §"Stubbed / disabled".
- [ ] **Pretty-JSON renderer** as an Inferno filter (idea, unscheduled).
- [ ] **BPI-R4 hardware bring-up** (future work; higher-level work first) —
      first real-hardware board for the native kernel: Banana Pi BPI-R4
      (MediaTek MT7988A). Milestone 1 = TFTP netboot → serial sh (Image
      header + board files + uart-16550 + gic-v3); then MSDC storage,
      mtk_eth, namespace-imported display / Limbo VNC export (no display
      hardware on the board). Recipe + cost table: `ON_PORTING.md` Part II;
      memory `bpi-r4-target`.

## Ideas / plans (scratchpad)

_When you have an idea or a plan, jot it here; promote it to Active when it starts._
