# Dis JIT / Native Code Compilation

Inferno can run Dis bytecode in two modes: interpreted (the default, architecture-independent) or JIT-compiled to native machine code. The JIT is controlled by `cflag` and implemented per-architecture in `libinterp/comp-OBJTYPE.c`. For a new architecture like aarch64, the first decision is whether to implement a JIT or run interpreter-only.

This doc does not re-cover the Dis VM scheduler (see AGENTS_EMU.md) or the Dis wire format (see AGENTS_9P.md). It focuses on the compilation pipeline itself.

## cflag: Enabling JIT

`cflag` is a global int (`include/interp.h:361`, set in `emu/port/main.c`). It is controlled by the `-c` flag to `emu`:

```sh
emu -c2 /dis/sh          # compile all modules at load time
emu -c0 /dis/sh          # interpreter only (default)
```

| cflag value | Effect |
|-------------|--------|
| 0 | Interpreter only |
| 1 | Compile modules at load time |
| 2 | Compile + verify against interpreter |
| >4 | Compile + disassemble generated code (calls `das()`) |

## When Compilation Happens

**Load-time** (`libinterp/load.c:495–505`): If `cflag > 0`, `readmod()` calls `compile()` immediately after loading a module's bytecode:

```c
if(cflag) {
    if((m->rt & DONTCOMPILE) == 0 && !dontcompile)
        compile(m, isize, nil);
}
else if(m->rt & MUSTCOMPILE && !dontcompile) {
    if(compile(m, isize, nil) == 0) {
        kwerrstr("compiler required");
        goto bad;       /* fail load if JIT unavailable but required */
    }
}
```

**Explicit/lazy** (`libinterp/loader.c:437–442`): Limbo programs can call `Loader->compile()` to JIT a specific module on demand.

**Never at first-call.** There is no tiered or on-demand per-function compilation — it's whole-module, all-or-nothing.

Module flags in `include/isa.h`:
- `MUSTCOMPILE` — module must be compiled; load fails if JIT unavailable
- `DONTCOMPILE` — module must not be compiled (used for built-in C modules)

## Interpreter vs JIT Execution

The execution branch in `libinterp/xec.c:1688–1695`:

```c
if(R.M->compiled)
    comvec();           /* jump to native code entry stub */
else do {
    dec[R.PC->add]();   /* decode addressing mode */
    op = R.PC->op;
    R.PC++;
    optab[op]();        /* execute interpreter handler */
} while(--R.IC != 0);  /* loop until quanta exhausted */
```

`R.M->compiled` is set by `compile()` after successful code generation. The two paths are mutually exclusive per module — a module is either fully compiled or fully interpreted.

**Cross-module calls** between compiled and uncompiled modules are handled gracefully: when `R.M->compiled != m->compiled` the scheduler quanta is forced to 1 (line 710 of xec.c), triggering a reschedule that allows the interpreter to pick up the call correctly.

## The REG Struct

Both the interpreter and generated JIT code operate on the same `REG` struct (`include/interp.h:211–228`):

```c
struct REG {
    Inst*    PC;    /* Dis program counter */
    uchar*   MP;    /* module data pointer */
    uchar*   FP;    /* frame pointer */
    uchar*   SP;    /* stack pointer */
    uchar*   TS;    /* top of stack */
    uchar*   EX;    /* extent */
    Modlink* M;     /* current module link */
    int      IC;    /* instruction count (quanta remaining) */
    Inst*    xpc;   /* saved PC for compiled→interp return */
    void*    s;     /* temp: source */
    void*    d;     /* temp: destination */
    void*    m;     /* temp: middle */
    WORD     t;     /* temp: type */
    WORD     st;    /* source type */
    WORD     dt;    /* destination type */
};

REG R;              /* single global, in libinterp/xec.c */
```

JIT-generated code keeps the address of `R` in a dedicated register (ARM: `RREG = R5`). All Dis virtual register accesses go through memory loads/stores into `R`.

## The Dis Instruction (Inst)

The bytecode instruction format (`include/interp.h:177–184`):

