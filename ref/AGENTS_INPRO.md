# In-Progress — current work, deferred items, and ideas (durable LP64/dual-ABI reference is now AGENTS_DUALABI.md)

This is the **live checklist**: what we are working on right now, what is parked,
and a scratchpad for ideas/plans before they become work. Keep it brief — when an
item grows real detail, write that detail in the subsystem doc it belongs to
(`AGENTS_DUALABI.md`, `AGENTS_CHARON.md`, `AGENTS_JIT.md`, …) and leave a one-line
pointer here.

> The big LP64/dual-ABI port writeup that used to live in this file is now the
> durable reference **`AGENTS_DUALABI.md`** (design, every fix, the `tptr` bug
> class, the test harnesses, deferred items, the open heap bug, amd64 glue). The
> narrative retrospective is `../LP64_NOTES.md`. This file is only the "what's
> active" view.

## Active

- [ ] **Charon form controls** — full-width dark-themed search input (CSS-themed
      `<input>`); part of the ongoing Charon modern-web / CSS-rendering work
      (`AGENTS_CHARON.md`, memory `charon-css-engine`, `charon-modernization`).
- [ ] **Charon HTTPS via mbedTLS** — vendor mbedTLS, add the emu `$Tls`/devtls glue,
      rewire `charon/http.b` (decision + passing spike in memory `charon-tls-mbedtls`).

## Parked / deferred

- [ ] **Idle-Charon heap corruption** (poolcheck abort on window close) —
      characterised, not root-caused. The bit-36 stray-free-tree-pointer bug.
      Detail: `AGENTS_DUALABI.md` §"Open runtime bug" + memory
      `charon-close-heap-corruption`. Next: static hunt for the `1<<36` /
      `-0x1000000000` pointer-arith site, or mine a fresh core.
- [ ] **Off-boot-path LP64 items** — `asm.c` `-S` `Tcasec` listing; `devprog.c`/
      `devprof.c` pointer↔text casts. Listing/debug only. `AGENTS_DUALABI.md`
      §"Deferred LP64 items".
- [ ] **amd64 (x86-64) bring-up** — glue is in-tree but UNBUILT/UNTESTED; needs a
      real build + test pass and the FP/MXCSR checks. `AGENTS_DUALABI.md`
      §"Second LP64 target".
- [ ] **AArch64 JIT** — `libinterp/comp-aarch64.c` is a working but off-by-default
      LP64 JIT (`emu -c1`); remaining ops punted. `AGENTS_JIT.md`,
      `AGENTS_DUALABI.md` §"Stubbed / disabled".
- [ ] **Pretty-JSON renderer** as an Inferno filter (idea, unscheduled).

## Ideas / plans (scratchpad)

_When you have an idea or a plan, jot it here; promote it to Active when it starts._
