# LP64 Port — In-Progress Notes (what is stubbed / disabled, and why)

> **Branch / roadmap (read first).** Active branch: **`port-LP64`** (renamed from
> `aarch64-port` — this is the LP64 data-model port, not aarch64-specific; the same
> XMAGIC8 `.dis` tree runs on any LP64 host, and `Linux/amd64` x86-64 glue is in,
> though unbuilt). **`master` is frozen** as 32-bit upstream + the pointer-width
> magic guard + a few LP64-safety one-liners — **do not apply further changes to
> master.** This is the durable project record (it travels with the repo); update
> the relevant `AGENTS_*.md` rather than relying on external notes.
> **The GUI works (2026-06).** `CONF=emu` is the default build and `wm/wm` runs
> the desktop under X11 (verified headless via Xvfb + screenshot: taskbar,
> FreeType menus, mouse input). Getting there fixed two LP64 bugs — the draw
> scan-line word width (libmemdraw/libdraw) and the exception-unwind `NOPC`
> sentinel — and vendored FreeType 2.13.2. See the "GUI stack" and "Fixes"
> sections below, and AGENTS_GRAPHICS.md. (`$Loader` LP64 fix is also done.)
> The CLI/sh path is done and hardened (FP, big constants, exceptions, replicate
> arrays, pick-ADTs, channels all correct; the pointer-width `tint` bug class is
> audited — see below). `github.com/caerwynj/inferno-lab` is the test battery;
> the in-repo `tests/lp64/` harness (166 assertions, 8 suites) is the standing
> regression net.

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
make all              # builds Linux/aarch64/bin/emu (full GUI; the default)
make all CONF=emu-g   # graphics-less headless build (faster; tests run under this)
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
- **`limbo/dtocanon.c` + `libinterp/load.c` (`dtocanon`/`canontod`)** — same
  `unsigned long`-is-8-bytes family. These split/reassemble an IEEE double into the
  two 32-bit words of the `.dis` data section via a `union { double d; unsigned long
  ul[2]; }`; on LP64 `ul[0]` aliased the whole double, so **every real *constant*
  loaded as ~0** (reals computed at run time were fine, which is why the CLI/sh path
  never caught it). Pinned the union element to `unsigned int`. Found by checking
  floating-point math (`sqrt`/`sin`/`pow`/…, real arrays, `1e±300`, string→real) —
  all correct after the fix. `dtocanon` is in the compiler, so the dis tree was
  recompiled. The self-host `appl/cmd/limbo` is unaffected (it serialises reals via
  the Math `export_real` builtin, not a C union).
- **`emu/port/alloc.c`** — the pool allocation quantum was `31` (32-byte minimum
  block). A free block stores its tree node *in-band* in the `Bhdr` union; on LP64
  that node is 56 bytes + 8-byte `Btail` = 64 bytes, so 32-byte blocks let the
  free-tree pointers and trailer spill into the neighbouring block. Changed the
  quantum to a word-size-aware value (`#define QUANTA (sizeof(Bhdr)+sizeof(Btail)
  <= 32 ? 31 : 63)`), so 64-bit builds use 64-byte minimum blocks. No-op on 32-bit.
- **`Linux/aarch64/include/lib9.h`** — `#define READ 4` should have been
  `#define AREAD 4` (the `access(2)` mode used by `libdraw/subfontname.c`). Typo
  fix.
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
  Fixed by pinning the draw word to 32 bits: `sizeof(u32int)` for strides,
  `8*sizeof(u32int)` in `wordsperline`, and `u32int*` (not `ulong*`) for the pixel
  pointers (`Buffer.rgba`, `boolcopy32`, `memsetl`, `chardraw`). **Rule: a draw
  word is 4 bytes — never `sizeof(ulong)`.** Found via gdb backtrace
  (`boolcalc1011` ← `memimagedraw`) then inspecting `dst->width`/`bwidth`.
