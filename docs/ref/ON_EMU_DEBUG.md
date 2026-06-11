# Debugging the Inferno Emulator (C internals — faults, hangs, sanitizers, cores)

> *So you want to debug the emu itself (a C-level crash, hang, or heap bug)?* This is the reference.

**Audience / when to read this:** the bug is in the **C emulator itself** — emu
crashed with a host SIGSEGV/SIGBUS/SIGILL, hung, corrupted its heap, or you're
hunting an LP64 64→32 truncation in the VM/libraries. Ask yourself first: *is the
fault in my Limbo program, or in the emu?* If it's a Limbo program faulting (nil
deref, bounds, an uncaught `raise`, a wedged app you can still reach via `/prog`),
use **`ON_DEBUGGING.md`** instead — `/prog` is the first tool for a *broken*
proc. This doc is for when the emu dies or freezes *before* you can `cat
/prog/*/status`. For the **static** LP64 width-bug catchers (lint, genmove,
verifytype, DISPTRCHECK) see **`ON_C_IN_DIS.md`**; this doc is the runtime
half (catch it once it has already faulted/hung) plus the C memory-tooling.

> **This repo differs from stock Inferno.** Debug builds default **`EMUCRASH=1`**
> (see below), the USR2 thread-dump and `EMUWATCHDOG` hooks are local additions,
> and the whole point is the **dual-ABI / LP64** port — wild faults here are
> disproportionately truncated pointers. A model trained on stock Inferno will not
> expect any of this.

Standing dev rule (see [[always-launch-emucrash]]): run with `EMUCRASH=1` +
`ulimit -c unlimited` so a flaky fault drops a core on first occurrence.

---

## Runtime observability — catching LP64 faults and hangs

LP64 bugs (a 64-bit value truncated to 32 bits) usually surface as a *wild
pointer* that faults far from its cause, or as a *hang* (a truncated value sends a
loop or scheduler into a state it never leaves). The emu has three built-in hooks
to make both legible. All output goes to the host's **stderr (fd 2)** and is
**async-signal-safe** (only `write(2)`, no malloc/locks/`print`), so it works even
mid-fault or mid-deadlock. Implemented in `emu/Linux/os.c`
(`disbacktrace`/`dumpallprogs`/`faultmon`/`syscrash`) and `emu/port/dis.c`
(`schedprogress`/`schedbusy`/`schedidlecheck`).

### `kill -USR2 <emu>` — JVM-style thread dump (always on)

Dumps every Dis prog: pid, scheduler state (`alt`/`send`/`recv`/`debug`/`ready`/
`release`/`exiting`/`broken`), and a per-frame backtrace (`module pc=<dis-offset>
op=<opcode>`) walked from the prog's registers down the `Frame` chain. The running
prog uses the live global `R`; blocked progs use their saved `p->R`. Every pointer
is validated (`faultprobe`, via a `write` to `/dev/null` that returns `EFAULT` on a
bad address) before deref, and the walk is depth-capped (64) — safe to fire at any
time. Example:

```
=== Dis proc dump (SIGUSR2) ===
prog 1 [release]
	$Sys pc=0x... op=45
	Bufio pc=147 op=45
	Sh pc=5348 op=93
	...
	Emuinit pc=55 op=12
=== end dump ===
```

`op=12` is `IRET` (see `isa.h`); a wild pointer reported in an `IRET` frame is a
truncated frame/linkage pointer (cf. the 24-bit `string.dis` fault).

> SIGUSR1 is **not** used for this — it is reserved for unblocking interruptible
> host I/O (`trapUSR1`). The dump is on USR2.

### `EMUCRASH=1` — fault → backtrace → core (on by default in debug builds)

> **Debug builds default this ON.** `make debug` (the default profile) compiles
> with `-DEMU_DEBUG_DEFAULTS`, which makes `faultcrash` default to 1 — so a debug
> `emu` already drops the dump+core on a wild fault without setting the env var
> (`emu/Linux/os.c:faultmoninit`). `EMUCRASH=0` explicitly opts out.
> `release`/`bleedingedge` builds strip the define, so there it is off unless you
> pass `EMUCRASH=1`. Still set `ulimit -c unlimited` to actually get the core. See
> the build-profile table in `ON_C_IN_DIS.md`.