```c
struct Inst {
    uchar  op;    /* opcode: IMOVW, IADDB, ICALL, ... */
    uchar  add;   /* addressing mode bits */
    ushort reg;   /* register/immediate */
    Adr    s;     /* source operand */
    Adr    d;     /* destination operand */
};
```

Addressing modes (encoded in `add`):
- `AFP` — frame-relative (FP + offset)
- `AMP` — module-relative (MP + offset)  
- `AIMM` — immediate/literal
- `AIND|AFP`, `AIND|AMP` — indirect

## comp-arm.c: The JIT Architecture

`libinterp/comp-arm.c` is the ARM32 JIT backend and is the nearest reference for aarch64. The overall structure:

### Register Assignment (ARM, lines 18–45)

```c
RFP  = R9    /* Dis frame pointer */
RMP  = R8    /* Dis module pointer */
RREG = R5    /* pointer to global REG struct */
RA0  = R1    /* general scratch 0 */
RA1  = R2    /* general scratch 1 */
RA2  = R3    /* general scratch 2 */
RCON = R6    /* constant builder */
RTA  = R7    /* indirect address temp */
```

### Two-Pass Compilation (`compile()`, lines 2162–2280)

**Pass 0** — size estimation: walk each Dis instruction, emit to a scratch buffer, record the native size in a `patch[]` table indexed by Dis PC offset. This builds the mapping `patch[dis_pc_offset] = native_byte_offset`.

**Pass 1** — actual generation: allocate the final code buffer with `mallocz()`, walk instructions again, emit real code. Verify that sizes match pass 0.

After both passes:
1. `patchex(m, patch)` — fix up exception handler table entries (they contain Dis PCs that need converting to native addresses)
2. Set `m->entry` to the native address of the module's entry point
3. `segflush(base, n * sizeof(*base))` — flush I-cache so CPU sees new code
4. Set `m->compiled = 1`

### Instruction Translation (`comp()`, lines 1155–1400)

Large switch on `i->op`. Each case calls helpers:

```c
case IMOVW:
    opwld(i, Ldw, RA0);    /* load source using addressing mode */
    opwst(i, Stw, RA0);    /* store to destination */
    break;

case ICALL:
    opwld(i, Ldw, RA0);                        /* load callee frame addr */
    con(RELPC(patch[i - mod->prog + 1]), RA1, 0); /* return address */
    mem(Stw, O(Frame, lr), RA0, RA1);          /* save return PC in frame */
    mem(Stw, O(Frame, fp), RA0, RFP);          /* save frame pointer */
    MOV(RA0, RFP);                             /* switch frame pointer */
    BRADIS(AL, i->d.ins - mod->prog);          /* branch to target */
    break;
```

`BRADIS(cond, dis_pc_offset)` expands to a branch to `patch[dis_pc_offset]` — the native address of that Dis instruction.

### Constant Pool (lines 397–467)

ARM can't encode arbitrary 32-bit constants in single instructions. `con(value, reg, 0)` queues the constant into a literal pool; `flushcon()` emits the pool when it's full or before a backward branch. AArch64 has `ldr x0, =value` (PC-relative literal) or `movz`/`movk` pairs for similar effect.

### Macro Routines (lines 1778–2090)

Helper routines compiled once per module, referenced by generated code:

| Macro | Purpose |
|-------|---------|
| `comvec` | Module entry: load RREG, fetch FP/MP/PC from REG, enter execution |
| `macret` | Return from compiled function; handles compiled↔interpreted boundary |
| `macmcal` | Cross-module call; checks if target module is compiled |
| `macfrp` | Decref and conditionally free a heap pointer |
| `maccolr` | Increment and GC-color a pointer |
| `macfram` | Allocate a new stack frame |
| `maccase` | Binary search for Dis `ICASEW` |
| `macrelq` | Check reschedule quanta |

These are called with `BL` (branch-and-link) from generated instruction code. AArch64 uses `bl` similarly.

### Entry Protocol (`comvec`, lines 1778–1798)

Generated once per module. When `comvec()` is called from `xec.c`:

