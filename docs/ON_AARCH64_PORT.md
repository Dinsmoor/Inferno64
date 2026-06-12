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

### General-Purpose Registers (AAPCS64 roles)

| Range | Role | Saved by |
|---|---|---|
| `x0`–`x7` | arguments / return values (`x0`, pair `x0:x1`) | caller |
| `x8` | indirect-result pointer (large structs); syscall number | caller |
| `x9`–`x15` | temporaries | caller |
| `x16`/`x17` | intra-procedure-call scratch (IP0/IP1) — PLT/veneers may clobber | caller |
| `x18` | platform register — reserved on some OSes, avoid | varies |
| `x19`–`x28` | callee-saved — the registers to pin long-lived VM state in | **callee** |
| `x29` | frame pointer | **callee** |
| `x30` | link register (return address) | caller |

Special: `sp` (16-byte aligned at public interfaces), `xzr`/`wzr` (zero
register), `nzcv` (condition flags). **Writing a `w` (32-bit) register
zero-extends into the upper half of the `x` register — there is no
sign-extension on register write.** This is why the JIT can use `w`-register
ops for Dis words and `x`-register ops for pointers on the same register file.

### SIMD / Floating-Point Registers

32 × 128-bit registers, viewed as `v` (128) / `d` (64, double) / `s` (32) /
`h`/`b`. ABI: `v0`–`v7` arguments+returns (caller-saved), `v8`–`v15`
callee-saved **but only the low 64 bits (`d8`–`d15`)**, `v16`–`v31`
temporaries. The JIT's scalar-double FP uses caller-saved `d` registers only,
so FP state never needs saving across its punts.

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

The map lives at the top of `comp-aarch64.c`; `ON_JIT.md` is the codegen
reference. The callee-saved choice is what makes `punt()` cheap: the pinned
Dis state survives the `bl` into the interpreter's C without spills.

---

## Calling Convention (AAPCS64)

- **Arguments:** first 8 integer/pointer args in `x0`–`x7`, first 8 FP args in
  `v0`–`v7`, the rest on the stack; large structs by reference in `x8`.
- **Returns:** `x0` (integer/pointer), `x0:x1` (128-bit), `d0`/`s0` (FP);
  large struct written through `x8`.
- **Stack:** grows down; `sp` must be **16-byte aligned at every `bl`/`blr`**.
- **Frame record:** `stp x29, x30, [sp,#-N]!; mov x29, sp` builds a 16-byte
  `{caller-FP, return-address}` record; stack walkers follow
  `x29 → [x29] → …` to unwind. Callee-saved registers a function uses are
  saved in its own frame (`stp x19,x20,[sp,#16]` …) and restored before `ret`.

The two AAPCS64 facts that have actually drawn blood here: the 16-byte `sp`
alignment rule, and **callee-saved means the JIT must save them too** —
`comvec` is reached by an ordinary C call, so its prologue saves
`x19/x20/x21/x24` and every path back to C restores them (see ON_JIT.md
"Root causes").

---

## Instruction Set — what the encoder layer needs

Every AArch64 instruction is a **fixed-width 32-bit word**, 4-byte aligned.
The full ISA is the ARM ARM's job; `comp-aarch64.c`'s encoder layer
(`addx`/`ldr`/`b_`/… emitters) is the in-tree ground truth, each emitter
validated bit-exact against `objdump` (see ON_JIT.md). The facts that shape
codegen:

**Immediates are not arbitrary.** Three encoding classes:
1. **12-bit unsigned, optionally `lsl #12`** — `add`/`sub`/`cmp` (0–4095, or
   that shifted).
2. **Logical immediates** — only replicated-rotated bitmask patterns are
   encodable for `and`/`orr`/`eor`; arbitrary masks must go through a register.
3. **Wide immediates** — 16 bits at shift 0/16/32/48 for `movz`/`movk`/`movn`;
   an arbitrary 64-bit constant is up to four instructions
   (`movz` + 3×`movk`), which is what the JIT's `con()` emits.

**Branch and literal ranges** (what forces veneers or register branches):

| Form | Range |
|---|---|
| `b`, `bl` | ±128 MB |
| `b.cond`, `cbz`/`cbnz`, `ldr` (literal) | ±1 MB |
| `tbz`/`tbnz` | ±32 KB |
| `adr` | ±1 MB |
| `adrp` (+ `:lo12:` add) | ±4 GB, page-granular |

**Flags and conditional ops.** Only `S`-suffixed instructions set NZCV
(`cmp` = `subs xzr,…`, `cmn` = `adds xzr,…`, `tst` = `ands xzr,…`); `csel`/
`cset` give branchless selects. The JIT's H-sentinel test is a `cmn`
(compare-negative) because H is a small negative constant.