By default a SIGSEGV/SIGBUS in the VM is swallowed into a recoverable Dis exception
(`sysfault`→`disfault`), so corruption surfaces benignly layers later. With
`EMUCRASH` enabled, a *wild-address* fault (non-nil — an ordinary nil deref still
becomes the normal Limbo exception) instead prints the one-line diagnostic + a full
`dumpallprogs` backtrace, then restores the default signal disposition and
**returns**, so the faulting instruction re-executes and the OS drops a core at the
exact C site. Then:

```sh
ulimit -c unlimited           # and ensure /proc/sys/kernel/core_pattern keeps the core
EMUCRASH=1 emu ... ; gdb emu core
```

gives the precise truncating C op-handler offline. SIGILL is routed the same way (a
corrupt/truncated code pointer). The gdb MCP and the deterministic headless runner
that automate this loop are described in the `inferno-autonomy` skill (see
[[inferno-autonomy-harness]]).

### `EMUWATCHDOG=<secs>` — hang detector (default 60s)

A watchdog kproc (`faultmon`, spawned from `disinit`) samples the scheduler
heartbeat `schedprogress`, which `vmachine` bumps each time it runs a prog. If
progress stops advancing **while a prog is still on the run queue** (`schedbusy()`),
a prog entered the interpreter and never came back (a C-level infinite loop or a
lock cycle) — a real hang, distinct from an idle system (run queue empty, blocked
on I/O, which is *not* flagged). It prints `HANG: ...` + a full dump; under
`EMUCRASH` it also `abort()`s for a core. `EMUWATCHDOG=0` disables it. (Note: a pure
channel-deadlock where every prog is blocked looks identical to idle and is *not*
caught here — that needs I/O accounting.)

Separately, `schedidlecheck()` asserts a scheduler invariant whenever the VM goes
idle: a `Pready` prog must be linked on the run queue, so a `Pready` prog found
while the queue is empty is a **lost wakeup** (classic deadlock signature) and
triggers a one-shot dump.

> Native `/prog` inspection (`ON_DEBUGGING.md`) is still the first tool for
> a *broken* proc you can reach; these hooks are for faults/hangs that kill or
> freeze the system before you can `cat /prog/*/status`.

### `LIMBRULFENCEMEMSIZE=<blocksize>` — electric-fence one pool size class (catch the *writer*)

The killer tool for heap corruption where **victim ≠ culprit** — a stray/wild/
use-after-free write that `poolcheck`/`EMUPOOLPARANOID` only notices *much later*,
at an unrelated free, with a useless backtrace. LIMBRUL routes one pool size class
(`LIMBRULFENCEMEMSIZE` = the **rounded `Bhdr` block size**, e.g. `128`) out of the
shared pool into a reserved-VA arena (`emu/Linux/os.c`): each block gets its own
page, placed END-flush against a trailing `PROT_NONE` **guard page** (a write past
the block → `SIGSEGV`), and on free the block's page is `mprotect(PROT_NONE)`'d —
**quarantine**, so any use-after-free read/write faults **synchronously at the
offending instruction**. Run it and open the core (or sit in gdb): the top frame
*is* the writer.

```sh
ulimit -c unlimited
LIMBRULFENCEMEMSIZE=128 EMUCRASH=1 emu -g1024x768 wm/wm /dis/sh.dis \
    -c 'memfs /tmp; charon file:///tests/web/fixtures/probe_mbounce.html'
# SIGSEGV at the bad access; `addr=` is inside the arena it prints at startup.
gdb emu/Linux/o.emu /tmp/inferno-cores/core.emu.*    # frame 0 = the culprit
```

- **No bit-36 / ASLR "arming" needed.** Unlike the lazy `EMUPOOLPARANOID` audit
  (which only *sees* the corruption when ASLR maps the arena with the clobbered
  bit set), the fence traps the access itself — so a deterministic ASLR-off run
  works, and it catches overruns and UAFs that don't even alter a sensitive bit.
- **Pick the size from a core.** The `poolcheck`/`POOLPARANOID` line names the
  victim block's `size` (e.g. `size 128`); fence *that* class.
