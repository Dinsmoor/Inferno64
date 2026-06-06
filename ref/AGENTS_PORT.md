# Porting emu to Linux/aarch64

This doc covers the concrete file-by-file work for the Linux/aarch64 emu port. It assumes familiarity with the kernel architecture (AGENTS_EMU.md), the build system (`INSTALL` and the root `Makefile`), and the JIT decision (AGENTS_JIT.md).

## Current State

Three pre-compiled `.o` files already exist in `emu/Linux/` with no corresponding source:

| Object | Symbols | Status |
|--------|---------|--------|
| `asm-aarch64.o` | `umult`, `FPsave`, `FPrestore` | compiled, source missing |
| `aarch64-tas.o` | `_tas` | compiled, source missing |
| `segflush-aarch64.o` | `segflush` | compiled, source missing |

Everything else is missing. The portable `emu/Linux/os.c` is largely architecture-neutral and needs only minor verification.

## Complete File Checklist

### Mkfiles

**`mkfiles/mkfile-Linux-aarch64`** — compiler/linker flags.  
Template: `mkfiles/mkfile-Linux-arm`. Change `CPUS`, `CC`/`AS`/`LD` to the aarch64 toolchain, update include path and `-D` flag:

```
TARGMODEL=  Posix
CPUS=       aarch64
O=          o
AR=         ar
ARFLAGS=    ruvs
AS=         aarch64-linux-gnu-gcc -c
CC=         aarch64-linux-gnu-gcc -c
CFLAGS=     -O -Wuninitialized -Wunused-variable -Wreturn-type -Wimplicit \
            -I$ROOT/Linux/aarch64/include \
            -I$ROOT/include \
            -DLINUX_AARCH64
LD=         aarch64-linux-gnu-gcc
LDFLAGS=
YACC=       iyacc
YFLAGS=     -d
```

For native builds (building on aarch64 hardware), replace `aarch64-linux-gnu-gcc` with `gcc`.

**`emu/Linux/mkfile-aarch64`** — sets `ARCHFILES` for the emu link step.  
Template: `emu/Linux/mkfile-arm`:

```
ARCHFILES=\
    aarch64-tas.$O\
```

### Headers

**`Linux/aarch64/include/emu.h`** — three architecture-specific definitions.  
Template: `Linux/arm/include/emu.h`. Three things must change:

1. **FPU struct size**: AArch64 has 32 × 64-bit FP registers (d0–d31) = 256 bytes. ARM32 saves only a 28-byte FP environment.
   ```c
   typedef struct FPU { uchar env[256]; } FPU;   /* was 28 on ARM32 */
   ```

2. **KSTACK**: Stack size per thread. ARM uses 16 KB; match or adjust:
   ```c
   #define KSTACK (16 * 1024)
   ```

3. **`getup()` inline asm**: Reads the stack pointer to find the current `Proc*`. AArch64 assembly syntax omits the `%%` prefix:
   ```c
   static __inline Proc*
   getup(void)
   {
       Proc *p;
       __asm__("mov %0, sp" : "=r"(p));          /* no %% in aarch64 asm */
       return *(Proc**)((uintptr)p & ~(KSTACK-1));
   }
   typedef sigjmp_buf osjmpbuf;
   #define ossetjmp(buf) sigsetjmp(buf, 1)
   ```

**`Linux/aarch64/include/lib9.h`** — POSIX type definitions.  
Template: `Linux/arm/include/lib9.h`. This file pulls in system headers and defines types. The main difference from ARM32 is pointer width (64-bit on aarch64 is already handled by the system headers if you use `uintptr_t`). Copy and review for any 32-bit assumptions.

**`Linux/aarch64/include/fpuctl.h`** — floating-point control. This file is empty on both ARM and 386. Create an empty file.

### Assembly Files

All three need to be written. The compiled `.o` files in the repo can serve as a reference (disassemble with `objdump -d`) if the originals can't be recovered.

---

**`emu/Linux/aarch64-tas.S`** — test-and-set spinlock.  
Template: `emu/Linux/arm-tas-v7.S`. Same algorithm, different instruction mnemonics.

ARM v7 uses `ldxr`/`stxr` (32-bit exclusive load/store) with `dmb`. AArch64 uses the same instructions with updated operand syntax (use `w` registers for 32-bit, `x` for 64-bit; stack pointer is `sp` not `r13`):

