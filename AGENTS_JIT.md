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