- **Exception unwind `NOPC` sentinel — `emu/port/exception.c`, `os/port/exception.c`.**
  `handler()` walks frames; the "no handler here, keep unwinding" terminator is
  stored in `Except.pc` (a `ulong`) as the loader's `operand()` value `-1`, which
  **sign-extends to `0xffffffffffffffff` on LP64**. `NOPC` was `0xffffffff`
  (32-bit), so `newpc != NOPC` was wrongly true and the unwinder jumped to
  `R.PC = prog + (-1) = prog-1` → "illegal dis instruction". This fired whenever an
  exception fell through a non-matching handler — e.g. `kill 99999` doing
  `raise "fail:nothing killed"` back into the shell, which broke `wm/wm`'s
  `wmsetup`/`plumber`. Fixed: `#define NOPC (~(ulong)0)` (all-ones at native width;
  correct on ILP32 and LP64). Regression: `tests/lp64/suites/70_except.b`. Found
  the native way (per AGENTS_DEBUGGING.md): the broken proc parks in `Broken` and
  `/prog/<pid>/{exception,stack}` give the Dis-level trace — reach for `/prog`
  before gdb.
- **Byte→word sign-extension into 64-bit fields (UBSan-audit class).** A `uchar`
  shifted `<< 24` promotes to `int`; for a high byte >= 0x80 (e.g. `0x80`=DMDIR,
  `0xFF`=alpha) the result is a negative `int` that **sign-extends to
  `0xFFFFFFFF…` when widened into a 64-bit `ulong`/`vlong`**. On 32-bit `ulong`
  was 4 bytes so it never showed. Fixed across: the 9P field-unpack macros
  `GBIT32`/`GBIT64` in `include/styx.h` + `include/fcall.h` (the big one — every
  9P `mode`/length/qid/time unpack; `GBIT64` also zero-extended its low word);
  `Dir.mode` assembly in `emu/port/dev.c`, `emu/port/devfs-posix.c`,
  `lib9/dirstat-{Nt,posix}.c`; and `disw()`/the DEFL big-constant path in
  `libinterp/load.c`. Also made `libinterp/load.c:operand()` (the bytecode operand
  decoder) shift in `u32int` — behavior-identical, removes the UB. Found by the
  UBSan sweep (see AGENTS_DEBUGGING.md "Sanitizer builds"); regression-covered by
  `tests/lp64/suites/30_styxnet` (9P) and the suite at large. The remaining UBSan
  findings (pixel-assembly shifts, crypto/bignum byte-assembly, the string hash,
  `memmove(x,nil,0)`) are **benign** — results verified (correct render + crypto
  vectors), values stay 32-bit/masked — and were left to avoid churn in hot paths.

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

### GUI stack — RESOLVED (2026-06): `CONF=emu` is now the default and the desktop runs
- **Was:** the build was `CONF=emu-g` (graphics-less) because `libfreetype` could
  not build — the upstream FreeType `src/`/`include/` tree (`libfreetype/libfreetype/`)
  was an *unpopulated git submodule*, so `freetype.c` had no headers to compile
  against and the full `emu` config could not link `freetype`/`tk`/`draw`.
- **Fixed by:**
  1. **Vendoring FreeType 2.13.2** into `libfreetype/libfreetype/` — the exact
     commit (`546237e1…`) the old `freetype2` submodule pinned, checked out as
     plain files (submodule de-registered, `.gitmodules` removed). `libfreetype/
     mkfile` compiles the upstream `src/` against the Inferno glue
     (`libfreetype/freetype.c`, `ftsystem_inf.c`); it builds clean.
  2. **The LP64 draw word-width fix** (see Fixes) — without it `CONF=emu` linked
     but `wm/wm` segfaulted in the libmemdraw compositor on the first window.
  3. **The LP64 `NOPC` exception-unwind fix** (see Fixes) — without it the desktop
     came up but `wmsetup`/`plumber` broke with "illegal dis instruction".
- **Now:** `make all` builds `CONF=emu` (libfreetype/libtk/libdraw/win-x11a),
  `wm/wm` renders and is interactive (Xvfb-verified). `make all CONF=emu-g` still
  gives the fast headless build. `libdynld` remains dropped (no `dynld-aarch64.c`,
  linked by neither config).
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
The 4-byte `.dis` cannot be mixed with the new VM, so any `.dis` that is loaded must
be recompiled.

