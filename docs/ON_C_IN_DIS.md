# Writing C that touches the Dis VM

This is the reference for the integer model, the one C hazard it creates, and
how to debug the heap corruption that follows from getting it wrong.

Inferno was designed at the turn of the millennium, when the machines it ran on
were 32-bit. Its virtual machine, **Dis**, rested on a quiet assumption: that a
Limbo `int` and a machine pointer are the same size — one 32-bit word. For two
decades that was simply true, so a great deal of C in the VM stuffs pointers into
`int`-sized slots and never thinks about it.

On a modern 64-bit machine that assumption breaks. A pointer is now 64 bits, but we
**deliberately keep a Limbo `int` at 32 bits** — because that is what lets a Limbo
program behave *identically* on every host (a 32-bit ARM board and a 64-bit server
give the same arithmetic, overflow, and layout), as long as the emulator is ported
to that host correctly. The compiled `.dis` may be rebuilt per arch; the *meaning*
of the source never changes. The cost of that promise is paid entirely in C: the
Dis word (32 bits) and a machine pointer (64 bits) are no longer the same size, so
any C that conflates them is now a bug.

To let **one** source tree build for both the old 32-bit machines and new 64-bit
ones, we had to make the VM's C say what it means everywhere it used to lean on
"pointer == word". When a stray pointer still gets truncated into a 32-bit slot,
the symptom you actually see is **heap corruption** — a wild address written
somewhere it shouldn't be, crashing much later and far away. This document is that
whole story: the integer model, the single hazard it creates, how the code is
structured to keep it out, and how to debug the corruption when it slips through.

If instead you want to write C in the wider Inferno/emu codebase (the Plan 9 C
dialect, `lib9` types, `error()`/`waserror()`, devices, the host port) and *not*
specifically the VM boundary, see **`ON_C_IN_INFERNO.md`**.

## The integer model: we target LP64

**This repo targets an LP64 Dis model.** The Dis word — a Limbo `int` — stays
**32 bits** (`IBY2WD`=4) on every host; only the C pointer grows to 64. The brief
reason is the one above: a fixed 32-bit `int` is what makes a `.dis` mean the same
thing on every machine, so Limbo stays genuinely portable. The price is the C
hazard this whole document is about — and it's a price worth paying.

The obvious alternative is to widen the Dis word to match the pointer
(`IBY2WD`=8 — an "ILP64" model). That would delete the hazard, but it makes the
width of a Limbo `int` depend on the host, so the *same* source stops behaving the
same on a 32-bit and a 64-bit machine. That trades away the one thing Limbo exists
to guarantee and turns it into the same unportable-VM nightmare that something like
.NET was. We keep an `ilp64` branch around as an experiment, but it is **not** the
model we build on; the rest of this document is the LP64 story.

**In code, the whole difference is *what `sizeof` drives*.** Both models build from
one source tree; the choice is which width is tied to the host:

