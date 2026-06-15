# LP64 VM/JIT follow-up jobs

Handoff worklist from the 2026-06-15 LP64 heap-corruption audit. Self-contained:
an agent picking this up needs no prior context beyond this file plus the named
sources. Jobs are ordered by priority. Mark done in `docs/DEV_INPRO.md`.

## Background (what happened, what's already done)

A real LP64 heap-corruption bug was found and fixed in the Dis VM: the
**array-of-channels `alt` receive** placed the received value at `ptr + 1`
(one `IBY2WD` = 4 bytes) when, under LP64, a pointer-bearing value is
pointer-aligned at `IBY2PTR` = 8. The value landed 4 bytes low → wild pointer →
heap free-tree corruption → nondeterministic segfault in emu ("open a file twice
→ crash") and, in the native aarch64 kernel, a scheduler **lockloop** (Lock
structs live in the corrupted heap, so a clobbered lock word spins `ready`/
`wakeup` forever).

**Fixed:** `libinterp/alt.c` now derives the value offset from the element
type's pointer map via `altvaloff()` (returns `IBY2PTR` if pointer-bearing, else
`IBY2WD`). Both placement sites (`altcomm`, `altunmark`) use it.

Commits already on master (local, **not pushed**):
- `d4b74d3e` — libinterp/alt: array-of-channels alt-receive LP64 offset fix
- `c984b1de` — os/port,aarch64: PARANOID-gated `nlocks` fault fail-fast guard
- `f2a07b66` — tests/kernel: network-cell hardening. Two parts: (a) a
  deterministic dns rewrite + impexp readiness poll — KEPT, genuine
  improvements; (b) an `@flaky` boot-retry crutch — REMOVED in `6be551ac`
  because it masked a real failure as green.
- `6be551ac` — tests/kernel: remove the `@flaky` crutch (a failure now reports
  `not ok` on the first boot). See Job 3.

**Audit result (six agents, read end-to-end, not grep):** the entire shared
LP64 hot path is **clean** apart from the alt.c anomaly already fixed —
`heap.c`, `gc.c`, `xec.c`, `runt.c`, `load.c`, `dis.c`, `raise.c`, `stack.c`,
`link.c`, `disops.c`, and the **aarch64 JIT** (`comp-aarch64.c`). The map-bit→
byte-offset conversion (the class-root) is uniformly `IBY2PTR`-scaled via
`WORD**` cursors and is guarded by `verifytype()`. The aarch64 JIT **punts**
`IALT`/`INBALT`/`ISEND`/`IRECV` to the interpreter, so the alt bug class cannot
recur there; its case tables mirror `limbo/dis.c` exactly. **`comp-amd64.c` on
master is a 34-line stub — there is no amd64 JIT on master** (see Job 2).

Conclusion: alt.c was the lone hand-rolled exception. If the kernel lockloop
survives the alt fix, it is **not** a shared-VM pointer-stride bug.

---

## Job 1 — Determine whether the aarch64 kernel lockloop is still alive (PRIORITY)

**Goal:** decide, on evidence, whether the `kernel/virt64` lockloop is dead
(killed by the alt.c fix) or still live, and if live, classify its real cause.

1. Clean build, JIT on: `make PARANOID=1` native aarch64 kernel for board
   `virt64`, full app root (the `kernel/virt64` make-check cell, `-c1`/JIT path).
   Ensure no stale objects — a stale pre-alt-fix kernel binary would invalidate
   the whole test (this exact staleness trap bit us before).
2. Run the full `tests/kernel` suite against `kernel/virt64` **in a loop, ~20–30
   iterations**, under realistic load (don't run it isolated and idle — the
   lockloop is load-correlated, surfaces under webgrab/dns/tls TCP churn). Record
   pass/fail and any panic/lockloop per iteration.
3. If **zero** lockloops across the run: the alt.c fix very likely closed it.
   Proceed to Job 3 (remove the `@flaky` crutch) and note the result in
   `docs/DEV_INPRO.md` (`native-kernel-lockloop-flake`).
4. If it **still loops**: capture the real trace, do NOT retry past it. It is
   not a shared-VM stride bug (that surface is audited clean). Classify against
   these candidates, in order of likelihood:
   - **Interrupt-vs-lock reentrancy** in the scheduler under IRQ-driven network
     load. The native kernel recently gained MSI/GICv3 IRQ-driven NICs
     (igbe/82563), AHCI, NVMe. A network IRQ that calls `wakeup()` on a Rendez
     while the runq lock is held, without `splhi`/`ilock` discipline, reenters
     the same lock → lockloop. Check `os/port` lock discipline vs the new
     `os/drivers` bottom-halves; check `splhi` coverage around runq operations.
   - **punt → interpreter handoff state** noted by the JIT audit
     (`comp-aarch64.c`): verify REG/Frame state consistency across a punt taken
     mid-`-c1` execution.
   - **native-PC truncation** flagged at `comp-aarch64.c:39-42` — confirm no
     64→32 PC narrowing on the JIT call/return path.
   - Re-confirm the killgrp UAF fix (emu `8b6027f0`) is fully present in the
     native kernel path too.
5. Tools: boot under qemu with the board's qemu profile; `EMUCRASH`/core
   equivalents; `/prog/*/status` + stack for the broken proc; the PARANOID
   `nlocks` fail-fast guard (commit `c984b1de`) will panic at the faulting site
   with lock count if a fault occurs with locks held — use it.