### Phase 2 — pointer-width `.dis` magic + recompile-on-mismatch (implemented)
Done (stage-2 commit on this branch; the guard half is also on `master`). A 64-bit
and a 32-bit Dis now **reject each other's binaries** instead of silently mis-running
them:
- **`include/isa.h`**: `XMAGIC8`/`SMAGIC8` (= `XMAGIC`/`SMAGIC` `| 0x100000`), the
  64-bit-pointer-ABI magics; on this branch `IBY2PTR=8`, on master `IBY2PTR=IBY2WD`.
- **compiler** (`limbo/com.c` and `appl/cmd/limbo/com.b`) stamps the magic selected by
  `IBY2PTR`: 64-bit → `XMAGIC8`, 32-bit → `XMAGIC`.
- **loader** (`libinterp/load.c`) accepts only this build's width; the other width's
  magic is rejected with a distinct catchable error `exDiswidth`
  ("dis module compiled for wrong pointer width"); garbage still says "bad magic".
- **`appl/cmd/limbo` was ported to LP64** (mirror of the stage-1 C-compiler changes:
  `isa.m`/`limbo.m`/`types.b`/`ecom.b`/`gen.b`/`com.b`/`decls.b`/`dis.b`/`stubs.b`), so
  the **self-hosted `/dis/limbo` emits correct 64-bit `.dis`** — this is what the
  recompile path runs. (Note: there are **two** compilers — the C `limbo/` host binary
  that `mk` uses, and the Limbo `appl/cmd/limbo/` one compiled to `/dis/limbo.dis`;
  both must be LP64-ported. `appl/cmd/limbo/optim.b` is a no-op stub, so no optimizer
  liveness fix is needed there.)
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

### Hardening fixes (found by an exceptions/big/tuple/pick/channel test sweep)
- **Big (64-bit) constants** (`libinterp/load.c` DEFL): `(LONG)hi<<32 |
  (LONG)(ulong)lo` sign-extended a low word with bit 31 set on LP64 (`ulong` is
  8 bytes), so e.g. `big 123456789012` loaded as `-1097262572` (constants whose
  low word's bit 31 was clear, like `9000000000`, were fine by luck). Now
  `(u32int)lo` (zero-extend); high word keeps the sign. VM-only; also on master.
- **Exception value layout (EXLP64, was deferred — now fixed):** the exbasetype
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
  away, which hid it). Now `tbig`, same as `rewrite()`'s `Oindex` and `arraycom`'s
  temp. **101 modules use the pattern; recompiled.** Found by the inferno-lab
  battery (`ffttest`, `puttar`).