```asm
    .file   "aarch64-tas.S"
    .text
    .align  2
    .global _tas
    .type   _tas, %function
_tas:
    dmb     ish             /* full-system memory barrier before */
    mov     x1, x0          /* x1 = pointer to lock word */
    mov     w2, #0xaa       /* sentinel: non-zero = acquired */
tas1:
    ldxr    w0, [x1]        /* load exclusive 32-bit */
    cbnz    w0, lockbusy    /* already locked */
    stxr    w3, w2, [x1]    /* try store exclusive */
    cbnz    w3, tas1        /* retry if store failed */
    dmb     ish             /* barrier after successful acquire */
    ret
lockbusy:
    clrex                   /* abandon exclusive monitor */
    ret                     /* return w0 = non-zero (locked) */
    .size   _tas, .-_tas
```

`_tas` returns 0 (w0=0) if the lock was acquired, non-zero if it was already held. The caller in `lock.c` spins until `_tas` returns 0.

---

**`emu/Linux/asm-aarch64.S`** — `umult`, `FPsave`, `FPrestore`.  
No direct template; write from scratch to the AArch64 ABI (AAPCS64: args in x0–x7, return in x0, callee-saves x19–x28).

```asm
    .file   "asm-aarch64.S"
    .text

/* umult(ulong m1, ulong m2, ulong *hi)
 * Returns m1*m2 low 64 bits in x0; stores high 64 bits at *hi (x2).
 * AArch64: umulh gives the high 64 bits of a 64×64 multiply.
 */
    .global umult
    .type   umult, %function
umult:
    umulh   x3, x0, x1      /* x3 = high 64 bits of x0 * x1 */
    mul     x0, x0, x1      /* x0 = low 64 bits */
    str     x3, [x2]        /* store high into *hi */
    ret
    .size   umult, .-umult

/* FPsave(uchar *ptr)
 * Save all 32 FP registers (d0–d31) = 256 bytes.
 * FPU struct in emu.h must be { uchar env[256]; }.
 */
    .global FPsave
    .type   FPsave, %function
FPsave:
    stp     d0,  d1,  [x0, #0]
    stp     d2,  d3,  [x0, #16]
    stp     d4,  d5,  [x0, #32]
    stp     d6,  d7,  [x0, #48]
    stp     d8,  d9,  [x0, #64]
    stp     d10, d11, [x0, #80]
    stp     d12, d13, [x0, #96]
    stp     d14, d15, [x0, #112]
    stp     d16, d17, [x0, #128]
    stp     d18, d19, [x0, #144]
    stp     d20, d21, [x0, #160]
    stp     d22, d23, [x0, #176]
    stp     d24, d25, [x0, #192]
    stp     d26, d27, [x0, #208]
    stp     d28, d29, [x0, #224]
    stp     d30, d31, [x0, #240]
    ret
    .size   FPsave, .-FPsave

/* FPrestore(uchar *ptr) — reverse of FPsave */
    .global FPrestore
    .type   FPrestore, %function
FPrestore:
    ldp     d0,  d1,  [x0, #0]
    ldp     d2,  d3,  [x0, #16]
    ldp     d4,  d5,  [x0, #32]
    ldp     d6,  d7,  [x0, #48]
    ldp     d8,  d9,  [x0, #64]
    ldp     d10, d11, [x0, #80]
    ldp     d12, d13, [x0, #96]
    ldp     d14, d15, [x0, #112]
    ldp     d16, d17, [x0, #128]
    ldp     d18, d19, [x0, #144]
    ldp     d20, d21, [x0, #160]
    ldp     d22, d23, [x0, #176]
    ldp     d24, d25, [x0, #192]
    ldp     d26, d27, [x0, #208]
    ldp     d28, d29, [x0, #224]
    ldp     d30, d31, [x0, #240]
    ret
    .size   FPrestore, .-FPrestore
```

---

**`emu/Linux/segflush-aarch64.c`** — I-cache coherency after JIT code generation.  
ARM uses an arch-specific Linux syscall (`__ARM_NR_cacheflush`). AArch64 Linux uses the GCC builtin instead:

```c
int
segflush(void *a, ulong n)
{
    if(n)
        __builtin___clear_cache((char*)a, (char*)a + n);
    return 0;
}
```

`__builtin___clear_cache` emits the correct sequence (D-cache clean + I-cache invalidate + DSB + ISB) for the current platform. It is declared in `<stdlib.h>` or available implicitly from GCC.

### lib9 Assembly

**`lib9/setfcr-Linux-aarch64.S`** — floating-point control/status register access.  
`os.c:trapFPE` calls `getfsr()` to read the FP status register. On AArch64 these are system registers:

```asm
    .text
    .global setfcr
    .global getfcr
    .global setfsr
    .global getfsr

/* void setfcr(ulong v) — set FP control register */
setfcr:
    msr     fpcr, x0
    ret

/* ulong getfcr(void) — get FP control register */
getfcr:
    mrs     x0, fpcr
    ret

/* void setfsr(ulong v) — set FP status register */
setfsr:
    msr     fpsr, x0
    ret

/* ulong getfsr(void) — get FP status register */
getfsr:
    mrs     x0, fpsr
    ret
```

