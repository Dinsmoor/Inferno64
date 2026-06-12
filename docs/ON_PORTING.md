# Porting Inferno — emu hosts, VM archs, native kernels, new boards

> *So you want to port Inferno to something new?* First decide **which kind
> of port** you are doing — they are different jobs with different blast
> radii, and each has its own reference.

## The four kinds of port

| # | You want Inferno on… | What actually changes | Worked example | Where the detail lives |
|---|---|---|---|---|
| 1 | a new **host OS/libc** for hosted emu | `emu/<Host>/` (os.c, devfs, ipif…), `lib9` shims, a mkfile | emu on Linux/aarch64 | **Part I below** (file-by-file) |
| 2 | a new **CPU architecture** (Dis VM + JIT) | `libinterp/comp-<arch>.c` + `das-<arch>.c`, `Inferno/<arch>/include/` (u.h/lib9.h/ureg.h), per-arch lib9 asm (tas, setfcr, getcallerpc), `coherence()` barriers, mkfile | aarch64 | `ON_AARCH64_PORT.md` (register map, calling convention, type widths), `ON_JIT.md`; LP64 hazards in `ON_C_IN_DIS.md` |
| 3 | a **native kernel** on an emulated machine | `os/aarch64/` arch core + `os/boards/<board>/` + picks from `os/drivers/` | `os/boards/virt64` (qemu -M virt: full wm desktop, JIT, net, disk, TLS) | **`os/boards/virt64/README.md`** — layout, image pipeline, gcc-vs-kencc rules, debug workflow |
| 4 | a native kernel on **real hardware** (a new board) | a new `os/boards/<board>/` + new drivers in `os/drivers/` | none yet — BPI-R4 (MediaTek MT7988A) is the parked first target | **Part II below** (what a real board costs) |

The levels stack: 2 underlies both 1-on-a-new-arch and 3; 3 is the proving
ground for 4 (bring drivers up under qemu where you can, on hardware only
where you must).

---

# Part I: porting emu to a new host (Linux/aarch64, as built)

This part is the file-by-file map of the Linux/aarch64 emu port. It assumes
familiarity with the kernel architecture (ON_EMU.md), the build system
(`ON_BUILDING.md` and the root `Makefile`), the JIT (ON_JIT.md), and the LP64/dual-ABI
work (ON_C_IN_DIS.md). For the architecture-level VM reference (register map,
calling convention, type-map widths) see ON_AARCH64_PORT.md.

> **Status: the port is complete and is the primary development target.** Every
> file below now exists in the tree; emu builds and runs (`make all`), the JIT
> works (`emu -c1`), and the test suites pass on Linux/aarch64. This doc therefore
> documents the port **as built** — what each file is and the decisions baked into
> it — not a to-do list. It doubles as the recipe if the port ever has to be
> reconstructed for another arch. **Only Linux/aarch64 has actually been built and
> tested here**; the amd64 glue is in-tree but unbuilt (ON_C_IN_DIS.md).

## What the port consists of

These arch-specific sources are all present in `emu/Linux/` (the historical
"compiled `.o` with no source" gap has been closed — the sources were written):

| Source | Symbols | Role |
|--------|---------|------|
| `asm-aarch64.S` | `umult`, `FPsave`, `FPrestore` | 64×64→128 multiply; FP register save/restore |
| `aarch64-tas.S` | `_tas` | test-and-set spinlock primitive |
| `segflush-aarch64.c` | `segflush` | I-cache flush after JIT codegen |

Plus `lib9/setfcr-Linux-aarch64.S`, `lib9/getcallerpc-Linux-aarch64.S`,
`libinterp/comp-aarch64.c` (the real JIT), and `libinterp/das-aarch64.c` (the
disassembler). The portable `emu/Linux/os.c` is shared across all Linux targets
and is architecture-neutral except for the `coherence` barrier (see below).

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

All three exist in the tree; the listings below document what they contain (and
serve as the reference if they ever have to be regenerated for another arch).

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

**`lib9/getcallerpc-Linux-aarch64.S`** — real, but trivial: returns the link
register (`mov x0, x30; ret`). Not empty.

### JIT / Interpreter Backend (libinterp)

See ON_JIT.md for the full architecture. The original bring-up shipped an
interpreter-only `compile()` stub (`return 0;`) so `cflag>0` degraded gracefully —
**that stub is gone.** Both files are now real:

**`libinterp/comp-aarch64.c`** — the working AArch64 JIT (~1500 lines): real
`compile()` plus the per-opcode native code generators. Off by default; enable
with `emu -c1`. Some opcodes are still punted to the interpreter (ON_JIT.md).
The register map (x19=RREG, x20=RFP, x21=RMP, x24=RLR2, …) lives in ON_JIT.md
/ ON_AARCH64_PORT.md — keep those in sync if you touch the generators.