1. Load `&R` (global REG address) into `RREG`
2. Load `R.FP`, `R.MP` into ARM registers `RFP`, `RMP`  
3. Load `R.PC`, compute index into `patch[]`, jump to native address
4. All further execution is native until a boundary crossing or reschedule

### Return Protocol (`macret`, lines 1891–1959)

When compiled code returns across a module boundary:

1. If the calling module is also compiled: tail-call directly to its native return address
2. If not compiled: save `R.PC` and `R.FP`, return via `R.xpc` back to the interpreter scheduler

## das-*.c: Disassemblers

`das-OBJTYPE.c` disassembles native instructions for debug output. Called only when `cflag > 4`. Not used during normal execution.

`libinterp/das-stub.c` is the no-op version for interpreter-only builds:

```c
void das(uchar *x, int n) { USED(x); USED(n); }
```

## segflush

```c
int segflush(void *addr, ulong nbytes);
```

Called in two places after code generation (comp-arm.c):
1. After generating `comvec` (the entry stub): `segflush(comvec, 10 * sizeof(*code))`
2. After generating the full module: `segflush(base, n * sizeof(*base))`

`segflush` must flush the D-cache write buffer and invalidate the I-cache for the given range so the CPU fetches the newly written instructions. See AGENTS_PORT.md for the aarch64 implementation.

## FPsave, FPrestore, umult

These three symbols exist in `emu/Linux/asm-aarch64.o`:

- **`umult(m1, m2, *hi)`** — unsigned 64-bit multiply returning the high word separately. Used by generated code for Dis `IMULL`/`IMULQ` (big multiply). ARM32: `umull r0, r3, r1, r2`. AArch64: `umulh x3, x0, x1; mul x0, x0, x1; str x3, [x2]`.

- **`FPsave(ptr)`** / **`FPrestore(ptr)`** — save/restore the hardware FP register state. ARM32: saves 28-byte FP environment. AArch64: must save all 32 × 64-bit FP registers = 256 bytes (using `stp` pairs).

These are called by JIT-generated code for modules that use floating point. With `SOFTFP=1` (line 14 of comp-arm.c), FP operations are punted to the interpreter and these are not called. AArch64 JIT would need to decide soft vs hard FP.

## Build System Integration

`libinterp/mkfile` selects the backend via `$OBJTYPE`:

```makefile
OFILES=\
    ...
    comp-$OBJTYPE.$O\   /* e.g. comp-arm.o, comp-aarch64.o */
    das-$OBJTYPE.$O\    /* e.g. das-arm.o, das-stub.o */
    ...
```

For interpreter-only builds, set `das-aarch64.$O: das-stub.c` in the mkfile (like `das-spim.c:N: das-mips.c` is done for SPIM).

## The aarch64 Decision

**Option A: Interpreter only**

- Provide `libinterp/comp-aarch64.c` that is a stub: `compile()` returns 0, all cflag values run the interpreter.
- Provide `libinterp/das-aarch64.c` as an alias to `das-stub.c`.
- Set `cflag=0` in mkconfig or at runtime.
- Cost: full Dis interpreter performance only. Straightforward port.

**Option B: JIT for aarch64**

- Port `comp-arm.c` to AArch64 ISA:
  - Replace ARM register names with AArch64 (`x0`–`x28`, `w0`–`w28` for 32-bit sub-registers)
  - Replace ARM instruction emission with AArch64 (fixed 32-bit instruction width, different encoding)
  - Update constant loading (`movz`/`movk` pairs instead of ARM literal pool)
  - Update `FPsave`/`FPrestore` to save 256 bytes (all 32 FP regs)
  - ABI: AAPCS64 (first 8 args in `x0`–`x7`, return in `x0`, callee-saves `x19`–`x28`)
  - Stack must be 16-byte aligned at calls
- Write `libinterp/das-aarch64.c` for debug disassembly.
- Cost: significant but well-defined — comp-arm.c is ~2300 lines.

Option A is sufficient to validate the port end-to-end; Option B can follow.

## Key Files