### The pointer-width `tint` bug class — audited (don't whack-a-mole)
Every LP64 bug here is the same shape: a slot that holds/computes a **pointer or
address** used `tint` (`IBY2WD`=4) where it needs `IBY2PTR`=8 (latent on 32-bit
where pointer==word), or a 64-bit value reconstructed by extending a 32-bit half
wrong. Audit conclusion (2026-06-02, both compilers): a `tint` node/temp is a bug
**only when its own type drives the move width AND it holds an address/8-byte
value** — i.e. a *materialised* address. Those sites are exactly the `Oindx`
(element-address) nodes, and all three creations are covered (`rewrite` Oindex →
`tbig`; `arraydefault` → `tbig`; `arraycom` → materialises into a `tbig` temp).
`Oadr` nodes always fold into an `Oind` addressing mode (the compiler `fatal`s if
they can't), so no truncating materialisation. `tint` temps used only as
intermediates for explicitly-typed `genop`/`genmove` (verified: big/real
`++`/`--`/`+=`, op-assign-in-expression, big-array-element `+=`) are safe — the op
carries the operand type. So **most `tint` is correct; do not blanket-convert.**

### Test battery
`github.com/caerwynj/inferno-lab` (~281 real Limbo programs) is the repeatable
battery. Compile sweep: 234/281 compile, 0 compiler crashes (misses = uninstalled
lab-local modules; the 18 errors are source-level API drift, not LP64). Run sweep
(headless, flag `segmentation violation`/`illegal dis`; ignore "module not loaded"
= uninstalled deps and "dereference of nil" = missing args) found the replicate
bug. After fixes, 1 residual fault: `toy0`, `IMFRAME` on a nil modlink from an
uninstalled `load` with no nil-check — a program bug, not codegen. Not yet wired as
a standing harness.

### In-repo headless test suite — `tests/lp64/` (standing regression harness)
A self-contained TAP suite that exercises the Dis VM + Limbo end-to-end through
`emu-g`, no display needed. `tests/lp64/run.sh` compiles each `suites/*.b` with the
C `limbo`, runs it under `emu-g`, and aggregates `ok`/`not ok` (via the shared
`lib/testing.{m,b}` helper). **166 assertions across 8 suites, all green.** Exits
non-zero on any failure/crash; tolerates the benign teardown SIGKILL (rc 137; see
below) but flags a mid-run VM break (`BROKE`/`NOPLAN` — a suite that never reaches
summary()'s `1..N` plan line). `run.sh` compiles every `lib/*.b` helper first, with
`-I module -I appl/lib -I tests/lp64/lib`. The suites:
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

**Gotchas baked into the suite (read before extending):** (1) tests live in the
repo tree and reference inferno paths under the emu root (`/tests/lp64/...`,
`/module`); generated files go in `_build/` (git-ignored), **not `/tmp`** — `/tmp`
is not in the headless namespace. (2) `exit` is a no-arg statement; programs signal
pass/fail through TAP, not an exit status. (3) **any spawned helper proc must
terminate** (sentinel/bounded) or `emu-g` hangs until the timeout — a leaked
infinite producer cost a 65 s-per-run stall before the sieve was made
sentinel-terminated. (4) the post-run rc 137 SIGKILL is the pre-existing benign
emu-g teardown (repro: bare `echo hi`), output always completes first — the harness
treats 0/1/137 as non-error **but** still requires summary()'s `1..N` plan line and
the absence of `Broken:`/`illegal dis`/panic, so a tolerated exit code can no longer
hide a mid-run VM fault (this is how `70_except` catches the `NOPC` regression).

### `$Loader` LP64 fix (done) — runtime module reflect/rebuild
`$Loader` (`libinterp/loader.c`, the `Loader->ifetch`/`newmod`/`link`/`tdesc`
reflective interface) round-trips a module's instructions to/from Limbo. Three
LP64 bugs, all fixed (VM-only, no `.dis` change); verified `ifetch`→`newmod`
round-trips echo/cat/wc/ls/tee and the 1967-instruction `sh/std.dis`, and the
rebuilt module frees cleanly:
1. **brunpatch** read a branch target from the truncating 4-byte `i->d.imm`; the
   core stores it as a full `Inst*` in `i->d.ins` (8 bytes), so the recovered
   instruction index was garbage and `newmod`'s `brpatch` rejected it. Now passes
   the `Inst*` and computes the index from `i->d.ins`.
2. **`Loader_newmod`** `malloc`'d the Module and set only some fields, leaving
   `ldt`/`htab`/`ext`/`link`/`dlm` as garbage 8-byte pointers that the teardown
   (`freemod`/`destroylinks`) walks → crash. Now `memset(m,0,sizeof(Module))`.
3. **`destroylinks`** (`link.c`) walked `m->ext` with no nil check; a `newmod`'d
   module has `ext==nil`. Guarded (as `freemod` already guards `ldt`/`htab`).

### Deferred LP64 items (compile fine; off the emuinit/sh boot path)
- **`asm.c` `-S` listing**: the textual assembly listing's `Tcasec` case was not
  updated for pointer-sized entries (the binary `dis.c` path was). Listing/debug
  only; does not affect execution.
- **`emu/port/devprog.c`, `devprof.c`**: a few pointer↔int casts (the `/prog` and
  `/prof` filesystems expose VM pointers as text) warn under LP64; revisit if those
  devices are used.

## Second LP64 target: Linux/amd64 (x86-64) — glue added, UNBUILT/UNTESTED
amd64 Linux is also LP64, so it **reuses the entire shared LP64 model** (the
`IBY2PTR=8` Dis ABI, the compilers, the interpreter, **the committed XMAGIC8 `.dis`
tree** — which should run unchanged) and adds only thin arch glue. None of it is
built or run yet (no x86-64 host/toolchain was available); the asm is written by
hand from the 386 + aarch64 references and needs a real build + test pass.

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