**Done when:** the lockloop is either proven dead (N clean loops, documented) or
root-caused to a specific non-stride cause with a fix or a precise bug write-up.

---

## Job 2 — Port the amd64 JIT from `ilp64` to master (LP64) — **DONE** (commit `79692575`)

`libinterp/comp-amd64.c` is a working LP64 x86-64 JIT, rebuilt around
`comp-aarch64.c`'s width discipline (not copied verbatim from `ilp64`, whose
`IBY2WD==IBY2PTR==8` assumption is wrong under LP64). Same native/punt split as
the aarch64 backend, plus FP and the mul/div/mod group punted in this first cut.
Cross-built and validated bit-identically against the interpreter under
qemu-x86_64. Internals + the cross-build/qemu recipe: `ON_JIT.md` §"amd64
(x86-64) JIT Implementation".

Remaining (perf/cleanup, not blocking): native SSE2 FP + mul/div, a real
`das-amd64.c` (debug-only), and the `kernel/pc64` cell — which needs an amd64
native kernel plus a kernel-side `jitcode` (xalloc-backed, like aarch64's),
neither of which is on master.

**Goal (original):** bring x86-64 native codegen to master. Today amd64 runs every
module interpreted (`comp-amd64.c` is a stub); `kernel/pc64` is green without it.
This is a **performance** feature, not a correctness fix — schedule accordingly.

1. Source: branch `ilp64`, commit `07adc082` ("ilp64: amd64 JIT backend + fix
   styx 32-bit-field sign extension"). `ilp64:libinterp/comp-amd64.c` is ~2090
   lines of real codegen. Also check `das-amd64.c` and any mkfile/conf wiring on
   that branch.
2. **Critical hazard:** ilp64 has `IBY2WD == IBY2PTR == 8`. On master (LP64)
   `IBY2WD = 4`, `IBY2PTR = 8`. **Every stride/offset written on ilp64 that
   assumed 8==8 silently breaks under LP64** — this is exactly the alt.c bug
   class, multiplied across 2090 lines. Do not port verbatim.
3. Port with a stride audit baked in, the same method that cleared
   `comp-aarch64.c`: for every hand-rolled offset, confirm it uses `IBY2PTR` for
   pointer slots, the type pointer-map for value moves, and **mirrors
   `limbo/dis.c`** (~lines 242-299) for case tables (`casec` count slot
   `IBY2PTR`, entry stride `3*IBY2PTR`; `casel` keys `IBY2LG`; `icase` pure
   `IBY2WD`). Cross-check the W/X (4-byte/8-byte) register-width split the way
   `comp-aarch64.c` does `Ldw` vs `Ldp`. Use `comp-aarch64.c` as the reference
   for "what correct LP64 codegen looks like"; use `comp-386.c` only as a
   structural template (it is 32-bit, `IBY2WD==IBY2PTR==4`, so its strides are
   themselves latent traps).
4. Confirm the JIT punts the same opcodes the aarch64 JIT punts
   (`IALT`/`INBALT`/`ISEND`/`IRECV`, refcounted pointer moves) rather than
   hand-rolling the alt value offset.
5. **Validation needs an x86-64 host.** Run `dis/.../jit` + `jitperf` suites and
   the `kernel/pc64` e2e cell with the JIT enabled (`-c1`), plus bit-identity vs
   the interpreter. Confirm the GUI/teapot apps run under `-c1`.

**Done when:** amd64 `-c1` passes the dis/jit + jitperf + kernel/pc64 suites
bit-identically, with every stride audited; or, if deferred, a written note in
`docs/DEV_INPRO.md` recording where the ilp64 source is and the hazard.

---

## Job 3 — Confirm the network cells are honest and green without retries

The `@flaky` crutch is **already removed** (commit `6be551ac`): `test_dns`/
`test_tls`/`test_impexp` now report `not ok` on the first failing boot, and the
deterministic-dns rewrite + impexp readiness poll were kept. What remains:

1. After Job 1 lands, re-run `make check`. The `kernel/virt64` cell must go
   green **with no retries**. If it doesn't, that is a real bug → back to Job 1.
   Do **not** reintroduce `@flaky` or any retry loop in `tests/kernel/ktests.py`.
   A DNS/TLS request is not legitimately flaky.
2. The dns docstring still explains why the cell was made deterministic (the old
   live `example.com` lookup was a genuine environment fault, not a kernel one);
   that rationale is correct — keep it.

**Done when:** `make check` is green and `tests/kernel/ktests.py` contains no
retry machinery.

---

## Optional / low-priority — residual unaudited surfaces

The class-root is clean, so these are low-yield, but for completeness the
following were NOT read end-to-end and could in principle hold a hand-rolled
stride: `libinterp/string.c`, and the generated builtin glue
(`*mod.h` / `runt.h` and the C builtins that marshal Limbo values). Audit only
if a new corruption symptom appears that the above jobs don't explain. Same
method: read, don't grep; look for `+1`/`IBY2WD`/literal byte offsets landing on
a pointer slot.

Also note the **unwritten contract**: the case-table layout in `xec.c` and each
`comp-*.c` must mirror `limbo/dis.c`'s emission exactly (the `.dis` wire format
carries no alignment/width field). `casec` is the fragile one — correct only
because `struct Casec` `{String*, String*, WORD}` naturally pads to `3*IBY2PTR`
under LP64. Any future field-type change there breaks silently. Worth a comment
at both ends if touched.