**`libinterp/das-aarch64.c`** — the AArch64 instruction disassembler (~880 lines,
modelled on `das-arm.c`), used to print generated native code when debugging the
JIT. Not a stub.

## os.c: What Changes for aarch64

`emu/Linux/os.c` is shared across all Linux targets. Almost nothing needs changing for aarch64 specifically:

- **Signal handlers** (`trapILL`, `trapFPE`, `trapmemref`) use `siginfo_t->si_addr` which is portable. No `Ureg` struct is parsed — Inferno's emu just calls `disfault()` with a string. ✓ unchanged.

- **`oslongjmp`** uses `siglongjmp` and ignores the `ucontext_t*` argument (marked `USED`). ✓ unchanged.

- **`coherence`** — **NOT a no-op on aarch64, and not optional.** `coherence()` is
  the release fence `unlock()` (`emu/port/lock.c`) runs between a critical
  section's stores and clearing the lock word. aarch64 is weakly ordered, so this
  **must** be a real barrier: without it, the next thread's `_tas()` can see the
  lock free (its own `dmb` is only an *acquire* fence) while the protected writes
  are not yet visible — it then acts on stale shared state, e.g. the pool
  free-tree links in `alloc.c`, which surfaced as rare, flaky, layout-dependent
  **heap corruption** (the long-hunted aarch64 bug; commit `00e34e0a`). The tree
  now does, in `os.c`:
  ```c
  #ifdef LINUX_AARCH64
  static void fencecoherence(void){ __sync_synchronize(); }  /* emits dmb ish */
  void (*coherence)(void) = fencecoherence;
  #else
  void (*coherence)(void) = nofence;   /* x86 TSO: store order is free */
  #endif
  ```
  Leaving this as `nofence` on aarch64 is exactly the bug that was fixed — do not
  "optimize" it back. 32-bit ARM has the same latent weakness. See memory
  `aarch64-unlock-release-barrier` and ON_C_IN_DIS.md.

- **`libinit()`** calls `kprocinit()` (portable), sets up signal handlers (portable), reads `/etc/passwd` for user info (portable). No arch-specific work.

- **getup()** is in `Linux/aarch64/include/emu.h`, not in `os.c`. ✓

## Bring-up / regression order

This is the sequence the port was brought up in — and the order to re-validate in
if the arch layer is ever disturbed (e.g. a toolchain change):

1. Create all mkfiles and headers. Run `mk 'OBJTYPE=aarch64'` to confirm the build system chains correctly and finds all source files.

2. Build `lib9` and `libkern` for aarch64. Verify `lib9.a` appears in `Linux/aarch64/lib/`.

3. Build `libinterp` with the stub `comp-aarch64.c`. Verify `libinterp.a`.

4. Build the full `emu` binary. At this point the linker will expose any missing symbols.

5. Run `./emu /dis/sh` on aarch64 hardware (or QEMU). The interpreter path should work immediately if the assembly stubs are correct.

6. Test `_tas` correctness: the spinlock must return 0 on first acquire and non-zero on a locked lock. A bug here causes hangs or data races that are hard to diagnose later.

7. The JIT (`comp-aarch64.c`) was implemented after interpreter-only was solid;
   enable it with `emu -c1` and re-run the suites.

## Summary Table (as built)

All present in-tree. "Origin" is the template the file was derived from (if any).

| File | Origin | Notes |
|------|--------|-------|
| `mkfiles/mkfile-Linux-aarch64` | `mkfile-Linux-arm` | compiler/linker flags, `-DLINUX_AARCH64` |
| `emu/Linux/mkfile-aarch64` | `mkfile-arm` | `ARCHFILES` for the emu link |
| `Linux/aarch64/include/emu.h` | `Linux/arm/include/emu.h` | FPU `env[256]`, `getup()`, KSTACK |
| `Linux/aarch64/include/lib9.h` | `Linux/arm/include/lib9.h` | POSIX types; `ulong` is 64-bit (LP64) |
| `Linux/aarch64/include/fpuctl.h` | `Linux/arm/include/fpuctl.h` | empty (as on ARM/386) |
| `emu/Linux/aarch64-tas.S` | `arm-tas-v7.S` | `_tas`: ldxr/stxr + `dmb ish` |
| `emu/Linux/asm-aarch64.S` | none | `umult` (umulh+mul), `FPsave`/`FPrestore` |
| `emu/Linux/segflush-aarch64.c` | `segflush-arm.c` | `__builtin___clear_cache` |
| `lib9/setfcr-Linux-aarch64.S` | none | `mrs/msr fpcr/fpsr` |
| `lib9/getcallerpc-Linux-aarch64.S` | other `getcallerpc-*.S` | `mov x0, x30; ret` |
| `libinterp/comp-aarch64.c` | none | **real JIT** (~1500 lines), `emu -c1` |
| `libinterp/das-aarch64.c` | `das-arm.c` | **real disassembler** (~880 lines) |