| File | Purpose |
|------|---------|
| `libinterp/comp-arm.c` | ARM32 JIT backend — primary reference for aarch64 |
| `libinterp/comp-386.c` | x86 JIT backend |
| `libinterp/das-stub.c` | No-op disassembler for interpreter-only |
| `libinterp/das-arm.c` | ARM disassembler (debug only) |
| `libinterp/xec.c:1688` | Interpreter/JIT dispatch |
| `libinterp/load.c:495` | cflag-triggered compile at module load |
| `libinterp/mkfile` | `comp-$OBJTYPE.$O` and `das-$OBJTYPE.$O` selection |
| `include/interp.h:177` | `Inst` struct (Dis bytecode) |
| `include/interp.h:211` | `REG` struct (Dis register file) |
| `include/isa.h:230` | `MUSTCOMPILE` / `DONTCOMPILE` flags |
| `emu/Linux/asm-aarch64.o` | Pre-compiled: `umult`, `FPsave`, `FPrestore` |

---

# AArch64 JIT Implementation (LP64) — status and internals

`libinterp/comp-aarch64.c` is a real from-scratch LP64 JIT (the first for Inferno).
It is **off by default** (`cflag==0` runs everything interpreted; suite is 166/166)
and activates with `emu -c1`/`-c2`, which is **working**: the full suite is also
166/166 under `-c1` (sh plus all 8 suites run natively, including limbo self-host).
The only `-c1` caveat is `$Loader` reflection, which is mutually exclusive with
compilation by design (see below); it is TAP-skipped, not a codegen bug. This
section is the durable reference for the implementation.

## What was solved (and how)

- **Verified encoder layer.** Every A64 instruction emitter (`movz/movk`, add/sub/
  logical/mul/shift register+immediate forms, `ldr/str` scaled + `ldur/stur` unscaled +
  register-offset, `b/b.cond/br/blr/ret`, `cmn` for the H-test) was validated bit-exact
  against `aarch64-linux-gnu-objdump` in a standalone harness *before* use. This is the
  single most important quality lever and exactly what the old WIP lacked — develop new
  encoders the same way (emit to a buffer, `objdump -D -b binary -m aarch64`, diff).
- **LP64 width discipline.** `mem()` takes a width pseudo-op: `Ldw/Stw` = 4-byte (W-reg,
  int/word fields), `Ldp/Stp` = 8-byte (X-reg, pointer/big/real fields), `Ldb/Stb` =
  byte, `Lea` = address. The crux is per-field: pointer fields of REG/Frame/Modlink and
  the `opx` indirection load are 8-byte; `Heap.ref` is `ulong`=8; `IC`/`compiled`/word
  operands are 4-byte. Longs/reals/pointers are single 8-byte ops (simpler than ARM's
  two-word dance).
- **No PC register.** ARM's `mov pc,reg`/`mov pc,lr`/load-into-pc become `BR`/`BLR`/`RET`.
- **Constants.** `con()` always emits a fixed 4-instruction `movz`+`movk*3` (pass-stable
  regardless of value — avoids the phase-error trap where `base` is nil in pass 0).
- **Executable, low-address code arena.** Pool/heap memory is non-executable on Linux and
  sits at ~0xaaaa........ (>4GB). `jitcode()` mmaps a low (<2GB) RWX arena (`segflush`
  also `mprotect`s RWX as a backstop). Low addresses are *required* because IGOTO/ICASE
  jump tables are 32-bit WORD slots that store native code addresses (the interpreter
  reads them back via `R.PC = (Inst*)t[0]`, xec.c).
- **Exception tables.** `handler()` (emu/port/exception.c) treats compiled handler PCs as
  native *byte* offsets from `m->prog`; `patchex` scales `patch[]` (instruction units) by
  `sizeof(u32)`.

## Design choices

- **Partial JIT.** Natively compile the hot integer/control path; `punt()` everything
  else to the interpreter. Punting is always correct: the interpreter reads operands via
  `R.s/R.d/R.m` (which `punt` sets up) and honours native PCs via `NEWPC` (load `R.PC`,
  `br`). This let v1 skip the mac routines (MacRET/FRAM/MCAL/...) and `typecom`.
