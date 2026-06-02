# AArch64 Port — In-Progress Notes (what is stubbed / disabled, and why)

Status as of this work: the aarch64 host toolchain (`limbo`, `mk`, `iyacc`) and the
emulator (`emu-g`) **build and link**, the **LP64 Dis pointer-model port is
implemented**, and **`emu-g` runs Limbo without failure** — the project goal is met.
A full interactive `sh` session works: command execution, **pipes** (`echo 1 2 3 | wc`
→ `1 3 6`), **I/O redirection**, **globbing** (`ls *.dis | wc`), **directory reads**
(`ls`, which drove the last bug via `readdir`), **`ps`** (lists the live Dis VM
procs), **env vars** (`echo $emuhost` → `Linux`), `cd`, dynamic builtin load
(`load std`), and shell **control flow** (`for`, `if`, `ftest`). Module load, mcall
to C builtins, varargs `print`, function frames, list build+iterate+format-print, and
`array of ref` sort/merge all execute correctly.

The port came together as a **sequence of "this codegen/analysis path still assumes
4-byte pointers" bugs**: each full dis-tree recompile with the corrected compiler
pushed the boot further and exposed the next unconverted pointer path. This session
fixed **five** distinct root causes — call-frame temp, array-literal element-address
temp, pointer comparison opcodes, optimizer liveness sizes, and the indexed-element
address node type (the `Oindex`→`Oindx` rewrite) — all detailed below. There are no
known remaining crashes on the CLI path. (Off-path LP64 items remain deferred:
exceptions/EXLP64, `$Loader`, the `-S` `Tcasec` listing, devprog/devprof — see
"Deferred LP64 items".)

**CRITICAL build gotcha (cost real time this session):** `mk`'s dependency tracking
does **not** rebuild a `.dis` when only the *compiler* changed and the `.b` is
unchanged — `mk install` over `appl/` is a **no-op** for unchanged sources. After any
`limbo` change you MUST force a full dis recompile, e.g. `find appl -name '*.b' -exec
touch {} +` then `mk -k <MKARGS> install`. Several "the fix didn't work" dead-ends
this session were actually stale `.dis` from the old compiler.

This file records every place where something was turned off, stubbed, or worked
around, plus the LP64 port design and the open bug, so the next person knows what
is real vs. deferred.

Build with the top-level `Makefile` (wraps `mk`, which has unreliable incremental
dependency tracking — the Makefile nukes objects between components):

```
make all          # builds Linux/aarch64/bin/emu-g
```

---

## Fixes (correct, not stubs — listed for context)

These are genuine 64-bit correctness fixes, not shortcuts:

- **`libmath/dtoa.c`** — David Gay's `dtoa` assumed the bignum word type and the
  two halves of an IEEE double are 32 bits. On LP64 `long` is 64 bits, which
  corrupted the bignum arithmetic and made `word0`/`word1` read past the end of
  the double. Pinned the word type to 32 bits (`typedef unsigned int ULong; typedef
  int Long;`). Without this the freshly built `limbo` segfaulted while generating
  `runt.h`.
- **`emu/port/alloc.c`** — the pool allocation quantum was `31` (32-byte minimum
  block). A free block stores its tree node *in-band* in the `Bhdr` union; on LP64
  that node is 56 bytes + 8-byte `Btail` = 64 bytes, so 32-byte blocks let the
  free-tree pointers and trailer spill into the neighbouring block. Changed the
  quantum to a word-size-aware value (`#define QUANTA (sizeof(Bhdr)+sizeof(Btail)
  <= 32 ? 31 : 63)`), so 64-bit builds use 64-byte minimum blocks. No-op on 32-bit.
- **`Linux/aarch64/include/lib9.h`** — `#define READ 4` should have been
  `#define AREAD 4` (the `access(2)` mode used by `libdraw/subfontname.c`). Typo
  fix.

---

## Stubbed / disabled

### JIT compiler — `libinterp/comp-aarch64.c` replaced with an interpreter-only stub
- **What:** The committed `comp-aarch64.c` (a WIP AArch64 JIT) does not compile —
  wrong macro arity (`DP`/`DPI`), undefined `uint32_t`, duplicate `Cmp`, bad
  pointer types — and its instruction *encodings* are incorrect throughout
  (e.g. `RET`/`DPR`/`DPI`/`B` macros emit wrong opcodes). It was never built.
- **Now:** `comp-aarch64.c` is a stub whose `compile()` returns 0, forcing every
  module onto the interpreter (the canonical, architecture-independent execution
  path). `comvec` stays nil, so `xec.c` never dispatches to native code.
- **Why:** The interpreter is correct and sufficient to run Limbo; a JIT is an
  optimization. Shipping a JIT that emits wrong code would be a landmine for anyone
  passing `emu -c`. The original attempt is preserved verbatim as
  `libinterp/comp-aarch64.c.jit-wip` for whoever revives it (see AGENTS_JIT.md and
  AGENTS_AARCH64.md for the encoding details a real back-end needs).

### Disassembler — `libinterp/das-aarch64.c` made to compile (approximate)
- **What:** Added `#include <stdint.h>`, added a missing `imm3` field, removed a
  duplicate `case 0x1E`. The instruction *classifier* is still approximate (it
  masks the opcode to 5 bits yet has `case` values above 0x1f that can never
  match).
- **Why:** `das()` is only reachable with `cflag > 4` (debug disassembly), never
  during normal execution. It only needs to compile/link. Not worth making the
  heuristics correct while the JIT is stubbed out.