| | `include/isa.h` | `include/interp.h` | what `sizeof` sizes |
|---|---|---|---|
| **us (LP64)** | `IBY2WD = 4` (fixed literal) · `IBY2PTR = sizeof(void*)` | `WORD = int` (32 bits) | the **pointer/register slot** — it adapts to the host; the Dis word is pinned at 32 |
| **ILP64** (`ilp64`, and caerwynj's fork) | `IBY2WD = sizeof(intptr)` | `WORD = long` (64 bits) | the **Dis word itself** — so a Limbo `int` follows the host pointer |

So both projects use `sizeof` — the difference is *where*. We apply it to `IBY2PTR`
(the pointer slot, which **must** equal the host's `sizeof(void*)` or the GC's
pointer-maps corrupt memory) and keep `IBY2WD` a fixed `4` so the Dis word never
moves. ILP64 instead ties `IBY2WD` to `sizeof(intptr)`, so widening the host pointer
widens a Limbo `int` along with it. That single line is the entire LP64-vs-ILP64
distinction.

> **Terminology trap: "LP64" means two different things — keep them apart.**
> (1) the *host C data model* — Linux aarch64/amd64 are LP64 *C platforms*
> (`int`=4, `long`=8, ptr=8); that's a fixed property of the host OS/arch. (2)
> *Inferno's Dis integer model* — our choice to keep the Dis word at `IBY2WD`=4
> (a 32-bit `int`) even on a 64-bit host. The two are independent; this document is
> about meaning (2).

The tables below are the evidence for the choice. Where an "ILP64" column appears,
it is the **rejected** alternative, shown only for contrast — not a second model we
ship.

### Table A — Host C data models (the platforms in this tree)

| Host arch (OBJTYPE) | Example hosts in tree | C `int` | C `long` | C ptr | C model |
|---|---|---|---|---|---|
| `386`, `arm`, `mips`, `power`, `s800` (32-bit) | Nt(386), legacy *BSD/Irix/Solaris 32 | 32 | 32 | 32 | **ILP32** |
| `aarch64` *(default)* | Linux, MacOSX | 32 | 64 | 64 | **LP64** |
| `amd64` *(override)* | Linux, *BSD, Solaris | 32 | 64 | 64 | **LP64** |
| `power64`/`mips64`/`sparc64` | (buildable, not active) | 32 | 64 | 64 | **LP64** |
| *Win64* | **not a target** (`emu/Nt`=`386`) | 32 | 32 | 64 | *LLP64* |

The host C model is a fixed property of the OS/arch — **identical on both
branches**. Only ILP32 and LP64 hosts are actually built; no LLP64.

### Table B — Limbo `int` (Dis WORD) width per host, under each Dis model

| Host class | C model | **LP64-Dis** (`master`, `IBY2WD`=4 always) | **ILP64-Dis** (`ilp64`, `IBY2WD`=ptr) |
|---|---|---|---|
| 32-bit (386/arm/…) | ILP32 | Limbo `int` = **32** | Limbo `int` = **32** |
| 64-bit (aarch64/amd64) | LP64 | Limbo `int` = **32** | Limbo `int` = **64** |
| **Limbo `int` constant across all hosts?** | | ✅ **Yes — always 32** | ❌ **No — 32 or 64 by host** |

This is the whole decision in one table. **LP64 pins Limbo `int` at 32 bits on
every host arch** → a `.dis` behaves bit-identically wherever `emu` runs (same
overflow, same `1<<31`, same masking, same struct layout), *as long as the host
port itself is correct*. ILP64 makes the Limbo `int` width follow the host pointer
width → the same source means different things on a 32-bit device and a 64-bit
server.

### Table C — What the C core must handle, per host platform

This is the cost side: LP64 buys identical Limbo at the price of one C hazard on
64-bit hosts. Here is exactly what the C core has to deal with, platform by
platform.

| Host / Dis model | ptr vs Dis WORD | What the C core must handle | What Limbo sees |
|---|---|---|---|
| 32-bit, either model (ILP32) | ptr 4 **==** WORD 4 | nothing special — pointer and Dis word are the same width, so the original Inferno "a pointer fits in a WORD" assumption still holds | `int` = 32 |
| 64-bit, **LP64-Dis** (`master`) | ptr 8 **>** WORD 4 | **the hazard class:** never store a pointer in a `WORD`/`int`/`s32` slot (the high 32 bits truncate → wild address). Use `tptr`/`uintptr`/`void*` for pointers and `WORD` only for an actual Dis word. Limbo↔C struct identity *still holds* (Dis `int`=32=C `int`, so `Draw_Rect`==`Rectangle`) | `int` = 32 (same as a 32-bit host) |
| 64-bit, **ILP64-Dis** (`ilp64`) | ptr 8 **==** WORD 8 | pointer==word again, so the truncation hazard goes away — **but** Limbo `int` is now 64-bit, so Limbo-struct **≠** C-struct: needs field-wise `IRECT/DRECT`, the `Tk_rect` return cast, and width care in `print %d`, the wire `g32`, and `alt` counts | `int` = 64 (**differs** from a 32-bit host) |

The LP64 row is the trade `master` accepts: a single, well-understood C hazard
(pointer wider than word) on 64-bit hosts, in exchange for Limbo that is identical
everywhere. The mechanisms that catch that hazard are Tables E–F.

### Table D — Verdict against the target

| Requirement | LP64-Dis | ILP64-Dis |
|---|---|---|
| Limbo source behaves the same on every host arch | ✅ guaranteed (int=32 everywhere) | ⚠️ only within one width class |
| `.dis` recompiled per arch is acceptable | ✅ (magic-gated, auto) | ✅ (magic-gated, auto) |
| Don't break userspace / Limbo-struct == C-struct (`Draw_Rect`==`Rectangle`) | ✅ **holds** (int=32 = C int) | ❌ **breaks** (needs field-wise `IRECT/DRECT`, `Tk_rect` cast) |
| Push complexity into C, keep Limbo simple | ✅ that's the model | ✗ inverts it (Limbo gets host-dependent int) |

**For the target as stated, LP64 is the model that delivers it.** Its price is the
C-side hazard class (pointer wider than word) — which is exactly what the checks
in Tables E–F exist to catch.

### Table E — LP64 C hazard classes → the defined check/test that catches each *(all verified in-tree)*

| # | Hazard (only arises because C ptr=8 > Dis WORD=4) | Detection mechanism | Where | Phase |
|---|---|---|---|---|
| 1 | C pointer stored into a `WORD`/`int`/`s32` slot → high 32 bits truncated (the "tptr" class) | `make lint` → clang **`-Wshorten-64-to-32`** vs frozen `tests/lint/baseline.txt` | `tests/lint/run.sh` | **Build** |
| 2 | Compiler emits a word-width move for a pointer-width type | **`genmove` width assert** → `fatal("… LP64 width mismatch")`, in **both** compilers | `limbo/gen.c` + `appl/cmd/limbo/gen.b` | **Compile** |
| 3 | A temp that must hold a pointer is typed `tint` (4B) not `tptr` (8B) | explicit **`tptr`** pointer-width type routing | `limbo/ecom.c` / `ecom.b` | **Compile** |
| 4 | GC pointer-map disagrees with a type's slot size/stride | **`verifytype` / `verifyctype`** GC-map↔size cross-check | `libinterp/heap.c` | **Init/runtime** |
| 5 | A truncated/stray Dis pointer gets walked by the collector | **`DISPTRCHECK`** ("Valgrind for Dis pointers"), `-DDISPTRCHECK` debug build | `libinterp/gc.c` | **Runtime (debug)** |
| 6 | Wrong-width `.dis` (stale 32-bit module on 64-bit emu) | **`XMAGIC` vs `XMAGIC8`** stamp + `exDiswidth` rejection → shell recompiles from source | `limbo/com.c`, `libinterp/load.c` | **Load** |
| 7 | Stale generated module headers (`srv.h`, runt.h) after an ABI switch | `make` **force-regenerates** generated headers per-ABI; `clean`/`nuke` wipe them | mkfiles | **Build** |
| 8 | Anything that slips all of the above | regression nets: **`tests/dis`** (9 suites) + **`tests/cunit`** (per-C-lib: lib9/libmp/libsec/libmath/libbio/…) + **`tests/cunit/cross.sh`** (the same lib tests cross-built ILP32/arm and big-endian/m68k, run under qemu-user) | `tests/` | **Test** |
| 9 | First-fault capture for a bug in the wild | **`EMUCRASH=1`** core + `USR2` dump + `EMUWATCHDOG` | `emu/Linux/os.c` | **Runtime obs.** |

### Table F — Defense-in-depth: when each net fires

| Stage | Catches | Cost |
|---|---|---|
| Write C | (discipline: use `tptr`/`WORD`/`uintptr` deliberately) | — |
| **Compile** | #2 `genmove` assert, #3 `tptr` typing | free, automatic, hard-fails |
| **Build** | #1 `make lint` regression, #7 header regen | seconds; baseline diff |
| **Load** | #6 wrong-width `.dis` | automatic recompile |
| **Init / run** | #4 `verifytype`, #5 `DISPTRCHECK` (debug) | debug-build only |
| **Test** | #8 `tests/dis` + `tests/cunit` | `make check` gate |
| **In the wild** | #9 `EMUCRASH`/`USR2`/watchdog | core on first fault |

The takeaway: the LP64 hazard is **real but bounded and mechanically caught** — two
of the nets (#2, #6) are *hard compile/load failures* you cannot miss, and #1/#8
are CI-gateable. That is the trade the target implicitly accepts: **a known, tooled
C hazard in exchange for Limbo source that means the same thing on every host
arch.**

### What the ABI means for your C

You're working in an **LP64** world: a C `int` is 32 bits, a C **pointer is 64
bits**, and a Dis word (a Limbo `int`) is 32 bits. The one thing that bites people:
the old Inferno habit of assuming "a pointer fits in a `WORD`" is **no longer
true** — stuff a pointer into a `WORD`/`int`/32-bit slot and it gets truncated, and
you get a wild address later (Table C, the LP64 row). Keep pointers and Dis words
distinct: use pointer-width types (`void*`, `uintptr`, `tptr`) for pointers, and
`WORD` only for an actual Dis word.

You don't have to catch this by eye — that's what Tables E–F are. Run `make lint`
and `make check` before you push and most truncation mistakes are caught for you.
(If you genuinely *want* `int == pointer` in C, that's exactly what the `ilp64`
branch gives you — but it's not `master`, and it moves the cost onto Limbo.)

### What the ABI means for your Limbo

Basically nothing — and that's the whole point. Your `int` is **32 bits no matter
what host the emu runs on**, so overflow, `1 << 31`, masking, and hashing all
behave identically everywhere, and the same `.dis` means the same thing on every
architecture. You never see pointers or any of the C-side hazards above; the VM
deals with all of it. Two things worth knowing:

- If you need a guaranteed 64-bit integer, use **`big`** (always 64 bits). `int` is
  kept at 32 bits deliberately, *for* portability — not by accident.
- A compiled `.dis` is stamped with the pointer width it was built for (`XMAGIC`
  for 32-bit, `XMAGIC8` for 64-bit), so a module built for one width won't load on
  the other — the shell just recompiles it from source when it can. That's the
  "recompile the `.dis` per arch" half of the deal; your *source* never changes.

## Debugging heap corruption (when prevention fails)

Heap corruption here is not mysterious, and it's almost always the *same* bug
wearing a different hat: a 64-bit pointer got truncated into a 32-bit Dis slot
(Table C, the LP64 row), then written back as a bogus address that lands in the
middle of the heap. The bad write *succeeds* silently, so the crash only comes much
later — when the allocator or the garbage collector next walks the structure that
got scribbled on. That gap between cause and symptom is the only thing that makes
it feel hard.

The cure for "hard to reproduce" is to make it **crash immediately, at the writer,
with a core** instead of much later somewhere innocent. The `debug` profile already
sets this up (it defaults `EMUCRASH` on and builds the `DISPTRCHECK` checker); the
steps below are the same thing by hand on any build.

**1. Tell the host kernel where to drop cores (once per boot):**

```sh
sudo mkdir -p /tmp/inferno-cores
echo '/tmp/inferno-cores/core.%e.%p.%t' | sudo tee /proc/sys/kernel/core_pattern
```

(`%e` program, `%p` pid, `%t` timestamp. The directory must exist and be writable;
to survive reboots put `kernel.core_pattern=...` in `/etc/sysctl.d/`.)

**2. Raise the core-size limit:** `ulimit -c unlimited`

**3. Leave ASLR on.** Several of these bugs only surface at high addresses, so do
**not** run emu under `setarch -R` (ASLR-off) — letting the host randomize the
address space is exactly what provokes the fault.

**4. Launch with the crash/observability knobs:**

```sh
ulimit -c unlimited
env EMUCRASH=1 EMUWATCHDOG=60 \
    ./Linux/aarch64/bin/emu -r"$PWD" -g1280x800 wm/wm
```

- `EMUCRASH=1` — a wild/illegal Dis fault aborts the process immediately (dropping a
  core) instead of being swallowed into a Dis exception that silently wedges the VM.
  **This is the important one** (on by default in `debug` builds) — without it an
  intermittent corruption fault just leaves a zombie/hung emu and the evidence is gone.
- `EMUWATCHDOG=60` — if the VM hangs for 60s (a deadlock, not a hard fault) the
  watchdog dumps every Dis thread so you can see who is stuck.
- `kill -USR2 <emu-pid>` forces that same thread dump from a live emu any time.
- `DISPTRCHECK` (the `debug` profile, or `make emu-disptrcheck`) is "Valgrind for
  Dis pointers": it validates every GC-reachable Dis pointer each collection, so a
  truncated one is caught the pass *after* it is written rather than at the eventual
  crash (see "Catching LP64 width bugs" below).

**5. Hand the core to gdb:**

```sh
gdb ./Linux/aarch64/bin/emu /tmp/inferno-cores/core.emu.<pid>.<ts>
(gdb) bt              # host C backtrace at the fault
(gdb) info registers  # the faulting address is usually a smashed pointer
```

The fault message emu prints on the way down names the Dis module, the builtin
(e.g. `Charon[$Sys]`), and a `pc=`; map that `pc` back to a Limbo source line with
the module's `.sbl` (`limbo -g`). When you need to catch the *exact* writer of a
specific size class, use the `LIMBRUL` electric-fence (see "Open runtime bug"
below). For the broader emu-fault tooling see `ON_EMU_DEBUG.md`; for debugging a
*Limbo program* rather than the C heap, see `ON_DEBUGGING.md`.

**Preventing it in the first place** is the static/semantic check layer — `make
lint`, the `genmove` width assert, the GC pointer-map cross-check, and `DISPTRCHECK`
— under "Catching LP64 width bugs statically and semantically" below.

**How one tree builds both ABIs.** The same source tree builds for either Dis
ABI, selected automatically by the host pointer width: `include/isa.h` sets
`IBY2PTR = sizeof(void*)`, all width logic is symbolic (`IBY2PTR` for
pointer/register slots vs `IBY2WD`=4 for the Dis word), and the `.dis` magic is
stamped (`limbo/com.c`) and accepted (`libinterp/load.c`) conditionally on
`IBY2PTR` — a 32-bit build gets `IBY2PTR==4` and uses `XMAGIC`, a 64-bit build
gets 8 and uses `XMAGIC8`. A static assert in `libinterp/xec.c`
(`sizeof(void*)==IBY2PTR`) turns any mismatch into a compile error. The two
ABIs' `.dis` binaries are not interchangeable; a wrong-width module is rejected
(`exDiswidth`) and the shell recompiles it from source if available. One
caveat: the self-hosting Limbo compiler (`appl/cmd/limbo/isa.m`) has no
`sizeof`, so its `IBY2PTR` is a literal `con` that must match the build ABI —
the one value not auto-derived (candidate for build-time generation).

Where the port stands: both ABIs build and run the full system — toolchain,
`emu`/`emu-g`, the shell, and the `wm` desktop (the GUI fixes are the draw
scan-line word width and the exception-unwind `NOPC` sentinel, in "Fixes"
below; see ON_GRAPHICS.md for the stack itself). The recurring bug shape of
the port is "this codegen/analysis path still assumes 4-byte pointers"; the
five root-cause classes — call-frame temp, array-literal element-address temp,
pointer comparison opcodes, optimizer liveness sizes, and the indexed-element
address node type (the `Oindex`→`Oindx` rewrite) — are each detailed below,
and the whole class is audited (see "The pointer-width `tint` bug class").
Remaining gaps are listed in "Deferred LP64 items"; the one open *runtime* bug
is the idle-Charon heap corruption, also below. `tests/dis/` is the standing
regression net (see ON_TESTING.md).

**Build dependencies:** the rule templates make a `.dis` depend on the `limbo`
binary (`mkfiles/mkdis`) and a `.o` depend on the per-target flags mkfile
(`mkfiles/mksyslib-sh`, `mkfiles/mkone-sh`), so mk recompiles when the compiler or
the build flags change — not just when a source `.b`/`.c` changes. (To force a
full dis recompile anyway: `find appl -name '*.b' -exec touch {} +`.)

This file records every place where something is turned off, stubbed, or worked
around, plus the LP64 port design and the one open runtime bug (the idle-Charon
heap corruption, below), so you know what is real vs. deferred.

How to build, the profiles, the vendored-library cache, and the `make check`
gate are all in **[`ON_BUILDING.md`](ON_BUILDING.md)** — not repeated here.
One build hazard is ABI-specific, though, so it stays:

> **Build hazard — stale generated module headers across an ABI switch.** The C
> activation-record headers for builtin modules (`limbo -a`/`limbo -t` output:
> `libinterp/runt.h`, `sysmod.h`, … and `emu/Linux/srv.h`/`srvm.h`) encode
> ABI-specific frame offsets (pointer/register-slot size, `MaxTemp`, frame
> `size`). A mk rule that depends only on the module *source* keeps the
> wrong-ABI header across a 32↔64-bit switch (the switch rebuilds `limbo` but
> touches no `.m`/`.b`), and links it into the new emu — the builtin then reads
> its arguments at the wrong frame offset (truncated pointer → wild-address
> fault, e.g. a stale 32-bit `srv.h` with `WORD regs`/`size=40` against the
> LP64 `void* regs`/`size=72`, faulting deep inside the builtin). The
> `srv.h`/`srvm.h` rule lists the `limbo` binary as a prerequisite so an ABI
> change forces regeneration; **the other generated headers share the latent
> flaw, so after any ABI switch on an existing tree do a clean rebuild
> (`mk nuke`) rather than an incremental one.**

---

## Fixes (correct, not stubs — each carries a rule)

These are genuine 64-bit correctness fixes, not shortcuts; each entry states
the rule the code now follows:

- **`libmath/dtoa.c`** — David Gay's `dtoa` assumes the bignum word type and the
  two halves of an IEEE double are 32 bits; on LP64 `long` is 64 bits, which
  corrupts the bignum arithmetic and makes `word0`/`word1` read past the end of
  the double. The word type is pinned to 32 bits (`typedef unsigned int ULong;
  typedef int Long;`). Same file, the byte-order rule: select `word0`/`word1`
  with the compiler predefine `__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__`, never
  `#ifdef __LITTLE_ENDIAN` — glibc defines that macro as a constant on every
  arch, so the ifdef is always true and big-endian gets the halves swapped
  (the `cunit/m68k` check cell guards this).
- **`limbo/dtocanon.c` + `libinterp/load.c` (`dtocanon`/`canontod`)** — same
  `unsigned long`-is-8-bytes family. These split/reassemble an IEEE double into
  the two 32-bit words of the `.dis` data section via a
  `union { double d; unsigned long ul[2]; }`; on LP64 `ul[0]` aliases the whole
  double, so **every real *constant* loads as ~0** while reals computed at run
  time stay fine — a trap that hides from any test that never reads a real
  literal. The union element is pinned to `unsigned int`. The self-host
  `appl/cmd/limbo` is unaffected (it serialises reals via the Math
  `export_real` builtin, not a C union).
- **`emu/port/alloc.c`** — a free block stores its tree node *in-band* in the
  `Bhdr` union; on LP64 that node is 56 bytes + 8-byte `Btail` = 64 bytes, so
  the original 32-byte minimum block lets the free-tree pointers and trailer
  spill into the neighbouring block. The allocation quantum is word-size-aware
  (`#define QUANTA (sizeof(Bhdr)+sizeof(Btail) <= 32 ? 31 : 63)`): 64-bit
  builds get 64-byte minimum blocks, 32-bit builds are unchanged.
- **`Linux/aarch64/include/lib9.h`** — the `access(2)` mode constant is
  `AREAD`, not `READ` (used by `libdraw/subfontname.c`).
- **Draw scan-line word width — `libdraw/bytesperline.c`, `libmemdraw/{alloc,draw,
  defont,load,unload,line}.c`** (the GUI-enabling graphics fix). libmemdraw models
  an image scan line as an array of `ulong` "words" and computed every stride as
  `sizeof(ulong)` and the per-line word count via `8*sizeof(ulong)`. On classic
  Inferno `ulong` is 32 bits = the pixel word; on LP64 it is 64 bits, so allocation
  *and* stride doubled. libmemdraw was internally self-consistent (it just used 2×
  memory), but it collided with everything that uses the real packed 32-bit-word
  layout — the draw protocol, image files, fonts, and the X11 backend `win-x11a.c`
  (which strides by `Xsize*4`). Result: the screen image (`width=1024`, depth 32)
  got stride `8*1024=8192` instead of `4096`, so the compositor walked off the end
  of the X buffer → SIGSEGV in `boolcalc1011`/`memimagedraw` on the first window.
  The draw word is pinned to 32 bits: `sizeof(u32int)` for strides,
  `8*sizeof(u32int)` in `wordsperline`, and `u32int*` (not `ulong*`) for the pixel
  pointers (`Buffer.rgba`, `boolcopy32`, `memsetl`, `chardraw`). **Rule: a draw
  word is 4 bytes — never `sizeof(ulong)`.**
- **Exception unwind `NOPC` sentinel — `emu/port/exception.c`, `os/port/exception.c`.**
  `handler()` walks frames; the "no handler here, keep unwinding" terminator is
  stored in `Except.pc` (a `ulong`) as the loader's `operand()` value `-1`, which
  **sign-extends to `0xffffffffffffffff` on LP64**. A 32-bit `NOPC`
  (`0xffffffff`) makes `newpc != NOPC` wrongly true and the unwinder jumps to
  `R.PC = prog + (-1) = prog-1` → "illegal dis instruction", firing whenever an
  exception falls through a non-matching handler (e.g. a `fail:` raise back
  into the shell). The sentinel is `#define NOPC (~(ulong)0)` — all-ones at
  native width, correct on ILP32 and LP64. Regression:
  `tests/dis/suites/70_except.b`.
- **Byte→word sign-extension into 64-bit fields (UBSan-audit class).** A `uchar`
  shifted `<< 24` promotes to `int`; for a high byte >= 0x80 (e.g. `0x80`=DMDIR,
  `0xFF`=alpha) the result is a negative `int` that **sign-extends to
  `0xFFFFFFFF…` when widened into a 64-bit `ulong`/`vlong`** — invisible on
  32-bit where `ulong` is 4 bytes. Fixed across: the 9P field-unpack macros
  `GBIT32`/`GBIT64` in `include/styx.h` + `include/fcall.h` (the big one — every
  9P `mode`/length/qid/time unpack; `GBIT64` also zero-extended its low word);
  `Dir.mode` assembly in `emu/port/dev.c`, `emu/port/devfs-posix.c`,
  `lib9/dirstat-{Nt,posix}.c`; and `disw()`/the DEFL big-constant path in
  `libinterp/load.c`. `libinterp/load.c:operand()` (the bytecode operand
  decoder) shifts in `u32int` — behavior-identical, removes the UB. The UBSan
  sweep finds this class (see ON_DEBUGGING.md "Sanitizer builds");
  regression-covered by `tests/dis/suites/30_styxnet` (9P) and the suite at
  large. The remaining UBSan findings (pixel-assembly shifts, crypto/bignum
  byte-assembly, the string hash, `memmove(x,nil,0)`) are **benign** — results
  verified (correct render + crypto vectors), values stay 32-bit/masked — and
  stay as-is to avoid churn in hot paths.

---

## Stubbed / disabled

### JIT compiler — `libinterp/comp-aarch64.c` is a working LP64 JIT, off by default
- **What:** `comp-aarch64.c` is a from-scratch LP64 AArch64 Dis JIT. It has a bit-exact,
  assembler-verified A64 encoder layer; LP64-correct 4-byte (Ldw/Stw, W-regs) vs 8-byte
  (Ldp/Stp, X-regs) memory access per field; and natively compiles the hot integer/control
  path (moves, word/byte/long arithmetic, shifts, mul, conversions, **conditional branches +
  IJMP**, LEN*, IIND*, MOVM/HEADM, and **IMCALL** via `commcall`/`macmcal`). The rest is
  punted (ICALL, IRET, IFRAME/IMFRAME, IGOTO/ICASE/ICASEC — tables relocated first, FP,
  news, div/mod, sends). Code is generated into a low (<2GB) executable mmap arena so the
  32-bit WORD jump tables can hold native addresses, matching the interpreter's
  `(Inst*)t[0]` reads.
- **Default behaviour is unchanged:** `cflag==0` (the default) never calls `compile()`,
  so every module runs interpreted exactly as before. The LP64 test suite is **178/178**
  with the JIT present. The JIT only activates with `emu -c1` (or `-c2`).
- **`emu -c1` works:** runs the Emuinit bootstrap, `sh` (pipes/glob/control flow), and the
  full battery natively — **9 of 9 suites pass 100%** under `-c1` (vm, concur, crypto,
  styxnet, selfhost, loader, plumb, except, modglobal). The only `-c1`-specific caveat is that
  `50_loader`'s `$Loader`-reflection round-trip is TAP-skipped: `ifetch`/`newmod` can't
  introspect a JIT-compiled module because `compile()` replaces `m->prog` (Dis) with native
  code and frees the original — `ifetch` rejects compiled modules *by design* in stock
  Inferno, and every JIT back-end makes this trade-off. Not a codegen defect; the full
  reflection round-trip runs and passes at `cflag==0`. The traps that bite this
  back-end — encoder field mix-ups, `comvec` failing to preserve the AAPCS64
  callee-saved registers across the C boundary, a stale `R.PC` during yielding
  builtins — are catalogued in ON_JIT.md "Root causes".
- **Supporting changes that DID land (and are correct/regression-free):**
  - `emu/Linux/segflush-aarch64.c` now `mprotect()`s the flushed range RWX (pool/heap
    memory is non-executable on Linux; generated code faulted on instruction fetch).
  - `xec.c` dispatch is `if(R.M->compiled || R.PC in [jitlo,jithi)) comvec()` — dispatch
    native whenever R.PC is in the JIT arena, not only when `R.M->compiled`. `jitlo`/
    `jithi` default to 0, so this is a no-op for non-JIT builds and `cflag==0`.
  - `xec.c handler()` already used byte offsets for compiled modules; `patchex` in
    comp-aarch64.c scales `patch[]` (instruction units) to bytes to match.

### Disassembler — `libinterp/das-aarch64.c` made to compile (approximate)
- **What:** Added `#include <stdint.h>`, added a missing `imm3` field, removed a
  duplicate `case 0x1E`. The instruction *classifier* is still approximate (it
  masks the opcode to 5 bits yet has `case` values above 0x1f that can never
  match).
- **Why:** `das()` is only reachable with `cflag > 4` (debug disassembly), never
  during normal execution. It only needs to compile/link. Not worth making the
  heuristics correct while the JIT is stubbed out.

### GUI stack — `CONF=emu` is the default and the desktop runs
- `make all` builds `CONF=emu` (libfreetype/libtk/libdraw/win-x11a) and `wm/wm`
  renders and is interactive; `make all CONF=emu-g` gives the fast headless
  build.
- **FreeType is vendored** (2.13.2) into `libfreetype/libfreetype/` as plain
  files — upstream used a git submodule, which leaves a fresh clone with no
  headers to compile `freetype.c` against. `libfreetype/mkfile` compiles the
  upstream `src/` against the Inferno glue (`libfreetype/freetype.c`,
  `ftsystem_inf.c`).
- The two LP64 fixes the GUI depends on are in "Fixes" above: the draw
  word-width rule (without it `wm/wm` segfaults in the libmemdraw compositor on
  the first window) and the `NOPC` exception-unwind sentinel (without it the
  desktop comes up but `wmsetup`/`plumber` break with "illegal dis
  instruction").
- `libdynld` (Vita Nuova's DLM facility —
  runtime-loadable *native* modules with signature-checked linkage) remains
  dropped for two independent reasons: (1) it has per-arch relocation backends
  only for 386/arm/mips/power/sparc, no LP64 `dynld-aarch64.c`/`dynld-amd64.c`, so
  it can't compile; and (2) hosted Unix emu never uses it anyway —
  `libinterp/dlm-Posix.c` stubs `dynld()`/`dynldable()` to nil/0, so
  `readmod.c`'s native-load path is dead on POSIX (DLMs are live only in the
  native kernel / Plan 9 / NT glue). Linked by neither emu config. Re-enabling on
  LP64 is real work — write `dynld-<arch>.c` **and** implement `dlm-Posix.c` for
  real — not a list edit.
- **Debugging the GUI headless:** `Xvfb :99 … & DISPLAY=:99 emu -g1024x768 wm/wm`,
  then screenshot with ImageMagick `import -window root out.png`; drive input with
  `xdotool`.

### `gkscanid` — stubbed in the `emu-g` config
- **What:** Added `char* gkscanid;` to the `code` section of `emu/Linux/emu-g`.
- **Why:** `devcons.c` references `gkscanid` (raw-keyboard scan-format name),
  normally defined by the X11 windowing layer that `emu-g` excludes. `devcons.c`
  already treats `gkscanid == nil` as "disabled", so a nil definition is correct
  for a headless build.

### NSS user/group lookups — overridden in `emu/Linux/os.c`
- **What:** `getpwnam`/`getpwuid`/`getgrnam`/`getgrgid` are shadowed with
  self-contained, NSS-free versions. Names come from `$USER`/`$LOGNAME` (default
  `inferno`); uid/gid come from `getuid()`/`getgid()`. `getpwnam("nobody")` returns
  nil (as before), leaving `uidnobody`/`gidnobody` unset.
- **Why:** emu interposes the C library's `malloc`/`free` with its own pool
  allocator. That is incompatible with glibc's own allocator (its tcache and
  `_int_malloc`/`_int_free` assume the glibc chunk layout). The standard `getpw*`
  entry points drag glibc's allocator in: `getpwnam(3)` `dlopen`s NSS modules
  (`libnss_systemd` and friends) that allocate and free *across* the boundary —
  glibc frees pointers emu's `free` never issued, and inspects emu's pool blocks
  with `malloc_usable_size`. Both corrupt the pool and crash at startup. Avoiding
  NSS entirely keeps glibc's allocator dormant, so emu's interposed allocator stays
  self-consistent (as it has been for decades on older systems).
- **Consequence:** Host-file owners display as the invoking user or as numeric ids.
  Sufficient for hosted Inferno. A more complete fix would stop interposing libc's
  allocator (route incidental C `malloc`/`free` to libc, keep the pool only for the
  Dis heap) — larger blast radius across all hosted platforms, deferred.
- **Approaches tried and rejected:** static linking (`-static`) — glibc's built-in
  "files" NSS still allocates through the interposed malloc; tolerant `free`
  delegating non-pool pointers to libc + mmap-backed arenas — fragile
  (`ptrinpools` false-negatives) and still loses to glibc's chunk assumptions.

---

## LP64 Dis port (implemented)

The Dis VM was a 32-bit model: `IBY2WD = 4` was used both for the Dis `int`/word
size *and* for pointer size, but the interpreter already stores native C pointers
(`P(r)` is `*((WORD**)(R.r))`, `initmem`/`markheap`/`freeptrs`/`gc.c` all stride
`w += 8` as `WORD**`). On LP64 those native pointers are 8 bytes, so the `.dis`
4-byte pointer layout no longer matched the interpreter. The fix makes pointers a
genuine 8-byte slot everywhere, on both the compiler and VM sides, kept in lockstep
by **one new constant**:

- **`include/isa.h`**: added `IBY2PTR = 8` — the Dis pointer/register-slot size,
  distinct from `IBY2WD = 4` (the Dis `int` size, which stays 4). `IBY2PTR` must
  equal `sizeof(void*)`; `libinterp/xec.c` has a `typedef`-based compile-time assert.

**limbo (compiler) changes — emit 8-byte layouts + 8-byte-granular maps:**
- `types.c`: pointer singletons (`tstring`, `tany`, `rtexception`) and the pointer
  kinds (`Tref/Tchan/Tarray/Tlist/Tmodule/Tpoly`) sized `IBY2PTR`; `Tfix` kept at
  `IBY2WD` (it is a scaled int, not a pointer). `tfnptr` second field offset →
  `IBY2PTR`. Map machinery (`mkdesc`/`mktdesc`/`tdescmap`, new `setmapbit` helper):
  one map bit per `IBY2PTR`-byte slot (matches `initmem`). `Talt` and `Tcasec`
  layouts use pointer-sized entries; `Tcase`/`Tcasel`/`Tgoto`/`Tiface` are all-int
  and unchanged.
- `limbo.h`: `STemp/RTemp/DTemp/MaxTemp` use `IBY2PTR` (frame register/temp slots
  are pointer-sized → frame header matches the interpreter `Frame` struct).
- `gen.c`/`ecom.c`/`optim.c`: REGRET slot offset `IBY2PTR*REGRET`; `tfnptr` field
  access; the single-channel-comm alt layout. `decls.c`: function frame total size
  aligned to `IBY2PTR`. `dis.c`: `Tcasec` data serialized with pointer-sized slots.
  `com.c`/`ecom.c`: alt channel table entries are `{Channel*; void*}` (2×`IBY2PTR`);
  the borrowed-channel "lie to the GC" store uses an 8-byte raw move (`tbig`/IMOVL).
- `stubs.c` (`limbo -T`, regenerates `runt.h`/`*mod.h`): C builtin frame structs use
  pointer-sized register slots (`void* regs[NREG-1]`, `void* noret`,
  `temps[MaxTemp-NREG*IBY2PTR]`) so they match the interpreter frame on LP64.

**limbo (compiler) changes — pointer-width temporaries, comparisons, and
analysis (each of these is a real crash class, not a tidy-up):**
- `ecom.c` `callcom()`: the call-frame-pointer temp (`IFRAME`/`IMFRAME` dst,
  `ICALL`/`IMCALL` src) was `talloc(&frame, tint, …)` — a 4-byte slot holding an
  8-byte frame pointer. `idoffsets` packs by each decl's own `ty->align/size`, so the
  4-byte slot overlapped the adjacent pointer local; storing the 8-byte frame pointer
  clobbered the neighbour's low word (`0xaaaa0000aaaa`-style). Now `talloc(&frame,
  tbig, …)`: `tbig` is 8 bytes / 8-aligned with `isptr=0`, so the GC does not trace
  it — matching the original 32-bit intent where `tint` was exactly pointer width and
  untraced. (`tany` would be wrong: `isptr=1` would make the GC trace a non-heap
  frame pointer.) This was the bug that blocked list+format-print.
- `ecom.c` `arraycom()` (array literal initialisation `array[] of {…}`): the temp
  holding the indexed element **address** (`Oindx` result, dereferenced via an
  `Oind` fake node) was `talloc(&tmp, tint, …)` — same 4-byte-pointer overlap. Now
  `tbig`. General rule learned: **any temp that receives an address-producing op
  (`ILEA`/`IND*`/`Oindx`/`Oadr`) must be pointer-width.** `eacom()` was already
  correct (it `talloc`s with the node's own `ty`); the dead `LDT` branch at ~1290 and
  the genuine int temps (`ri` range counter, `n` length, `which` alt index, the
  `Oinc`/`Oinds` arithmetic scratch) correctly stay `tint`.
- `gen.c` `genbra()`: pointer comparisons (`p == q`, `p == nil`) were compiled to the
  column-0 word ops `IBEQW`/`IBNEW`, which only test the low 32 bits of an LP64
  pointer. `opind[]` leaves pointer kinds (Tref/Tchan/Tarray/Tlist/Tmodule/Tpoly/Tany)
  at the default column 0; `genbra` now redirects those (when `opind==0 &&
  tattr.isptr && IBY2PTR==IBY2LG`) to the `Tbig` column, giving the 8-byte `IBEQL`/
  `IBNEL`. `Tstring` keeps its own column (`IBEQC`, content compare) and numeric kinds
  keep theirs; only comparisons reach `genbra` and pointers only use `Oeq`/`Oneq`,
  both of which have valid long-compare opcodes. (`genop` is **not** changed: pointer
  types legitimately use column 0 there for `Oindx`→`IINDX`, `Olen`→`ILENA`.)
- `optim.c` operand-size enum: `P` (pointer), `A` (array), `C` (string) were `4`. The
  optimizer's use-def/liveness analysis uses these to decide how many bytes each
  operand touches (`finddec(off, size, …)`); with `P=4` a pointer store marked only 4
  bytes, so the high 4 bytes of a pointer slot looked dead and another decl was
  coalesced over them (`0xffffffff0000xxxx` / duplicated-half corruption). Now
  `P=A=C=IBY2PTR`. `X` (fixed, a scaled int) correctly stays 4.
- `ecom.c` `rewrite()` `case Oindex` (~line 258): `a[i]` is rewritten to
  `Oind(Oindx(a,i))`; the inner `Oindx` node computes the **address** of the indexed
  element, and its type was hardcoded to `tint`. When that address has to be
  materialised into a temp (e.g. `a[k] = b[i]`, or any `0(elemaddr(fp))` indirect
  addressing — `IND*` writes the element address to the `m` operand), the temp was
  4-byte; on LP64 the 8-byte element address overran the adjacent temp (two
  element-address temps ended up 4 bytes apart and the second clobbered the first's
  low word). Now `tbig` (8-byte, 8-aligned, `isptr=0` — an interior pointer the GC
  must not trace). This was the `Readdir`/`mergesort` `array of ref Dir` crash. The
  general pattern across all five fixes: **anything that holds or computes a pointer/
  address — a temp, a comparison, the optimizer's notion of a slot's width — has to be
  pointer-width (IBY2PTR), and `tint` (IBY2WD) was the recurring 32-bit-ism.**

**VM (interpreter/loader) changes:**
- `xec.c`: `Stmp`/`Dtmp` macros use `IBY2PTR`; `OP(lea)` stores a full pointer
  (`T(d)=R.s`, was a truncating `W(d)=(WORD)R.s`); `OP(indx/indw/indf/indl/indb)`
  store the element address as a full pointer (`T(m)=...`, was truncating `W(m)`);
  `consp` allocates `IBY2PTR` for a pointer list element; `movtmp` reads the channel
  element type from `c->mid` as a full pointer (`T(m)`, was `W(m)`); `icase`/`casel`/
  `igoto` use byte arithmetic on `R.d` (was `(WORD)R.d`, truncating); `casec`
  rewritten for pointer-sized `{String* low; String* high; int dest}` entries.
- `runt.c`: `cons(IBY2PTR,...)` for the tokenize string-list; the vararg formatter
  (`%s`/`%H`) aligns to `IBY2PTR` and advances by `IBY2PTR` for pointer args.
- `load.c`: `brpatch` stores absolute branch/spawn targets in the `Inst.d.ins`
  pointer member (was the truncating `WORD d.imm`; `JMP` reads `*(Inst**)&d.imm`).

**Build / dis tree:** the build order is limbo → libinterp (regenerates
`runt.h`/`*mod.h` maps) → emu, then the whole `appl/lib` and `appl/cmd` dis
trees recompiled with the new compiler. The two ABIs' `.dis` cannot be mixed
with the wrong VM, so any `.dis` a build loads must come from its own compiler.

### Pointer-width `.dis` magic + recompile-on-mismatch
A 64-bit and a 32-bit Dis **reject each other's binaries** instead of silently
mis-running them:
- **`include/isa.h`**: `XMAGIC8`/`SMAGIC8` (= `XMAGIC`/`SMAGIC` `| 0x100000`), the
  64-bit-pointer-ABI magics; on this branch `IBY2PTR=8`, on master `IBY2PTR=IBY2WD`.
- **compiler** (`limbo/com.c` and `appl/cmd/limbo/com.b`) stamps the magic selected by
  `IBY2PTR`: 64-bit → `XMAGIC8`, 32-bit → `XMAGIC`.
- **loader** (`libinterp/load.c`) accepts only this build's width; the other width's
  magic is rejected with a distinct catchable error `exDiswidth`
  ("dis module compiled for wrong pointer width"); garbage still says "bad magic".
- **`appl/cmd/limbo` carries the same LP64 port** (mirrors of the C-compiler
  changes in `isa.m`/`limbo.m`/`types.b`/`ecom.b`/`gen.b`/`com.b`/`decls.b`/
  `dis.b`/`stubs.b`), so the **self-hosted `/dis/limbo` emits correct 64-bit
  `.dis`** — this is what the recompile path runs. (Note: there are **two**
  compilers — the C `limbo/` host binary that `mk` uses, and the Limbo
  `appl/cmd/limbo/` one compiled to `/dis/limbo.dis`; a width change must land
  in both. `appl/cmd/limbo/optim.b` is a no-op stub, so no optimizer liveness
  fix is needed there.)
- **recompile-on-mismatch** (`appl/cmd/sh/sh.b`): on the wrong-width error, sh reads the
  source path embedded at the end of the `.dis` (the trailing `source` string, read
  width-independently), and if that `.b` exists runs `limbo -o <dis> <src>` and retries
  the load once. Validated: a stale 32-bit `.dis` is auto-rebuilt from `/appl/cmd/*.b`
  and run.
- **dis readers** (`module/dis.m`, `appl/lib/dis.b`) accept both magics (mdb/rt/the
  recompile lookup read only the width-independent header/stream).

Bootstrap caveat: a fresh checkout's committed `.dis` are the old `XMAGIC` tree, which
the new emu-g rejects; you must build (`make`) and recompile the dis tree once. The
recompile-on-mismatch only helps for *application* modules once a correct-width
`emuinit`/`sh`/`limbo` core is in place.

### Reading a width-bug fault in gdb
The recipe for the whole bug class: run under gdb **without**
`-s` (so SIGSEGV stops inside the faulting VM `OP()` rather than the signal handler),
`bt` to see which op, then read `R` at its **literal** address (gdb's symbolic `&R`
is wrong because emu is built `-O`; find `R`'s static address with `nm emu-g | grep
' R$'` and add the ASLR-off load base `0xaaaaaaaa0000`). From `R`: `R.PC` (+0), `R.FP`
(+16), `R.M` (+48), `R.s/d/m` (+72/80/88). The faulting Dis instruction is at
`R.PC - sizeof(Inst)` and `sizeof(Inst)==24` on LP64 (`op,add,reg`=4 + pad + two
8-byte `Adr`s, because `Adr` contains an `Inst*`). The corrupt value's bit pattern is
diagnostic: `0xffffffff0000xxxx` = high-half overwrite (overlap/coalesce of a slot
that held `H`); `0xXXXXXXXXXXXXXXXX` with equal 32-bit halves = a low-half value
duplicated; two distinct small halves = an 8-byte read straddling two int fields.

### Fault-path instrumentation
- `emu/Linux/os.c` `sysfault()`: prints `LP64 fault: ... in <module> pc=<n> op=<n>`
  via `modstatus(&R,...)` — a permanent part of the fault path (the recoverable,
  non-`EMUCRASH` branch — see ON_DEBUGGING.md "Graceful failure isolation"),
  kept for per-module fault triage.
- Reading a reported `pc=N`: the dispatch loop increments `R.PC` **before** running
  the op, so during a fault `R.PC` points at the *next* instruction; the faulting
  instruction is typically `pc-1` (account for this when matching a `limbo -S`
  listing). `limbo -S file.b` writes the Dis assembly listing to `file.s`.

### Hardening fixes
- **Big (64-bit) constants** (`libinterp/load.c` DEFL): `(LONG)hi<<32 |
  (LONG)(ulong)lo` sign-extends a low word with bit 31 set on LP64 (`ulong` is
  8 bytes), so e.g. `big 123456789012` loads as `-1097262572` while constants
  whose low word's bit 31 is clear are fine by luck. The low word is
  `(u32int)lo` (zero-extend); the high word keeps the sign. VM-only.
- **Exception value layout:** the exbasetype
  `{string name; tag; args}` header is now IBY2LG-aligned (tag is `tbig` on LP64
  → `{string(8),tag(8)}=16`) so the user args sit at an 8-aligned offset and line
  up whether accessed (laid out from 0) or constructed (from the header); the
  skip is `align(IBY2PTR+IBY2WD, IBY2LG)`. A non-8-aligned `{string,int}=12`
  header desynced the two once args of mixed alignment appeared
  (`exception(int,string,big)` corrupted/crashed). Fixed in both compilers
  (`limbo/{ecom.c,types.c}`, `appl/cmd/limbo/{ecom.b,types.b}`); 32-bit unchanged;
  runtime reads only the offset-0 name string so the wider tag is invisible.
  Verified incl. `fibonacci` (computes via `FIB(int,int)` exceptions) and the
  in-emu `/dis/limbo`.
- **Replicate array fill** (`limbo/ecom.c` + `appl/cmd/limbo/ecom.b`,
  `arraydefault`): `array[n] of {* => v}` typed its `Oindx` element-address node
  `tint`, so on LP64 the 8-byte element address overran its 4-byte temp and the
  fill stored through a corrupt (duplicated-half) pointer — faulting for any
  non-zero replicate of a real/big/pointer-element array (zero fills are optimised
  away, which hides it). Typed pointer-width, same as `rewrite()`'s `Oindex` and
  `arraycom`'s temp.

### The pointer-width `tint` bug class — audited (don't whack-a-mole)
Every LP64 bug here is the same shape: a slot that holds/computes a **pointer or
address** used `tint` (`IBY2WD`=4) where it needs `IBY2PTR` (latent on 32-bit
where pointer==word), or a 64-bit value reconstructed by extending a 32-bit half
wrong. A `tint` node/temp is a bug **only when its own type drives the move width
AND it holds an address/pointer value** — i.e. a *materialised* address or a
loaded pointer. `tint` temps used only as intermediates for explicitly-typed
`genop`/`genmove` (big/real `++`/`--`/`+=`, op-assign-in-expression,
big-array-element `+=`) are safe — the op carries the operand type. So **most
`tint` is correct; do not blanket-convert.**

**Use `tptr`, not `tbig`, for these slots.**
The materialised-pointer slots must be **pointer-width**: `IBY2PTR` bytes — 4 on
ILP32, 8 on LP64. `tbig` is a fixed 8-byte/`IMOVL` type, so it is correct on LP64
*only because* `IBY2PTR == IBY2LG` there; on a 32-bit build (the C compiler gets
`IBY2PTR = sizeof(void*) = 4`; the self-hosted one gets `IBY2PTR = con
sizeof(string)`) a bare `tbig` emits 8-byte moves for 4-byte pointers and corrupts
the neighbouring slot — i.e. bare `tbig` silently pins the compiler to 64-bit and
defeats the one-tree dual-ABI goal. The fix is a single pointer-width, **untraced**
type `tptr = (IBY2PTR == IBY2LG)? tbig : tint` (both `isptr=0`; `tany` is
pointer-width too but `isptr=1`, so the GC would wrongly trace a non-heap interior
pointer). Defined once (`limbo/types.c` + `limbo.h`; `appl/cmd/limbo/types.b` +
`limbo.b`) and used for the whole class: the `Oindx` element-address nodes
(`rewrite` Oindex, `arraydefault`, `arraycom`), the `callcom` call-frame temp, the
borrowed-channel raw move (`com.c`/`ecom.c`), **and the newly found imported-global
load (below)**. On LP64 `tptr ≡ tbig`, so the change is byte-identical codegen
there (the 178-assertion suite + acme/charon stay green and *prove* no
regression); ILP32 becomes correct. Genuine-`big` sites stay `tbig`
(`globalBconst`; the alignment-guarded exception/pick-tag header, which is already
`IBY2PTR`-conditioned).

**Imported global VARIABLES — the GUI-app launch crash.** Accessing a
variable imported from another module (`x: import othermod`, e.g. acme's
`display: import gui`) is rewritten (`ecom.c`/`ecom.b` `rewrite()` Omdot/Dglobal)
to `Oind(Oadd(Oind(module), field_offset))`: load the foreign module's
data-segment pointer (`Modlink.MP`), add the global's offset, load the field. An
inner `Oind(module)` load typed `tint` is a 4-byte `movw` on LP64 that
truncates/sign-extends the 8-byte `Modlink.MP` (e.g. fault at
`0xffffffff2c138d00`); the next deref faults **at app launch**. The trap: apps
that read another module's globals (acme, charon) crash immediately while apps
that don't (bounce, tetris, clock, …) are fine, and a test suite that imports
only functions and types never exercises the path. The load is typed `tptr`.
Regression: `suites/80_modglobal.b`
(imports ref/string/list/array globals from `lib/modglobals`; reverting the fix
turns it `BROKE` with the segfault). `Oadr` nodes still always fold into an `Oind`
addressing mode (the compiler `fatal`s otherwise), so no other truncating
materialisation remains.

### External test battery
`github.com/caerwynj/inferno-lab` (~281 real Limbo programs) is a useful
one-shot battery beyond the in-repo suites: compile every program, then run
headless and flag `segmentation violation`/`illegal dis` (ignore "module not
loaded" = uninstalled deps and "dereference of nil" = missing args — those are
environment, not codegen). Expect a few dozen compile errors from source-level
API drift; they are not LP64 findings. Not wired as a standing harness.

### In-repo headless test suite — `tests/dis/` (standing regression harness)
A self-contained TAP suite that exercises the Dis VM + Limbo end-to-end through
`emu-g`, no display needed. `tests/dis/run.sh` compiles each `suites/*.b` with the
C `limbo`, runs it under `emu-g`, and aggregates `ok`/`not ok` (via the shared
`lib/testing.{m,b}` helper). **178 assertions across 9 suites, all green.** Exits
non-zero on any failure/crash; tolerates the benign teardown SIGKILL (rc 137; see
below) but flags a mid-run VM break (`BROKE`/`NOPLAN` — a suite that never reaches
summary()'s `1..N` plan line). `run.sh` compiles every `lib/*.b` helper first, with
`-I module -I appl/lib -I tests/dis/lib`. The suites:
- `00_vm` — big/real constants+math, strings, lists/tuples/arrays incl. replicate
  fill, pick-ADTs, data-carrying exceptions, and the modern features (`**`,
  `fixed()`, function refs). Regression-guards every pointer-width fix above.
- `10_concur` — spawn fan-in, buffered/unbuffered channels, the chan-mutex idiom,
  `alt`, a sentinel-terminated prime sieve, chan-of-ref request/reply, and a
  retained list surviving ~1M churned allocations (GC pointer-map traversal).
- `20_crypto` — Keyring md5/sha1/sha256 (one-shot+incremental) vs published
  vectors, AES/DES-CBC round-trips, and IPint modexp/add/mul (the `libmp` C-port
  on LP64).
- `30_styxnet` — real TCP loopback through `devip` (Dial announce/listen/accept/
  dial), Styx `Tmsg`/`Rmsg` pack/unpack incl. 64-bit offsets, `packdir`/
  `unpackdir` with a >4 GiB length.
- `40_selfhost` — drives the in-emu `/dis/limbo.dis` to compile a generated module
  then loads+runs it (also proves XMAGIC8 emission via a successful load).
- `50_loader` — `$Loader` `ifetch`/`tdesc`/`link` → `newmod`/`tnew`/`dnew`/`ext`
  round-trip with a byte-for-byte instruction match + forced-GC teardown; the
  Limbo-level guard for the three `loader.c` fixes.
- `60_plumb` — the plumber stack (never exercised before): `Regex` compile/execute/
  executese incl. multi-range classes and submatch capture, `Plumbmsg` pack/unpack
  + attribute parsing, and the `Plumbing` rule parser (regex-backed `matches`). 48
  assertions; loads `Plumbing` from `appl/lib`.
- `70_except` — exception unwinding across **non-matching** handlers (the `NOPC`
  fix's regression): single/stacked fall-through, catch-all, the `fail:` command
  convention, and **cross-module** raise/catch via the helper `lib/exraise.{m,b}`.
  Reintroducing the old 32-bit `NOPC` drops it from 9 → 1 assertions (the proc
  breaks mid-run), which the `BROKE`/`NOPLAN` guard now flags.
- `80_modglobal` — cross-module **imported global variables** (the acme/charon
  launch-crash regression): imports ref/string/list/array globals from the helper
  `lib/modglobals.{m,b}` and reads them back, exercising the `Modlink.MP` load that
  the `tptr` fix repairs. Reverting the imported-global load to `tint` turns it
  `BROKE` with the truncated-pointer segfault. 12 assertions. **This path is the
  one the GUI apps hit that nothing else in the suite did** (the suites otherwise
  import only funcs and types, never global variables).

### GUI app sweep — `tests/dis/gui_sweep.sh` (compile + headless launch)
The TAP suites never open a window, so GUI-only LP64 crashes (like the imported-
global one) need a separate net. `gui_sweep.sh` has two phases: **(1) compile** —
runs `limbo` over every `.b` under the GUI app trees (`appl/{wm,acme,charon,ebook,
demo,spree,tiny,…}`) and flags compile errors; **(2) launch** — starts each
top-level GUI app under `Xvfb` + `wm/wm` with the graphical `emu`, waits a few
seconds, and FAILs it only if the emu log shows a C-level VM crash (`LP64 fault`/
`segmentation`/`Broken:`/`illegal dis`/`panic`). Benign env noise (no `/tmp`, no
plumber, no network) is ignored — we hunt VM crashes, which is where LP64 bugs
live. The expected baseline: 4 known compile errors (`mpeg`, `qt`, `samtk`,
`paginate` — source-level API drift, not LP64) and **every launched app
crash-free** (acme, charon, and ~20 `wm` apps). Caveats baked in: never
`pkill -f <pattern>` from the script —
it matches the script's own command line and kills it; bound each emu with
`timeout -s KILL` instead. The full launch phase runs ~2 min, so run it
backgrounded (it exceeds a 120 s foreground budget).

**Gotchas baked into the suite (read before extending):** (1) tests live in the
repo tree and reference inferno paths under the emu root (`/tests/dis/...`,
`/module`); generated files go in `_build/` (git-ignored), **not `/tmp`** — `/tmp`
is not in the headless namespace. (2) `exit` is a no-arg statement; programs signal
pass/fail through TAP, not an exit status. (3) **any spawned helper proc must
terminate** (sentinel/bounded) or `emu-g` hangs until the timeout — a leaked
infinite producer stalls every run. (4) the post-run rc 137 SIGKILL is the pre-existing benign
emu-g teardown (repro: bare `echo hi`), output always completes first — the harness
treats 0/1/137 as non-error **but** still requires summary()'s `1..N` plan line and
the absence of `Broken:`/`illegal dis`/panic, so a tolerated exit code can no longer
hide a mid-run VM fault (this is how `70_except` catches the `NOPC` regression).

### `$Loader` on LP64 — runtime module reflect/rebuild
`$Loader` (`libinterp/loader.c`, the `Loader->ifetch`/`newmod`/`link`/`tdesc`
reflective interface) round-trips a module's instructions to/from Limbo. Its
three LP64 hazards (all VM-only, no `.dis` change; `50_loader` is the
regression):
1. **brunpatch** must read a branch target from the full `Inst*` in `i->d.ins`
   (8 bytes), not the truncating 4-byte `i->d.imm` — otherwise the recovered
   instruction index is garbage and `newmod`'s `brpatch` rejects it.
2. **`Loader_newmod`** must `memset(m,0,sizeof(Module))`: a Module with only
   some fields set leaves `ldt`/`htab`/`ext`/`link`/`dlm` as garbage 8-byte
   pointers that the teardown (`freemod`/`destroylinks`) walks → crash.
3. **`destroylinks`** (`link.c`) guards `m->ext` against nil — a `newmod`'d
   module has `ext==nil` (as `freemod` already guards `ldt`/`htab`).

### Deferred LP64 items (compile fine; off the emuinit/sh boot path)
- **`asm.c` `-S` listing**: the textual assembly listing's `Tcasec` case was not
  updated for pointer-sized entries (the binary `dis.c` path was). Listing/debug
  only; does not affect execution.
- **`emu/port/devprog.c`, `devprof.c`**: a few pointer↔int casts (the `/prog` and
  `/prof` filesystems expose VM pointers as text) warn under LP64; revisit if those
  devices are used.

### Open runtime bug — idle-Charon heap corruption (stray free-tree pointer)

The one known open runtime bug, and it has a strong LP64 fingerprint. Closing a
Charon window that has been **left idle for ~an hour** (intermittently) aborts the
whole emu: the pool free-tree integrity auditor (`poolcheck`/`poolaudit`, armed by
default — `EMUPOOLCHECK`, every 64th GC) detects a corrupt free block, or the
teardown `pooldel` dereferences the bad pointer and faults.

**Signature (two independent cores analysed):** a freed **128-byte block in the
`main` pool** whose free-tree **`parent` pointer** has had **bit 36 cleared**
(equivalently `- 0x10_0000_0000` / `^ (1<<36)`) — the **low 32 bits stay intact**,
only the high half loses that one bit. Proven by the back-pointer (the real parent's
`left` child points at the victim, and the stored value is that address minus bit
36, now unmapped). **Same bit, same size class, only the `parent` field, in two
ASLR-independent processes** → a systematic software bug, not hardware and not a
torn/stale store (aligned 64-bit stores don't tear).

**Why it reads as LP64:** bit 36 sits just above the 32-bit boundary, and the bug
only turns *fatal* when ASLR maps the arena high enough that bit 36 is set in real
pointers (matches the "ASLR-off masks high-address bugs" observation). That points
at a 64→32 narrowing / bad mask in some pointer arithmetic. **The allocator is
exonerated** (`alloc`/`free`/coalesce/`pooldel`/`pooladd`/`poolcompact` all copy
`parent` as clean 64-bit stores; the free tree is verified *clean during idle* —
the corrupting write happens at the move-window + close teardown). So an external
writer is hitting the high half of that slot.

**Status:** characterised, not yet root-caused — **parked**. It is not data-loss
(crash on close), and `poolcheck`'s `abort()` on detection is the correct, safe
response (never continue on a corrupt heap). Next step is a static hunt for the
`1<<36` / `- 0x1000000000` pointer-arith site (weight the draw/teardown path and the
`tests/lint/baseline.txt` narrowing sites), or mining a fresh core for the freed
object's identity. Full detail + repro recipe: the project memory note
`charon-close-heap-corruption` and ON_DEBUGGING.md ("Graceful failure
isolation", `EMUCRASH`, `EMUPOOLCHECK`).

## Second LP64 target: Linux/amd64 (x86-64) — glue added, UNBUILT/UNTESTED
amd64 Linux is also LP64, so it **reuses the entire shared LP64 model** (the
`IBY2PTR=8` Dis ABI, the compilers, the interpreter, **the committed XMAGIC8 `.dis`
tree** — which should run unchanged) and adds only thin arch glue. None of it
has had a real build or run yet; the asm is written by hand from the 386 +
aarch64 references and needs a build + test pass on an x86-64 host.

Files added (all amd64-specific; no shared code changed):
- `mkfiles/mkfile-Linux-amd64` (`gcc -m64`, `-DLINUX_AMD64`), `emu/Linux/mkfile-amd64`
  (empty `ARCHFILES`; `_tas` lives in `asm-amd64.S` as on 386).
- `Linux/amd64/include/{lib9.h,emu.h,fpuctl.h}` — `lib9.h` is the aarch64 copy with
  `getcallerpc` via `__builtin_return_address(0)`; `emu.h` `FPU env[64]` (x87 env +
  MXCSR) and `getup` via `%rsp`.
- `emu/Linux/asm-amd64.S` — `umult` (`mulq`), `FPsave`/`FPrestore` (`fnstenv`+`stmxcsr`
  / `fldenv`+`ldmxcsr`), `_tas` (`xchg`). `emu/Linux/segflush-amd64.c` — no-op (x86 is
  I-cache coherent).
- `lib9/setfcr-Linux-amd64.S` — x87 control/status (`fldcw`/`fnstcw`/`fnstsw`) with the
  Inferno `xorb $0x3f` FCR ABI, arg in `%edi`. `lib9/getcallerpc-Linux-amd64.S` — build
  stub (real impl is the lib9.h inline).
- `libinterp/comp-amd64.c` (interpreter-only JIT stub), `libinterp/das-amd64.c` (no-op).
- Build with `make OBJTYPE=amd64 all` (the top Makefile `OBJTYPE` is now overridable).
  libmp/libsec need nothing: with no `Posix-amd64` asm dir they use the C `port/`
  fallback, exactly as aarch64 does.

Known caveats to check on first real build/run:
- **FP control is x87-only.** `setfcr`/`getfcr`/`getfsr` drive the x87 control/status
  words (matching 386), but the interpreter's `double` arithmetic runs on SSE2
  (MXCSR). FP *results* are correct regardless; only explicit `Math->FPcontrol`
  rounding-mode changes won't reach SSE, and `getfsr` reports x87 (not SSE) exception
  status. Wire MXCSR into setfcr/getfsr if a program needs non-default rounding.
- **`FPsave`/`FPrestore`** save x87 env + MXCSR via `fnstenv`/`fldenv` (no alignment
  requirement) — verify proc-switch FP isolation once running.
- Bootstrap: `mk` must first be built for `Linux/amd64` (the Makefile expects
  `Linux/amd64/bin/mk`), same chicken-and-egg the aarch64 bring-up had.

### Alternatives considered (and rejected)
- **`-mabi=ilp32` (32-bit pointers on aarch64):** would keep the 4-byte `.dis`
  layout but needs an aarch64 ILP32 libc that stock Ubuntu does not ship.
- **Compile emu as 32-bit ARM:** not aarch64; out of scope.

---

## Catching LP64 width bugs statically and semantically

The defining bug class of this port is the **64→32 truncation**: a 64-bit value
(usually a pointer) silently narrowed to 32 bits, which later faults as a wild
pointer far from its cause, or wedges a loop/scheduler. Four layers catch a
truncation *before* it corrupts anything — at compile, link/load, and (debug) run
time. (For *runtime* catching of a truncation that already slipped through and
faulted/hung, see the fault/hang hooks in `ON_EMU_DEBUG.md`; for the
sanitizer/Valgrind audit of the C, same doc.)

### `make lint` — clang 64→32 narrowing lint

clang's `-Wshorten-64-to-32` is exactly this bug class as a warning, and gcc has
no equivalent. `tests/lint/run.sh` (via `make lint`) asks `mk -n -a` for the real
per-file compile flags of every host C file (libs + emu) and replays each through
clang in `-fsyntax-only` mode with only that warning on, diffing against
`tests/lint/baseline.txt` so a **new** narrowing fails the run while the ~246
pre-existing (mostly benign) ones stay quiet. gcc remains the production compiler.
`make lint-all` lists every site; `make lint-update` re-baselines after triage.
See `tests/lint/README.md`.

**Triage note (real bug vs benign):** a left-shift/overflow finding is a real LP64
bug only when the value **sign-extends into a wider (64-bit) field used at full
width** (e.g. `(uchar)<<24` → negative int → `0xFFFFFFFF…` in a `ulong`). If the
result is stored into a 32-bit field, masked, or truncated, it is benign
2's-complement UB (correct result). The graphics pixel pipelines, crypto/bignum
byte-assembly, the string hash, `operand()`, and `memmove(x,nil,0)` are all benign
(verified: correct render + crypto vectors); the real ones found this way were the
sign-extending `mode`/9P-field/`disw` family.

### `genmove` width assertion (limbo compiler)

The move/cons opcode the code generator picks from a type's kind has a fixed width
(`IMOVW`=4, `IMOVL`=8, `IMOVP`=`IBY2PTR`, …); it must equal the type's size or the
emitted code moves the wrong number of bytes — the truncation class. `genmove`
(both `limbo/gen.c` and `appl/cmd/limbo/gen.b`) asserts `movewidth(op) == mt->size`,
a compile-time guard against type/optab/size drift. (`tptr = IBY2PTR==IBY2LG ? tbig
: tint` is what keeps pointer temps in step across both ABIs.)

### GC pointer-map vs layout (libinterp)

`markheap` traces the pointer at every set bit of a type's map, at byte offset
`slot*IBY2PTR`. `verifytype()` (`heap.c`) asserts every set bit lies wholly within
the object's size; the `.dis` loader (`load.c`) runs it on each type descriptor — a
module that parses but whose maps are inconsistent for this ABI is rejected up
front, naming the module. `verifyctype()` runs at init for the C-registered draw
types, additionally requiring a generated ADT map to stay within the Limbo ADT
prefix it describes (the C-only tail pointers are deliberately untraced) — a
mismatch panics at boot.

### `make emu-disptrcheck` — "Valgrind for Dis pointers"

A `-DDISPTRCHECK` build validates every map-marked pointer slot against the live
heap as the GC walks it: a real reference is `H`, or points just past a `Heap`
header inside a heap arena (`ptrinpool`), with a sane GC colour. A 64→32 truncated
pointer fails all three and is reported (type, object, byte offset, value) at the
first GC after it is installed, instead of crashing layers away when chased; the
slot is then skipped. Debug only (slow); `make emu` reverts to production. This is
the dynamic analog of `verifytype`/`verifyctype`.

> **Layering of all the LP64 defences.** `make lint` + the `genmove` assert catch
> width bugs at **build time**; `verifytype`/`verifyctype` at **load/init**;
> `DISPTRCHECK` at **run time** as the GC walks; and the runtime fault/hang hooks
> (`EMUCRASH`/USR2/`EMUWATCHDOG`, in `ON_EMU_DEBUG.md`) when one still gets
> through and faults or hangs.