---

# Part II: native-kernel ports — emulated machines and real boards

Level 3 (a native kernel under an emulator) is **done once per machine
model** and documented where the code lives: **`os/boards/virt64/README.md`**
covers the whole stack as built for qemu -M virt — the arch-core /
drivers / boards layout, the image pipeline (config → mkdevc/mkroot →
one self-contained ELF), `make HWTARG=<board> USERSPACE=full|headless`,
the gcc-vs-kencc porting rules, and the QMP/gdb debug workflow. Read
that first; this part covers only what is *different about real
hardware*.

## What a real board costs (level 4)

A board is `os/boards/<board>/` — board.h (addresses, IRQs, RAM, MMU
map, PSCI conduit), board.c (hooks), board.mk (driver picks), kernel.ld,
the kernel config — plus whatever `os/drivers/` is missing for its SoC.
The rule that keeps the factoring honest: **nothing in os/aarch64 or
os/drivers takes a board #ifdef** — a board fact belongs in board.h or
behind a hook (`boardinit`/`boardready`/`rtctime`, the `intc*` seam).

What carries over for free: everything above the driver line (Dis/JIT,
draw/Tk, the os/ip stack, devsd/devtls, the baked root), the generic
timer, and l.S (entry, EL2→EL1, vectors, MMU skeleton — feed it the
board's `L1MAPENT0..3`).

What a typical SBC needs that qemu -M virt didn't:

- **Boot protocol**: U-Boot `booti` wants the Linux arm64 Image header
  (a 64-byte stub before `_start`); the ELF-loading luxury is qemu-only.
  U-Boot's TFTP (`dhcp; tftpboot; booti`) is the dev loop — netboot
  until storage works, build dd-able media last.
- **Console UART**: if not PL011, a 16550 driver (~100 lines).
- **Interrupt controller**: GICv2 boards reuse gic-v2.c at a new base;
  modern SoCs need a gic-v3.c (sysreg interface + redistributors) behind
  the same four intc calls.
- **DMA cache coherency** — the trap nobody warns you about: qemu's
  virtio DMA is cache-coherent, so the virt64 drivers never flush.
  Real SoC DMA (SD controllers, NICs) usually is NOT: every DMA driver
  needs dcache clean/invalidate-range discipline around buffers. Write
  the helpers before the first real driver, not after the first
  corruption hunt.
- **Storage**: SDHCI where you're lucky; vendor MMC controllers (e.g.
  MediaTek MSDC) where you're not. U-Boot's drivers are the compact
  porting sources (hundreds of lines, vs. thousands in Linux). devsd
  is portable — a new controller is just an SDifc.
- **Network**: per-SoC MAC + PHY/MDIO (again: port from U-Boot, not
  Linux). devether keeps the driver thin.
- **Entropy/RTC**: SoC TRNG (often behind a TF-A SMC); boards rarely
  have an RTC — the Inferno answer is a userspace SNTP client over the
  net stack, not an I2C driver.
- **Display/input — think namespace first**: a headless board gets a
  graphical session by *importing* a display (mount a remote /dev/draw
  and run wm against it — zero code, works today over styxlisten/mount)
  or *exporting* its screen (a Limbo VNC server over the in-memory
  framebuffer; screen.c renders to a plain Memimage regardless of
  scanout hardware). Writing scanout/USB-HID drivers is the *last*
  resort, not the first step. USB host (xHCI/DWC2 + enumeration + HID)
  is the single biggest driver item on any board — defer it.

First target (parked, future work): **Banana Pi BPI-R4** — MediaTek
MT7988A, 4× Cortex-A73. Delta from virt64: Image header, 16550-compat
UART, **GICv3**, MSDC storage, mtk_eth networking, TRNG via TF-A,
PSCI via `smc` (`BOARD_PSCI_SMC`), no display hardware (namespace
display / VNC export, above). Hardware wiki:
https://www.fw-web.de/dokuwiki/doku.php?id=en:bpi-r4:start — exact
MMIO bases/IRQs from the Linux DTB (mt7988a.dtsi) at bring-up.