### GUI stack — built with the `emu-g` (graphics-less) config, not `emu`
- **What:** The top-level `Makefile` builds `CONF=emu-g` and drops `libfreetype`
  (and the unused `libdynld`) from the component list.
- **Why:** `libfreetype` cannot build — the upstream FreeType `src/` tree
  (`libfreetype/libfreetype/`) and `ft2build.h` were never vendored into this
  repository, so `freetype.c` fails on any architecture, not just aarch64. The full
  `emu` config links `freetype`/`tk`/`draw`, so it can't link either. `emu-g` is the
  stock graphics-less configuration; it runs the Dis VM, namespace, networking, and
  CLI without the windowing system. `libdynld` lacks a `dynld-aarch64.c` and is not
  linked by either `emu` or `emu-g`, so it was simply removed from the build list.
- **Consequence:** No GUI (wm, acme, Tk programs). CLI Limbo is unaffected. To
  restore the GUI, vendor the FreeType sources and build `CONF=emu`.

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

**limbo (compiler) changes — pointer-width temporaries, comparisons, and analysis
(added this session; each was a real crash):**
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

**Build / dis tree:** rebuilt limbo → libinterp (regenerates `runt.h`/`*mod.h` maps)
→ emu-g, then **recompiled the whole `appl/lib` and `appl/cmd` dis trees** with the
new compiler (`mk -k ... install`; `-k` to skip the pre-existing broken `venti.b`).
The committed 4-byte `.dis` cannot be mixed with the new VM, so any `.dis` that is
loaded must be recompiled. NOTE: the `.dis` magic is unchanged (still `XMAGIC`), so
there is currently **no guard** against accidentally loading an old 4-byte `.dis`;
adding a distinct magic / ABI tag is the planned phase-2 work (ship `.b` + lazy
recompile on mismatch).

### Solved this session
The list+format-print crash (the previous "one remaining bug") was the **call-frame
temp** bug (`callcom`, above): the loop variable `l` at `72(fp)` sat adjacent to the
4-byte frame-pointer temp at `68(fp)`; `frame $1,68(fp)` stored an 8-byte pointer
that overran into `l`'s low word. Fixed by making the frame temp `tbig`. The
`MP+24`/module-data theory in the prior notes was a **misdiagnosis** — a gdb hardware
watchpoint showed `MP+24` was never written; the corruption was the overlapping frame
slot. Lesson: trust the watchpoint, not the inferred instruction window.

### No known CLI crashes
The previous "active edge" — `Readdir`/`mergesort` faulting on `array of ref Dir` —
was the `Oindex`→`Oindx` element-address-type bug (above) and is fixed. A full `sh`
session (pipes, redirection, globbing, `ls`/`ps`/`cat`/`wc`, env vars, `cd`,
`load std`, `for`/`if`/`ftest`) now runs with no faults.

Debug recipe that found these (keep for the deferred items): run under gdb **without**
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

### Temporary debug instrumentation
- `emu/Linux/os.c` `sysfault()`: prints `LP64 fault: ... in <module> pc=<n> op=<n>`
  via `modstatus(&R,...)` (added `#include "interp.h"`). Genuinely useful for the
  per-module fault triage above; keep, or gate behind a flag before shipping.
- The `libinterp/xec.c` `OP(consp)`/`OP(headp)` `print("DBG …")` dumps have been
  **removed**, and `appl/cmd/emuinit.b` has been **restored** from git (it is the real
  emuinit again). The `lt.b`/`t64.b` reproducers under `appl/cmd/` can stay as tests.
- Reading a reported `pc=N`: the dispatch loop increments `R.PC` **before** running
  the op, so during a fault `R.PC` points at the *next* instruction; the faulting
  instruction is typically `pc-1` (account for this when matching a `limbo -S`
  listing). `limbo -S file.b` writes the Dis assembly listing to `file.s`.

### Deferred LP64 items (compile fine; off the emuinit/sh boot path)
- **Exceptions** (`limbo/ecom.c:191`, tracked as task EXLP64): the bare-exception
  value rewrite still uses `2*IBY2WD` to skip the exception object's `{string,int}`
  header, which on LP64 is `{IBY2PTR,IBY2WD}` (12, possibly padded), not 8. Needs
  the computed exbasetype args offset; audit raise construction + handler `eoff`
  delivery in `emu/port/exception.c`.
- **`$Loader` module** (`libinterp/loader.c`): its `brpatch`/`brunpatch` round-trip
  branch targets through `Inst.d.imm` and a 4-byte `Loader_Inst.dst`; the core now
  uses `d.ins`. Rework to compute indices from `d.ins` for dynamic module load/build.
- **`asm.c` `-S` listing**: the textual assembly listing's `Tcasec` case was not
  updated for pointer-sized entries (the binary `dis.c` path was). Listing/debug
  only; does not affect execution.
- **`emu/port/devprog.c`, `devprof.c`**: a few pointer↔int casts (the `/prog` and
  `/prof` filesystems expose VM pointers as text) warn under LP64; revisit if those
  devices are used.

### Alternatives considered (and rejected)
- **`-mabi=ilp32` (32-bit pointers on aarch64):** would keep the 4-byte `.dis`
  layout but needs an aarch64 ILP32 libc that stock Ubuntu does not ship.
- **Compile emu as 32-bit ARM:** not aarch64; out of scope.