- **Registers (AAPCS64).** `x0–x3`=RA0–RA3 scratch/C-args, `x4`=RCON, `x5`=RTA, `x16`=
  branch-through temp, `x19`=RREG(&R), `x20`=RFP, `x21`=RMP (callee-saved survive C
  calls), `x30`=LR. Generated code only ever touches these, leaving `x22–x28` free for a
  future macmcal/macret.
- **Scheduler safety.** Backward branches (IJMP and `cbra` family) emit an inline
  reschedule (decrement `R.IC`, on `<=0` save FP/PC and `ret` to `R.xpc`) so compiled
  loops don't starve the cooperative scheduler.

## Current status — WORKING (sh + full battery under `-c1`)

The aarch64 LP64 JIT is functional. `emu -c1` runs the Emuinit bootstrap, **sh**
(pipes, globbing, control flow), and the full headless test battery natively.
- Default `cflag==0`: **166/166** (zero regression — all JIT changes are no-ops on the
  interpreter path).
- `emu -c1` (sh + every suite compiled): **8 of 8 suites pass 100%** (166/166: vm, concur,
  crypto, styxnet, selfhost — i.e. limbo compiling itself —, loader, plumb, except). In
  `50_loader` the six bytecode-round-trip assertions are **TAP-skipped** under `-c1` because
  reflection and compilation are mutually exclusive (see the limitation below); the other six
  (load/tdesc/link/dnew/nil-rejection/GC-teardown) run for real. At `cflag==0` all twelve run.

**Native:** moves (W/B/L/F), LEA, CVT(BW/WB/WL/LW), arithmetic (ADD/SUB/AND/OR/XOR for
W/B/L), shifts, MUL, LEN*, IIND*, MOVM/HEADM, **conditional branches + IJMP**
(`cbra`/`cbrab`/`cbral` + `bradis`, backward branches carry `schedcheck`), and **IMCALL**
(`commcall`+`macmcal`).
**Punted (correct, just not inlined):** ICALL, IRET, IFRAME/IMFRAME, IGOTO/ICASE/ICASEC
(table dst slots relocated first by `comgoto`/`comcase`/`comcasel`/`comcasec`), allocation,
list/string/pointer ops, FP, div/mod, sends.

### Known limitation: `$Loader` reflection vs JIT
`loader->ifetch`/`newmod` cannot introspect a **JIT-compiled** module: `compile()` replaces
`m->prog` (Dis bytecode) with the native code buffer and frees the original, so there are
no Dis instructions left to fetch. `ifetch` rejects this *by design* in stock Inferno
(`kwerrstr("compiled module")`); it is the same trade-off every Inferno JIT back-end makes
(`free(m->prog); m->prog = base`). Enabling reflection on compiled modules would require
permanently retaining each compiled module's Dis bytecode — a footprint regression on every
module under `-c1`, for a debug-only feature upstream deliberately omits — so it is **not**
a worthwhile enhancement and was not done. Instead `50_loader` detects a compiled target
(ifetch yields no instructions for an otherwise-valid module) and TAP-skips the round-trip,
so the suite is honest in both modes rather than reporting a spurious failure.

## Root causes found and fixed (the hard part)

1. **`cmnix` (`cmn xn,#1`, the is-H test) encoded the wrong register.** The base constant
   was `0xB100043F` whose Rn field is **1**, so `cmnix(rn)` ORed `rn` onto an already-set
   Rn and only produced the right register for odd `rn`; `cmnix(RA0)` actually tested **x1**.
   It mostly "worked" because x1 was rarely H — but e.g. indexing an array right after a
   `nil` list left x1 = H, so the array-bounds nil-check (`indarr`), `notnil`, `LEN*`, and
   the `macmcal` `ml==H` test spuriously fired. This is what hung `sh` (via readdir's
   `array of list` + cons-into-element path). Fix: base `0xB100041F` (Rn=0). One-character
   bug, found by single-stepping the faulting `indl` in gdb and decoding `b100043f`.
