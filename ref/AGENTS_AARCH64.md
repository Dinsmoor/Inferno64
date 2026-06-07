# AArch64 Architecture Reference — VM Porting Guide

This document covers the AArch64 (ARM64, ARMv8-A) architecture at the depth needed to port a virtual machine interpreter and JIT compiler — specifically the Dis VM. It covers the register file, calling convention, instruction set, memory model, atomics, cache coherency for JIT, signal integration, and assembly syntax. It does not cover the native Inferno kernel (bare-metal); this is the hosted-emulator (emu) perspective.

**Authoritative sources** (consult for anything not covered here):
- [ARM Architecture Reference Manual for Armv8-A](https://developer.arm.com/documentation/ddi0487/) (requires free registration)
- [AAPCS64 — Procedure Call Standard for the Arm 64-bit Architecture](https://c9x.me/compile/bib/abi-arm64.pdf)
- [GNU Assembler AArch64 Directives](https://sourceware.org/binutils/docs/as/AArch64-Directives.html)
- [GCC AArch64 Options](https://gcc.gnu.org/onlinedocs/gcc/AArch64-Options.html)

---

## Register File

AArch64 has 31 general-purpose registers (no r0–r15 as in AArch32) plus dedicated special-purpose registers. All registers are 64 bits wide.

### General-Purpose Registers

| 64-bit | 32-bit | ABI Role | Saved by |
|--------|--------|----------|----------|
| `x0`   | `w0`   | Argument 1 / return value | Caller |
| `x1`   | `w1`   | Argument 2 / return value (pair) | Caller |
| `x2`   | `w2`   | Argument 3 | Caller |
| `x3`   | `w3`   | Argument 4 | Caller |
| `x4`   | `w4`   | Argument 5 | Caller |
| `x5`   | `w5`   | Argument 6 | Caller |
| `x6`   | `w6`   | Argument 7 | Caller |
| `x7`   | `w7`   | Argument 8 | Caller |
| `x8`   | `w8`   | Indirect result register (large structs); syscall number | Caller |
| `x9`   | `w9`   | Temporary | Caller |
| `x10`  | `w10`  | Temporary | Caller |
| `x11`  | `w11`  | Temporary | Caller |
| `x12`  | `w12`  | Temporary | Caller |
| `x13`  | `w13`  | Temporary | Caller |
| `x14`  | `w14`  | Temporary | Caller |
| `x15`  | `w15`  | Temporary | Caller |
| `x16`  | `w16`  | Intra-procedure-call scratch (IP0); used by PLT/veneers | Caller |
| `x17`  | `w17`  | Intra-procedure-call scratch (IP1); used by PLT/veneers | Caller |
| `x18`  | `w18`  | Platform register (reserved on some OSes — avoid) | Varies |
| `x19`  | `w19`  | Callee-saved | **Callee** |
| `x20`  | `w20`  | Callee-saved | **Callee** |
| `x21`  | `w21`  | Callee-saved | **Callee** |
| `x22`  | `w22`  | Callee-saved | **Callee** |
| `x23`  | `w23`  | Callee-saved | **Callee** |
| `x24`  | `w24`  | Callee-saved | **Callee** |
| `x25`  | `w25`  | Callee-saved | **Callee** |
| `x26`  | `w26`  | Callee-saved | **Callee** |
| `x27`  | `w27`  | Callee-saved | **Callee** |
| `x28`  | `w28`  | Callee-saved | **Callee** |
| `x29`  | `w29`  | **Frame pointer (FP)** | **Callee** |
| `x30`  | `w30`  | **Link register (LR)** — return address | Caller |

**Special registers** (not general-purpose):

| Name      | Description |
|-----------|-------------|
| `sp`      | Stack pointer (64-bit, must be 16-byte aligned at public interfaces) |
| `pc`      | Program counter (not directly readable/writable in most instructions) |
| `xzr`/`wzr` | Zero register: reads always return 0, writes are discarded |
| `nzcv`    | Condition flags register (N, Z, C, V — see Condition Flags section) |

**Important**: Writing to a `w` (32-bit) form of a register **zero-extends** into the upper 32 bits of the `x` register. There is no sign-extension on register write.

### SIMD / Floating-Point Registers

AArch64 has 32 × 128-bit SIMD/FP registers. Each has multiple views:

| Name | Width | Description |
|------|-------|-------------|
| `v0`–`v31` | 128-bit | Full SIMD vector register |
| `q0`–`q31` | 128-bit | Alias for full register |
| `d0`–`d31` | 64-bit  | Double-precision FP / lower 64 bits |
| `s0`–`s31` | 32-bit  | Single-precision FP / lower 32 bits |
| `h0`–`h31` | 16-bit  | Half-precision FP / lower 16 bits |
| `b0`–`b31` | 8-bit   | Byte / lower 8 bits |

**ABI roles for SIMD/FP registers**:

| Range    | Role | Saved by |
|----------|------|----------|
| `v0`–`v7`  | FP/SIMD arguments and return values | Caller |
| `v8`–`v15` | Callee-saved (but only the lower 64 bits — `d8`–`d15`) | **Callee** |
| `v16`–`v31` | Temporaries | Caller |

Note: callee-save for `v8`–`v15` only preserves the bottom 64 bits. The upper 64 bits may be clobbered.

### VM Register Allocation Strategy

For a VM interpreter written as a C function, the callee-saved registers `x19`–`x28` are the best candidates to pin VM state across the dispatch loop, because they survive calls into helper functions without being pushed/popped each iteration.

The existing `libinterp/comp-aarch64.c` in this codebase uses (callee-saved
registers for the long-lived Dis state, so they survive `bl` into C helpers):

```
x0–x3 = RA0–RA3 (work registers / C args+return)
x4    = RCON  (constant / address builder)
x5    = RTA   (indirect-addressing temp)
x16   = branch-through temp
x19   = RREG  (pointer to the C REG struct; callee-saved)
x20   = RFP   (Dis frame pointer; callee-saved)
x21   = RMP   (Dis module data pointer; callee-saved)
x24   = RLR2  (link save inside macros, e.g. macmcal; callee-saved)
```

(An earlier version of this section listed the **ARM32** scheme — `x5`=RREG,
`x8`=RMP, `x9`=RFP — which is `comp-arm.c`, not the aarch64 backend. The map above
is the real `comp-aarch64.c`; see `ref/AGENTS_DIS_ARCH.md` / `ref/AGENTS_JIT.md`.)

For an interpreted (non-JIT) loop pinning state in C code, prefer `x19`–`x28` since they are callee-saved:

```c
// Recommended pinned-register strategy for interpreter loop:
// x19 = program counter (Inst* PC)
// x20 = frame pointer (uchar* FP)
// x21 = module pointer (uchar* MP)
// x22 = instruction count (int IC)
// x23 = pointer to REG struct or Prog
```

Using `register` keyword with GCC:
```c
register Inst* my_pc asm("x19");
register uchar* my_fp asm("x20");
```

---

## Calling Convention (AAPCS64)

### Parameter Passing

- First 8 integer/pointer arguments: `x0`–`x7` (in order).
- First 8 FP/SIMD arguments: `v0`–`v7`.
- Additional arguments: pushed onto the stack right-to-left (lowest-numbered extra arg is closest to `sp`).
- Large structs: caller allocates memory, passes address in `x8`.

### Return Values

- Single integer/pointer: `x0`.
- 128-bit integer: `x0` (low) and `x1` (high).
- Single FP: `s0` or `d0`.
- Large struct: written to address in `x8`; `x8` is returned in `x0`.

### Stack Alignment

The stack pointer must be **16-byte aligned** at any `bl` or `blr` instruction boundary (i.e., when calling a public function). Within a leaf function, alignment can be relaxed but must be restored before any `bl`. The stack grows **downward** (full-descending).

### Function Prologue/Epilogue Pattern

**Standard prologue** (saves FP and LR, allocates frame):

```asm
// Minimal: leaf function using only caller-saved registers
// No prologue needed if no calls are made and sp alignment is maintained.

// Non-leaf function:
stp     x29, x30, [sp, #-N]!    // allocate N bytes (multiple of 16), save FP+LR
mov     x29, sp                  // set frame pointer

// Save callee-saved registers used by this function:
stp     x19, x20, [sp, #16]
stp     x21, x22, [sp, #32]
// ... etc.
```

**Standard epilogue**:

```asm
ldp     x19, x20, [sp, #16]
ldp     x21, x22, [sp, #32]
ldp     x29, x30, [sp], #N      // restore FP+LR, deallocate frame
ret                              // branch to x30
```

**With pointer authentication (PAC, ARMv8.3+)**:

```asm
// Prologue: sign LR before saving
pacibsp                          // sign x30 with SP as context using key IB
stp     x29, x30, [sp, #-16]!
mov     x29, sp
// Epilogue:
ldp     x29, x30, [sp], #16
autibsp                          // authenticate x30
ret
```

**STP/LDP addressing modes**:

```asm
stp x1, x2, [sp, #-16]!    // pre-index: subtract 16 from sp, then store
stp x1, x2, [sp, #8]       // signed offset: store at sp+8, sp unchanged
ldp x1, x2, [sp], #16      // post-index: load from sp, then add 16 to sp
```

### Frame Record Layout

The frame chain is a linked list of frame records on the stack. Each record occupies 16 bytes:

```
[sp + 0]:  previous FP (x29 of caller)
[sp + 8]:  return address (LR = x30 of caller)
x29 points to [sp+0] of the current frame
```

Stack walkers follow `x29 → [x29] → [x29]` to unwind.

---

## Instruction Set

AArch64 uses a **fixed-width 32-bit instruction encoding** (unlike Thumb-2's variable width). Instructions must be 4-byte aligned.

### Data Processing — Integer

```asm
// Arithmetic (immediate or register)
add  x0, x1, x2          // x0 = x1 + x2
add  x0, x1, #imm        // x0 = x1 + imm (12-bit, optionally shifted by 12)
adds x0, x1, x2          // same, sets NZCV flags
sub  x0, x1, x2          // x0 = x1 - x2
subs x0, x1, x2          // same, sets NZCV flags (CMP is alias: subs xzr, ...)
mul  x0, x1, x2          // x0 = x1 * x2 (low 64 bits)
umulh x0, x1, x2         // x0 = (x1 * x2) >> 64  (unsigned high multiply)
smulh x0, x1, x2         // signed high multiply
udiv x0, x1, x2          // unsigned divide
sdiv x0, x1, x2          // signed divide
msub x0, x1, x2, x3      // x0 = x3 - (x1 * x2)  (multiply-subtract; MNEG uses xzr)
madd x0, x1, x2, x3      // x0 = x3 + (x1 * x2)

// Aliases
cmp  x1, x2              // subs xzr, x1, x2  (sets flags)
cmn  x1, x2              // adds xzr, x1, x2  (compare negative)
neg  x0, x1              // sub x0, xzr, x1
negs x0, x1              // subs x0, xzr, x1 (sets flags)

// Shifts and rotations
lsl  x0, x1, #n          // logical shift left
lsr  x0, x1, #n          // logical shift right (zero fill)
asr  x0, x1, #n          // arithmetic shift right (sign fill)
ror  x0, x1, #n          // rotate right
lsl  x0, x1, x2          // variable shift (register)
lsr  x0, x1, x2
asr  x0, x1, x2

// Bitwise
and  x0, x1, x2
orr  x0, x1, x2
eor  x0, x1, x2
bic  x0, x1, x2          // bit clear: x0 = x1 & ~x2
orn  x0, x1, x2          // x0 = x1 | ~x2
eon  x0, x1, x2          // x0 = x1 ^ ~x2

// Aliases
tst  x1, x2              // ands xzr, x1, x2  (test bits, sets flags)
mvn  x0, x1              // orn x0, xzr, x1   (bitwise NOT)
mov  x0, x1              // orr x0, xzr, x1   (move register)
mov  x0, #imm            // movz or movn depending on value

// Bit manipulation
ubfx x0, x1, #lsb, #width  // unsigned bit field extract
sbfx x0, x1, #lsb, #width  // signed bit field extract
bfi  x0, x1, #lsb, #width  // bit field insert
clz  x0, x1                 // count leading zeros
cls  x0, x1                 // count leading sign bits
rbit x0, x1                 // reverse bits
rev  x0, x1                 // reverse bytes (64-bit)
rev32 x0, x1                // reverse bytes within each 32-bit word

// Sign/zero extension
sxtb x0, w1              // sign-extend byte to 64 bits
sxth x0, w1              // sign-extend halfword
sxtw x0, w1              // sign-extend word (32-bit) to 64 bits
uxtb w0, w1              // zero-extend byte to 32 bits
uxth w0, w1              // zero-extend halfword to 32 bits
```

### Data Processing — Immediate Constants

AArch64 immediates are not arbitrary. There are three encoding classes:

1. **12-bit unsigned + optional 12-bit left shift**: Used in `add`/`sub`/`cmp`. Range 0–4095, or 0–(4095 << 12).
2. **Logical immediates**: Specific bitmask patterns (any rotation of a sequence of 1-bits) for `and`/`orr`/`eor`.
3. **Wide immediates**: 16-bit values with optional shifts of 0/16/32/48 bits, for `movz`/`movn`/`movk`.

To load an arbitrary 64-bit constant, use the assembler pseudo-instruction `ldr x0, =value` (PC-relative load from literal pool), or build it with `movz`/`movk`:

```asm
movz x0, #0x1234, lsl #48    // load 0x1234_0000_0000_0000
movk x0, #0x5678, lsl #32    // keep other bits, insert 0x5678
movk x0, #0x9abc, lsl #16
movk x0, #0xdef0
```

### Memory Access

**Load/Store addressing modes**:

```asm
// Base register only
ldr  x0, [x1]              // load 64-bit from address in x1
ldrb w0, [x1]              // load byte, zero-extend to 32 bits
ldrh w0, [x1]              // load halfword, zero-extend
ldrsb x0, [x1]             // load byte, sign-extend to 64 bits
ldrsh x0, [x1]             // load halfword, sign-extend to 64 bits
ldrsw x0, [x1]             // load word (32-bit), sign-extend to 64 bits
str  x0, [x1]              // store 64-bit
strb w0, [x1]              // store byte
strh w0, [x1]              // store halfword

// Immediate offset (signed, scaled)
ldr  x0, [x1, #8]          // load from x1+8
str  x0, [x1, #-16]        // store to x1-16 (negative allowed)

// Register offset (with optional shift)
ldr  x0, [x1, x2]          // load from x1+x2
ldr  x0, [x1, x2, lsl #3]  // load from x1 + (x2 << 3)  — scale by element size
ldr  x0, [x1, w2, sxtw]    // load from x1 + sign_extend_32(w2)
ldr  x0, [x1, w2, uxtw #3] // load from x1 + (zero_extend(w2) << 3)

// Pre-index (update base before access)
ldr  x0, [x1, #8]!         // x1 += 8; load from x1
str  x0, [sp, #-16]!       // sp -= 16; store to sp  (standard push pattern)

// Post-index (update base after access)
ldr  x0, [x1], #8          // load from x1; x1 += 8  (standard pop pattern)

// PC-relative (literals)
ldr  x0, label             // load value at label (within ±1MB)
adr  x0, label             // load address of label (within ±1MB)
adrp x0, label             // load page-aligned address of label (within ±4GB)
// adrp + add for full address:
adrp x0, symbol
add  x0, x0, :lo12:symbol

// Pair access (two registers simultaneously)
ldp  x0, x1, [x2]          // x0 = [x2], x1 = [x2+8]
stp  x0, x1, [x2, #16]     // [x2+16]=x0, [x2+24]=x1
ldp  x0, x1, [x2], #16     // post-index pair
stp  x0, x1, [sp, #-16]!   // pre-index pair (common prologue pattern)
```

### Branch Instructions

```asm
// Unconditional
b    label                  // PC-relative branch (±128MB)
bl   label                  // branch with link (sets x30=PC+4)
br   x0                     // branch to register
blr  x0                     // branch with link to register
ret                         // return: branch to x30
ret  x0                     // return to x0 (non-standard use)

// Conditional branch (on NZCV flags)
b.eq label    // equal (Z=1)
b.ne label    // not equal (Z=0)
b.cs label    // carry set / unsigned ≥ (C=1)  alias: b.hs
b.cc label    // carry clear / unsigned < (C=0) alias: b.lo
b.mi label    // minus / negative (N=1)
b.pl label    // plus / non-negative (N=0)
b.vs label    // overflow (V=1)
b.vc label    // no overflow (V=0)
b.hi label    // unsigned > (C=1 && Z=0)
b.ls label    // unsigned ≤ (C=0 || Z=1)
b.ge label    // signed ≥ (N=V)
b.lt label    // signed < (N≠V)
b.gt label    // signed > (Z=0 && N=V)
b.le label    // signed ≤ (Z=1 || N≠V)
b.al label    // always (same as b)

// Compare-and-branch (no flag setting, compact — avoids cmp+b pair)
cbz  x0, label   // branch if x0 == 0
cbnz x0, label   // branch if x0 != 0
cbz  w0, label   // same for 32-bit

// Test-and-branch (tests a single bit)
tbz  x0, #n, label    // branch if bit n of x0 is zero
tbnz x0, #n, label    // branch if bit n of x0 is non-zero
// TBZ/TBNZ range: ±32KB. Useful for flag testing without CMP.
```

### Condition Flags and Conditional Instructions

Instructions that **set flags** end in `S` (e.g., `adds`, `subs`, `ands`). `cmp` = `subs xzr, ...`; `cmn` = `adds xzr, ...`; `tst` = `ands xzr, ...`.

**Conditional select instructions** (no branching required):

```asm
csel  x0, x1, x2, cond   // x0 = (cond true) ? x1 : x2
cset  x0, cond            // x0 = (cond true) ? 1 : 0
csetm x0, cond            // x0 = (cond true) ? ~0 : 0  (all 1s or all 0s)
csinc x0, x1, x2, cond   // x0 = (cond true) ? x1 : x2+1
csinv x0, x1, x2, cond   // x0 = (cond true) ? x1 : ~x2
csneg x0, x1, x2, cond   // x0 = (cond true) ? x1 : -x2
cinc  x0, x1, cond        // csinc x0, x1, x1, !cond  (increment if cond)
cinv  x0, x1, cond        // csinv x0, x1, x1, !cond
cneg  x0, x1, cond        // csneg x0, x1, x1, !cond
```

**Conditional compare** (chain comparisons without branching):

```asm
ccmp  x0, x1, #flags, cond  // if cond: CMP x0,x1; else: NZCV = flags
ccmn  x0, x1, #flags, cond  // if cond: CMN x0,x1; else: NZCV = flags
```

### System Instructions

```asm
nop                          // no operation
wfe                          // wait for event (spin-lock sleep primitive)
wfi                          // wait for interrupt (EL1+ only in practice)
sev                          // send event (wake WFE on other cores)
sevl                         // send event local
yield                        // hint: this thread can be preempted
isb                          // instruction sync barrier (flush pipeline, refetch)
dsb  sy                      // data sync barrier (all memory ops complete before)
dsb  ish                     // inner-shareable domain (typical in user space)
dsb  ishld                   // load-only DSB
dsb  ishst                   // store-only DSB
dmb  ish                     // data memory barrier (ordering, no completion wait)
dmb  ishld
dmb  ishst
svc  #0                      // supervisor call (Linux syscall)
brk  #imm                    // breakpoint (SIGTRAP on Linux)
hlt  #imm                    // halt (debug)

// System register access
mrs  x0, nzcv                // read condition flags
msr  nzcv, x0               // write condition flags
mrs  x0, tpidr_el0           // read thread pointer (TLS base)
mrs  x0, ctr_el0             // read cache type register (cache line sizes)
```

---

## Addressing Modes Summary

| Mode | Syntax | Description |
|------|--------|-------------|
| Base | `[Xn]` | Address = Xn |
| Immediate offset | `[Xn, #imm]` | Address = Xn + imm (signed, scaled) |
| Register offset | `[Xn, Xm]` | Address = Xn + Xm |
| Scaled reg offset | `[Xn, Xm, lsl #s]` | Address = Xn + (Xm << s) |
| Extended reg | `[Xn, Wm, sxtw]` | Address = Xn + sign_extend(Wm) |
| Pre-index | `[Xn, #imm]!` | Xn += imm; Address = Xn |
| Post-index | `[Xn], #imm` | Address = Xn; Xn += imm |
| PC-relative | `label` (ldr) | Address = PC ± offset |

---

## Memory Model

AArch64 uses a **weakly-ordered** memory model. Loads and stores may be observed out of order by other cores. Explicit barriers or acquire/release instructions are required for synchronization.

### Barrier Instructions

| Instruction | Effect |
|-------------|--------|
| `DMB ish`   | Data Memory Barrier: all preceding memory accesses complete before subsequent ones are issued (ordering only) |
| `DSB ish`   | Data Synchronization Barrier: all preceding memory accesses **complete** before subsequent instructions execute |
| `ISB`       | Instruction Synchronization Barrier: flush pipeline, re-fetch instructions (needed after JIT code write, after modifying system registers) |

**Domain specifiers** (suffix on DMB/DSB):
- `sy` — full system
- `ish` — inner shareable (all cores in the same cluster; typical for user-space SMP)
- `osh` — outer shareable
- `nsh` — non-shareable
- Add `ld` for load-only, `st` for store-only (e.g., `ishld`, `ishst`)

### Acquire/Release Instructions

Preferred over DMB for lock implementations — lower cost on out-of-order hardware:

```asm
ldar   x0, [x1]     // load-acquire: no load/store after this may reorder before it
stlr   x0, [x1]     // store-release: no load/store before this may reorder after it
ldarb  w0, [x1]     // byte variant
ldarh  w0, [x1]     // halfword variant
stlrb  w0, [x1]
stlrh  w0, [x1]
```

### Exclusive Monitors (LDXR/STXR) — LL/SC Atomics

Used to implement compare-and-swap, atomic increment, and spinlocks:

```asm
// Atomic increment:
1:  ldxr   w1, [x0]       // load exclusive (sets exclusive monitor)
    add    w1, w1, #1
    stxr   w2, w1, [x0]   // store exclusive: w2=0 on success, w2=1 on failure
    cbnz   w2, 1b          // retry on failure

// Compare-and-swap (CAS) manually:
1:  ldaxr  w1, [x0]       // load-acquire exclusive (for lock semantics)
    cmp    w1, w2          // compare with expected
    b.ne   2f              // not equal: fail
    stlxr  w3, w4, [x0]   // store-release exclusive: new value
    cbnz   w3, 1b          // retry if store failed
2:
```

Available widths: `LDXRB/STXRB` (byte), `LDXRH/STXRH` (halfword), `LDXR/STXR` (32 or 64-bit).
With acquire/release: `LDAXR`/`STLXR` (most common for locks).
Pair: `LDXP`/`STXP` (two registers at once, for 128-bit atomics).

**Rules**: LDXR and STXR must operate on the same address. Avoid calling functions between LDXR and STXR — a context switch or any intervening memory access may clear the exclusive monitor. The retry loop should be tight and short.

**Clrex**: `clrex` clears the exclusive monitor without doing a store. Use it in signal handlers or after an abandoned exclusive sequence.

### LSE — Large System Extensions (ARMv8.1+)

All server-class AArch64 chips (Cortex-A55+, Neoverse N1/V1/V2, Apple M1+, Ampere Altra) support LSE. It provides single-instruction atomics — no retry loop needed:

```asm
// Atomic fetch-and-add (returns old value in x1):
ldadd   x0, x1, [x2]     // x1 = [x2]; [x2] += x0
ldadda  x0, x1, [x2]     // with acquire
ldaddl  x0, x1, [x2]     // with release
ldaddal x0, x1, [x2]     // with acquire+release (sequentially consistent)

// Atomic operations: ADD, CLR (AND NOT), EOR, SET (OR), SMAX, SMIN, UMAX, UMIN
// Pattern: ld{op}{a}{l}  Xs, Xt, [Xn]  (also st{op} variants that don't return old)

// Atomic swap (exchange):
swp   x0, x1, [x2]       // x1 = [x2]; [x2] = x0
swpa  x0, x1, [x2]       // with acquire
swpl  x0, x1, [x2]       // with release
swpal x0, x1, [x2]       // with acquire+release

// Compare and swap:
cas   w0, w1, [x2]        // if [x2]==w0: [x2]=w1; w0=old [x2]
casl  w0, w1, [x2]        // with release
casa  w0, w1, [x2]        // with acquire
casal w0, w1, [x2]        // with acquire+release
// Also: casb, cash, casp (pair), caspal, etc.
```

**Detecting LSE at runtime**:
```sh
dmesg | grep LSE              # kernel prints "LSE atomic instructions"
lscpu | grep atomics          # CPU flags
cat /proc/cpuinfo | grep atomics
```

**GCC flags**:
```sh
-march=armv8.1-a              # enable LSE unconditionally
-moutline-atomics             # runtime dispatch to LSE or LL/SC (GCC 10+)
-mno-outline-atomics          # always use LL/SC
```

**For the Dis VM spinlock** (`emu/Linux/lock.c` / `aarch64-tas.S`): prefer `CASAL` or `SWPAL` on ARMv8.1+ targets; fall back to `LDAXR`/`STLXR` loop for portability.

---

## Implementing a Test-and-Set Lock

The existing `emu/Linux/aarch64-tas.S` implements the Dis VM's TAS primitive. For reference, a portable acquire-release spinlock on AArch64:

```asm
// spin_lock(int* lock):
//   Loops until the lock transitions from 0 to 1.
spin_lock:
1:  ldaxr  w1, [x0]       // load-acquire exclusive
    cbnz   w1, 2f          // lock held — spin
    mov    w1, #1
    stlxr  w2, w1, [x0]   // store-release exclusive
    cbnz   w2, 1b          // store failed — retry
    ret

2:  wfe                    // low-power wait for event
    b      1b

// spin_unlock(int* lock):
spin_unlock:
    stlr   wzr, [x0]       // store-release 0 (unlock)
    sev                    // wake any WFE waiters
    ret
```

With LSE (ARMv8.1+), trylock becomes one instruction:
```asm
// int spin_trylock(int* lock): returns 0 on success, 1 on failure
spin_trylock:
    mov    w1, #0           // expected (unlocked)
    mov    w2, #1           // desired (locked)
    casal  w1, w2, [x0]    // atomic CAS: if [x0]==0: [x0]=1, w1=old
    // w1 now holds old value; 0 means we acquired, non-zero means failed
    mov    w0, w1
    ret
```

---

## Cache Coherency for JIT Code

AArch64 separates the instruction cache (I-cache) from the data cache (D-cache). After writing JIT-compiled native code into a buffer, you **must** flush caches before executing it.

### Required Sequence

```c
// C wrapper using GCC builtins (simplest portable approach):
__builtin___clear_cache((char*)start, (char*)end);

// This calls the kernel's sys_cacheflush equivalent or does the
// cache maintenance instructions directly.
```

Direct assembly (when you need precise control or can't use GCC builtins):

```c
void flush_icache(uintptr_t start, uintptr_t end) {
    // 1. Determine cache line sizes from CTR_EL0
    uint32_t ctr;
    asm("mrs %[ctr], ctr_el0" : [ctr] "=r" (ctr));
    uintptr_t dsize = 4 << ((ctr >> 16) & 0xf);  // D-cache line size
    uintptr_t isize = 4 << ((ctr >>  0) & 0xf);  // I-cache line size

    // 2. Clean D-cache lines to point of unification (PoU)
    for (uintptr_t d = start & ~(dsize-1); d < end; d += dsize)
        asm("dc cvau, %0" :: "r"(d) : "memory");

    // 3. DSB: wait for DC operations to complete
    asm("dsb ish" ::: "memory");

    // 4. Invalidate I-cache lines at PoU
    for (uintptr_t i = start & ~(isize-1); i < end; i += isize)
        asm("ic ivau, %0" :: "r"(i) : "memory");

    // 5. DSB: wait for IC operations to complete
    asm("dsb ish" ::: "memory");

    // 6. ISB: flush pipeline so new instructions are fetched fresh
    asm("isb" ::: "memory");
}
```

**When to skip steps**: On some CPUs, `CTR_EL0.DIC=1` means the I-cache is automatically coherent after a D-cache clean (can skip step 4). `CTR_EL0.IDC=1` means the D-cache is automatically coherent (can skip steps 2–3). Check at startup and cache the result. However, beware errata (e.g., Neoverse N1 Errata 1542419). The safest approach is to always run the full sequence.

**The existing `segflush-aarch64.c` in this codebase** uses `__builtin___clear_cache`, which is correct and sufficient for the Dis VM's JIT use case.

---

## JIT Memory Management

To generate native code at runtime, you need a memory region that is both writable (to write instructions) and executable (to run them).

### Linux Approach

```c
#include <sys/mman.h>

// Allocate RW memory
void* buf = mmap(NULL, size,
                 PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

// ... write machine code into buf ...
flush_icache((uintptr_t)buf, (uintptr_t)buf + size);

// Make executable (remove write permission)
mprotect(buf, size, PROT_READ | PROT_EXEC);

// Call the code
((void(*)(void))buf)();
```

**Never map RWX simultaneously** if avoidable — SELinux, seccomp, and W^X policies may reject it, and it's a security risk. Use the write→flush→mprotect(RX) pattern.

**Dual mapping** (write one mapping, execute another — for streaming JIT):
```c
// Create anonymous fd
int fd = memfd_create("jit", 0);
ftruncate(fd, size);

// Map writable for writing code
void* rw = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
// Map read+execute for running code
void* rx = mmap(NULL, size, PROT_READ|PROT_EXEC,  MAP_SHARED, fd, 0);

// Write into rw, execute from rx — no mprotect needed
```

---

## GNU Assembler Syntax

Inferno uses GNU `as` (GAS) for all assembly files. AArch64 assembly in this codebase uses AT&T conventions as extended by GAS.

### File Directives

```asm
.file   "foo.S"
.arch   armv8-a                  // minimum required architecture
.arch_extension crc              // enable specific extension (crc, crypto, lse, etc.)
.cpu    generic+lse              // alternate: specify CPU with extensions
.text                            // switch to .text section
.data                            // switch to .data section
.bss                             // switch to .bss section
.section .rodata                 // read-only data

.global my_func                  // export symbol
.type   my_func, %function       // declare as function (for stack unwinding)
.size   my_func, . - my_func     // size of function

.align  4                        // align to 2^4 = 16 bytes
.balign 16                       // align to 16 bytes (synonym, clearer)
```

### Instruction Syntax

GAS uses **destination-first** for most instructions (same as ARM documentation):

```asm
add  x0, x1, x2          // x0 = x1 + x2  (dest, src1, src2)
ldr  x0, [x1, #8]        // x0 = *(x1+8)
str  x0, [x1, #8]        // *(x1+8) = x0
```

### Labels and Symbols

```asm
my_label:                 // define label
    b    my_label         // branch to label

1:                        // numeric local label
    b    1b               // branch to previous "1:" label
    b    1f               // branch to next "1:" label

.Llocal:                  // local label (not exported)
```

### Assembly for .S Files with CPP

Inferno `.S` files are run through the C preprocessor. Use `#include`, `#define`, `#ifdef`, etc. The `$(AS)` variable in mkfiles uses `gcc -c` which handles preprocessing automatically.

### Inline Assembly in C

Used throughout `emu/Linux/os.c` and `libinterp/comp-aarch64.c`:

```c
// Basic form: asm("instruction" : outputs : inputs : clobbers);

// Read a system register:
uint64_t val;
asm("mrs %0, tpidr_el0" : "=r"(val));

// Memory barrier:
asm("dmb ish" ::: "memory");   // "memory" clobber prevents reordering in compiler

// ISB (pipeline flush):
asm("isb" ::: "memory");

// Atomic: test-and-set (returns old value)
int test_and_set(volatile int* p) {
    int old, tmp;
    asm volatile(
        "1:\n\t"
        "ldaxr  %w0, [%2]\n\t"
        "cbnz   %w0, 2f\n\t"
        "stlxr  %w1, %w3, [%2]\n\t"
        "cbnz   %w1, 1b\n\t"
        "2:\n\t"
        : "=&r"(old), "=&r"(tmp)
        : "r"(p), "r"(1)
        : "memory"
    );
    return old;
}
```

**GCC inline asm constraints for AArch64**:

| Constraint | Meaning |
|------------|---------|
| `r`        | Any general-purpose register |
| `w`        | SIMD/FP register |
| `m`        | Memory address |
| `i`        | Immediate integer |
| `=r`       | Output in any GPR |
| `=&r`      | Early-clobber output (written before all inputs read) |
| `+r`       | Read-write GPR |
| `"memory"` | Clobber: prevents compiler reordering memory accesses around this asm |
| `"cc"`     | Clobber: this asm may change condition flags |

Specific register constraints: `"{x0}"`, `"{w8}"`, etc. (force a specific register).

---

## Linux Signal Handling

Inferno's OS integration layer (`emu/Linux/os.c`) uses `sigaction` with `SA_SIGINFO` to catch hardware faults and translate them into Dis VM exceptions.

### Signal Handler Signature

```c
void handler(int signo, siginfo_t *si, void *uctx);
// uctx is really ucontext_t* — cast it to access registers
```

### AArch64 ucontext_t Layout

```c
// From <sys/ucontext.h> on Linux/aarch64:
typedef struct {
    unsigned long long regs[31];  // x0–x30
    unsigned long long sp;
    unsigned long long pc;
    unsigned long long pstate;    // NZCV + DAIF + other PSTATE bits
    // ...followed by FP/SIMD state and extension records
} mcontext_t;

typedef struct ucontext_t {
    unsigned long  uc_flags;
    struct ucontext_t *uc_link;
    stack_t        uc_stack;
    sigset_t       uc_sigmask;
    mcontext_t     uc_mcontext;   // register state
} ucontext_t;
```

**Accessing registers in a signal handler**:

```c
void trapmemref(int signo, siginfo_t *si, void *ctx) {
    ucontext_t *uc = (ucontext_t*)ctx;
    unsigned long long pc  = uc->uc_mcontext.pc;
    unsigned long long sp  = uc->uc_mcontext.sp;
    unsigned long long *r  = uc->uc_mcontext.regs;  // r[0]=x0, r[30]=x30
    void *fault_addr = si->si_addr;

    // Redirect execution by modifying pc in the context:
    uc->uc_mcontext.pc = (unsigned long long)my_handler;
}
```

**siginfo_t fields relevant to SIGSEGV/SIGBUS**:

```c
si->si_signo   // signal number
si->si_code    // SEGV_MAPERR (bad address), SEGV_ACCERR (permissions), BUS_ADRALN (alignment)
si->si_addr    // faulting address
```

**Detecting a nil dereference** (address near zero):

```c
static int isnilref(siginfo_t *si) {
    return (uintptr_t)si->si_addr < 4096;
}
```

### Installing Signal Handlers

```c
struct sigaction act;
memset(&act, 0, sizeof(act));
act.sa_sigaction = my_handler;
act.sa_flags = SA_SIGINFO;          // use 3-arg handler form
sigemptyset(&act.sa_mask);
sigaction(SIGSEGV, &act, NULL);
sigaction(SIGBUS,  &act, NULL);
sigaction(SIGFPE,  &act, NULL);
sigaction(SIGILL,  &act, NULL);
```

---

## Thread-Local Storage

The thread pointer is in `TPIDR_EL0` (EL0 Read/Write Software Thread ID Register). On Linux with pthreads, this is set automatically per-thread by the C runtime.

```c
// Reading the thread pointer:
uintptr_t tp;
asm("mrs %0, tpidr_el0" : "=r"(tp));

// TLS layout on Linux/glibc/AArch64:
// tp → [0..15] = ABI TCB (16-byte reserved)
// tp - offset  = per-module TLS data (negative offsets for static TLS)
```

**Using `__thread` / `_Thread_local`** in C is the standard way to allocate thread-local variables; the compiler generates the appropriate `TPIDR_EL0`-relative accesses automatically.

**Per-Proc data for the Dis VM**: The `up` macro (pointer to current `Proc`) is implemented in `emu/Linux/os.c` using `pthread_getspecific`. On AArch64, `pthread_getspecific` ultimately reads from `TPIDR_EL0`-relative storage.

---

## VM Dispatch Techniques

### Switch Dispatch (Baseline)

```c
for (;;) {
    switch (R.PC->op) {
    case IADDW: /* ... */ break;
    case ISUBW: /* ... */ break;
    // ...
    }
    R.PC++;
}
```

Compilers typically generate a jump table for this. On AArch64, `BR X0` (indirect branch) is used — one indirect branch per opcode. Branch predictors on ARM cores may have simpler indirect-branch pattern matching than recent Intel, meaning the predicted target (the same opcode handler next time) is less likely to be cached.

### Direct Threading (Computed Goto — GCC Extension)

The fastest interpreted dispatch technique on AArch64. Eliminates the switch-table indirection by ending each handler with a direct jump to the next handler:

```c
static void* dispatch_table[] = {
    [INOP]   = &&do_nop,
    [IADDW]  = &&do_addw,
    [ISUBW]  = &&do_subw,
    // ...
};

#define DISPATCH() \
    goto *dispatch_table[(R.PC++)->op]

DISPATCH();   // start

do_addw:
    *(WORD*)R.d = *(WORD*)R.s + *(WORD*)R.m;
    DISPATCH();

do_subw:
    *(WORD*)R.d = *(WORD*)R.s - *(WORD*)R.m;
    DISPATCH();
// ...
```

GCC generates `BR Xn` at each dispatch point, targeting the handler's address loaded from the table. On AArch64, this allows the branch predictor to speculate the target based on the specific dispatch site — each `DISPATCH()` expansion becomes a different indirect branch instruction, giving the predictor more context.

**Pinning the dispatch table**: Keeping `dispatch_table`'s address in a callee-saved register (`x19`–`x28`) reduces memory loads per dispatch:

```c
// In C, hint to keep dispatch_table ptr in a register:
register void** dtable asm("x23") = dispatch_table;
#define DISPATCH() goto *dtable[(R.PC++)->op]
```

### Tail-Call Threading (C23 / Clang musttail)

Each opcode handler is a separate function; each calls the next via tail call. Requires TCO (tail-call optimization) — GCC and clang on AArch64 support this for `__attribute__((musttail))` in C23 or `[[clang::musttail]]`:

```c
typedef void (*Handler)(Prog* p);
void do_addw(Prog* p) {
    *(WORD*)p->R.d = *(WORD*)p->R.s + *(WORD*)p->R.m;
    [[clang::musttail]] return dispatch_table[p->R.PC->op](p);
}
```

Advantage: handler code is better isolatable for the compiler. Disadvantage: function call overhead if TCO fails; harder to keep VM state in registers.

### JIT (Native Code Generation)

See `libinterp/comp-aarch64.c`. The JIT translates Dis instructions to AArch64 machine code at load time. Key considerations:

1. **Instruction encoding**: All AArch64 instructions are 32-bit. Generate them by building 32-bit integers from field specifications or use a code generation library.
2. **PC-relative addressing**: Literals and labels must be within ±1MB for `LDR`/`ADR`, ±4GB for `ADRP`. For larger ranges, use a register as base.
3. **Time-slice check**: The PQUANTA counter must be decremented and checked. Insert a `SUBS` + `B.LE trampoline` every N instructions or per-basic-block.
4. **Cache flush**: Call `flush_icache(start, end)` after generating each module's native code (before first execution).
5. **Relocation**: Forward branches to not-yet-generated code need patching. Keep a list of fixup locations.

---

## Security Features Affecting VM Code

### Pointer Authentication (PAC, ARMv8.3+)

PAC signs pointers with a cryptographic MAC stored in unused bits. Functions that use PAC must:
- Begin prologue with `PACIBSP` (sign LR with SP as context, key IB)
- End epilogue with `AUTIBSP` (authenticate) before `RET`

For generated code: if the host kernel enforces PAC (e.g., with `PSTATE.TCO` cleared), any indirect branch to unsigned code may fault. JIT-generated code may need `PACIAZ`/`BRAA` style branches, or must be generated in a way that the kernel accepts. On Linux, PAC enforcement is opt-in per-process; most userspace JITs are not affected unless the process sets `PR_SET_TAGGED_ADDR_CTRL`.

### Branch Target Identification (BTI, ARMv8.5+)

On BTI-enabled pages, indirect branches (`BR`, `BLR`) may only target `BTI` landing-pad instructions. Types:
- `BTI c` — target of `BL`/`BLR` (call)
- `BTI j` — target of `BR` (jump)
- `BTI jc` — target of either
- `HINT #34` (opcode for `BTI`) — NOP on older hardware

For computed-goto dispatch tables: each handler's address must be preceded by a `BTI j` instruction. For JIT code: each function entry must have `BTI c`. If the JIT region is not marked with the BTI flag in its ELF segment, BTI is not enforced on that region.

**Checking at runtime**:
```sh
cat /proc/cpuinfo | grep bti
```

---

## AArch64 Data Type Sizes

Critical for Dis VM code that assumes C type widths:

| C Type       | AArch64 size | Dis type |
|--------------|--------------|----------|
| `char`       | 1 byte       | — |
| `short`      | 2 bytes      | — |
| `int`        | 4 bytes      | `WORD` |
| `long`       | **8 bytes**  | — (differs from 32-bit ARM where long=4) |
| `long long`  | 8 bytes      | `LONG` |
| `void*`      | 8 bytes      | pointer |
| `size_t`     | 8 bytes      | — |
| `uintptr_t`  | 8 bytes      | — |
| `double`     | 8 bytes      | `REAL` |
| `float`      | 4 bytes      | `SREAL` |

**Key portability issue**: On AArch64, `sizeof(long) == sizeof(void*) == 8`. Code that stores pointers in `long` or `int` variables works on 32-bit but breaks on AArch64. This was the main fix in the portability commit (34afd3f5): replacing `long` with `uintptr_t` for pointer-integer round-trips in `lib9/`, `utils/mk/`.

**Struct alignment on AArch64**:
- Natural alignment: each field aligned to its own size
- `int` (4 bytes): aligned to 4
- `long`/`void*` (8 bytes): aligned to 8
- `double` (8 bytes): aligned to 8
- Structs: aligned to largest member; padded to multiple of that alignment

---

## Linux Syscall ABI

For bare-assembly usage (not typical in emu, but relevant for native kernel work):

```asm
// Arguments: x0–x7 (up to 8)
// Syscall number: w8
// Invoke: svc #0
// Return value: x0 (negative errno on error)
// Clobbered by kernel: x0–x18, cc

// Example: write(fd=1, buf, len)
mov  w8, #64            // __NR_write = 64 on AArch64
mov  x0, #1             // fd = 1 (stdout)
ldr  x1, =buf           // buffer address
mov  x2, #13            // length
svc  #0
```

Common AArch64 Linux syscall numbers:
```
read=63  write=64  openat=56  close=57  mmap=222  mprotect=226
munmap=215  brk=214  clone=220  exit=93  exit_group=94
futex=98  nanosleep=101  getpid=172  kill=129  sigaltstack=132
rt_sigaction=134  rt_sigprocmask=135  rt_sigreturn=139
```

Full table: `include/uapi/asm-generic/unistd.h` in the Linux kernel source.

---

## Porting Checklist for the Dis VM

**Status: the aarch64 port is complete and working** — `emu` builds, the full test
suite is 178/178 under both the interpreter and `-c1` (JIT), and the LP64 Dis ABI
runs the committed XMAGIC8 `.dis` tree. The checklist below is therefore a
historical record; only the optional LSE item remains open.

- [x] `mkfiles/mkfile-Linux-aarch64` — compiler flags (`-march=armv8-a`, include paths, defines)
- [x] `emu/Linux/mkfile-aarch64` — `ARCHFILES` listing arch-specific .o files
- [x] `Linux/aarch64/include/lib9.h` — architecture-specific `lib9` header (type sizes, FP control)
- [x] `Linux/aarch64/include/emu.h` — architecture-specific emu header (pthreads, signal config)
- [x] `emu/Linux/asm-aarch64.S` — `umult` and other arithmetic helpers needing asm
- [x] `emu/Linux/aarch64-tas.S` — test-and-set for the spinlock primitive
- [x] `emu/Linux/segflush-aarch64.c` — instruction cache flush (`__builtin___clear_cache`)
- [x] `lib9/getcallerpc-Linux-aarch64.S` — return address introspection (`mov x0, x30; ret`)
- [x] `lib9/setfcr-Linux-aarch64.S` — floating-point control register setup (FPCR)
- [x] `libinterp/comp-aarch64.c` — JIT compiler: Dis→AArch64 native code
- [x] Signal handler correctness — `trapmemref` (`emu/Linux/os.c`) uses `uc_mcontext.regs`/`.pc`; drives EMUCRASH/fault recovery
- [x] `uintptr_t` casts — pointer↔integer conversions use `uintptr_t` (commit `34afd3f5`)
- [x] `sizeof(long) == 8` — handled; the whole LP64 dual-ABI model builds and runs
- [x] Struct layout — no hand-coded offsets assume 32-bit pointers (dual-ABI verified)
- [x] Stack alignment — `sp` writes keep 16-byte alignment (JIT runs the full suite)
- [x] JIT cache flush — `segflush-aarch64.c` (`__builtin___clear_cache`) after each compile
- [ ] LSE detection (optional, **not done**) — `aarch64-tas.S` still uses the `ldxr`/`stxr` LL/SC loop; LSE `CASAL`/`SWPAL` fast path is unimplemented (works fine without it)

---

Sources:
- [AArch64 Procedure Call Standard (AAPCS64) — Tuna Cici, Medium](https://medium.com/@tunacici7/aarch64-procedure-call-standard-aapcs64-abi-calling-conventions-machine-registers-a2c762540278)
- [AAPCS64 PDF — c9x.me](https://c9x.me/compile/bib/abi-arm64.pdf)
- [NZCV Condition Flags — ARM Developer](https://developer.arm.com/documentation/ddi0601/latest/AArch64-Registers/NZCV--Condition-Flags)
- [AArch64 Barriers — The Old New Thing](https://devblogs.microsoft.com/oldnewthing/20220812-00/?p=106968)
- [AArch64 Atomic Access — The Old New Thing](https://devblogs.microsoft.com/oldnewthing/20220811-00/?p=106963)
- [AArch64 Prologues and Epilogues — The Old New Thing](https://devblogs.microsoft.com/oldnewthing/20220824-00/?p=107043)
- [AArch64 Manipulating Flags — The Old New Thing](https://devblogs.microsoft.com/oldnewthing/20220818-00/?p=107005)
- [Caches and Self-Modifying Code: implementing clear-cache — ARM Community](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/caches-self-modifying-code-implementing-clear-cache)
- [ARM64 One-Way Barriers (LDAR/STLR) — ElseWhere](https://duetorun.com/blog/20231007/a64-oneway-barrier/)
- [ARM64 Exclusive Load/Store — ElseWhere](https://duetorun.com/blog/20231007/a64-load-store-exclusive/)
- [Large System Extensions Intro — ARM Learning Paths](https://learn.arm.com/learning-paths/servers-and-cloud-computing/lse/intro/)
- [Thread Pointer/ID Register TPIDR_EL0 — blog.iret.xyz](https://blog.iret.xyz/posts/thread-pointer-aarch64/)
- [All About Thread-Local Storage — MaskRay](https://maskray.me/blog/2021-02-14-all-about-thread-local-storage)
- [linux/arch/arm64/include/uapi/asm/sigcontext.h — torvalds/linux](https://github.com/torvalds/linux/blob/master/arch/arm64/include/uapi/asm/sigcontext.h)
- [AArch64 Notes — johannst.github.io](https://johannst.github.io/notes/arch/arm64.html)
- [GNU Assembler AArch64 Directives — sourceware.org](https://sourceware.org/binutils/docs/as/AArch64-Directives.html)
- [GCC AArch64 Options — gcc.gnu.org](https://gcc.gnu.org/onlinedocs/gcc/AArch64-Options.html)
- [Enabling PAC and BTI on AArch64 for Linux — ARM Community](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/enabling-pac-and-bti-on-aarch64)
- [VM Dispatch Experiments — Peter Liniker](https://pliniker.github.io/post/dispatchers/)
- [How to JIT — Eli Bendersky](https://eli.thegreenplace.net/2013/11/05/how-to-jit-an-introduction)
- [ARM Trusted Firmware spinlock.S](https://github.com/ARM-software/arm-trusted-firmware/blob/master/lib/locks/exclusive/aarch64/spinlock.S)
