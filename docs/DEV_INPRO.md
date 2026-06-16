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
- [ ] **Theme the userspace app suite** — mostly DONE (commit `5ec5e49e`). The
      enabling helper `tkclient->themecolour(top, key)` (wraps libtk `theme get`)
      landed, and the offenders were fixed with two patterns: drop explicit
      `-bg`/`-fg` so `theme reapply` re-colours them; and for what reapply can not
      reach (`-state disabled` text, canvas items, per-tag tables) re-derive from
      the live theme on the `"theme"` ctl push. Fixed: `wm/toolbar` (Log),
      `wm/bible`, `wm/pleromussy`, `wm/sh`, `wm/man`, `wm/memory`, `wm/ftree`
      (verified dark on the scenario harness; ftree has a boot-race — see below).
      **Remaining:** (1) `wmclient`-only apps (`wm/clock`, `acme/gui`,
      `wm/drawmux/dmwm`) still never get the push — needs the verb in `wmclient`
      or a tkclient conversion; (2) **`wm/ftree` boot-race** — it builds its tree
      and joins before the desktop theme settles, missing the on-join push, so a
      cold boot-launch comes up light (a normal launch onto an already-themed
      desktop is born dark); the real fix is wm-side (re-push curtheme once
      resolved). `ON_THEMING.md` §"Planned: theming the app suite".
- [ ] **Charon: pass the desktop theme to web pages** (idea, unstarted) — expose
      the live palette/dark-mode to CSS (`prefers-color-scheme`) with an override,
      so sites render in the user's theme. The big one; touches the CSS engine.
- [ ] **wm/ftree → proper file manager** (idea) — ftree's canvas treeview is
      ad-hoc; replace with the `Tkwidgets` Tree megawidget (`tk-extensions`) and
      build a real file manager. Larger task, separate from the theming fix above.

## Recently landed (move detail into the subsystem doc, then drop)

_Empty — landed work whose detail has been moved: portability generalization +
cross-ABI canaries → `tests/cunit/README.md` + `ON_TESTING.md`; native aarch64
kernel → `os/boards/virt64/README.md` + `ON_PORTING.md`; modern TLS →
`ON_NETWORK.md`._

## Parked / deferred

- [x] **Native-kernel scheduler lockloop** — RESOLVED (Job 1, 2026-06-15). The
      lockloop has one precondition: a synchronous CPU fault (a wild kernel
      pointer) taken while a spinlock is held — `splhi` does not mask synchronous
      aborts, so the fault reaches `disfault()`, whose `error()/longjmp` abandons
      the lock, and the next `lock()` spins. Two things close it: (1) the root
      cause — Dis-heap corruption from the array-of-channels alt LP64 offset bug —
      is fixed in `libinterp/alt.c` (`altvaloff`, commit d4b74d3e; see memory
      `array-alt-lp64-misalign`); (2) the PARANOID `nlocks` guard
      (`os/aarch64/trap.c:171`, commit c984b1de) makes the precondition a
      **deterministic panic at the fault site** — a fault with locks held can no
      longer become a silent lockloop, so a surviving bug announces itself on the
      first occurrence rather than needing a timing window. ~20 PARANOID
      full-suite runs (this audit + prior) show zero `nlocks` panics and zero
      lockloops. Residual `kernel/virt64` flakes are network-layer timing only
      (the dns/tls crypto-fetch windows, widened in `ktests.py` for the slow
      TCG+PARANOID path), not kernel faults.
- [ ] **Remove the `nlocks` fail-fast guard from PARANOID builds** (followup;
      added 2026-06-15) — `os/aarch64/faultarm64` panics on a fault taken with
      spinlocks held (`up->nlocks`), gated behind `#if POOLPARANOID` so
      `make PARANOID=0` release images already drop it. It was the instrument
      that localized the array-alt wild-pointer bug and is a cheap keeper while
      LP64/aarch64 kernel C keeps landing. **Delete it outright** (the
      `up->nlocks` accounting in `os/port/taslock.c`, the field in `portdat.h`,
      and the trap.c check) once the wild-pointer/use-after-free class is closed
      out (cf. `aarch64-unlock-release-barrier`, `charon-close-heap-corruption`).