2. **comvec clobbered C callee-saved registers.** Native code uses x19/x20/x21/x24
   (RREG/RFP/RMP/RLR2), all AAPCS64 callee-saved, but `comvec` is reached by an ordinary C
   call from `xec` and `macrelq`/the punt-TCHECK/`macmcal`-interp paths returned to `xec`
   via `ret R.xpc` **without restoring them** — so `xec`'s locals (notably its `Prog *p`
   arg, held in a callee-saved reg) were corrupted, and the wrong proc's `R` got saved on a
   reschedule. Fix: `comvec` prologue `stp x19,x20,[sp,#-32]!; stp x21,x24,[sp,#16]`, and a
   `schedret()` epilogue (restore + `ret R.xpc`) used at every return-to-scheduler site.
   Found by tracing `xec` entry/exit `p` and `R.PC` across a reschedule.
3. **IMCALL left `R.PC` stale during a yielding builtin.** The interpreter advances `R.PC`
   to the next instruction before running a runt builtin; `commcall` did not, so a builtin
   that yields (`release`/`acquire` → `isave`) saved a bogus resume PC. Fix: `commcall`
   stores the IMCALL return address to `R.PC` (mirrors the interpreter).
4. **ICASEC table not relocated.** Added `comcasec` (string-case dst slots: 24-byte
   entries, dst WORD at offset `2*IBY2PTR`, wild dst after) — without it the interpreter's
   `casec` jumped to raw Dis offsets (sh's command dispatcher is all string case).

### Earlier fixes that landed
- **Native IMCALL** (`commcall`/`macmcal` + the `rmcall` C helper). The runt case keeps
  `R.M` = caller so a yielding builtin saves a consistent `R.M`/`R.PC`. LP64 specifics:
  pointer fields 8-byte; `sizeof(Modl)`==16 (index shift 4, not ARM's 3); the runt fn
  pointer passes in `R.d` (8 bytes, not 4-byte `R.dt`); the macro link-save uses
  callee-saved `x24` (`RLR2`), not the 4-byte `REG.st`.
- **`freemod`** (libinterp/load.c) skips `free(m->prog)` when `m->compiled` — a compiled
  module's `prog` is in the mmap JIT arena, not a pool block.
- **`segflush`** mprotects the arena RWX; **low (<2GB) executable mmap arena** because
  IGOTO/ICASE/ICASEC jump tables store native addresses in 32-bit WORD slots.
- **`patchex`** scales exception-table PCs by `sizeof(u32)` (handler() uses native byte
  offsets for compiled modules).

## Debugging recipe used

- `gdb -batch`, `break badop` / `break frame` / `break nullity`/`bounds`, then inspect
  `R.PC` vs the arena bounds `0x20000000–0x24000000` to tell native-vs-Dis.
- Temporary `print()` probes in `OP(mcall)`/`OP(badop)`/the xec dispatch reveal the
  caller→callee transitions and the exact `R.M`/`R.PC`/`R.IC` at the failure.
- `gdb`'s `R` symbol is awkward (`R.PC` fails to parse); use C `print()` probes or
  `*(int*)((char*)R.M+16)` style offset reads instead.

---

# JIT and interactive responsiveness — the boot-stall trade-off

## Symptom

`emu -c1 ... wm/wm` is noticeably *less* responsive at startup than the
interpreter: the desktop takes a while to paint. This is **expected, not a bug**.

## Why

Compilation is **eager, whole-module, and synchronous on the loading proc**
(`load.c`):

```c
if(cflag) {
    if((m->rt&DONTCOMPILE) == 0 && !dontcompile)
        compile(m, isize, nil);   /* compile the ENTIRE module, right now */
}
```

Booting `wm/wm` `load`s dozens of modules (wm, tk, draw, the shared libs, every
applet you open). With `-c1` each `load` pays a full whole-module translation
before it returns, so the cost lands as one upfront burst before anything draws.

`cflag` is **not** an optimisation level: in `comp-aarch64.c`, `cflag > 3` / `> 4`
only switch on debug disassembly dumps. `-c1`, `-c2`, `-c3` produce identical
code — there is no "lighter, faster-to-start" JIT setting.

## When the JIT is (and isn't) worth it

The JIT only speeds up **CPU-bound Limbo inner loops**. It does nothing for:
- **event/IO-bound** code — the desktop spends its life blocked on draw / mouse /
  keyboard, where native vs interpreted is invisible; and
- **C builtins** — the genuinely heavy paths (`$Raster3` rasteriser, `$Imageio`
  decode, mbedTLS) are already native C the JIT never touches.

**Recommendation: run the desktop interpreted (`-c0`/omit).** Reserve `-c1` for
compute-bound batch / benchmark Limbo. If you want native speed on a *specific*
hot Limbo module without the global boot tax, two targeted hooks already exist:

1. **`MUSTCOMPILE` module flag** (`load.c`, the `else if` arm) — compiles that one
   module even when `cflag==0`. Leave the global default interpreted; annotate only
   the hot module.
2. **`Loader->compile()`** (`loader.c` `Loader_compile`) — a running program can JIT
   a module on demand (e.g. right before entering its hot loop).

## Future direction: async / tiered compilation ("best of both worlds")

Goal: interpret immediately for instant responsiveness, compile in the
background, and let native code take over transparently. The VM is unusually
ready for this because **two normally-missing pieces already exist**:

1. **Mixed compiled/interpreted execution already works and resyncs at call
   boundaries.** `mcall` (`xec.c`, `if(f->mr->compiled != R.M->compiled) R.IC=1;`)
   and `ret` (same test → `R.IC=1; R.t=1;`) bounce control back to the dispatcher
   (`xec.c` `if(R.M->compiled || PC in [jitlo,jithi)) comvec(); else interpret`)
   whenever execution crosses between a native and an interpreted module. Compiled
   and interpreted modules already call each other freely.
2. **Post-load compilation already works.** `Loader_compile` compiles an
   *already-loaded, running* module and publishes it: `compile(m,…)` then
   `f->mp->prog = m->prog; f->mp->compiled = 1`.

**Crucial consequence: no on-stack replacement (OSR) is needed.** The hard part of
tiered JITs — migrating a thread mid-function from interpreted to native — can be
skipped. The natural tier boundary is the module call: a proc currently *inside*
an interpreted invocation finishes it interpreted; the *next* entry into the
module goes native. The `ret`/`mcall` resync above already implements exactly that
transition.

What is actually missing, in order of difficulty:

1. **Background driver (easy).** A dedicated compiler `kproc` + work queue.
   `load.c` enqueues the module and returns immediately with `compiled=0`
   (interpret now); the kproc compiles and publishes. This removes the boot stall.
2. **Concurrency-safe publication (the real risk).** `compile()` sets
   `m->compiled=1` and repoints `m->prog` into the JIT arena while other procs may
   be interpreting the same module. Publishing the flip needs proper
   release/acquire ordering, the interpreter must only observe it at a safe point
   (it does — call/ret), **and the original interpreted Inst array must not be
   freed while in-flight interpreters still read it** (today `freemod`/`compile`
   free `m->prog` — see the `$Loader` limitation above). This is the same bug class
   as the documented missing-release-barrier heap corruption (`unlock()` had
   `coherence=nofence` → stale free-tree → corruption); live module mutation is
   squarely in that danger zone, so this needs careful barriers verified under
   EMUCRASH + `make emu-disptrcheck`, not a quick patch.
3. **Policy (easy, tunable).** Simplest: background-compile every loaded module
   (eager-but-async) — biggest UX win, no profiling. Later: a call-count threshold
   so cold modules never burn CPU/memory getting compiled.

Suggested staging: (Phase 1) async-eager behind a new flag, keeping the
synchronous path for debugging; (Phase 2) add hotspot counters. A "Compiling
<module>" progress window is a reasonable *interim* only if compilation stays
synchronous — once Phase 1 lands the desktop just comes up and quietly gets
faster, making the progress UI redundant. Phase 1's correctness hinges entirely
on item 2.