**Width discipline.** `w`-register forms operate on and zero-extend to 32
bits; sign-extension is explicit (`sxtw` etc.). Loads pick the width *and*
the extension: `ldr w0` zero-extends, `ldrsw x0` sign-extends a 32-bit load —
choosing wrong silently corrupts the high half of a Dis pointer slot.

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

In-tree state: the JIT generates into a single low (<2 GB) arena that
`segflush-aarch64.c` leaves RWX (`mprotect` RWX on the flushed range) so the
32-bit WORD jump tables can hold native addresses and recompiles can patch in
place. Moving to the write→RX or dual-mapping pattern above is the hardening
direction if a host policy ever rejects RWX.

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

## GNU Assembler Notes

The hand-written `.S` files (`asm-aarch64.S`, `aarch64-tas.S`,
`lib9/*-Linux-aarch64.S`) use GNU `as`: destination-first operand order, the
usual `.text`/`.global name`/`.type name, %function` skeleton, and `.S` files
run through cpp first (so `#include`/`#ifdef` work). Full directive reference:
the binutils AArch64 docs. Inline asm in C follows standard GCC extended-asm
syntax; the only places this tree uses it are the cache-maintenance and
`tpidr_el0`/`ctr_el0` reads shown in this file.

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

## VM Dispatch

The interpreter uses the portable switch dispatch in `libinterp/xec.c` (the
compiler builds a jump table; each iteration is one indirect `br`). The
performance path on this arch is not a cleverer interpreter loop but the JIT
(`comp-aarch64.c` — see ON_JIT.md), which removes dispatch entirely for the
compiled ops and `punt()`s the rest. If interpreter dispatch ever becomes the
bottleneck at `cflag==0`, computed-goto direct threading (a GCC extension:
per-handler `goto *table[op]`) is the standard next step — it gives the
branch predictor one indirect branch site per handler instead of one for the
whole loop.

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

**Key portability issue**: On AArch64, `sizeof(long) == sizeof(void*) == 8`. Code that stores pointers in `long` or `int` variables works on 32-bit but breaks on AArch64; pointer-integer round-trips use `uintptr_t` throughout `lib9/` and `utils/mk/`.

**Struct alignment on AArch64**:
- Natural alignment: each field aligned to its own size
- `int` (4 bytes): aligned to 4
- `long`/`void*` (8 bytes): aligned to 8
- `double` (8 bytes): aligned to 8
- Structs: aligned to largest member; padded to multiple of that alignment

---

## Linux Syscall ABI

emu calls libc, never `svc` directly, so this only matters when reading
kernel-adjacent disassembly or strace: arguments in `x0`–`x7`, syscall number
in `w8`, `svc #0`, result (or negative errno) in `x0`; numbers are the
asm-generic table (`include/uapi/asm-generic/unistd.h`) — AArch64 has no
legacy numbering.

---

## Porting Checklist for the Dis VM

This is what a Dis VM port to a new architecture must cover. On aarch64 every
item is in place — `emu` builds and the full `tests/dis` suite passes under
both the interpreter and the JIT — except the optional LSE fast path.

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
- [x] `uintptr_t` casts — pointer↔integer conversions use `uintptr_t`
- [x] `sizeof(long) == 8` — handled; the whole LP64 dual-ABI model builds and runs
- [x] Struct layout — no hand-coded offsets assume 32-bit pointers (dual-ABI verified)
- [x] Stack alignment — `sp` writes keep 16-byte alignment (JIT runs the full suite)
- [x] JIT cache flush — `segflush-aarch64.c` (`__builtin___clear_cache`) after each compile
- [ ] LSE detection (optional, **not done**) — `aarch64-tas.S` still uses the `ldxr`/`stxr` LL/SC loop; LSE `CASAL`/`SWPAL` fast path is unimplemented (works fine without it)

---

Sources:
- [Arm Architecture Reference Manual (the ARM ARM)](https://developer.arm.com/documentation/ddi0487/latest) — the ground truth for encodings, the memory model, and PSTATE
- [AAPCS64 — Procedure Call Standard for the Arm 64-bit Architecture](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst)
- [Caches and Self-Modifying Code: implementing clear-cache — ARM Community](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/caches-self-modifying-code-implementing-clear-cache)
- [GNU Assembler AArch64 Directives — sourceware.org](https://sourceware.org/binutils/docs/as/AArch64-Directives.html)
- [GCC AArch64 Options — gcc.gnu.org](https://gcc.gnu.org/onlinedocs/gcc/AArch64-Options.html)
- [linux/arch/arm64/include/uapi/asm/sigcontext.h — torvalds/linux](https://github.com/torvalds/linux/blob/master/arch/arm64/include/uapi/asm/sigcontext.h)
- [Enabling PAC and BTI on AArch64 for Linux — ARM Community](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/enabling-pac-and-bti-on-aarch64)