- **Cost:** one page per block (debug-only). Practical for one class at a time;
  the class implicated by the cores is the one to fence. Heavy on VMAs — if
  `mprotect` starts failing, raise `vm.max_map_count`. Off unless the env var is
  set (zero behaviour change otherwise). Hooks: `poolfence*` in `emu/Linux/os.c`,
  two call sites in `emu/port/alloc.c` (`dopoolalloc`, `poolfree`).
- **Worked example:** this is what cracked the long-standing charon-teardown
  bit-36 free-tree corruption — a use-after-free of the proc group in `killgrp()`
  (`g->flags &= ~Pkilled` after the group was freed; `flags` aliased bit 36 of a
  recycled free block's `parent`). Lazy detection had chased it for sessions;
  fencing the 128-byte class faulted on the first bounce, in `killgrp`, with the
  writer's stack. Fixed in `emu/port/dis.c` (`delgrp` defers freeing a `Pkilled`
  group); guarded by `tests/web/regress_killgrp_uaf.sh` (fences that class +
  bounces charon — CLEAN means the UAF hasn't returned).

### Graceful failure isolation — what already survives, what aborts

A single misbehaving app does **not**, in general, take emu down — Dis already
isolates procs. The full model:

| Failure | Path | Outcome |
|---|---|---|
| Limbo proc faults (nil deref, bounds, `raise`) | Dis exception → `killprog`/`killgrp` | that proc(group) dies, **scheduler continues** |
| Wild-address `SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGFPE` in the VM | `trapmemref`/`trapILL`/`trapFPE` → `sysfault` → `disfault` | converted to a Limbo exception → kills the faulting app, **emu survives** |
| …same, but with `EMUCRASH=1` | `syscrash` → dump + restore `SIG_DFL` + re-raise | **whole emu dies** with a core (intentional, for debugging) |
| Heap corruption | `poolcheck`/`EMUPOOLPARANOID` → `abort()` | **whole emu dies** (unrecoverable; detection is *lazy* — to catch the writer use `LIMBRULFENCEMEMSIZE`, above) |

`disfault()` (`emu/port/dis.c`) `oslongjmp`s back to `vmachine`'s `waserror()`
loop, which runs the prog's handler or `progexit()`s it, then re-enters the
scheduler. nil derefs are recognised by `isnilref` (`addr==~0 || addr<512`) and stay
ordinary exceptions even under `EMUCRASH`.

**Two known gaps (analysed; left as-is by decision, 2026-06-06):**

1. **The `EMUCRASH` trade-off.** `EMUCRASH=1` (the standard dev setting) turns
   *every* wild fault into a fatal core, so an app crash kills the whole desktop.
   Without `EMUCRASH`, emu already survives app faults — but then there is no core.
   You currently get one or the other. A *fork-to-core* design (fault handler
   `fork()`s; child re-raises for the core, parent `disfault`s and lives) could give
   both; `fork()` is async-signal-safe and emu already forks in `cmd.c`. Not
   implemented (deliberately, for now).
2. **The graceful path is not lock-safe.** `disfault`'s longjmp does not release any
   C-level lock the faulting thread held (there is no per-proc held-lock tracking),
   so a fault inside a locked region can leak the lock and deadlock later; graceful
   recovery can also *mask* the original corruption (it resurfaces "layers later").
   Making it provably safe would need a per-proc lock stack released in `disfault`.
   Not implemented.

Decision: the existing model is adequate — run `EMUCRASH` selectively (drop it for
daily desktop use to keep app crashes isolated; set it when hunting a fault). Keep
`abort()` on `poolcheck`; never continue on a known-corrupt heap.

---

## Sanitizer builds (UBSan / ASan / Valgrind) — auditing the C for memory + LP64 bugs

The LP64 bugs all live in **C** (the VM, libraries), not in Limbo — Limbo is
pointer-width-agnostic. Limbo programs are just the vehicle that drives the C paths.
A sanitizer build turns silent corruption into an immediate report.

**UBSan is the workhorse** (catches the LP64 classes: integer overflow, shifts,
pointer overflow, misaligned access; no allocator conflict). Inject the flags via
the arch mkfile and rebuild the emu-g runtime libs + emu-g (leave the host
`limbo`/`iyacc` normal so the toolchain stays fast and stable):

```sh
# in mkfiles/mkfile-Linux-$OBJTYPE: append to CFLAGS and set LDFLAGS
#   CFLAGS:  -fsanitize=undefined -fno-omit-frame-pointer -g
#   LDFLAGS: -fsanitize=undefined
ARGS="ROOT=$PWD SYSHOST=Linux SYSTARG=Linux OBJTYPE=aarch64"
for d in lib9 libbio libmp libsec libmath libinterp libkeyring; do
  (cd $d && mk $ARGS nuke && mk $ARGS install); done
(cd emu/Linux && mk $ARGS CONF=emu-g clean && rm -f *.o && mk $ARGS CONF=emu-g install)
UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=0 emu-g -r$PWD /dis/sh.dis -c PROG
# For the GUI stack also rebuild libdraw/libmemdraw/libmemlayer/libprefab/libtk
# (leave the vendored libfreetype uninstrumented — third-party noise; UBSan is
# per-TU so mixed linking is fine) and link CONF=emu, then run under Xvfb.
```
Revert the mkfile and `make all` to restore the normal build afterwards. (The rule
templates make `.o` depend on the per-target flags mkfile, so changing the sanitizer
flags there does invalidate stale objects — but `mk clean` the emu dir anyway if you
mix configs.)

**ASan does NOT work** with emu: `emu/port/alloc.c` defines its own pool
`malloc`/`free`, which ASan's interceptors override, so a pool pointer reaches
`free`/`D2B` and panics `alloc:D2B ... not in pools` at boot. Don't fight it.

**Valgrind** is the substitute for ASan's heap/uninitialised-value checking — it
needs no recompile and tolerates the custom allocator (intra-pool granularity is
lost, but it catches uninitialised reads — great for width bugs — and overruns of
plain `malloc` buffers like `gscreendata`):
`valgrind --track-origins=yes emu-g -r$PWD /dis/sh.dis -c PROG`.

### Dis-heap object granularity for Valgrind (`-DVALGRIND`) — use-after-free in the GC heap

By default Valgrind sees the whole Dis garbage-collected heap as a few giant pool
superblocks, so a *use-after-free of a collected object* — a dangling pointer left
in an `isptr=0` (untraced) `tptr`/`tbig` slot, or any reference that outlives a GC
sweep — is invisible. `libinterp/vgheap.h` (off unless built with `-DVALGRIND`)
overlays object-level tracking: every Dis object is a `VALGRIND_MALLOCLIKE_BLOCK`
when `poolalloc(heapmem,…)` hands it out (`libinterp/heap.c`: `nheap`/`heapz`/`heap`)
and a `VALGRIND_FREELIKE_BLOCK` when it is reclaimed — by refcount (`destroy`,
`freelist`) **or by the GC sweep** (`gc.c`). After the FREELIKE the object is
poisoned NOACCESS, so reading a reclaimed object is reported immediately as "Invalid
read … block was freed by `<stack>`" with **both** the alloc and free/GC stacks —
i.e. it confirms-or-denies a GC dangling-pointer and points at the offending slot.
Build + run:
```sh
# rebuild just libinterp with the flag, relink emu, run under valgrind+Xvfb:
cd libinterp; gcc -c -DVALGRIND <normal-cflags> heap.c gc.c
ar r $ROOT/$OBJDIR/lib/libinterp.a heap.o gc.o
(cd emu/Linux && rm -f o.emu && mk $ARGS CONF=emu install)   # or CONF=emu-g
DISPLAY=:99 valgrind --error-exitcode=99 --num-callers=20 \
    emu -g1024x768 wm/wm /dis/<app>.dis
```
When off (`-DVALGRIND` absent) the macros are no-ops, so the production allocator is
byte-for-byte unchanged. Notes: redzones are 0 (the pool packs objects adjacently,
so this catches use-after-free + uninitialised reads, not adjacent-object overruns);
pool block coalescing makes a reused region's tracking approximate; the `MALLOCLIKE`
instructions are harmless no-ops when the binary is run *outside* valgrind, so one
`-DVALGRIND` emu serves both. The `-DVALGRIND` build also swaps the pool's arena
growth from `sbrk` to `mmap` (`emu/port/alloc.c`) — `sbrk` overflows Valgrind's
brk-segment limit and emu dies with `mallocz failed` before reaching the code under
test. **ASan still can't use these** (its `malloc` interceptor already breaks emu at
boot), so this is Valgrind-only.