**`lib9/getcallerpc-Linux-aarch64.S`** — stub. The implementation is typically inlined via a macro in `lib9.h`; this file can be empty or a minimal stub.

### JIT / Interpreter Backend (libinterp)

See AGENTS_JIT.md for the full decision and architecture. At minimum for a working interpreter-only port:

**`libinterp/comp-aarch64.c`** — stub that returns failure so cflag>0 is handled gracefully:

```c
#include "dat.h"
#include "interp.h"

int
compile(Module *m, int size, Modlink *ml)
{
    USED(m); USED(size); USED(ml);
    return 0;   /* not implemented; interpreter only */
}
```

**`libinterp/das-aarch64.c`** — alias to das-stub behavior. Either create a one-liner or add to `libinterp/mkfile`:

```makefile
das-aarch64.c:N: das-stub.c
comp-aarch64.c:N: comp-stub.c   # if comp-stub.c exists, else use above
```

## os.c: What Changes for aarch64

`emu/Linux/os.c` is shared across all Linux targets. Almost nothing needs changing for aarch64 specifically:

- **Signal handlers** (`trapILL`, `trapFPE`, `trapmemref`) use `siginfo_t->si_addr` which is portable. No `Ureg` struct is parsed — Inferno's emu just calls `disfault()` with a string. ✓ unchanged.

- **`oslongjmp`** uses `siglongjmp` and ignores the `ucontext_t*` argument (marked `USED`). ✓ unchanged.

- **`coherence`** (line 37): `void (*coherence)(void) = nofence;`  
  `coherence()` is called in `lock.c:unlock()` before clearing the lock value, ensuring the write is visible across cores. On x86 this is a no-op (strong memory model). On ARM it should be a `dmb ish`. For aarch64, `nofence` is safe for single-core and adequate for initial bringup. For SMP correctness, add to `libinit()` in `os.c`:
  ```c
  extern void dmb(void);        /* provided in asm-aarch64.S */
  coherence = dmb;
  ```
  Or inline it. This is optional for the initial port.

- **`libinit()`** calls `kprocinit()` (portable), sets up signal handlers (portable), reads `/etc/passwd` for user info (portable). No arch-specific work.

- **getup()** is in `Linux/aarch64/include/emu.h`, not in `os.c`. ✓

## Verification Order

Suggested bring-up sequence:

1. Create all mkfiles and headers. Run `mk 'OBJTYPE=aarch64'` to confirm the build system chains correctly and finds all source files.

2. Build `lib9` and `libkern` for aarch64. Verify `lib9.a` appears in `Linux/aarch64/lib/`.

3. Build `libinterp` with the stub `comp-aarch64.c`. Verify `libinterp.a`.

4. Build the full `emu` binary. At this point the linker will expose any missing symbols.

5. Run `./emu /dis/sh` on aarch64 hardware (or QEMU). The interpreter path should work immediately if the assembly stubs are correct.

6. Test `_tas` correctness: the spinlock must return 0 on first acquire and non-zero on a locked lock. A bug here causes hangs or data races that are hard to diagnose later.

7. Once interpreter-only works, implement `comp-aarch64.c` if JIT performance is needed.

## Summary Table

| File | Lines | Template | Action |
|------|-------|----------|--------|
| `mkfiles/mkfile-Linux-aarch64` | ~25 | `mkfile-Linux-arm` | Create |
| `emu/Linux/mkfile-aarch64` | 2 | `mkfile-arm` | Create |
| `Linux/aarch64/include/emu.h` | ~35 | `Linux/arm/include/emu.h` | Create, change FPU/getup |
| `Linux/aarch64/include/lib9.h` | ~500 | `Linux/arm/include/lib9.h` | Copy, review 64-bit types |
| `Linux/aarch64/include/fpuctl.h` | 0 | `Linux/arm/include/fpuctl.h` | Empty file |
| `emu/Linux/aarch64-tas.S` | ~25 | `arm-tas-v7.S` | Create (ldxr/stxr/dmb) |
| `emu/Linux/asm-aarch64.S` | ~80 | none | Create (umult/FPsave/FPrestore) |
| `emu/Linux/segflush-aarch64.c` | ~8 | `segflush-arm.c` | Create (`__builtin___clear_cache`) |
| `lib9/setfcr-Linux-aarch64.S` | ~25 | none | Create (mrs/msr fpcr/fpsr) |
| `lib9/getcallerpc-Linux-aarch64.S` | ~5 | other getcallerpc-*.S | Stub |
| `libinterp/comp-aarch64.c` | ~10 | none | Stub returning 0 |
| `libinterp/das-aarch64.c` | ~5 | `das-stub.c` | Stub |