- [ ] **Idle-Charon heap corruption** (poolcheck abort on window close) —
      characterised, not root-caused. The bit-36 stray-free-tree-pointer bug.
      Detail: `ON_C_IN_DIS.md` §"Open runtime bug" + memory
      `charon-close-heap-corruption`. Next: static hunt for the `1<<36` /
      `-0x1000000000` pointer-arith site, or mine a fresh core.
- [ ] **Off-boot-path LP64 items** — `asm.c` `-S` `Tcasec` listing; `devprog.c`/
      `devprof.c` pointer↔text casts. Listing/debug only. `ON_C_IN_DIS.md`
      §"Deferred LP64 items".
- [x] **amd64 (x86-64) JIT** — `libinterp/comp-amd64.c` is a working LP64 x86-64
      JIT (`emu -c1`; `-c0` unaffected), mirroring `comp-aarch64.c`'s width split
      and punt set. Native SSE2 FP + the integer mul/div/mod group + long/logical
      shifts are compiled (the fixed-point/`IEXP`/`IADDC` ops still interpret).
      Bit-identity is gated by the `crossjit` make-check cell (qemu-x86_64 cross).
      `das-amd64.c` is a real disassembler now (`emu -c5`). Internals + recipe:
      `ON_JIT.md` §"amd64 (x86-64) JIT Implementation". Nothing outstanding.
- [ ] **AArch64 JIT** — `libinterp/comp-aarch64.c` is a working but off-by-default
      LP64 JIT (`emu -c1`); remaining ops punted. `ON_JIT.md`,
      `ON_C_IN_DIS.md` §"Stubbed / disabled".
- [ ] **Native driver stubs/shims follow-up** — the `os/drivers` pool (pci,
      ether-rtl8139, sd-nvme, sd-ahci, sd-scsi, devusb/usbxhci/usbxhcipci) is a
      first pass proven only against `qemu -M virt`. Per-driver tables of what is
      stubbed/simplified and what full hardware support needs:
      `DEV_INPRO_DRIVERS.md`. Headline items: AHCI is fully polled, USB has no
      enumerator/HID driver yet, and MSI/MSI-X needs an ITS. (Done: the high-ECAM
      map — default `qemu -M virt` runs without `highmem-ecam=off`; and GICv3 —
      `make ... GIC=v3` boots on `gic-version=3`, single-cpu.)
- [ ] **Pretty-JSON renderer** as an Inferno filter (idea, unscheduled).
- [ ] **wm launcher: auto-refresh the program list** (idea, unscheduled) — the
      Start menu is built once from `/lib/wmsetup` at wm start (`appl/wm/toolbar.b`,
      the `menu` builtin), so adding an app means re-running `/lib/wmsetup` by
      hand. Make the menu reload on click when stale — e.g. stat `/lib/wmsetup`
      (and `$home/lib/wmsetup`) and, if the mtime changed since the last build,
      `delmenu`/re-run before posting. Watch the menu-rebuild cost and the
      `wmrun`/builtin re-registration.
- [ ] **BPI-R4 hardware bring-up** (future work; higher-level work first) —
      first real-hardware board for the native kernel: Banana Pi BPI-R4
      (MediaTek MT7988A). Milestone 1 = TFTP netboot → serial sh (Image
      header + board files + uart-16550 + gic-v3); then MSDC storage,
      mtk_eth, namespace-imported display / Limbo VNC export (no display
      hardware on the board). Recipe + cost table: `ON_PORTING.md` Part II;
      memory `bpi-r4-target`.

## Ideas / plans (scratchpad)

_When you have an idea or a plan, jot it here; promote it to Active when it starts._