**Accuracy to Inferno's memory model — GC-phase-aware (this is what makes it
usable).** A naive `FREELIKE` poison is swamped with false positives because the
memory manager *itself* legitimately reads freed-but-not-yet-reused memory, and by
memory access alone that is **indistinguishable from a real dangling-pointer UAF —
the only difference is WHO reads: the manager (legitimate) vs. the mutator (a
bug).** So the fix is phase-based, not frame-based:

1. **`VG_MM_BEGIN`/`VG_MM_END`** (`VALGRIND_{DISABLE,ENABLE}_ERROR_REPORTING`,
   nestable; defined in `vgheap.h`/`alloc.c`) bracket the manager's
   freed-memory-touching phases — the **GC mark+sweep** (`rungc`'s loop and
   `rootset`, which covers the `markheap`/`markarray`/`marklist` callbacks too), the
   **refcount free-cascade** (`destroy`'s `t->free`/`freeptrs`), and the **pool
   tree/coalesce** (`poolalloc`'s `dopoolalloc`, `poolfree`'s body). While the
   manager runs, freed reads are not reported; **the object stays `FREELIKE`-poisoned,
   so a *mutator* read of it IS still caught** outside the bracket.
2. **Bhdr registration** (`VGHEAP_HDR` in `vgheap.h`): the pool's `Bhdr` header sits
   16 bytes *before* `B2D`, and `D2B`'s consistency check reads it in plain mutator
   context. `VGHEAP_ALLOC` marks it `DEFINED` so those reads are clean — without
   un-poisoning any object byte, so a `destroy` that reads a *genuinely* freed
   child's `->ref` still fires (the real signal).
3. **Full-block registration**: `VGHEAP_ALLOC` registers the block's actual
   `poolmsize` extent, not `sizeof(Heap)+n` — a String's C-terminator write at
   `s->Sascii[s->len]` runs to the rounded block end, so the smaller size made that
   legitimate write look like "N bytes after the block".
4. **`libinterp/valgrind-inferno.supp`** mops up only the few un-bracketed paths:
   `smalloc` (the libc-malloc interposition artifact — production uses emu's pool)
   and the `poolread`/`poolmsize` `/prog` inspectors. Run with
   `--suppressions=libinterp/valgrind-inferno.supp`.

Measured on a charon launch (full GUI): **389 → 1** Invalid read/write reports (the
one residual is a benign boundary read). **Validated** that it still catches real
bugs: a synthetic mutator UAF (`newstring`; `destroy`; read `s->len` in `Sys_write`)
is reported as the *only* error — "Invalid read … inside a block … free'd at
`destroy`", top frame `Sys_write ← mcall ← xec` (a VM/mutator frame) with both alloc
and free stacks. **So a genuine UAF = a report reading *inside* a freed block from a
VM frame** (`Sys_*`/`xec`/string/font ops); the manager's own freed reads are
silenced, not conflated. (Caveat for intermittent races: Valgrind's ~30× slowdown
perturbs timing — the brutus/charon `Tkclient[$Sys]` intermittent did **not** fire
under it; chase that one via the deterministic address with `/prog`/gdb instead.)

---

## Key files

| File | Purpose |
|------|---------|
| `emu/Linux/os.c` | host signal traps, `dumpallprogs`, `faultmon`, `syscrash`, `EMUCRASH`/watchdog init |
| `emu/port/dis.c` | scheduler (`vmachine`), `disfault`, `schedprogress`/`schedbusy`/`schedidlecheck` |
| `emu/port/alloc.c` | the pool allocator (`poolalloc`/`poolfree`/`D2B`, `poolcheck` abort) |
| `libinterp/heap.c`, `gc.c` | Dis heap alloc + GC mark/sweep; `verifytype` |
| `libinterp/vgheap.h`, `valgrind-inferno.supp` | `-DVALGRIND` object-level heap tracking |
| `include/isa.h` | Dis opcodes (decode the `op=` numbers in dumps) |

**Cross-references:** `ON_DEBUGGING.md` (debugging a *Limbo program*: `/prog`,
exceptions, disdump) · `ON_C_IN_DIS.md` (the **static** LP64 width-bug
catchers + build profiles) · `ON_EMU.md` (emulator architecture) ·
`ON_PORTING.md` (Linux/aarch64 port internals) · the `inferno-autonomy` skill
(headless repro + gdb MCP loop).
